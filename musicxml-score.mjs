import createModule from "./assets/verovio-module.mjs";
import { VerovioToolkit } from "./assets/verovio.mjs";

const SVG_NS = "http://www.w3.org/2000/svg";
const modulePromise = createModule();

function svgElement(tag, attributes = {}) {
  const element = document.createElementNS(SVG_NS, tag);
  Object.entries(attributes).forEach(([name, value]) => element.setAttribute(name, value));
  return element;
}

function xmlId(element) {
  return element?.getAttribute("xml:id") || element?.getAttribute("id") || "";
}

function sanitizeSvg(svg) {
  svg.querySelectorAll("script,foreignObject").forEach(element => element.remove());
  svg.querySelectorAll("*").forEach(element => {
    [...element.attributes].forEach(attribute => {
      const externalLink = attribute.localName === "href" && !attribute.value.startsWith("#");
      if (attribute.name.startsWith("on") || externalLink) element.removeAttributeNode(attribute);
    });
  });
  return svg;
}

function relativeBox(element, root) {
  const box = element.getBBox();
  const rootMatrix = root.getScreenCTM();
  const elementMatrix = element.getScreenCTM();
  if (!rootMatrix || !elementMatrix) return box;
  const matrix = rootMatrix.inverse().multiply(elementMatrix);
  const points = [
    new DOMPoint(box.x, box.y).matrixTransform(matrix),
    new DOMPoint(box.x + box.width, box.y + box.height).matrixTransform(matrix)
  ];
  return {
    x: points[0].x,
    y: points[0].y,
    width: points[1].x - points[0].x,
    height: points[1].y - points[0].y
  };
}

function normalizeScoreText(text) {
  const documentXml = new DOMParser().parseFromString(text, "application/xml");
  if (documentXml.querySelector("parsererror")) throw new Error("MusicXML invalide");
  const durationByUnit = {
    maxima: 32,
    long: 16,
    breve: 8,
    whole: 4,
    half: 2,
    quarter: 1,
    eighth: .5,
    "16th": .25,
    "32nd": .125,
    "64th": .0625
  };
  documentXml.querySelectorAll("direction").forEach(direction => {
    const metronome = direction.querySelector("metronome");
    const perMinute = Number(metronome?.querySelector("per-minute")?.textContent);
    const unit = durationByUnit[metronome?.querySelector("beat-unit")?.textContent];
    if (!(perMinute > 0 && unit) || direction.querySelector("sound[tempo]")) return;
    const dots = metronome.querySelectorAll("beat-unit-dot").length;
    let sound = direction.querySelector("sound");
    if (!sound) {
      sound = documentXml.createElement("sound");
      direction.append(sound);
    }
    sound.setAttribute("tempo", String(perMinute * unit * (2 - 2 ** (-dots))));
  });
  return new XMLSerializer().serializeToString(documentXml);
}

function groupAt(groups, value, key = "time") {
  let low = 0;
  let high = groups.length;
  while (low < high) {
    const middle = (low + high) >> 1;
    if ((Number(groups[middle][key]) || 0) <= value + 1e-6) low = middle + 1;
    else high = middle;
  }
  return Math.max(0, low - 1);
}

export class MusicXmlScoreRenderer {
  constructor({ host, systemsHost, loading, status, onExpectedNotes, onError }) {
    this.host = host;
    this.systemsHost = systemsHost;
    this.loading = loading;
    this.status = status;
    this.onExpectedNotes = onExpectedNotes || (() => {});
    this.onError = onError || (() => {});
    this.systems = [];
    this.notesById = new Map();
    this.measuresById = new Map();
    this.groups = [];
    this.playbackGroups = [];
    this.playbackTotalBeats = 0;
    this.measureRanges = [];
    this.duration = 0;
    this.baseTempo = 120;
    this.pair = -1;
    this.currentSystem = -1;
    this.veilMeasure = null;
    this.active = false;
    this.token = 0;
    this.resizeObserver = new ResizeObserver(() => this.fit());
    this.resizeObserver.observe(this.host);
  }

