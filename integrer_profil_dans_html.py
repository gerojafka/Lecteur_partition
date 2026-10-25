#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import json
import os
import subprocess
import sys
from pathlib import Path

MARKER_BEGIN = "/* === PROFILS VOCAUX INTEGRES PAR SCRIPT : DEBUT === */"
MARKER_END   = "/* === PROFILS VOCAUX INTEGRES PAR SCRIPT : FIN === */"


def strip_quotes(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1]
    return value


def script_dir() -> Path:
    return Path(__file__).resolve().parent


def find_source_html() -> Path:
    base = script_dir()

    # Fichier attendu en priorité : aucune question inutile si présent.
    preferred = base / "lecture-notes_PC_iPad.html"
    if preferred.is_file():
        return preferred

    # Sinon, chercher automatiquement un HTML de l'application.
    html_files = [
        p for p in base.iterdir()
        if p.is_file()
        and p.suffix.lower() == ".html"
        and "_profil_integre" not in p.stem.lower()
    ]

    if len(html_files) == 1:
        return html_files[0]

    # En dernier recours seulement, demander le HTML par une fenêtre Windows.
    try:
        import tkinter as tk
        from tkinter import filedialog
        root = tk.Tk()
        root.withdraw()
        root.attributes("-topmost", True)
        chosen = filedialog.askopenfilename(
            title="Choisir le fichier HTML de l'application",
            initialdir=str(base),
            filetypes=[("Fichiers HTML", "*.html"), ("Tous les fichiers", "*.*")]
        )
        root.destroy()
        if chosen:
            return Path(chosen)
    except Exception:
        pass

    raise FileNotFoundError(
        "Impossible de déterminer automatiquement le fichier HTML. "
        "Placez lecture-notes_PC_iPad.html dans le même dossier que ce script."
    )


def choose_json_profile() -> Path:
    base = script_dir()

    # Fenêtre native Windows, ouverte directement dans le dossier du script.
    # Elle n'affiche que les fichiers JSON.
    try:
        import tkinter as tk
        from tkinter import filedialog

        root = tk.Tk()
        root.withdraw()
        root.attributes("-topmost", True)

        chosen = filedialog.askopenfilename(
            title="Choisir le profil vocal JSON",
            initialdir=str(base),
            filetypes=[
                ("Profils JSON", "*.json"),
                ("Tous les fichiers", "*.*")
            ]
        )
        root.destroy()

        if chosen:
            return Path(chosen)

    except Exception as exc:
        print("La fenêtre de sélection n'a pas pu être ouverte :", exc)

    # Secours console : filtre insensible à la casse (.json, .JSON, etc.).
    json_files = sorted(
        [
            p for p in base.iterdir()
            if p.is_file() and p.suffix.lower() == ".json"
        ],
        key=lambda p: p.name.lower()
    )

    if not json_files:
        raise FileNotFoundError(
            f"Aucun fichier JSON trouvé dans : {base}"
        )

    print()
    print("Profils JSON présents :")
    for i, p in enumerate(json_files, 1):
        print(f"  {i}. {p.name}")

    while True:
        raw = input("Numéro du profil JSON : ").strip()
        if raw.isdigit() and 1 <= int(raw) <= len(json_files):
            return json_files[int(raw) - 1]
        print("Choix invalide.")



def load_payload(json_path: Path):
    with json_path.open("r", encoding="utf-8-sig") as f:
        data = json.load(f)

    if isinstance(data, dict) and isinstance(data.get("profiles"), list):
        profiles = data["profiles"]
        active_id = str(data.get("activeProfileId") or "")
    elif isinstance(data, dict) and isinstance(data.get("profile"), dict):
        profiles = [data["profile"]]
        active_id = str(data.get("activeProfileId") or "")
    elif isinstance(data, dict):
        profiles = [data]
        active_id = str(data.get("id") or "")
    else:
        raise ValueError("Le JSON ne contient pas un profil vocal valide.")

    if not profiles:
        raise ValueError("Aucun profil trouvé dans le fichier JSON.")

    for i, profile in enumerate(profiles, 1):
        if not isinstance(profile, dict):
            raise ValueError(f"Le profil n°{i} n'est pas un objet JSON.")
        if not str(profile.get("name") or "").strip():
            raise ValueError(f"Le profil n°{i} n'a pas de nom.")
        audio = profile.get("audioSamples")
        if not isinstance(audio, list) or len(audio) != 7:
            raise ValueError(
                f"Le profil « {profile.get('name','?')} » ne contient pas "
                "les 7 groupes audio attendus."
            )

    return {
        "app": "lecture-notes",
        "version": 2,
        "activeProfileId": active_id,
        "profiles": profiles,
    }


