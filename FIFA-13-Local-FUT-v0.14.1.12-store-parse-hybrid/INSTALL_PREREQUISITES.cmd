@echo off
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0"
title FIFA 13 LOCAL FUT - PREREQUISITES

echo ============================================================
echo  FIFA 13 LOCAL FUT - PREREQUISITES
echo ============================================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\install_prerequisites.ps1"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
    echo.
    echo Prerequisites failed with exit code %RC%.
    pause
    exit /b %RC%
)
echo.
echo Prerequisites complete.
pause
exit /b 0
