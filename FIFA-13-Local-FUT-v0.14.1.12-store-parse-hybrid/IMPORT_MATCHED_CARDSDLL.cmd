@echo off
setlocal
cd /d "%~dp0"
title FIFA 13 LOCAL FUT - IMPORT MATCHED CARDS DLL
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\import_matched_cardsdll.ps1"
set "RC=%ERRORLEVEL%"
pause
exit /b %RC%
