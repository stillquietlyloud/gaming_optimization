#Requires -Version 5.1
<#
.SYNOPSIS
    Captures the current Windows system state before gaming optimizations are
    applied, persists it to disk, and restores it on demand (or at startup via
    a Scheduled Task).

.DESCRIPTION
    Functions exported:
      Save-SystemState       – Snapshot services, power plan, registry tweaks,
                               network settings and environment variables.
      Restore-SystemState    – Read the snapshot and revert every change.
      Register-RestoreTask   – Install a one-shot Scheduled Task that calls
                               Restore-SystemState at the next Windows logon.
      Remove-RestoreTask     – Delete that Scheduled Task once the restore has run.
      Get-StateFilePath      – Return the path used for the state file.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Import protected-items list so we never capture or alter those items.
$_ModuleDir = if ($PSScriptRoot) { $PSScriptRoot } else {
    Split-Path $MyInvocation.MyCommand.Path -Parent
}
$_ProtectedItemsModule = Join-Path $_ModuleDir 'ProtectedItems.psm1'
Import-Module $_ProtectedItemsModule -Force

# ---------------------------------------------------------------------------
# Internal constants
# ---------------------------------------------------------------------------
$_ProgramData = if ($env:ProgramData) { $env:ProgramData } else {
    Join-Path ([System.IO.Path]::GetTempPath()) '.GamingOptimizer'
}
$Script:StateDir   = Join-Path $_ProgramData 'GamingOptimizer'
$Script:StateFile  = Join-Path $Script:StateDir  'system_state.json'
$Script:TaskName   = 'GamingOptimizer_Restore'
$Script:ScriptRoot = $_ModuleDir

# ---------------------------------------------------------------------------
# Registry paths whose values we snapshot
# ---------------------------------------------------------------------------
$Script:RegistrySnapshots = @(
    # Visual performance settings
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects';
       Value = 'VisualFXSetting' },

    # Disable animations
    @{ Path = 'HKCU:\Control Panel\Desktop';
       Value = 'UserPreferencesMask' },
    @{ Path = 'HKCU:\Control Panel\Desktop';
       Value = 'MenuShowDelay' },
    @{ Path = 'HKCU:\Control Panel\Desktop\WindowMetrics';
       Value = 'MinAnimate' },

    # Game Mode
    @{ Path = 'HKCU:\Software\Microsoft\GameBar';
       Value = 'AllowAutoGameMode' },
    @{ Path = 'HKCU:\Software\Microsoft\GameBar';
       Value = 'AutoGameModeEnabled' },

    # Network throttling index (0xFFFFFFFF = disabled)
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile';
       Value = 'NetworkThrottlingIndex' },
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile';
       Value = 'SystemResponsiveness' },

    # System profile for games
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games';
       Value = 'GPU Priority' },
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games';
       Value = 'Priority' },
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games';
       Value = 'Scheduling Category' },

    # Hardware-accelerated GPU scheduling (HAGS)
    @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers';
       Value = 'HwSchMode' },

    # Nagle's algorithm (TCP_NODELAY) – per-interface keys added dynamically
    # Memory management
    @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management';
       Value = 'DisablePagingExecutive' },
    @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management';
       Value = 'LargeSystemCache' },

    # Power throttling
    @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling';
       Value = 'PowerThrottlingOff' },

    # FSO / fullscreen optimizations
    @{ Path = 'HKCU:\System\GameConfigStore';
       Value = 'GameDVR_Enabled' },
    @{ Path = 'HKCU:\System\GameConfigStore';
       Value = 'GameDVR_FSEBehaviorMode' },
    @{ Path = 'HKCU:\System\GameConfigStore';
       Value = 'GameDVR_HonorUserFSEBehaviorMode' },
    @{ Path = 'HKCU:\System\GameConfigStore';
       Value = 'GameDVR_DXGIHonorFSEWindowsCompatible' },
    @{ Path = 'HKCU:\System\GameConfigStore';
       Value = 'GameDVR_EFSEFeatureFlags' }
)

# ---------------------------------------------------------------------------
# Helper: safe registry read (returns $null if key/value does not exist)
# ---------------------------------------------------------------------------
function Read-RegistryValue {
    param([string]$Path, [string]$Value)
    try {
        $item = Get-ItemProperty -Path $Path -Name $Value -ErrorAction SilentlyContinue
        if ($null -eq $item) { return $null }
        return $item.$Value
    } catch {
        return $null
    }
}

