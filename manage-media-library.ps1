[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('list', 'open-library', 'add', 'add-batch', 'add-guided', 'remove', 'remove-numbered', 'remove-batch')]
  [string]$Action,

  [string]$Midi,
  [string]$Video,
  [string]$Audio,
  [string]$Title,
  [string]$Id
)

$projectRoot = Split-Path -Parent $PSScriptRoot
$libraryRoot = Join-Path $projectRoot 'media-library'
$piecesRoot = Join-Path $libraryRoot 'pieces'
$catalogPath = Join-Path $libraryRoot 'catalog.json'

function Read-Catalog {
  if (-not (Test-Path -LiteralPath $catalogPath)) {
    return [pscustomobject]@{ version = 1; pieces = @() }
  }
  $catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
  if ($null -eq $catalog.pieces) { $catalog | Add-Member -NotePropertyName pieces -NotePropertyValue @() }
  return $catalog
}

function Save-Catalog($catalog) {
  $catalog | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $catalogPath -Encoding utf8
}

function New-Slug([string]$value) {
  $slug = $value.ToLowerInvariant() -replace '[^a-z0-9]+', '-'
  $slug = $slug.Trim('-')
  if ([string]::IsNullOrWhiteSpace($slug)) { $slug = 'morceau' }
  return $slug
}

function Copy-MediaFile([string]$source, [string]$destinationFolder) {
  if ([string]::IsNullOrWhiteSpace($source)) { return $null }
  $resolved = (Resolve-Path -LiteralPath $source -ErrorAction Stop).Path
  $fileName = Split-Path -Leaf $resolved
  Copy-Item -LiteralPath $resolved -Destination (Join-Path $destinationFolder $fileName) -Force
  return $fileName
}

function Select-MidiFiles([string]$title = 'Choisir un ou plusieurs fichiers MIDI') {
  Add-Type -AssemblyName System.Windows.Forms
  $dialog = New-Object System.Windows.Forms.OpenFileDialog
  $dialog.Title = $title
  $dialog.Filter = 'Fichiers MIDI (*.mid;*.midi)|*.mid;*.midi|Tous les fichiers (*.*)|*.*'
  $dialog.Multiselect = $true
  $dialog.CheckFileExists = $true
  $dialog.RestoreDirectory = $true
  if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return @() }
  return @($dialog.FileNames)
}

function Select-MediaFile([string]$title, [string]$filter) {
  Add-Type -AssemblyName System.Windows.Forms
  $dialog = New-Object System.Windows.Forms.OpenFileDialog
  $dialog.Title = $title
  $dialog.Filter = "$filter|Tous les fichiers (*.*)|*.*"
  $dialog.Multiselect = $false
  $dialog.CheckFileExists = $true
  $dialog.RestoreDirectory = $true
  if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
  return $dialog.FileName
}

New-Item -ItemType Directory -Force -Path $piecesRoot | Out-Null
$catalog = Read-Catalog

