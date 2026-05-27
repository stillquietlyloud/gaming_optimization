@echo off
:: ============================================================
:: Start-GameStream.cmd
:: UAC-elevating launcher for game streaming automation.
::
:: Applies GamingOptimizer performance tweaks and then starts
:: the OBS Studio streaming watcher.  OBS will start/stop
:: automatically whenever a watched game process is detected.
::
:: Prerequisites:
::   1. Copy config\streaming.example.json to config\streaming.json
::      and fill in your YouTube stream key and OBS settings.
::   2. Set "EnableStreaming": true in config\settings.json.
::   3. Set up a dedicated OBS profile + scene collection that
::      uses Game Capture (not Display Capture) and Application
::      Audio Capture scoped to your game executable only.
::
:: Usage:
::   Start-GameStream.cmd
:: ============================================================
setlocal enabledelayedexpansion

:: Resolve the launcher directory (handles paths with spaces)
set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

set "PS_SCRIPT=%SCRIPT_DIR%\..\GamingOptimizer.ps1"

:: ---- Elevation check ----
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges…
    powershell -NoProfile -Command ^
        "Start-Process -FilePath cmd.exe -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
    exit /b
)

:: ---- Already elevated – apply optimizations + start streaming watcher ----
echo.
echo  GamingOptimizer  ^|  Game Streaming Mode
echo  Script: %PS_SCRIPT%
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass ^
    -File "%PS_SCRIPT%" -Mode Enable -NoPrompt

if %errorlevel% neq 0 (
    echo.
    echo  GamingOptimizer exited with error code %errorlevel%.
    pause
)
endlocal