  setBusy(busy) {
    if (this.loading) this.loading.hidden = !busy;
    this.host.classList.toggle("is-loading", busy);
  }

  async load(source, fileName = "partition.musicxml") {
    const token = ++this.token;
    this.setBusy(true);
    this.clear(false);
    try {
      let data = source;
      if (typeof source === "string" || source instanceof URL) {
        const response = await fetch(source, { cache: "no-cache" });
        if (!response.ok) throw new Error(`MusicXML introuvable (HTTP ${response.status})`);
        data = await response.arrayBuffer();
      } else if (source instanceof Blob) {
        data = await source.arrayBuffer();
      }
      if (token !== this.token) return false;

      this.toolkit?.destroy?.();
      this.toolkit = new VerovioToolkit(await modulePromise);
      this.toolkit.setOptions({
        pageWidth: 2100,
        pageHeight: 3000,
        scale: 40,
        breaks: "auto",
        header: "none",
        footer: "none",
        svgViewBox: true,
        adjustPageHeight: true,
        spacingStaff: 12,
        spacingSystem: 10
      });
      const compressed = String(fileName).toLowerCase().endsWith(".mxl");
      const loaded = compressed
        ? this.toolkit.loadZipDataBuffer(data)
        : this.toolkit.loadData(normalizeScoreText(
            typeof data === "string" ? data : new TextDecoder().decode(data)
          ));
      if (!loaded) throw new Error("Impossible de graver cette partition");

      await this.engrave();
      this.buildTimeline();
      if (!this.systems.length || !this.groups.length) throw new Error("Partition vide ou non reconnue");
      if (token !== this.token) return false;

      this.active = true;
      this.host.hidden = false;
      this.pair = -1;
      this.updateTime(0);
      return true;
    } catch (error) {
      console.error("MusicXML:", error);
      this.clear();
      this.onError(error);
      return false;
    } finally {
      if (token === this.token) this.setBusy(false);
    }
  }

  async engrave() {
    this.systems = [];
    this.notesById = new Map();
    this.measuresById = new Map();
    const mei = new DOMParser().parseFromString(this.toolkit.getMEI(), "application/xml");
    [...mei.querySelectorAll("measure")].forEach((measure, index) => {
      const id = xmlId(measure);
      this.measuresById.set(id, {
        id,
        label: measure.getAttribute("n") || String(index + 1),
        ordinal: index
      });
    });

    const staging = document.createElement("div");
    staging.style.cssText = "position:fixed;left:-20000px;top:0;width:1100px;visibility:hidden";
    document.body.append(staging);
    try {
      for (let page = 1; page <= this.toolkit.getPageCount(); page++) {
        const pageSvg = sanitizeSvg(new DOMParser().parseFromString(
          this.toolkit.renderToSVG(page), "image/svg+xml"
        ).documentElement);
        const definitions = pageSvg.querySelector("defs");
        for (const original of pageSvg.querySelectorAll("g.system")) {
          const svg = svgElement("svg", { xmlns: SVG_NS, viewBox: "0 0 22000 32000" });
          if (definitions) svg.append(definitions.cloneNode(true));
          const style = svgElement("style");
          style.textContent = "text,tspan{font-family:Times New Roman,serif}.tempo,.ending,.fing{font-weight:bold}.dir,.dynam,.mNum{font-style:italic}path{stroke:currentColor}";
          svg.append(style);
          const system = original.cloneNode(true);
          svg.append(system);
          staging.append(svg);

          const bounds = system.getBBox();
          const staffLines = [...system.querySelectorAll("g.staff > path")]
            .map(path => relativeBox(path, svg))
            .filter(box => box.width > 500 && box.height < 2);
          const top = staffLines.length ? Math.min(...staffLines.map(box => box.y)) - 190 : bounds.y;
          const bottom = staffLines.length ? Math.max(...staffLines.map(box => box.y)) + 260 : bounds.y + bounds.height;
          const padding = 150;
          const x = Math.min(bounds.x, 0) - padding;
          const y = Math.min(bounds.y, top) - padding;
          const width = Math.max(bounds.x + bounds.width, 19500) - x + padding;
          const height = Math.max(bounds.y + bounds.height, bottom) - y + padding;
          const model = {
            svg,
            index: this.systems.length,
            top,
            bottom,
            measures: [],
            cursor: null,
            veil: null
          };

          system.querySelectorAll("g.measure").forEach(measure => {
            const meta = this.measuresById.get(measure.id);
            if (!meta) return;
            Object.assign(meta, { system: model.index, box: relativeBox(measure, svg) });
            model.measures.push(meta);
          });
          system.querySelectorAll("g.note,g.rest,g.mRest").forEach(note => {
            const head = note.querySelector(".notehead") || note;
            const box = relativeBox(head, svg);
            const measureMeta = this.measuresById.get(note.closest("g.measure")?.id);
            if (measureMeta) {
              const noteX = box.x + box.width / 2;
              measureMeta.contentStartX = Number.isFinite(measureMeta.contentStartX)
                ? Math.min(measureMeta.contentStartX, noteX)
                : noteX;
            }
            this.notesById.set(note.id, {
              id: note.id,
              element: note,
              system: model.index,
              x: box.x + box.width / 2,
              measure: measureMeta
            });
          });
          model.veil = svgElement("rect", {
            class: "musicxml-measure-veil",
            x: 0,
            y: top,
            width: 0,
            height: bottom - top,
            visibility: "hidden"
          });
          svg.insertBefore(model.veil, system);
          model.cursor = svgElement("line", {
            class: "musicxml-score-cursor",
            y1: top,
            y2: bottom,
            x1: 0,
            x2: 0,
            visibility: "hidden"
          });
          svg.append(model.cursor);
          svg.setAttribute("viewBox", `${x} ${y} ${width} ${height}`);
          svg.style.width = "100%";
          svg.style.height = "auto";
          this.systems.push(model);
          svg.remove();
        }
      }
    } finally {
      staging.remove();
    }
  }

