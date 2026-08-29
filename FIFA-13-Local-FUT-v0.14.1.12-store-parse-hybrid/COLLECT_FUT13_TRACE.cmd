@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0COLLECT_FUT13_TRACE.ps1"
if errorlevel 1 pause