switch ($Action) {
  'list' {
    if (-not @($catalog.pieces).Count) { Write-Output 'La bibliothèque est vide.'; break }
    $catalog.pieces | ForEach-Object {
      $media = if ($_.video) { 'MIDI + MP4' } elseif ($_.audio) { 'MIDI + MP3' } else { 'MIDI' }
      Write-Output ("{0}  |  {1}  |  {2}" -f $_.id, $_.title, $media)
    }
  }
  'open-library' {
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $libraryRoot)
    Write-Output "Bibliothèque ouverte : $libraryRoot"
  }
  'add' {
    if ([string]::IsNullOrWhiteSpace($Midi)) { throw 'Ajoutez un fichier MIDI avec -Midi.' }
    if (-not (Test-Path -LiteralPath $Midi)) { throw "MIDI introuvable : $Midi" }
    if ($Video -and -not (Test-Path -LiteralPath $Video)) { throw "MP4 introuvable : $Video" }
    if ($Audio -and -not (Test-Path -LiteralPath $Audio)) { throw "MP3 introuvable : $Audio" }
    $extension = [System.IO.Path]::GetExtension($Midi).ToLowerInvariant()
    if ($extension -notin '.mid', '.midi') { throw 'Le fichier -Midi doit être au format .mid ou .midi.' }
    if ($Video -and [System.IO.Path]::GetExtension($Video).ToLowerInvariant() -ne '.mp4') { throw 'Le fichier -Video doit être au format .mp4.' }
    if ($Audio -and [System.IO.Path]::GetExtension($Audio).ToLowerInvariant() -ne '.mp3') { throw 'Le fichier -Audio doit être au format .mp3.' }

    $displayTitle = if ($Title) { $Title.Trim() } else { [System.IO.Path]::GetFileNameWithoutExtension($Midi) }
    $pieceId = if ($Id) { New-Slug $Id } else { New-Slug $displayTitle }
    if (@($catalog.pieces | Where-Object { $_.id -eq $pieceId }).Count) { throw "Un morceau porte déjà l’identifiant : $pieceId" }
    $pieceFolder = Join-Path $piecesRoot $pieceId
    New-Item -ItemType Directory -Force -Path $pieceFolder | Out-Null
    try {
      $midiName = Copy-MediaFile $Midi $pieceFolder
      $videoName = Copy-MediaFile $Video $pieceFolder
      $audioName = Copy-MediaFile $Audio $pieceFolder
      $piece = [ordered]@{ id = $pieceId; title = $displayTitle; midi = "pieces/$pieceId/$midiName" }
      if ($videoName) { $piece.video = "pieces/$pieceId/$videoName" }
      if ($audioName) { $piece.audio = "pieces/$pieceId/$audioName" }
      $catalog.pieces = @($catalog.pieces) + [pscustomobject]$piece
      Save-Catalog $catalog
      Write-Output "Ajouté : $displayTitle ($pieceId)"
    } catch {
      if (Test-Path -LiteralPath $pieceFolder) { Remove-Item -LiteralPath $pieceFolder -Recurse -Force }
      throw
    }
  }
  'add-batch' {
    $midiFiles = Select-MidiFiles
    if (-not $midiFiles.Count) { Write-Output 'Aucun fichier sélectionné.'; break }
    $added = 0
    $skipped = 0
    foreach ($midiFile in $midiFiles) {
      $sourceFolder = Split-Path -Parent $midiFile
      $baseName = [System.IO.Path]::GetFileNameWithoutExtension($midiFile)
      $matchingVideo = Join-Path $sourceFolder ($baseName + '.mp4')
      if (-not (Test-Path -LiteralPath $matchingVideo)) {
        Write-Warning "MP4 correspondant introuvable : $baseName.mp4 - MIDI ignoré."
        $skipped++
        continue
      }
      $displayTitle = [System.IO.Path]::GetFileNameWithoutExtension($midiFile)
      $baseId = New-Slug $displayTitle
      $pieceId = $baseId
      $number = 2
      while (@($catalog.pieces | Where-Object { $_.id -eq $pieceId }).Count) {
        $pieceId = "$baseId-$number"
        $number++
      }
      $pieceFolder = Join-Path $piecesRoot $pieceId
      New-Item -ItemType Directory -Force -Path $pieceFolder | Out-Null
      try {
        $midiName = Copy-MediaFile $midiFile $pieceFolder
        $videoName = Copy-MediaFile $matchingVideo $pieceFolder
        $piece = [ordered]@{ id = $pieceId; title = $displayTitle; midi = "pieces/$pieceId/$midiName"; video = "pieces/$pieceId/$videoName" }
        $catalog.pieces = @($catalog.pieces) + [pscustomobject]$piece
        $added++
        Write-Output "Ajouté : $displayTitle ($pieceId)"
      } catch {
        if (Test-Path -LiteralPath $pieceFolder) { Remove-Item -LiteralPath $pieceFolder -Recurse -Force }
        Write-Warning "Impossible d’ajouter $midiFile : $($_.Exception.Message)"
      }
    }
    if ($added) { Save-Catalog $catalog }
    Write-Output "$added paire(s) MIDI + MP4 ajoutée(s)."
    if ($skipped) { Write-Output "$skipped MIDI ignoré(s) faute de MP4 portant le même nom." }
  }
  'add-guided' {
    $selectedMidi = Select-MediaFile 'Choisir le fichier MIDI' 'Fichiers MIDI (*.mid;*.midi)|*.mid;*.midi'
    if (-not $selectedMidi) { Write-Output 'Aucun fichier sélectionné.'; break }
    $selectedVideo = Select-MediaFile 'Choisir la vidéo MP4 (Annuler pour ignorer)' 'Vidéos MP4 (*.mp4)|*.mp4'
    $selectedAudio = Select-MediaFile 'Choisir l’audio MP3 (Annuler pour ignorer)' 'Audio MP3 (*.mp3)|*.mp3'
    $displayTitle = [System.IO.Path]::GetFileNameWithoutExtension($selectedMidi)
    $baseId = New-Slug $displayTitle
    $pieceId = $baseId
    $number = 2
    while (@($catalog.pieces | Where-Object { $_.id -eq $pieceId }).Count) {
      $pieceId = "$baseId-$number"
      $number++
    }
    $pieceFolder = Join-Path $piecesRoot $pieceId
    New-Item -ItemType Directory -Force -Path $pieceFolder | Out-Null
    try {
      $midiName = Copy-MediaFile $selectedMidi $pieceFolder
      $videoName = Copy-MediaFile $selectedVideo $pieceFolder
      $audioName = Copy-MediaFile $selectedAudio $pieceFolder
      $piece = [ordered]@{ id = $pieceId; title = $displayTitle; midi = "pieces/$pieceId/$midiName" }
      if ($videoName) { $piece.video = "pieces/$pieceId/$videoName" }
      if ($audioName) { $piece.audio = "pieces/$pieceId/$audioName" }
      $catalog.pieces = @($catalog.pieces) + [pscustomobject]$piece
      Save-Catalog $catalog
      Write-Output "Ajouté : $displayTitle ($pieceId)"
    } catch {
      if (Test-Path -LiteralPath $pieceFolder) { Remove-Item -LiteralPath $pieceFolder -Recurse -Force }
      throw
    }
  }
  'remove' {
    if ([string]::IsNullOrWhiteSpace($Id)) { throw 'Indiquez le morceau à retirer avec -Id.' }
    $piece = @($catalog.pieces | Where-Object { $_.id -eq $Id }) | Select-Object -First 1
    if (-not $piece) { throw "Morceau introuvable : $Id" }
    $pieceFolder = Join-Path $piecesRoot $Id
    if (Test-Path -LiteralPath $pieceFolder) { Remove-Item -LiteralPath $pieceFolder -Recurse -Force }
    $catalog.pieces = @($catalog.pieces | Where-Object { $_.id -ne $Id })
    Save-Catalog $catalog
    Write-Output "Retiré : $Id"
  }
  'remove-numbered' {
    $pieces = @($catalog.pieces)
    if (-not $pieces.Count) { Write-Output 'La bibliothèque est vide.'; break }
    Write-Output 'MORCEAUX DISPONIBLES :'
    for ($index = 0; $index -lt $pieces.Count; $index++) {
      Write-Output ("{0,3}. {1}" -f ($index + 1), $pieces[$index].title)
    }
    $answer = Read-Host 'Numéros des morceaux à retirer, séparés par des virgules (ex. 1, 3, 5 ; Entrée pour annuler)'
    if ([string]::IsNullOrWhiteSpace($answer)) { Write-Output 'Annulé.'; break }
    $selectedNumbers = @()
    foreach ($item in ($answer -split '[,;\s]+' | Where-Object { $_ })) {
      $selectedNumber = 0
      if (-not [int]::TryParse($item, [ref]$selectedNumber) -or $selectedNumber -lt 1 -or $selectedNumber -gt $pieces.Count) {
        throw "Numéro invalide : $item"
      }
      if ($selectedNumber -notin $selectedNumbers) { $selectedNumbers += $selectedNumber }
    }
    $selectedPieces = @($selectedNumbers | ForEach-Object { $pieces[$_ - 1] })
    foreach ($selected in $selectedPieces) {
      $pieceFolder = Join-Path $piecesRoot $selected.id
      if (Test-Path -LiteralPath $pieceFolder) { Remove-Item -LiteralPath $pieceFolder -Recurse -Force }
    }
    $selectedIds = @($selectedPieces | ForEach-Object { $_.id })
    $catalog.pieces = @($catalog.pieces | Where-Object { $_.id -notin $selectedIds })
    Save-Catalog $catalog
    Write-Output ("Retiré(s) : " + ($selectedPieces.title -join ', '))
  }
  'remove-batch' {
    $midiFiles = Select-MidiFiles 'Choisir les fichiers MIDI des paires à enlever'
    if (-not $midiFiles.Count) { Write-Output 'Aucun fichier sélectionné.'; break }

    $selectedMidiNames = @($midiFiles | ForEach-Object { Split-Path -Leaf $_ } | Select-Object -Unique)
    $selectedPieces = @($catalog.pieces | Where-Object {
      if (-not $_.midi -or -not $_.video) { return $false }
      $storedMidiName = Split-Path -Leaf ([string]$_.midi)
      $storedMidiName -in $selectedMidiNames
    })

    if (-not $selectedPieces.Count) {
      Write-Output 'Aucune paire MIDI + MP4 correspondante dans la bibliothèque.'
      break
    }

    foreach ($selected in $selectedPieces) {
      $pieceFolder = Join-Path $piecesRoot $selected.id
      if (Test-Path -LiteralPath $pieceFolder) { Remove-Item -LiteralPath $pieceFolder -Recurse -Force }
    }
    $selectedIds = @($selectedPieces | ForEach-Object { $_.id })
    $catalog.pieces = @($catalog.pieces | Where-Object { $_.id -notin $selectedIds })
    Save-Catalog $catalog

    $foundMidiNames = @($selectedPieces | ForEach-Object { Split-Path -Leaf ([string]$_.midi) } | Select-Object -Unique)
    $missingMidiNames = @($selectedMidiNames | Where-Object { $_ -notin $foundMidiNames })
    Write-Output ("Paire(s) retirée(s) : " + ($selectedPieces.title -join ', '))
    if ($missingMidiNames.Count) {
      Write-Warning ("Aucune paire trouvée pour : " + ($missingMidiNames -join ', '))
    }
  }
}
