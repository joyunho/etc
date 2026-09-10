@echo off
rem ===========================================================================
rem  NPC Friends x Heap of Foods - cooking patch : RESTORE (undo)
rem
rem  ASCII-only on purpose. All Korean text is printed by tools\patch.ps1.
rem ===========================================================================

chcp 65001 >nul 2>&1
title NPC Friends x Heap of Foods - Cooking Patch (restore)

if not exist "%~dp0tools\patch.ps1" (
  echo.
  echo  [ERROR] tools\patch.ps1 not found.
  echo          Unzip the whole package first, then run restore.bat
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

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\patch.ps1" -Action restore
set "RC=%ERRORLEVEL%"

echo.
if not "%RC%"=="0" (
  echo  ^>^> Read the message above.
  echo  ^>^> If it is a permission error: close DST completely, then
  echo     right-click restore.bat and choose "Run as administrator".
  echo.
)

pause
exit /b %RC%