  buildTimeline() {
    const aliases = new Map();
    const alias = id => {
      if (!aliases.has(id)) aliases.set(id, this.toolkit.getNotatedIdForElement(id) || id);
      return aliases.get(id);
    };
    const active = new Map();
    const groups = [];
    let currentMeasure = null;
    const timeMap = this.toolkit.renderToTimemap({
      includeMeasures: true,
      includeRests: true
    });
    timeMap.forEach(event => {
      const time = event.tstamp / 1000;
      const beat = Number.isFinite(Number(event.qstamp)) ? Number(event.qstamp) : null;
      (event.off || []).forEach(id => active.delete(id));
      if (event.measureOn) currentMeasure = this.measuresById.get(alias(event.measureOn)) || currentMeasure;
      const pitches = [];
      (event.on || []).forEach(id => {
        const pitch = this.toolkit.getMIDIValuesForElement(id)?.pitch;
        if (Number.isFinite(pitch)) pitches.push(pitch);
        active.set(id, pitch);
      });
      const ids = [...new Set([...(event.on || []), ...(event.restsOn || [])].map(alias))];
      if (ids.length || event.measureOn) {
        groups.push({ time, beat, ids, pitches: [...new Set(pitches)], measure: currentMeasure, tempo: event.tempo });
      }
    });
    this.baseTempo = timeMap.find(event => event.tempo)?.tempo || 120;
    groups.forEach(group => {
      if (!Number.isFinite(group.beat)) group.beat = group.time * this.baseTempo / 60;
    });
    this.groups = groups;
    this.playbackGroups = groups;
    this.duration = Math.max(0, ...timeMap.map(event => event.tstamp / 1000));
    groups.forEach(group => { group.playbackBeat = group.beat; });
    this.buildMeasureRanges();
  }

