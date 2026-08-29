@echo off
setlocal
cd /d "%~dp0"
title FIFA 13 Local FUT - Publish to GitHub
powershell -NoProfile -ExecutionPolicy Bypass -File ".\tools\publish_to_github.ps1"
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" echo Publish helper exited with code %RC%.
pause
exit /b %RC%
