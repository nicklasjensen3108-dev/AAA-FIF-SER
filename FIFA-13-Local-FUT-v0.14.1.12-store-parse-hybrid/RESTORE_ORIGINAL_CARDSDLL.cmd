@echo off
setlocal
cd /d "%~dp0"
title FIFA 13 LOCAL FUT - RESTORE CARDS DLL
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\restore_original_cardsdll.ps1"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" pause
exit /b %RC%