  scoreBeatToPlaybackBeat(scoreBeat, anchors) {
    const value = Math.max(0, Number(scoreBeat) || 0);
    const points = Array.from(anchors || [])
      .filter(group => Number.isFinite(group.beat) && Number.isFinite(group.playbackBeat))
      .sort((left, right) => left.beat - right.beat);
    if (!points.length) return value;
    if (points.length === 1) return Math.max(0, points[0].playbackBeat + value - points[0].beat);
    let rightIndex = points.findIndex(point => point.beat >= value - 1e-6);
    if (rightIndex < 0) rightIndex = points.length;
    const right = points[Math.min(points.length - 1, rightIndex)];
    const left = points[Math.max(0, rightIndex - 1)];
    if (left === right || Math.abs(right.beat - left.beat) < 1e-6) {
      const neighbour = rightIndex <= 0 ? points[1] : points[points.length - 2];
      const scoreSpan = right.beat - neighbour.beat;
      const playbackSpan = right.playbackBeat - neighbour.playbackBeat;
      const slope = Math.abs(scoreSpan) > 1e-6 ? playbackSpan / scoreSpan : 1;
      return Math.max(0, right.playbackBeat + (value - right.beat) * slope);
    }
    const progress = (value - left.beat) / (right.beat - left.beat);
    return Math.max(0, left.playbackBeat + (right.playbackBeat - left.playbackBeat) * progress);
  }

  buildMeasureRanges(anchors = this.groups) {
    const measures = [...this.measuresById.values()].sort((left, right) => left.ordinal - right.ordinal);
    const scoreEndBeat = Math.max(0, this.duration * Math.max(1, this.baseTempo) / 60);
    const starts = measures.map((measure, index) => {
      const beats = this.groups
        .filter(group => group.measure?.id === measure.id && Number.isFinite(group.beat))
        .map(group => group.beat);
      if (beats.length) return Math.min(...beats);
      return index ? null : 0;
    });
    for (let index = 0; index < starts.length; index++) {
      if (Number.isFinite(starts[index])) continue;
      const previous = index > 0 && Number.isFinite(starts[index - 1]) ? starts[index - 1] : 0;
      let nextIndex = index + 1;
      while (nextIndex < starts.length && !Number.isFinite(starts[nextIndex])) nextIndex++;
      const next = nextIndex < starts.length ? starts[nextIndex] : scoreEndBeat;
      starts[index] = previous + (next - previous) / Math.max(1, nextIndex - index + 1);
    }
    this.measureRanges = measures.map((measure, index) => {
      const scoreStart = Math.max(0, Number(starts[index]) || 0);
      const scoreEnd = index + 1 < starts.length
        ? Math.max(scoreStart, Number(starts[index + 1]) || scoreStart)
        : Math.max(scoreStart, scoreEndBeat);
      return {
        index: index + 1,
        label: measure.label || String(index + 1),
        startBeat: this.scoreBeatToPlaybackBeat(scoreStart, anchors),
        endBeat: this.scoreBeatToPlaybackBeat(scoreEnd, anchors)
      };
    }).filter((range, index, ranges) => {
      if (index && range.startBeat < ranges[index - 1].startBeat) range.startBeat = ranges[index - 1].startBeat;
      range.endBeat = Math.max(range.startBeat + .125, range.endBeat);
      return Number.isFinite(range.startBeat) && Number.isFinite(range.endBeat);
    });
  }

  getMeasureRanges() {
    return this.measureRanges.map(range => ({ ...range }));
  }

  getPlaybackData() {
    const musicalGroups = this.groups.filter(group => group.pitches.length && Number.isFinite(group.beat));
    const notes = [];
    musicalGroups.forEach((group, index) => {
      const next = musicalGroups[index + 1];
      const durationBeats = Math.max(.125, next ? next.beat - group.beat : 1);
      group.pitches.forEach(pitch => notes.push({
        pitch,
        beat: group.beat,
        durationBeats,
        soundDurationBeats: durationBeats,
        velocity: 82,
        channel: 0
      }));
    });
    const totalBeats = Math.max(.125, this.duration * Math.max(1, this.baseTempo) / 60);
    const firstMeasure = this.measureRanges[0];
    const beatsPerMeasure = firstMeasure
      ? Math.max(1, Math.round(firstMeasure.endBeat - firstMeasure.startBeat))
      : 4;
    return {
      notes,
      totalBeats,
      bpm: Math.max(1, Number(this.baseTempo) || 120),
      timeSignature: { num: beatsPerMeasure, den: 4 }
    };
  }

