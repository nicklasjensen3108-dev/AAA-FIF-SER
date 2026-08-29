@echo off
setlocal
cd /d "%~dp0"
title FIFA 13 LOCAL FUT - RESET SAVE
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\reset_local_save.ps1"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" pause
exit /b %RC%
