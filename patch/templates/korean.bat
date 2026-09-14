@echo off
rem ===========================================================================
rem  NPC Friends x Heap of Foods : SWITCH MODS TO KOREAN
rem
rem  Most big mods already ship a full Korean translation. It does not show
rem  because the mod's language setting is on English. This finds that setting
rem  in each mod's modinfo.lua, works out which value means Korean, and writes
rem  it into modoverrides.lua. It only changes a setting, so nothing can break.
rem
rem  It also reports which mods have Korean text but no setting to pick it
rem  (set the game language instead), and which have no Korean at all -- those
rem  are the only ones that really need translating.
rem
rem  Usage:
rem      korean.bat            switch everything that can be switched
rem      korean.bat stop       put modoverrides.lua back
rem
rem  ASCII-only on purpose. All Korean text is printed by tools\patch.ps1.
rem ===========================================================================

chcp 65001 >nul 2>&1
title DST - collect all mod code

if not exist "%~dp0tools\patch.ps1" (
  echo.
  echo  [ERROR] tools\patch.ps1 not found.
  echo          Unzip the whole package first, then run korean.bat
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

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\patch.ps1" -Action korean -Arg "%~1"
set "RC=%ERRORLEVEL%"

echo.
if not "%RC%"=="0" (
  echo  ^>^> Read the message above.
  echo.
)

pause
exit /b %RC%