# ---------------------------------------------------------------------------
# Helper: write registry value, creating key if needed
# ---------------------------------------------------------------------------
function Write-RegistryValue {
    param([string]$Path, [string]$Value, $Data, [string]$Type = 'DWord')
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    Set-ItemProperty -Path $Path -Name $Value -Value $Data -Type $Type -Force
}

# ---------------------------------------------------------------------------
# PUBLIC: Get-StateFilePath
# ---------------------------------------------------------------------------
function Get-StateFilePath {
    <#
    .SYNOPSIS
        Returns the full path of the state snapshot JSON file.
    #>
    return $Script:StateFile
}

# ---------------------------------------------------------------------------
# PUBLIC: Save-SystemState
# ---------------------------------------------------------------------------
function Save-SystemState {
    <#
    .SYNOPSIS
        Captures the current system configuration and writes it to disk.

    .OUTPUTS
        [string] Path to the saved state file.
    #>

    if (-not (Test-Path $Script:StateDir)) {
        New-Item -ItemType Directory -Path $Script:StateDir -Force | Out-Null
    }

    Write-Verbose '[StateCapture] Capturing service states…'
    $serviceState = Get-Service |
        Where-Object { -not (Test-ServiceProtected $_.Name) } |
        Select-Object Name, StartType, Status |
        ForEach-Object {
            @{
                Name      = $_.Name
                StartType = $_.StartType.ToString()
                Status    = $_.Status.ToString()
            }
        }

    Write-Verbose '[StateCapture] Capturing power plan…'
    $powerPlanGuid = ''
    $planOutput = & powercfg /getactivescheme 2>$null
    if ($planOutput -match 'GUID:\s*([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
        $powerPlanGuid = $Matches[1].Trim()
    }

    Write-Verbose '[StateCapture] Capturing registry values…'
    $regState = @()
    foreach ($entry in $Script:RegistrySnapshots) {
        $val = Read-RegistryValue -Path $entry.Path -Value $entry.Value
        $regState += @{
            Path  = $entry.Path
            Value = $entry.Value
            Data  = $val
        }
    }

    Write-Verbose '[StateCapture] Capturing network adapter TCP settings…'
    $tcpState = @()
    try {
        $adapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq 'Up' }
        foreach ($adapter in $adapters) {
            $tcp = Get-NetAdapterAdvancedProperty -Name $adapter.Name `
                       -ErrorAction SilentlyContinue |
                   Where-Object { $_.RegistryKeyword -eq '*InterruptModeration' }
            if ($tcp) {
                $tcpState += @{
                    AdapterName = $adapter.Name
                    Keyword     = $tcp.RegistryKeyword
                    Value       = $tcp.RegistryValue
                }
            }
        }
    } catch {
        Write-Verbose "[StateCapture] Could not read adapter TCP settings: $_"
    }

    Write-Verbose '[StateCapture] Capturing environment variables (user scope)…'
    $envState = @{}
    [System.Environment]::GetEnvironmentVariables('User').GetEnumerator() |
        ForEach-Object { $envState[$_.Key] = $_.Value }

    $state = @{
        CapturedAt     = (Get-Date -Format 'o')
        PowerPlanGuid  = $powerPlanGuid
        Services       = $serviceState
        Registry       = $regState
        TcpAdapters    = $tcpState
        Environment    = $envState
    }

    $state | ConvertTo-Json -Depth 10 | Set-Content -Path $Script:StateFile -Encoding UTF8 -Force

    Write-Verbose "[StateCapture] State saved to: $Script:StateFile"
    return $Script:StateFile
}

# ---------------------------------------------------------------------------
# PUBLIC: Restore-SystemState
# ---------------------------------------------------------------------------
function Restore-SystemState {
    <#
    .SYNOPSIS
        Reads the saved state snapshot and restores it.

    .PARAMETER StateFilePath
        Path to the JSON state file. Defaults to the standard location.
    #>
    param(
        [string]$StateFilePath = $Script:StateFile
    )

    if (-not (Test-Path $StateFilePath)) {
        Write-Warning "[StateCapture] State file not found: $StateFilePath"
        return
    }

    $state = Get-Content -Path $StateFilePath -Raw | ConvertFrom-Json

    # ---- Restore power plan ----
    if ($state.PowerPlanGuid -and $state.PowerPlanGuid -ne '') {
        Write-Verbose "[StateCapture] Restoring power plan: $($state.PowerPlanGuid)"
        & powercfg /setactive "$($state.PowerPlanGuid)" 2>$null
    }

    # ---- Restore registry values ----
    Write-Verbose '[StateCapture] Restoring registry values…'
    foreach ($entry in $state.Registry) {
        if ($null -ne $entry.Data) {
            try {
                Write-RegistryValue -Path $entry.Path -Value $entry.Value -Data $entry.Data
            } catch {
                Write-Warning "[StateCapture] Could not restore registry $($entry.Path)\$($entry.Value): $_"
            }
        } else {
            # If the value did not exist before, remove it now
            try {
                if (Test-Path $entry.Path) {
                    Remove-ItemProperty -Path $entry.Path -Name $entry.Value -ErrorAction SilentlyContinue
                }
            } catch {}
        }
    }

    # ---- Restore services ----
    Write-Verbose '[StateCapture] Restoring service states…'
    foreach ($svc in $state.Services) {
        if (Test-ServiceProtected $svc.Name) { continue }
        try {
            $live = Get-Service -Name $svc.Name -ErrorAction SilentlyContinue
            if (-not $live) { continue }

            # Restore start type
            Set-Service -Name $svc.Name -StartupType $svc.StartType -ErrorAction SilentlyContinue

            # Restore running/stopped state
            if ($svc.Status -eq 'Running' -and $live.Status -ne 'Running') {
                Start-Service -Name $svc.Name -ErrorAction SilentlyContinue
            } elseif ($svc.Status -eq 'Stopped' -and $live.Status -ne 'Stopped') {
                Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
            }
        } catch {
            Write-Warning "[StateCapture] Could not restore service '$($svc.Name)': $_"
        }
    }

    # ---- Restore network adapter settings ----
    Write-Verbose '[StateCapture] Restoring network adapter TCP settings…'
    foreach ($entry in $state.TcpAdapters) {
        try {
            Set-NetAdapterAdvancedProperty -Name $entry.AdapterName `
                -RegistryKeyword $entry.Keyword `
                -RegistryValue   $entry.Value `
                -ErrorAction SilentlyContinue
        } catch {
            Write-Warning "[StateCapture] Could not restore adapter '$($entry.AdapterName)': $_"
        }
    }

    Write-Verbose '[StateCapture] System state restored.'
}

