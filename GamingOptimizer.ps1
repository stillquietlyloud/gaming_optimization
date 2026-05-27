#Requires -Version 5.1
<#
.SYNOPSIS
    GamingOptimizer – Windows 11 permanent gaming console pipeline.

.DESCRIPTION
    Applies a suite of gaming performance optimizations that are permanent.
    No state snapshot or auto-restore is performed; this system is a
    dedicated gaming console on its own NVMe drive.

    Usage:
        .\GamingOptimizer.ps1 -Mode Enable          # Apply optimizations
        .\GamingOptimizer.ps1 -Mode Status          # Show current status
        .\GamingOptimizer.ps1 -Mode Enable -NoPrompt # Non-interactive

    Must be run as Administrator.

.PARAMETER Mode
    Enable  – Apply optimizations permanently.
    Status  – Show current optimization status.

.PARAMETER ConfigPath
    Path to settings.json. Defaults to .\config\settings.json.

.PARAMETER NoPrompt
    Skip confirmation prompts (useful for scripted runs).

.EXAMPLE
    .\GamingOptimizer.ps1 -Mode Enable

.NOTES
    Requires Windows 11 (build 22000+) and PowerShell 5.1 or later.
    Must be run with Administrator privileges.
    No hardware modifications (overclocking) are performed.
    Anti-cheat services, game launchers, and overclocking tools are
    explicitly protected and never altered.
    Rollback/restore is permanently disabled – this is a console OS.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('Enable', 'Status')]
    [string]$Mode = 'Enable',

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = '',

    [switch]$NoPrompt
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Resolve script root (works whether called via & operator or as a file)
# ---------------------------------------------------------------------------
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }

# ---------------------------------------------------------------------------
# Check for administrator privileges
# ---------------------------------------------------------------------------
function Test-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal   = [Security.Principal.WindowsPrincipal]$currentUser
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
    Write-Error @'
GamingOptimizer must be run as Administrator.
Right-click the launcher and choose "Run as administrator", or use
Start-GamingOptimizer.cmd which handles elevation automatically.
'@
    exit 1
}

# ---------------------------------------------------------------------------
# Load configuration
# ---------------------------------------------------------------------------
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $ScriptDir 'config\settings.json'
}

$Config = @{}
if (Test-Path $ConfigPath) {
    try {
        $rawJson = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
        # Convert PSCustomObject to hashtable
        $rawJson.PSObject.Properties |
            Where-Object { $_.Name -notlike '_*' } |
            ForEach-Object { $Config[$_.Name] = $_.Value }
    } catch {
        Write-Warning "Could not parse config file '$ConfigPath': $_. Using defaults."
    }
} else {
    Write-Warning "Config file not found at '$ConfigPath'. Using defaults."
}

# Apply defaults for any missing keys
$defaults = @{
    EnableHAGS                = $true
    DisablePowerThrottling    = $true
    DisableVisualEffects      = $true
    NetworkOptimizations      = $true
    StopNonEssentialServices  = $true
    BoostLauncherPriorities   = $true
    MmcssGamingProfile        = $true
    GameMode                  = $true
    FullscreenOptimizations   = $true
    PowerPlan                 = 'UltimatePerformance'
    LogLevel                  = 'Normal'
    AutoRestoreAtLogon        = $false
    StateFileDir              = ''
    EnableStreaming           = $false
    StreamingConfigPath       = ''
}
foreach ($key in $defaults.Keys) {
    if (-not $Config.ContainsKey($key)) { $Config[$key] = $defaults[$key] }
}

# Set verbosity
if ($Config.LogLevel -eq 'Verbose') {
    $VerbosePreference = 'Continue'
} elseif ($Config.LogLevel -eq 'Silent') {
    $VerbosePreference = 'SilentlyContinue'
    $WarningPreference = 'SilentlyContinue'
}

# ---------------------------------------------------------------------------
# Import modules
# ---------------------------------------------------------------------------
$modulesDir = Join-Path $ScriptDir 'modules'

Import-Module (Join-Path $modulesDir 'ProtectedItems.psm1') -Force
Import-Module (Join-Path $modulesDir 'Optimizations.psm1')  -Force
Import-Module (Join-Path $modulesDir 'Streaming.psm1')      -Force

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
function Write-Banner {
    Write-Host ''
    Write-Host '╔══════════════════════════════════════════════════════╗' -ForegroundColor DarkCyan
    Write-Host '║        GamingOptimizer for Windows 11                ║' -ForegroundColor DarkCyan
    Write-Host '║  Maximize performance · Permanent gaming console     ║' -ForegroundColor DarkCyan
    Write-Host '╚══════════════════════════════════════════════════════╝' -ForegroundColor DarkCyan
    Write-Host ''
}

# ---------------------------------------------------------------------------
# MODE: Status
# ---------------------------------------------------------------------------
function Invoke-StatusMode {
    Write-Host '--- GamingOptimizer Status ---' -ForegroundColor Cyan
    Write-Host '  Mode          : PERMANENT GAMING CONSOLE (rollback disabled)' -ForegroundColor Yellow

    # Show active power plan
    $planOut = & powercfg /getactivescheme 2>$null
    Write-Host "  Power plan    : $planOut" -ForegroundColor White
    Write-Host ''
}

# ---------------------------------------------------------------------------
# MODE: Enable
# ---------------------------------------------------------------------------
function Invoke-EnableMode {
    if (-not $NoPrompt) {
        Write-Host @'
GamingOptimizer will:
  1. Apply gaming performance tweaks permanently.

Anti-cheat software, game launchers, and overclocking tools will NOT
be altered. No hardware modifications are performed.
Rollback/restore is permanently disabled on this console OS.
'@ -ForegroundColor White
        $answer = Read-Host 'Proceed? [Y/n]'
        if ($answer -match '^[Nn]') {
            Write-Host 'Aborted.' -ForegroundColor DarkGray
            return
        }
    }

    # Apply optimizations
    Enable-GamingOptimizations

    Write-Host ''
    Write-Host '  ► Launch your game and enjoy peak performance!' -ForegroundColor Green
    Write-Host ''

    # Start game-stream watcher if the user opted in.
    if ($Config.EnableStreaming) {
        $streamCfgPath = if ($Config.StreamingConfigPath) {
            $Config.StreamingConfigPath
        } else {
            Join-Path $ScriptDir 'config\streaming.json'
        }
        try {
            Start-StreamingWatcher -ConfigPath $streamCfgPath
        } catch {
            Write-Warning "[GamingOptimizer] Streaming watcher could not start: $_"
            Write-Warning '  Verify config\streaming.json is correctly filled in.'
        }
    }
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------
Write-Banner

switch ($Mode) {
    'Enable'  { Invoke-EnableMode  }
    'Status'  { Invoke-StatusMode  }
}