  setMidiNotes(notes, totalBeats = 0) {
    const events = Array.from(notes || [])
      .map(note => ({ beat: Number(note.beat), pitch: Number(note.midi ?? note.pitch) }))
      .filter(note => Number.isFinite(note.beat) && Number.isFinite(note.pitch))
      .sort((a, b) => a.beat - b.beat || a.pitch - b.pitch);
    const midiGroups = [];
    events.forEach(note => {
      let group = midiGroups[midiGroups.length - 1];
      if (!group || note.beat - group.beat > .12) {
        group = { beat: note.beat, pitches: [] };
        midiGroups.push(group);
      }
      if (!group.pitches.includes(note.pitch)) group.pitches.push(note.pitch);
    });
    midiGroups.forEach(group => group.pitches.sort((a, b) => a - b));
    const scoreGroups = this.groups.filter(group => group.pitches.length);
    this.playbackTotalBeats = Math.max(0, Number(totalBeats) || 0);
    if (!midiGroups.length || !scoreGroups.length) {
      this.playbackGroups = this.groups;
      this.buildMeasureRanges();
      return;
    }

    const rows = scoreGroups.length + 1;
    const columns = midiGroups.length + 1;
    const gap = 1.25;
    const costs = Array.from({ length: rows }, () => new Float64Array(columns));
    const steps = Array.from({ length: rows }, () => new Uint8Array(columns));
    for (let i = 1; i < rows; i++) { costs[i][0] = i * gap; steps[i][0] = 1; }
    for (let j = 1; j < columns; j++) { costs[0][j] = j * gap; steps[0][j] = 2; }
    const difference = (left, right) => {
      const a = new Set(left);
      const b = new Set(right);
      let shared = 0;
      a.forEach(pitch => { if (b.has(pitch)) shared++; });
      const delta = a.size + b.size - shared * 2;
      return delta === 0 ? 0 : 2 + delta * .55;
    };
    for (let i = 1; i < rows; i++) {
      for (let j = 1; j < columns; j++) {
        const diagonal = costs[i - 1][j - 1] + difference(scoreGroups[i - 1].pitches, midiGroups[j - 1].pitches);
        const skipScore = costs[i - 1][j] + gap;
        const skipMidi = costs[i][j - 1] + gap;
        if (diagonal <= skipScore && diagonal <= skipMidi) { costs[i][j] = diagonal; steps[i][j] = 0; }
        else if (skipScore <= skipMidi) { costs[i][j] = skipScore; steps[i][j] = 1; }
        else { costs[i][j] = skipMidi; steps[i][j] = 2; }
      }
    }
    const anchors = [];
    let row = scoreGroups.length;
    let column = midiGroups.length;
    while (row > 0 || column > 0) {
      const step = steps[row][column];
      if (row > 0 && column > 0 && step === 0) {
        anchors.push([row - 1, column - 1]);
        row--;
        column--;
      } else if (row > 0 && (column === 0 || step === 1)) row--;
      else column--;
    }
    anchors.reverse();
    if (!anchors.length) {
      scoreGroups.forEach((group, index) => {
        const midiIndex = Math.round(index * (midiGroups.length - 1) / Math.max(1, scoreGroups.length - 1));
        group.playbackBeat = midiGroups[midiIndex].beat;
      });
    } else {
      anchors.forEach(([scoreIndex, midiIndex]) => { scoreGroups[scoreIndex].playbackBeat = midiGroups[midiIndex].beat; });
      for (let index = 0; index < scoreGroups.length; index++) {
        if (Number.isFinite(scoreGroups[index].playbackBeat)) continue;
        let previous = index - 1;
        let next = index + 1;
        while (previous >= 0 && !Number.isFinite(scoreGroups[previous].playbackBeat)) previous--;
        while (next < scoreGroups.length && !Number.isFinite(scoreGroups[next].playbackBeat)) next++;
        if (previous >= 0 && next < scoreGroups.length) {
          const progress = (index - previous) / (next - previous);
          scoreGroups[index].playbackBeat = scoreGroups[previous].playbackBeat
            + (scoreGroups[next].playbackBeat - scoreGroups[previous].playbackBeat) * progress;
        } else if (previous >= 0) {
          const spacing = previous > 0
            ? Math.max(.01, scoreGroups[previous].playbackBeat - scoreGroups[previous - 1].playbackBeat)
            : 1;
          scoreGroups[index].playbackBeat = scoreGroups[previous].playbackBeat + spacing * (index - previous);
        } else {
          const spacing = next + 1 < scoreGroups.length
            ? Math.max(.01, scoreGroups[next + 1].playbackBeat - scoreGroups[next].playbackBeat)
            : 1;
          scoreGroups[index].playbackBeat = Math.max(0, scoreGroups[next].playbackBeat - spacing * (next - index));
        }
      }
    }
    this.playbackGroups = scoreGroups;
    this.buildMeasureRanges(scoreGroups);
  }

