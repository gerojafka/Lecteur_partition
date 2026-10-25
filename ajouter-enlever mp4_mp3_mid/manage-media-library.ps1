[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('list', 'open-library', 'choose-library', 'add', 'add-batch', 'add-guided', 'remove', 'remove-numbered', 'remove-batch')]
  [string]$Action,

  [string]$Midi,
  [string]$Video,
  [string]$Audio,
  [string]$Title,
  [string]$Id
)

$configPath = Join-Path $PSScriptRoot '.media-library-path.txt'
$configuredLibrary = $null
if (Test-Path -LiteralPath $configPath) {
  $savedPath = (Get-Content -LiteralPath $configPath -Raw).Trim()
  if ($savedPath -and (Test-Path -LiteralPath $savedPath -PathType Container)) {
    $configuredLibrary = (Resolve-Path -LiteralPath $savedPath).Path
  }
}
$projectRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
if ($configuredLibrary) {
  $libraryRoot = $configuredLibrary
} else {
  while ($projectRoot -and -not (Test-Path -LiteralPath (Join-Path $projectRoot 'media-library'))) {
    $parentRoot = Split-Path -Parent $projectRoot
    if ($parentRoot -eq $projectRoot) { break }
    $projectRoot = $parentRoot
  }
  $libraryRoot = Join-Path $projectRoot 'media-library'
}
if (-not $libraryRoot) { $libraryRoot = Join-Path $projectRoot 'media-library' }
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

function Select-PieceFolders {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  $folders = @(Get-ChildItem -LiteralPath $piecesRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
  if (-not $folders.Count) { return @() }

  $form = New-Object System.Windows.Forms.Form
  $form.Text = 'Choisir les répertoires à enlever'
  $form.StartPosition = 'CenterScreen'
  $form.Size = New-Object System.Drawing.Size(720, 560)
  $form.MinimumSize = New-Object System.Drawing.Size(560, 420)

  $label = New-Object System.Windows.Forms.Label
  $label.Text = "Cochez les répertoires à supprimer dans :`r`n$piecesRoot"
  $label.Dock = 'Top'
  $label.Height = 48
  $label.Padding = New-Object System.Windows.Forms.Padding(12, 10, 12, 4)
  $form.Controls.Add($label)

  $list = New-Object System.Windows.Forms.CheckedListBox
  $list.Dock = 'Fill'
  $list.CheckOnClick = $true
  $list.IntegralHeight = $false
  $list.Font = New-Object System.Drawing.Font('Segoe UI', 10)
  foreach ($folder in $folders) {
    $piece = @($catalog.pieces | Where-Object { $_.id -eq $folder.Name }) | Select-Object -First 1
    $title = if ($piece) { $piece.title } else { '(non présent dans catalog.json)' }
    [void]$list.Items.Add("$title  [$($folder.Name)]")
  }
  $form.Controls.Add($list)

  $buttons = New-Object System.Windows.Forms.FlowLayoutPanel
  $buttons.Dock = 'Bottom'
  $buttons.Height = 52
  $buttons.FlowDirection = 'RightToLeft'
  $buttons.Padding = New-Object System.Windows.Forms.Padding(8)
  $ok = New-Object System.Windows.Forms.Button
  $ok.Text = 'Supprimer les sélectionnés'
  $ok.Width = 180
  $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
  $cancel = New-Object System.Windows.Forms.Button
  $cancel.Text = 'Annuler'
  $cancel.Width = 90
  $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
  $buttons.Controls.Add($ok)
  $buttons.Controls.Add($cancel)
  $form.Controls.Add($buttons)
  $form.AcceptButton = $ok
  $form.CancelButton = $cancel

  if ($form.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return @() }
  return @($list.CheckedIndices | ForEach-Object { $folders[$_].Name })
}

function Select-LibraryFolder {
  Add-Type -AssemblyName System.Windows.Forms
  $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
  $dialog.Description = 'Choisir le dossier media-library à utiliser'
  $dialog.ShowNewFolderButton = $true
  if ($configuredLibrary) { $dialog.SelectedPath = $configuredLibrary }
  if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
  return (Resolve-Path -LiteralPath $dialog.SelectedPath).Path
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
  'choose-library' {
    $chosenLibrary = Select-LibraryFolder
    if (-not $chosenLibrary) { Write-Output 'Annulé.'; break }
    Set-Content -LiteralPath $configPath -Value $chosenLibrary -Encoding utf8
    $libraryRoot = $chosenLibrary
    $piecesRoot = Join-Path $libraryRoot 'pieces'
    $catalogPath = Join-Path $libraryRoot 'catalog.json'
    New-Item -ItemType Directory -Force -Path $piecesRoot | Out-Null
    if (-not (Test-Path -LiteralPath $catalogPath)) {
      [pscustomobject]@{ version = 1; pieces = @() } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $catalogPath -Encoding utf8
    }
    Write-Output "Bibliothèque sélectionnée : $libraryRoot"
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
    $selectedIds = @(Select-PieceFolders)
    if (-not $selectedIds.Count) { Write-Output 'Aucun répertoire sélectionné.'; break }
    $selectedPieces = @($catalog.pieces | Where-Object { $_.id -in $selectedIds })

    foreach ($selectedId in $selectedIds) {
      $pieceFolder = Join-Path $piecesRoot $selectedId
      if (Test-Path -LiteralPath $pieceFolder) { Remove-Item -LiteralPath $pieceFolder -Recurse -Force }
    }
    $catalog.pieces = @($catalog.pieces | Where-Object { $_.id -notin $selectedIds })
    Save-Catalog $catalog

    $unknownIds = @($selectedIds | Where-Object { $_ -notin @($selectedPieces | ForEach-Object { $_.id }) })
    Write-Output ("Répertoire(s) supprimé(s) : " + ($selectedIds -join ', '))
    if ($unknownIds.Count) { Write-Warning ("Répertoire(s) absent(s) du catalog.json : " + ($unknownIds -join ', ')) }
  }
}
