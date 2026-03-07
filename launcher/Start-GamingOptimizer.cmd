@echo off
:: ============================================================
:: Start-GamingOptimizer.cmd
:: UAC-elevating launcher for GamingOptimizer.ps1
::
:: Double-click (or run from a terminal) to start the
:: gaming optimization pipeline.  Pass a mode as the first
:: argument:  Enable (default) | Disable | Status
::
::   Start-GamingOptimizer.cmd Enable
::   Start-GamingOptimizer.cmd Disable
::   Start-GamingOptimizer.cmd Status
:: ============================================================
setlocal enabledelayedexpansion

:: Resolve script directory (works even with spaces in path)
set "SCRIPT_DIR=%~dp0"
:: Remove trailing backslash
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

set "PS_SCRIPT=%SCRIPT_DIR%\..\GamingOptimizer.ps1"
set "MODE=%~1"
if "%MODE%"=="" set "MODE=Enable"

:: Validate mode
if /i "%MODE%"=="Enable"  goto :run
if /i "%MODE%"=="Disable" goto :run
if /i "%MODE%"=="Status"  goto :run

echo.
echo  Invalid mode: %MODE%
echo  Usage: Start-GamingOptimizer.cmd [Enable^|Disable^|Status]
echo.
pause
exit /b 1

:run
:: ---- Elevation check ----
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges…
    powershell -NoProfile -Command ^
        "Start-Process -FilePath cmd.exe -ArgumentList '/c \"\"%~f0\" %MODE%\"' -Verb RunAs"
    exit /b
)

:: ---- Already elevated – run the PowerShell script ----
echo.
echo  GamingOptimizer  ^|  Mode: %MODE%
echo  Script: %PS_SCRIPT%
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass ^
    -File "%PS_SCRIPT%" -Mode %MODE%

if %errorlevel% neq 0 (
    echo.
    echo  GamingOptimizer exited with error code %errorlevel%.
    pause
)
endlocal
