@echo off
rem ===========================================================================
rem  NPC Friends x Heap of Foods : COLLECT THE TEXT TO TRANSLATE
rem
rem  Mod text lives in three places and nowhere else:
rem      languages/*.po   the official translation files
rem      modinfo.lua      the name and description in the mod list
rem      .lua STRINGS     mods that hardcode their text
rem  This picks out those files only, works out which mods are already in
rem  Korean, and packs the rest into one zip with a report.
rem
rem  Usage:
rem      translate.bat
rem      translate.bat "D:\Steam\steamapps\workshop\content\322330"
rem                       ^-- only if the mods are not found automatically
rem
rem  ASCII-only on purpose. All Korean text is printed by tools\patch.ps1.
rem ===========================================================================

chcp 65001 >nul 2>&1
title DST - collect all mod code

if not exist "%~dp0tools\patch.ps1" (
  echo.
  echo  [ERROR] tools\patch.ps1 not found.
  echo          Unzip the whole package first, then run collecttext.bat
  echo          from inside the unzipped folder.
  echo.
  pause
  exit /b 1
)

where powershell >nul 2>&1
if errorlevel 1 (
  echo.
  echo  [ERROR] Windows PowerShell was not found on this machine.
  echo.
  pause
  exit /b 1
)

echo.
echo  Scanning every installed mod. This can take a minute.
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\patch.ps1" -Action collecttext -ModFolder "%~1"
set "RC=%ERRORLEVEL%"

echo.
if not "%RC%"=="0" (
  echo  ^>^> Read the message above.
  echo.
)

pause
exit /b %RC%
