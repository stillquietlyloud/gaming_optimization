#Requires -Version 5.1
<#
.SYNOPSIS
    GamingOptimizer – Windows 11 gaming optimization pipeline.

.DESCRIPTION
    Captures the current system state, applies a suite of gaming performance
    optimizations, and registers a Scheduled Task to restore the original
    configuration automatically at the next Windows logon / reboot.

    Usage:
        .\GamingOptimizer.ps1 -Mode Enable          # Capture state & optimize
        .\GamingOptimizer.ps1 -Mode Disable         # Restore state now
        .\GamingOptimizer.ps1 -Mode Status          # Show current status
        .\GamingOptimizer.ps1 -Mode Enable -NoPrompt # Non-interactive

    Must be run as Administrator.

.PARAMETER Mode
    Enable  – Capture current state, then apply optimizations.
    Disable – Restore original state (also called by the startup task).
    Status  – Show whether optimizations are currently active.

.PARAMETER ConfigPath
    Path to settings.json. Defaults to .\config\settings.json.

.PARAMETER NoPrompt
    Skip confirmation prompts (useful for scripted / scheduled runs).

.EXAMPLE
    .\GamingOptimizer.ps1 -Mode Enable

.EXAMPLE
    .\GamingOptimizer.ps1 -Mode Disable -NoPrompt

.NOTES
    Requires Windows 11 (build 22000+) and PowerShell 5.1 or later.
    Must be run with Administrator privileges.
    No hardware modifications (overclocking) are performed.
    Anti-cheat services, game launchers, and overclocking tools are
    explicitly protected and never altered.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('Enable', 'Disable', 'Status')]
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
    AutoRestoreAtLogon        = $true
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
Import-Module (Join-Path $modulesDir 'StateCapture.psm1')   -Force
Import-Module (Join-Path $modulesDir 'Optimizations.psm1')  -Force
Import-Module (Join-Path $modulesDir 'Streaming.psm1')      -Force

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
function Write-Banner {
    Write-Host ''
    Write-Host '╔══════════════════════════════════════════════════════╗' -ForegroundColor DarkCyan
    Write-Host '║        GamingOptimizer for Windows 11                ║' -ForegroundColor DarkCyan
    Write-Host '║  Maximize performance · Auto-restore at reboot       ║' -ForegroundColor DarkCyan
    Write-Host '╚══════════════════════════════════════════════════════╝' -ForegroundColor DarkCyan
    Write-Host ''
}

# ---------------------------------------------------------------------------
# MODE: Status
# ---------------------------------------------------------------------------
function Invoke-StatusMode {
    $stateExists = Test-StateExists
    $taskExists  = $null -ne (Get-ScheduledTask -TaskName 'GamingOptimizer_Restore' -ErrorAction SilentlyContinue)

    Write-Host '--- GamingOptimizer Status ---' -ForegroundColor Cyan
    if ($stateExists) {
        $statePath = Get-StateFilePath
        $stateAge  = (Get-Item $statePath).LastWriteTime
        Write-Host "  State file    : $statePath" -ForegroundColor White
        Write-Host "  Captured at   : $stateAge"  -ForegroundColor White
        Write-Host '  Status        : OPTIMIZATIONS ACTIVE' -ForegroundColor Yellow
    } else {
        Write-Host '  Status        : NOT ACTIVE (no saved state found)' -ForegroundColor Green
    }

    if ($taskExists) {
        Write-Host '  Restore task  : Registered (will run at next logon)' -ForegroundColor Yellow
    } else {
        Write-Host '  Restore task  : Not registered' -ForegroundColor DarkGray
    }

    # Show active power plan
    $planOut = & powercfg /getactivescheme 2>$null
    Write-Host "  Power plan    : $planOut" -ForegroundColor White
    Write-Host ''
}

# ---------------------------------------------------------------------------
# MODE: Enable
# ---------------------------------------------------------------------------
function Invoke-EnableMode {
    if (Test-StateExists) {
        Write-Host '[GamingOptimizer] A saved state already exists.' -ForegroundColor Yellow
        Write-Host '  This means optimizations may already be active.' -ForegroundColor Yellow
        if (-not $NoPrompt) {
            $answer = Read-Host '  Re-capture state and re-apply? [y/N]'
            if ($answer -notmatch '^[Yy]') {
                Write-Host 'Aborted.' -ForegroundColor DarkGray
                return
            }
        }
    }

    if (-not $NoPrompt) {
        Write-Host @'
GamingOptimizer will:
  1. Snapshot your current services, power plan, and settings.
  2. Apply gaming performance tweaks.
  3. Register a startup task to restore everything at the next logon.

Anti-cheat software, game launchers, and overclocking tools will NOT
be altered. No hardware modifications are performed.
'@ -ForegroundColor White
        $answer = Read-Host 'Proceed? [Y/n]'
        if ($answer -match '^[Nn]') {
            Write-Host 'Aborted.' -ForegroundColor DarkGray
            return
        }
    }

    # 1. Capture state
    Write-Host '[GamingOptimizer] Capturing system state…' -ForegroundColor Cyan
    $savedPath = Save-SystemState
    Write-Host "  State saved to: $savedPath" -ForegroundColor DarkGray

    # 2. Apply optimizations
    Enable-GamingOptimizations

    # 3. Register restore task
    if ($Config.AutoRestoreAtLogon) {
        Write-Host '[GamingOptimizer] Registering restore task for next logon…' -ForegroundColor Cyan
        Register-RestoreTask -MainScriptPath (Join-Path $ScriptDir 'GamingOptimizer.ps1')
        Write-Host '  Restore task registered. Your settings will be restored at next logon.' `
            -ForegroundColor Green
    } else {
        Write-Host '  AutoRestoreAtLogon is disabled. Run -Mode Disable manually to restore.' `
            -ForegroundColor Yellow
    }

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
# MODE: Disable
# ---------------------------------------------------------------------------
function Invoke-DisableMode {
    if (-not (Test-StateExists)) {
        Write-Host '[GamingOptimizer] No saved state found. Nothing to restore.' `
            -ForegroundColor Yellow
        # Still revert tweaks in case they were applied manually
        Disable-GamingOptimizations
        return
    }

    if (-not $NoPrompt) {
        $answer = Read-Host '[GamingOptimizer] Restore original system state? [Y/n]'
        if ($answer -match '^[Nn]') {
            Write-Host 'Aborted.' -ForegroundColor DarkGray
            return
        }
    }

    # 1. Revert optimization-specific registry tweaks
    Disable-GamingOptimizations

    # 2. Stop streaming watcher and OBS if they were running.
    Stop-StreamingWatcher

    # 3. Restore services, power plan, registry from snapshot
    Write-Host '[GamingOptimizer] Restoring system state…' -ForegroundColor Cyan
    Restore-SystemState

    # 3. Remove scheduled restore task
    Remove-RestoreTask

    # 4. Remove state file
    $statePath = Get-StateFilePath
    if (Test-Path $statePath) {
        Remove-Item $statePath -Force
        Write-Host "  State file removed: $statePath" -ForegroundColor DarkGray
    }

    Write-Host '[GamingOptimizer] System restored to original configuration.' -ForegroundColor Green
    Write-Host ''
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------
Write-Banner

switch ($Mode) {
    'Enable'  { Invoke-EnableMode  }
    'Disable' { Invoke-DisableMode }
    'Status'  { Invoke-StatusMode  }
}
