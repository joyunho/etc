@echo off
rem ===========================================================================
rem  NPC Friends x Heap of Foods : WHY THE SERVER WILL NOT START
rem
rem  Packs the CODE of every installed Don't Starve Together mod into one zip.
rem  Animations, textures and sounds are left out on purpose -- they are most
rem  of the gigabytes and none of the answers. Every mod is listed either way,
rem  with its name, version and real size.
rem
rem  Usage:
rem      lasterror.bat
rem
rem  ASCII-only on purpose. All Korean text is printed by tools\patch.ps1.
rem ===========================================================================

chcp 65001 >nul 2>&1
title DST - find the server startup error

if not exist "%~dp0tools\patch.ps1" (
  echo.
  echo  [ERROR] tools\patch.ps1 not found.
  echo          Unzip the whole package first, then run lasterror.bat
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
echo  Looking through the DST logs for the error.
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\patch.ps1" -Action lasterror
set "RC=%ERRORLEVEL%"

echo.
if not "%RC%"=="0" (
  echo  ^>^> Read the message above.
  echo.
)

pause
exit /b %RC%
