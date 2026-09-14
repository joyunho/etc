@echo off
rem ===========================================================================
rem  NPC Friends x Heap of Foods : INSTALL THE KOREAN STRING PATCH
rem
rem  Copies the mod_korean_patch folder into Don't Starve Together's mods
rem  folder and writes ForceEnableMod into modsettings.lua, so the game turns
rem  it on by itself. Nothing else is touched: no other mod's files, and only
rem  the one marked line in modsettings.lua.
rem
rem  1224 strings across 8 mods are overridden in Korean. The patch assigns
rem  STRINGS values and nothing more, so a wrong translation cannot stop a mod
rem  or the server from starting.
rem
rem  Usage:
rem      hangul.bat            install and switch on
rem      hangul.bat stop       remove it again
rem
rem  ASCII-only on purpose. All Korean text is printed by tools\patch.ps1.
rem ===========================================================================

chcp 65001 >nul 2>&1
title DST - collect all mod code

if not exist "%~dp0tools\patch.ps1" (
  echo.
  echo  [ERROR] tools\patch.ps1 not found.
  echo          Unzip the whole package first, then run hangul.bat
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

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\patch.ps1" -Action hangul -Arg "%~1"
set "RC=%ERRORLEVEL%"

echo.
if not "%RC%"=="0" (
  echo  ^>^> Read the message above.
  echo.
)

pause
exit /b %RC%
