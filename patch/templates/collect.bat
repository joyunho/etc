@echo off
rem ===========================================================================
rem  NPC Friends x Heap of Foods - cooking patch : COLLECT
rem
rem  Gathers only the files needed to diagnose the cooking problem, redacts
rem  account names / Steam IDs, and packs everything into one zip next to this
rem  file. Send that zip; nothing else is needed.
rem
rem  Usage:
rem      collect.bat
rem      collect.bat "D:\Steam\steamapps\workshop\content\322330\3684000581"
rem                  ^-- only if the folder is not found automatically
rem
rem  ASCII-only on purpose. All Korean text is printed by tools\patch.ps1.
rem ===========================================================================

chcp 65001 >nul 2>&1
title NPC Friends x Heap of Foods - Cooking Patch (collect)

if not exist "%~dp0tools\patch.ps1" (
  echo.
  echo  [ERROR] tools\patch.ps1 not found.
  echo          Unzip the whole package first, then run collect.bat
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

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\patch.ps1" -Action collect -ModFolder "%~1"
set "RC=%ERRORLEVEL%"

echo.
if not "%RC%"=="0" (
  echo  ^>^> Read the message above.
  echo  ^>^> If the mod folder was not found, drag the 3684000581 folder
  echo     onto collect.bat, or run:
  echo        collect.bat "D:\Steam\steamapps\workshop\content\322330\3684000581"
  echo.
)

pause
exit /b %RC%
