@echo off
setlocal EnableExtensions DisableDelayedExpansion
title Bibliotheque multimedia - Atelier des notes

set "script=%~dp0manage-media-library.ps1"

if not exist "%script%" (
  echo.
  echo Erreur : le fichier manage-media-library.ps1 est introuvable.
  echo Il doit rester dans le meme dossier que ce lanceur.
  pause
  exit /b 1
)

:menu
cls
echo.
echo   ATELIER DES NOTES - BIBLIOTHEQUE MULTIMEDIA
echo   ============================================
echo.
echo   1. Ouvrir les fichiers de la bibliotheque dans l'Explorateur
echo   2. Ajouter plusieurs paires MIDI + MP4 avec l'Explorateur
echo   3. Ajouter un morceau MIDI avec video ou audio, avec l'Explorateur
echo   4. Enlever plusieurs paires MIDI + MP4 avec l'Explorateur
echo   5. Choisir un autre dossier media-library
echo   0. Fermer
echo.
set "choice="
set /p "choice=Votre choix : "

if "%choice%"=="1" goto openLibrary
if "%choice%"=="2" goto addBatch
if "%choice%"=="3" goto addGuided
if "%choice%"=="4" goto removeBatch
if "%choice%"=="5" goto chooseLibrary
if "%choice%"=="0" exit /b 0
goto menu

:openLibrary
cls
echo.
echo   OUVERTURE DE LA BIBLIOTHEQUE DANS L'EXPLORATEUR
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%script%" -Action open-library
echo.
goto menu

:chooseLibrary
cls
echo.
echo   CHOISIR LE DOSSIER MEDIA-LIBRARY
echo.
echo   Sélectionnez le dossier media-library à utiliser.
echo   Le choix sera mémorisé pour ce lanceur.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%script%" -Action choose-library
echo.
pause
goto menu

:addBatch
cls
echo.
echo   AJOUTER PLUSIEURS PAIRES MIDI + MP4
echo.
echo   La fenetre de l'Explorateur va s'ouvrir.
echo   Sélectionnez uniquement les fichiers MIDI avec Ctrl ou Maj.
echo   Le MP4 du même nom, dans le même dossier, sera ajouté automatiquement.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%script%" -Action add-batch
if errorlevel 1 (
  echo.
  echo L'ajout n'a pas pu etre effectue. Verifiez les chemins et les formats.
) else (
  echo.
  echo Ajout termine. Les morceaux apparaitront dans la liste de la page Partition defilante.
)
echo.
pause
goto menu

:addGuided
cls
echo.
echo   AJOUTER UN MORCEAU AVEC VIDEO OU AUDIO
echo.
echo   L'Explorateur s'ouvrira pour le MIDI, puis facultativement pour le MP4 et le MP3.
echo   Cliquez sur Annuler dans les deux dernieres fenetres si vous ne souhaitez pas les ajouter.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%script%" -Action add-guided
if errorlevel 1 (
  echo.
  echo L'ajout n'a pas pu etre effectue.
) else (
  echo.
  echo Ajout termine. Le morceau apparaitra dans la liste de la page Partition defilante.
)
echo.
pause
goto menu

:removeBatch
cls
echo.
echo   ENLEVER PLUSIEURS PAIRES MIDI + MP4
echo.
echo   La fenetre de l'Explorateur va s'ouvrir.
echo   Cochez les répertoires a enlever dans media-library\pieces, puis validez.
echo   Les répertoires sélectionnés et leurs entrées catalog.json seront supprimés.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%script%" -Action remove-batch
if errorlevel 1 (
  echo.
  echo La suppression n'a pas pu etre effectuee. Verifiez les fichiers selectionnes.
) else (
  echo.
  echo Suppression terminee.
)
echo.
pause
goto menu
