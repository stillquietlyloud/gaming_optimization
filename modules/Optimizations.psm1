#Requires -Version 5.1
<#
.SYNOPSIS
    Applies and reverts all gaming-specific system optimizations on Windows 11.

.DESCRIPTION
    Functions exported:
      Enable-GamingOptimizations  – Apply all optimizations.
      Disable-GamingOptimizations – Revert all optimizations (called by
                                    Restore-SystemState after a state restore).

    Optimization categories:
      • Power plan   – Activate "Ultimate Performance"
      • Game Mode    – Enable Windows Game Mode
      • Services     – Stop / delay non-essential background services
      • Visual FX    – Disable desktop animations / transparency
      • Network      – Disable Nagle, enable CTCP, set throttling index
      • Memory       – Disable SysMain (Superfetch), adjust page-file settings
      • CPU/GPU      – Enable HAGS, disable Power Throttling, set MMCSS profiles
      • Process prio – Raise priority of running game launchers (safe list only)
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$_ModuleDir = if ($PSScriptRoot) { $PSScriptRoot } else {
    Split-Path $MyInvocation.MyCommand.Path -Parent
}
$_ProtectedItemsModule = Join-Path $_ModuleDir 'ProtectedItems.psm1'
Import-Module $_ProtectedItemsModule -Force

# ---------------------------------------------------------------------------
# GUID for Ultimate Performance power plan (built-in to Windows 10 1803+ / 11)
# ---------------------------------------------------------------------------
$Script:UltimatePerfGuid = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$Script:BalancedGuid     = '381b4222-f694-41f0-9685-ff5bb260df2e'

# ---------------------------------------------------------------------------
# Services to temporarily STOP and set to Manual while gaming.
# Never include anything in ProtectedItems.
# ---------------------------------------------------------------------------
$Script:ServicesToStop = @(
    'SysMain',          # Superfetch / SysMain – can cause disk thrashing
    'WSearch',          # Windows Search indexer
    'DiagTrack',        # Connected User Experiences and Telemetry
    'dmwappushservice', # WAP Push Message Routing Service
    'RetailDemo',       # Retail Demo Service
    'MapsBroker',       # Downloaded Maps Manager
    'RemoteRegistry',   # Remote Registry
    'Fax',              # Fax service
    'TabletInputService', # Touch keyboard / handwriting
    'PrintNotify',      # Printer notifications
    'Spooler',          # Print Spooler (stop only if no printer connected)
    'lfsvc',            # Geolocation service
    'SharedAccess',     # Internet Connection Sharing
    'wisvc',            # Windows Insider Service
    'WerSvc',           # Windows Error Reporting
    'wercplsupport',    # Problem Reports Control Panel Support
    'PcaSvc',           # Program Compatibility Assistant
    'DPS',              # Diagnostic Policy Service (non-critical diag)
    'WdiSystemHost',    # Diagnostic System Host
    'WdiServiceHost'    # Diagnostic Service Host
)

# ---------------------------------------------------------------------------
# Helper: safe registry write
# ---------------------------------------------------------------------------
function Write-RegValue {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force
}

# ---------------------------------------------------------------------------
# Helper: get active power plan GUID
# ---------------------------------------------------------------------------
function Get-ActivePowerPlanGuid {
    $out = & powercfg /getactivescheme 2>$null
    if ($out -match 'GUID:\s*([0-9a-fA-F\-]{36})') {
        return $Matches[1].Trim()
    }
    return $Script:BalancedGuid
}

# ---------------------------------------------------------------------------
# POWER PLAN
# ---------------------------------------------------------------------------
function Enable-UltimatePerformance {
    Write-Verbose '[Optimizations] Activating Ultimate Performance power plan…'
    # Duplicate the plan if it does not exist yet
    $existing = & powercfg /list 2>$null | Select-String $Script:UltimatePerfGuid
    if (-not $existing) {
        & powercfg /duplicatescheme $Script:UltimatePerfGuid 2>$null | Out-Null
    }
    & powercfg /setactive $Script:UltimatePerfGuid 2>$null
}