# ---------------------------------------------------------------------------
# PUBLIC: Register-RestoreTask
# ---------------------------------------------------------------------------
function Register-RestoreTask {
    <#
    .SYNOPSIS
        Registers a Scheduled Task that runs Restore-SystemState once at the
        next user logon, then removes itself.

    .PARAMETER MainScriptPath
        Full path to GamingOptimizer.ps1 (the orchestrator).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$MainScriptPath
    )

    # Build the PowerShell command that will be run by the task
    $psArgs = "-NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass " +
              "-File `"$MainScriptPath`" -Mode Disable -NoPrompt"

    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $psArgs
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $settings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
        -MultipleInstances IgnoreNew `
        -StartWhenAvailable

    $principal = New-ScheduledTaskPrincipal `
        -UserId 'SYSTEM' `
        -LogonType ServiceAccount `
        -RunLevel Highest

    Register-ScheduledTask `
        -TaskName  $Script:TaskName `
        -Action    $action `
        -Trigger   $trigger `
        -Settings  $settings `
        -Principal $principal `
        -Force     | Out-Null

    Write-Verbose "[StateCapture] Restore task '$($Script:TaskName)' registered."
}

# ---------------------------------------------------------------------------
# PUBLIC: Remove-RestoreTask
# ---------------------------------------------------------------------------
function Remove-RestoreTask {
    <#
    .SYNOPSIS
        Removes the restore Scheduled Task if it exists.
    #>
    $existing = Get-ScheduledTask -TaskName $Script:TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $Script:TaskName -Confirm:$false
        Write-Verbose "[StateCapture] Restore task '$($Script:TaskName)' removed."
    }
}

# ---------------------------------------------------------------------------
# PUBLIC: Test-StateExists
# ---------------------------------------------------------------------------
function Test-StateExists {
    <#
    .SYNOPSIS
        Returns $true when a saved state file is present on disk.
    #>
    return (Test-Path $Script:StateFile)
}

Export-ModuleMember -Function `
    Get-StateFilePath, `
    Save-SystemState, `
    Restore-SystemState, `
    Register-RestoreTask, `
    Remove-RestoreTask, `
    Test-StateExists