  showSystem(systemIndex) {
    if (systemIndex === this.currentSystem && this.systemsHost.firstElementChild) return;
    this.pair = systemIndex;
    this.currentSystem = systemIndex;
    this.systemsHost.replaceChildren();
    this.systemsHost.classList.add("single");
    const model = this.systems[systemIndex];
    if (!model) return;
    const slot = document.createElement("div");
    slot.className = "musicxml-system-slot";
    slot.dataset.system = String(model.index);
    slot.append(model.svg);
    this.systemsHost.append(slot);
    this.fit();
  }

  fit() {
    [...this.systemsHost.children].forEach(slot => {
      const svg = slot.querySelector("svg");
      if (!svg) return;
      const box = svg.viewBox.baseVal;
      if (!(box.width > 0 && box.height > 0)) return;
      const availableWidth = Math.max(1, slot.clientWidth);
      const availableHeight = Math.max(1, slot.clientHeight);
      const scale = Math.min(availableWidth / box.width, availableHeight / box.height);
      svg.style.width = `${box.width * scale}px`;
      svg.style.height = `${box.height * scale}px`;
    });
  }

  paintVeil(model, measure, cursorX) {
    if (!model?.veil || !measure?.box) return;
    // L’armure, la clé et la signature rythmique précèdent la première note :
    // le voile de progression ne doit jamais les recouvrir.
    const startX = Number.isFinite(measure.contentStartX)
      ? Math.max(measure.box.x, measure.contentStartX)
      : measure.box.x;
    const endX = measure.box.x + measure.box.width;
    const width = Math.max(0, Math.min(endX - startX, cursorX - startX));
    model.veil.setAttribute("x", startX);
    model.veil.setAttribute("width", width);
    model.veil.setAttribute("visibility", "visible");
  }

  paintMeasureEnd(playbackBeat, bpm) {
    const value = Math.max(0, Number(playbackBeat) || 0);
    const rangeIndex = this.measureRanges.findIndex(range => Math.abs(range.endBeat - value) <= .03);
    if (rangeIndex < 0) return false;
    const measure = [...this.measuresById.values()]
      .sort((left, right) => left.ordinal - right.ordinal)[rangeIndex];
    const model = this.systems[measure?.system];
    if (!measure?.box || !model) return false;
    this.showSystem(measure.system);
    this.systems.forEach(system => {
      system.cursor?.setAttribute("visibility", "hidden");
      system.veil?.setAttribute("visibility", "hidden");
    });
    const barlineX = measure.box.x + measure.box.width;
    model.cursor.setAttribute("x1", barlineX);
    model.cursor.setAttribute("x2", barlineX);
    model.cursor.setAttribute("visibility", "visible");
    this.paintVeil(model, measure, barlineX);
    this.systemsHost.querySelectorAll(".musicxml-current-note").forEach(element => {
      element.classList.remove("musicxml-current-note");
    });
    this.onExpectedNotes([]);
    if (this.status) {
      const safeBpm = Math.max(1, Number(bpm) || this.baseTempo || 120);
      const totalSeconds = this.playbackTotalBeats > 0
        ? this.playbackTotalBeats * 60 / safeBpm
        : this.duration;
      this.status.textContent = `Mesure ${measure.label || rangeIndex + 1} · ${this.formatTime(value * 60 / safeBpm)} / ${this.formatTime(totalSeconds)}`;
    }
    return true;
  }