# ---------------------------------------------------------------------------
# GAME MODE
# ---------------------------------------------------------------------------
function Enable-GameMode {
    Write-Verbose '[Optimizations] Enabling Windows Game Mode…'
    Write-RegValue 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode'   1
    Write-RegValue 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1
}

function Disable-GameMode {
    Write-Verbose '[Optimizations] Disabling Windows Game Mode…'
    Write-RegValue 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode'   0
    Write-RegValue 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 0
}

# ---------------------------------------------------------------------------
# VISUAL EFFECTS
# ---------------------------------------------------------------------------
function Disable-VisualEffects {
    Write-Verbose '[Optimizations] Disabling non-essential visual effects…'

    # VisualFXSetting: 0=Let Windows choose, 1=Best appearance, 2=Best performance, 3=Custom
    Write-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' `
        'VisualFXSetting' 2

    # Disable menu animations
    Write-RegValue 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '0' -Type String

    # Disable window minimise/maximise animations
    Write-RegValue 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' -Type String

    # Disable transparency effects
    Write-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' `
        'EnableTransparency' 0
}

function Enable-VisualEffects {
    Write-Verbose '[Optimizations] Restoring default visual effects…'
    Write-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' `
        'VisualFXSetting' 0
    Write-RegValue 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '400' -Type String
    Write-RegValue 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '1' -Type String
    Write-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' `
        'EnableTransparency' 1
}