def remove_previous_injection(html: str) -> str:
    start = html.find(MARKER_BEGIN)
    if start == -1:
        return html

    end = html.find(MARKER_END, start)
    if end == -1:
        raise RuntimeError("Une ancienne intégration a été trouvée mais sa fin est absente.")

    end += len(MARKER_END)
    while end < len(html) and html[end] in "\r\n":
        end += 1
    return html[:start] + html[end:]


def build_injection(payload) -> str:
    payload_js = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).replace("</", "<\\/")

    template = r'''
  __MARKER_BEGIN__
  const EMBEDDED_VOICE_PROFILES_PAYLOAD = __PAYLOAD__;

  function loadEmbeddedVoiceProfiles() {
    try {
      const imported = EMBEDDED_VOICE_PROFILES_PAYLOAD;
      const rawProfiles = Array.isArray(imported && imported.profiles)
        ? imported.profiles
        : [];

      const embeddedProfiles = rawProfiles
        .map((value) => sanitizeVoiceProfile(value))
        .filter((profile) => profile && hasCompleteAcousticProfile(profile));

      if (!embeddedProfiles.length) return;

      embeddedProfiles.forEach((profile) => {
        profile.id = voiceProfileIdForName(profile.name);
        if (!state.voiceProfiles[profile.id]) {
          state.voiceProfiles[profile.id] = profile;
        }
      });

      if (!state.voiceProfileId) {
        const requestedId = String(imported.activeProfileId || "");
        let selected = embeddedProfiles.find((profile) => profile.id === requestedId);

        if (!selected && requestedId) {
          selected = embeddedProfiles.find(
            (profile) => voiceProfileIdForName(profile.name) === requestedId
          );
        }

        if (!selected) selected = embeddedProfiles[embeddedProfiles.length - 1];
        state.voiceProfileId = selected ? selected.id : null;
      }

      refreshAcousticModel();
      saveVoiceProfiles();
    } catch (error) {
      console.error("Erreur lors du chargement du profil vocal intégré :", error);
    }
  }
  __MARKER_END__
'''
    return (template
            .replace("__MARKER_BEGIN__", MARKER_BEGIN)
            .replace("__MARKER_END__", MARKER_END)
            .replace("__PAYLOAD__", payload_js))


def integrate(html_path: Path, json_path: Path, output_path: Path):
    payload = load_payload(json_path)
    html = html_path.read_text(encoding="utf-8-sig", errors="strict")
    html = remove_previous_injection(html)

    init_marker = "  loadVoiceProfiles();"
    pos = html.rfind(init_marker)
    if pos == -1:
        raise RuntimeError("Impossible de trouver « loadVoiceProfiles(); » dans le HTML.")

    injection = build_injection(payload)
    html = html[:pos] + injection + "\n" + html[pos:]

    old_init = "  loadVoiceProfiles();\n  applyI18n();"
    new_init = "  loadVoiceProfiles();\n  loadEmbeddedVoiceProfiles();\n  applyI18n();"
    if old_init not in html:
        raise RuntimeError("Initialisation finale inattendue : intégration annulée.")
    html = html.replace(old_init, new_init, 1)

    output_path.write_text(html, encoding="utf-8")

    names = [str(p.get("name", "?")) for p in payload["profiles"]]
    print()
    print("Intégration terminée.")
    print("Profil(s) intégré(s) :", ", ".join(names))
    print("HTML créé :", output_path.resolve())
    print()
    print("Le profil vocal est maintenant contenu directement dans le HTML.")
    print("Sur un appareil neuf, il sera chargé automatiquement.")


def main():
    try:
        if len(sys.argv) >= 3:
            html_path = Path(strip_quotes(sys.argv[1])).expanduser()
            json_path = Path(strip_quotes(sys.argv[2])).expanduser()
        else:
            print("=== Intégration d'un profil vocal dans le HTML ===")
            print()
            html_path = find_source_html()
            json_path = choose_json_profile()
            print("HTML utilisé :", html_path.name)
            print("Profil choisi :", json_path.name)

        if not html_path.is_file():
            raise FileNotFoundError(html_path)
        if not json_path.is_file():
            raise FileNotFoundError(json_path)

        if len(sys.argv) >= 4:
            output_path = Path(strip_quotes(sys.argv[3])).expanduser()
        else:
            base = script_dir()
            default = base / (html_path.stem + "_profil_integre.html")
            raw = input(f"Fichier de sortie [Entrée = {default}] : ").strip()
            if raw:
                candidate = Path(strip_quotes(raw)).expanduser()
                output_path = candidate if candidate.is_absolute() else base / candidate
            else:
                output_path = default

        integrate(html_path, json_path, output_path)

    except Exception as exc:
        print()
        print("ERREUR :", exc)
        print()
        if sys.stdin.isatty():
            input("Appuyez sur Entrée pour fermer...")
        sys.exit(1)


if __name__ == "__main__":
    main()