  updatePosition(position, key, elapsedSeconds, groups = this.groups, totalSeconds = this.duration) {
    if (!this.active || !groups.length) return;
    const value = Math.max(0, Number(position) || 0);
    const index = groupAt(groups, value, key);
    const group = groups[index];
    let note = group.ids.map(id => this.notesById.get(id)).find(Boolean);
    if (!note && group.measure?.system !== undefined) {
      note = { system: group.measure.system, x: group.measure.box.x + 100 };
    }
    if (note) {
      let movingX = note.x;
      for (let nextIndex = index + 1; nextIndex < groups.length; nextIndex++) {
        const nextGroup = groups[nextIndex];
        const nextNote = nextGroup.ids.map(id => this.notesById.get(id)).find(Boolean);
        if (!nextNote) continue;
        if (nextNote.system === note.system && nextGroup[key] > group[key]) {
          const progress = Math.max(0, Math.min(1, (value - group[key]) / (nextGroup[key] - group[key])));
          movingX = note.x + (nextNote.x - note.x) * progress;
        }
        break;
      }
      this.showSystem(note.system);
      this.currentSystem = note.system;
      this.systems.forEach(model => {
        model.cursor?.setAttribute("visibility", "hidden");
        model.veil?.setAttribute("visibility", "hidden");
      });
      const model = this.systems[note.system];
      if (model?.cursor) {
        model.cursor.setAttribute("x1", movingX);
        model.cursor.setAttribute("x2", movingX);
        model.cursor.setAttribute("visibility", "visible");
        this.paintVeil(model, group.measure || note.measure, movingX);
      }
    }
    this.systemsHost.querySelectorAll(".musicxml-current-note").forEach(element => {
      element.classList.remove("musicxml-current-note");
    });
    group.ids.forEach(id => this.notesById.get(id)?.element.classList.add("musicxml-current-note"));
    this.onExpectedNotes(group.pitches);
    if (this.status) {
      const measure = group.measure?.label || "—";
      this.status.textContent = `Mesure ${measure} · ${this.formatTime(elapsedSeconds)} / ${this.formatTime(totalSeconds)}`;
    }
  }

  updateTime(seconds) {
    this.updatePosition(seconds, "time", seconds);
  }

  updateBeat(beat, bpm, options = {}) {
    const safeBpm = Math.max(1, Number(bpm) || this.baseTempo || 120);
    const safeBeat = Math.max(0, Number(beat) || 0);
    if (options.atMeasureEnd && this.paintMeasureEnd(safeBeat, safeBpm)) return;
    const totalSeconds = this.playbackTotalBeats > 0 ? this.playbackTotalBeats * 60 / safeBpm : this.duration;
    const groups = this.playbackGroups.length ? this.playbackGroups : this.groups;
    const key = groups === this.groups ? "beat" : "playbackBeat";
    this.updatePosition(safeBeat, key, safeBeat * 60 / safeBpm, groups, totalSeconds);
  }

  formatTime(seconds) {
    const value = Math.max(0, Math.floor(Number(seconds) || 0));
    return `${Math.floor(value / 60)}:${String(value % 60).padStart(2, "0")}`;
  }

  clear(hide = true) {
    this.active = false;
    this.systemsHost.replaceChildren();
    this.systems = [];
    this.notesById.clear();
    this.measuresById.clear();
    this.groups = [];
    this.playbackGroups = [];
    this.playbackTotalBeats = 0;
    this.measureRanges = [];
    this.pair = -1;
    this.currentSystem = -1;
    this.veilMeasure = null;
    if (hide) this.host.hidden = true;
    this.onExpectedNotes([]);
    if (this.status) this.status.textContent = "";
  }
}