# ---------------------------------------------------------------------------
# NETWORK OPTIMIZATIONS
# ---------------------------------------------------------------------------
function Enable-NetworkOptimizations {
    Write-Verbose '[Optimizations] Applying network tweaks…'

    # Disable network throttling (0xFFFFFFFF = disabled)
    Write-RegValue `
        'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' `
        'NetworkThrottlingIndex' 0xFFFFFFFF

    # Lower system responsiveness value for games (2 = 2% reserved for non-game tasks; default 20)
    Write-RegValue `
        'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' `
        'SystemResponsiveness' 2

    # Disable Nagle algorithm on all physical, up adapters
    try {
        $interfaces = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
        foreach ($iface in $interfaces) {
            $ifData = Get-ItemProperty -Path $iface.PSPath -ErrorAction SilentlyContinue
            # Only touch adapters that have an IP address assigned (non-empty DhcpIPAddress or IPAddress)
            if ($ifData.DhcpIPAddress -or ($ifData.IPAddress -and $ifData.IPAddress -ne '0.0.0.0')) {
                Set-ItemProperty -Path $iface.PSPath -Name 'TcpAckFrequency' -Value 1 `
                    -Type DWord -Force -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $iface.PSPath -Name 'TCPNoDelay'      -Value 1 `
                    -Type DWord -Force -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $iface.PSPath -Name 'TcpDelAckTicks'  -Value 0 `
                    -Type DWord -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {
        Write-Warning "[Optimizations] Could not apply Nagle tweak: $_"
    }
}

function Disable-NetworkOptimizations {
    Write-Verbose '[Optimizations] Reverting network tweaks…'

    Write-RegValue `
        'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' `
        'NetworkThrottlingIndex' 10   # Windows default

    Write-RegValue `
        'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' `
        'SystemResponsiveness' 20    # Windows default

    try {
        $interfaces = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
        foreach ($iface in $interfaces) {
            Remove-ItemProperty -Path $iface.PSPath -Name 'TcpAckFrequency' -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path $iface.PSPath -Name 'TCPNoDelay'      -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path $iface.PSPath -Name 'TcpDelAckTicks'  -ErrorAction SilentlyContinue
        }
    } catch {}
}

# ---------------------------------------------------------------------------
# MMCSS (Multimedia Class Scheduler) PROFILES FOR GAMES
# ---------------------------------------------------------------------------
function Enable-MmcssGamingProfile {
    Write-Verbose '[Optimizations] Tuning MMCSS Games profile…'
    $base = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'
    Write-RegValue $base 'Affinity'           0
    Write-RegValue $base 'Background Only'    'False' -Type String
    Write-RegValue $base 'Clock Rate'         10000
    Write-RegValue $base 'GPU Priority'       8
    Write-RegValue $base 'Priority'           6
    Write-RegValue $base 'Scheduling Category' 'High' -Type String
    Write-RegValue $base 'SFIO Priority'       'High' -Type String
}

function Disable-MmcssGamingProfile {
    Write-Verbose '[Optimizations] Reverting MMCSS Games profile…'
    $base = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'
    Write-RegValue $base 'GPU Priority'        2
    Write-RegValue $base 'Priority'            2
    Write-RegValue $base 'Scheduling Category' 'Medium' -Type String
    Write-RegValue $base 'SFIO Priority'       'Normal'  -Type String
}

# ---------------------------------------------------------------------------
# HARDWARE-ACCELERATED GPU SCHEDULING (HAGS)
# ---------------------------------------------------------------------------
function Enable-HAGS {
    Write-Verbose '[Optimizations] Enabling HAGS (Hardware-Accelerated GPU Scheduling)…'
    Write-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2
}

function Disable-HAGS {
    Write-Verbose '[Optimizations] Disabling HAGS…'
    Write-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 1
}

# ---------------------------------------------------------------------------
# POWER THROTTLING (disable to stop CPU frequency scaling mid-game)
# ---------------------------------------------------------------------------
function Disable-PowerThrottling {
    Write-Verbose '[Optimizations] Disabling Power Throttling…'
    $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling'
    Write-RegValue $path 'PowerThrottlingOff' 1
}

function Enable-PowerThrottling {
    Write-Verbose '[Optimizations] Enabling Power Throttling…'
    $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling'
    Write-RegValue $path 'PowerThrottlingOff' 0
}

# ---------------------------------------------------------------------------
# MEMORY
# ---------------------------------------------------------------------------
function Enable-MemoryOptimizations {
    Write-Verbose '[Optimizations] Applying memory optimizations…'
    $mm = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
    # Keep kernel in RAM (faster syscalls)
    Write-RegValue $mm 'DisablePagingExecutive' 1
    # Do not grow the standby list aggressively (helps keep game memory resident)
    Write-RegValue $mm 'LargeSystemCache'        0
}

function Disable-MemoryOptimizations {
    Write-Verbose '[Optimizations] Reverting memory optimizations…'
    $mm = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
    Write-RegValue $mm 'DisablePagingExecutive' 0
    Write-RegValue $mm 'LargeSystemCache'        0
}

# ---------------------------------------------------------------------------
# FULLSCREEN OPTIMIZATIONS / GAME DVR
# ---------------------------------------------------------------------------
function Enable-FullscreenOptimizations {
    Write-Verbose '[Optimizations] Configuring Fullscreen Optimizations and GameDVR…'
    $gc = 'HKCU:\System\GameConfigStore'
    # Keep Game DVR OFF while gaming (reduces overhead), FSO ON
    Write-RegValue $gc 'GameDVR_Enabled'                      0
    Write-RegValue $gc 'GameDVR_FSEBehaviorMode'              2
    Write-RegValue $gc 'GameDVR_HonorUserFSEBehaviorMode'     1
    Write-RegValue $gc 'GameDVR_DXGIHonorFSEWindowsCompatible' 1
    Write-RegValue $gc 'GameDVR_EFSEFeatureFlags'             0
}

function Disable-FullscreenOptimizations {
    Write-Verbose '[Optimizations] Restoring Fullscreen Optimizations defaults…'
    $gc = 'HKCU:\System\GameConfigStore'
    Write-RegValue $gc 'GameDVR_Enabled'                      1
    Write-RegValue $gc 'GameDVR_FSEBehaviorMode'              0
    Write-RegValue $gc 'GameDVR_HonorUserFSEBehaviorMode'     0
    Write-RegValue $gc 'GameDVR_DXGIHonorFSEWindowsCompatible' 0
    Write-RegValue $gc 'GameDVR_EFSEFeatureFlags'             0
}

# ---------------------------------------------------------------------------
# SERVICES
# ---------------------------------------------------------------------------
function Stop-NonEssentialServices {
    Write-Verbose '[Optimizations] Stopping non-essential background services…'
    foreach ($name in $Script:ServicesToStop) {
        # Double-check against protected list
        if (Test-ServiceProtected $name) {
            Write-Verbose "  [SKIP] Protected service: $name"
            continue
        }
        try {
            $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq 'Running') {
                Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
                Set-Service  -Name $name -StartupType Manual -ErrorAction SilentlyContinue
                Write-Verbose "  [STOPPED] $name"
            }
        } catch {
            Write-Warning "  [WARN] Could not stop service '$name': $_"
        }
    }
}

# ---------------------------------------------------------------------------
# PROCESS PRIORITIES (game launchers get Above Normal; nothing gets lowered)
# ---------------------------------------------------------------------------
$Script:LauncherProcessBoosts = @(
    'steam', 'steamwebhelper',
    'EpicGamesLauncher',
    'GalaxyClient',
    'Battle.net',
    'EADesktop',
    'UbisoftConnect',
    'RiotClientServices'
)

function Set-LauncherPriorities {
    Write-Verbose '[Optimizations] Boosting game launcher process priorities…'
    foreach ($procName in $Script:LauncherProcessBoosts) {
        Get-Process -Name $procName -ErrorAction SilentlyContinue |
            ForEach-Object {
                try {
                    $_.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::AboveNormal
                    Write-Verbose "  [BOOSTED] $($_.Name) (PID $($_.Id))"
                } catch {
                    Write-Verbose "  [WARN] Could not boost $($_.Name): $_"
                }
            }
    }
}

function Reset-LauncherPriorities {
    Write-Verbose '[Optimizations] Resetting game launcher process priorities to Normal…'
    foreach ($procName in $Script:LauncherProcessBoosts) {
        Get-Process -Name $procName -ErrorAction SilentlyContinue |
            ForEach-Object {
                try {
                    $_.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Normal
                } catch {}
            }
    }
}

# ---------------------------------------------------------------------------
# PUBLIC: Enable-GamingOptimizations
# ---------------------------------------------------------------------------
function Enable-GamingOptimizations {
    <#
    .SYNOPSIS
        Applies all gaming performance optimizations.
        Call Save-SystemState (from StateCapture.psm1) BEFORE this function.
    #>
    Write-Host '[GamingOptimizer] Applying optimizations…' -ForegroundColor Cyan

    Enable-UltimatePerformance
    Enable-GameMode
    Disable-VisualEffects
    Enable-NetworkOptimizations
    Enable-MmcssGamingProfile
    Enable-HAGS
    Disable-PowerThrottling
    Enable-MemoryOptimizations
    Enable-FullscreenOptimizations
    Stop-NonEssentialServices
    Set-LauncherPriorities

    Write-Host '[GamingOptimizer] All optimizations applied. Enjoy your game!' `
        -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# PUBLIC: Disable-GamingOptimizations
# ---------------------------------------------------------------------------
function Disable-GamingOptimizations {
    <#
    .SYNOPSIS
        Reverts all gaming-specific tweaks applied by Enable-GamingOptimizations.
        Called automatically at the next logon via the Scheduled Task, or manually.
    #>
    Write-Host '[GamingOptimizer] Reverting optimizations…' -ForegroundColor Cyan

    Disable-GameMode
    Enable-VisualEffects
    Disable-NetworkOptimizations
    Disable-MmcssGamingProfile
    Disable-HAGS
    Enable-PowerThrottling
    Disable-MemoryOptimizations
    Disable-FullscreenOptimizations
    Reset-LauncherPriorities
    # Services are restored by Restore-SystemState in StateCapture.psm1
    # Power plan is restored by Restore-SystemState in StateCapture.psm1

    Write-Host '[GamingOptimizer] Optimizations reverted.' -ForegroundColor Green
}

Export-ModuleMember -Function `
    Enable-GamingOptimizations, `
    Disable-GamingOptimizations
