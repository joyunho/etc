@echo off
rem ===========================================================================
rem  NPC Friends x Heap of Foods : WHICH MOD IS THE PROBLEM
rem
rem  Reads the lua of every installed Don't Starve Together mod and reports the
rem  places where two mods can collide: WX-78 module slots (a hard limit of 63
rem  that stops the server booting), error-handler overrides, container and
rem  cookpot hooks, and crock-pot dish names claimed by more than one mod.
rem  Also names any mod the recent logs blamed by workshop id.
rem  Writes the result to a text file next to this one.
rem
rem  Usage:
rem      modcheck.bat
rem      modcheck.bat "D:\Steam\steamapps\workshop\content\322330"
rem                      ^-- only if the mods are not found automatically
rem
rem  ASCII-only on purpose. All Korean text is printed by tools\patch.ps1.
rem ===========================================================================

chcp 65001 >nul 2>&1
title DST - which mod is the problem

if not exist "%~dp0tools\patch.ps1" (
  echo.
  echo  [ERROR] tools\patch.ps1 not found.
  echo          Unzip the whole package first, then run modcheck.bat
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
echo  Reading every installed mod's code. This can take a minute.
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\patch.ps1" -Action modcheck -ModFolder "%~1"
set "RC=%ERRORLEVEL%"

echo.
if not "%RC%"=="0" (
  echo  ^>^> Read the message above.
  echo.
)

pause
exit /b %RC%
