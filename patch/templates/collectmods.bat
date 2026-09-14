@echo off
rem ===========================================================================
rem  NPC Friends x Heap of Foods : COLLECT ALL MODS (code only)
rem
rem  Packs the CODE of every installed Don't Starve Together mod into one zip.
rem  Animations, textures and sounds are left out on purpose -- they are most
rem  of the gigabytes and none of the answers. Every mod is listed either way,
rem  with its name, version and real size.
rem
rem  Usage:
rem      collectmods.bat
rem      collectmods.bat "D:\Steam\steamapps\workshop\content\322330"
rem                      ^-- only if the mods are not found automatically
rem
rem  ASCII-only on purpose. All Korean text is printed by tools\patch.ps1.
rem ===========================================================================

chcp 65001 >nul 2>&1
title DST - collect all mod code

if not exist "%~dp0tools\patch.ps1" (
  echo.
  echo  [ERROR] tools\patch.ps1 not found.
  echo          Unzip the whole package first, then run collectmods.bat
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

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\patch.ps1" -Action collectmods -ModFolder "%~1"
set "RC=%ERRORLEVEL%"

echo.
if not "%RC%"=="0" (
  echo  ^>^> Read the message above.
  echo.
)

pause
exit /b %RC%
