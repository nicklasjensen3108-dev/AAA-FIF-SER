@echo off
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0"
title FIFA 13 LOCAL FUT - REVERSE ENGINEERING TRACE

echo ============================================================
echo  FIFA 13 LOCAL FUT - ONE CLICK LAUNCHER
echo ============================================================
echo.
echo This launcher starts the working FIFA 13 FUT build with tracing enabled.
echo It will request Administrator permission when required.
echo.

rem Resolve the REAL Python interpreter before PowerShell/UAC gets involved.
rem The Python Launcher (py.exe) is the most reliable source because it returns
rem sys.executable rather than a WindowsApps alias.
set "PYTHON_EXE="
for /f "usebackq delims=" %%P in (`py -3 -c "import sys; print(sys.executable)" 2^>nul`) do if not defined PYTHON_EXE set "PYTHON_EXE=%%P"
if not defined PYTHON_EXE (
    for /f "usebackq delims=" %%P in (`python -c "import sys; print(sys.executable)" 2^>nul`) do if not defined PYTHON_EXE set "PYTHON_EXE=%%P"
)

if defined PYTHON_EXE (
    >"%~dp0.runtime_python_path.txt" echo %PYTHON_EXE%
    echo Python interpreter found before UAC:
    echo   %PYTHON_EXE%
    echo.
) else (
    echo WARNING: CMD could not resolve Python before UAC.
    echo The PowerShell launcher will try its own fallbacks.
    echo.
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0RUN_LOCAL_FUT13.ps1" -PythonPath "%PYTHON_EXE%"
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo ============================================================
    echo  FIFA 13 LOCAL FUT FAILED - EXIT CODE %RC%
    echo ============================================================
    echo Read the error above. This window will stay open.
    pause
)

exit /b %RC%
