@echo off
rem ===========================================================================
rem  NPC Friends x Heap of Foods : FIND THE MOD THAT STOPS THE SERVER BOOTING
rem
rem  Halves the enabled mod list, over and over, until only the mods that
rem  actually cause the failure are left. 48 mods take about 6 tries instead
rem  of 48. Finds pairs that only break when both are on.
rem
rem  Run it, start the server, run it again. Repeat until it names the mod.
rem  modoverrides.lua is backed up first and put back when it finishes.
rem
rem  Usage:
rem      bisect.bat            one step
rem      bisect.bat stop       give up and restore the original mod settings
rem
rem  ASCII-only on purpose. All Korean text is printed by tools\patch.ps1.
rem ===========================================================================

chcp 65001 >nul 2>&1
title DST - collect all mod code

if not exist "%~dp0tools\patch.ps1" (
  echo.
  echo  [ERROR] tools\patch.ps1 not found.
  echo          Unzip the whole package first, then run bisect.bat
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

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\patch.ps1" -Action bisect -Arg "%~1"
set "RC=%ERRORLEVEL%"

echo.
if not "%RC%"=="0" (
  echo  ^>^> Read the message above.
  echo.
)

pause
exit /b %RC%
