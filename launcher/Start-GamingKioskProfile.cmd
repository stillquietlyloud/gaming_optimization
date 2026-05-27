@echo off
:: ============================================================
:: Start-GamingKioskProfile.cmd
:: UAC-elevating launcher for GamingKioskProfile.ps1
::
:: Usage:
::   Start-GamingKioskProfile.cmd Deploy
::   Start-GamingKioskProfile.cmd Status
:: ============================================================
setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

set "PS_SCRIPT=%SCRIPT_DIR%\..\GamingKioskProfile.ps1"
set "MODE=%~1"
if "%MODE%"=="" set "MODE=Deploy"

if /i "%MODE%"=="Deploy" goto :run
if /i "%MODE%"=="Status" goto :run

echo.
echo  Invalid mode: %MODE%
echo  Usage: Start-GamingKioskProfile.cmd [Deploy^|Status]
echo.
pause
exit /b 1

:run
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -NoProfile -Command ^
        "Start-Process -FilePath cmd.exe -ArgumentList '/c ""%~f0" %MODE%"' -Verb RunAs"
    exit /b
)

echo.
echo  GamingKioskProfile  ^|  Mode: %MODE%
echo  Script: %PS_SCRIPT%
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass ^
    -File "%PS_SCRIPT%" -Mode %MODE%

if %errorlevel% neq 0 (
    echo.
    echo  GamingKioskProfile exited with error code %errorlevel%.
    pause
)

endlocal
