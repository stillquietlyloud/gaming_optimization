#Requires -Version 5.1
<#
.SYNOPSIS
    Defines all services and processes that must never be stopped, suspended,
    or have their priority altered by the gaming optimizer.

.DESCRIPTION
    Three categories of protected items:
      - EssentialServices   : Core Windows services required for stability.
      - ProtectedServices   : Anti-cheat, game-launcher, and OC-tool services.
      - ProtectedProcesses  : Anti-cheat, game-launcher, and OC-tool executables.

    Any service or process whose name (case-insensitive) matches an entry in
    these lists will be completely ignored by the optimizer.
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# ESSENTIAL WINDOWS SERVICES
# These underpin system stability and must never be touched.
# ---------------------------------------------------------------------------
$Script:EssentialServices = @(
    # Remote Procedure Call stack
    'RpcSs', 'RpcEptMapper', 'DcomLaunch',

    # Security / credential pipeline
    'lsass', 'SamSs', 'KeyIso', 'VaultSvc', 'CryptSvc', 'AppIDSvc',
    'NgcSvc', 'NgcCtnrSvc',

    # Network essentials
    'Tcpip', 'Tcpip6', 'Dhcp', 'Dnscache', 'NlaSvc', 'netprofm',
    'LanmanWorkstation', 'LanmanServer', 'MRxSmb20', 'mrxsmb',
    'Netlogon', 'Browser',

    # Windows Defender – required for anti-cheat compatibility
    'WinDefend', 'WdNisSvc', 'WdNisDrv', 'WdFilter',
    'SecurityHealthService', 'wscsvc',

    # Event / diagnostics pipeline
    'EventLog', 'EventSystem', 'DiagTrack',

    # WMI / management infrastructure
    'Winmgmt', 'WmiPrvSE',

    # Plug-and-play / hardware
    'PlugPlay', 'Power', 'UmRdpService',

    # Task scheduler
    'Schedule',

    # Windows Update (allow system to work, optimizer can defer it but not kill it)
    'wuauserv', 'UsoSvc', 'WaaSMedicSvc',

    # Driver / kernel helpers
    'SystemEventsBroker', 'BrokerInfrastructure', 'LSM',
    'gpsvc', 'ProfSvc', 'UserManager',

    # Audio (needed by games)
    'Audiosrv', 'AudioEndpointBuilder',

    # DirectX / graphics infrastructure
    'GraphicsPerfSvc',

    # Xbox / GameBar / GameDVR services (needed for Game Mode)
    'XblAuthManager', 'XblGameSave', 'XboxNetApiSvc', 'XboxGipSvc',
    'BcastDVRUserService',

    # Store / UWP infrastructure
    'ClipSVC', 'AppXSvc',

    # Font / rendering cache
    'FontCache',

    # Firewall
    'mpssvc', 'BFE'
)

# ---------------------------------------------------------------------------
# PROTECTED SERVICES
# Anti-cheat engines, game-launcher services, hardware-monitoring / OC daemons.
# The optimizer will skip these entirely.
# ---------------------------------------------------------------------------
$Script:ProtectedServices = @(
    # ---- Anti-cheat ----
    'EasyAntiCheat',        # Easy Anti-Cheat (EAC)
    'BEService',            # BattlEye
    'vgc',                  # Riot Vanguard client
    'vgk',                  # Riot Vanguard kernel driver
    'PnkBstrA',             # PunkBuster Service A
    'PnkBstrB',             # PunkBuster Service B
    'FACEIT',               # FACEIT Anti-Cheat
    'nProtectGameGuard',    # nProtect GameGuard
    'GameGuard',

    # ---- Game launchers ----
    'Steam Client Service', # Steam
    'SteamClient',
    'EpicGamesLauncher',    # Epic Games
    'EpicOnlineServices',
    'GalaxyClientService',  # GOG Galaxy
    'Battle.net Update Agent', # Battle.net / Blizzard
    'Blizzard Update Agent',
    'Origin',               # EA / Origin
    'EABackgroundService',  # EA App
    'EADesktop',
    'UbisoftGameLauncher',  # Ubisoft Connect
    'RiotClientService',    # Riot Client
    'RiotGamesService',
    'GfnRuntimeService',    # NVIDIA GeForce NOW
    'NvContainerLocalSystem',

    # ---- Overclocking / hardware-monitoring tools ----
    'MSIAfterburner',       # MSI Afterburner
    'RTSSService',          # RivaTuner Statistics Server
    'XTUSvc',               # Intel Extreme Tuning Utility
    'AMDRyzenMasterService',# AMD Ryzen Master
    'PrecisionXService',    # EVGA Precision X1
    'NVDisplay.ContainerLocalSystem', # NVIDIA display container
    'NvTelemetryContainer',
    'OverwolfUpdater',      # Overwolf (used by many HUD tools)

    # ---- Hardware info tools ----
    'HWiNFO64',
    'CPUID',
    'OpenHardwareMonitor'
)

# ---------------------------------------------------------------------------
# PROTECTED PROCESSES
# Executables that must not be suspended, killed, or reprioritised.
# Matched case-insensitively against the process Name or MainModule.
# ---------------------------------------------------------------------------
$Script:ProtectedProcesses = @(
    # ---- Anti-cheat ----
    'EasyAntiCheat',
    'EasyAntiCheat_EOS',
    'BEService',
    'BEClient',
    'vgtray',
    'vgc',
    'PnkBstrA',
    'PnkBstrB',
    'FACEITClient',
    'GameGuard',
    'GGMon',
    'nProtect',

    # ---- Game launchers ----
    'steam',
    'steamwebhelper',
    'steamservice',
    'GameOverlayUI',
    'EpicGamesLauncher',
    'EpicWebHelper',
    'GalaxyClient',
    'GalaxyClientService',
    'Battle.net',
    'Agent',                # Blizzard Update Agent
    'BlizzardError',
    'Origin',
    'OriginClientService',
    'EADesktop',
    'EABackgroundService',
    'EALink',
    'UbisoftConnect',
    'UplayWebCore',
    'RiotClientServices',
    'RiotClientCrashHandler',

    # ---- Overclocking / hardware monitoring ----
    'MSIAfterburner',
    'RTSS',                 # RivaTuner Statistics Server
    'RTSSHooksLoader64',
    'HWiNFO64',
    'HWiNFO32',
    'cpuz',
    'CPU-Z',
    'GPU-Z',
    'ThrottleStop',
    'XTUService',
    'XTU',
    'AMDRyzenMaster',
    'AMDRyzenMasterDriverV23',
    'PrecisionX',
    'EVGA-Precision',
    'PowerGadget',          # Intel Power Gadget
    'PerformanceMonitor',
    'AIDA64',
    'OpenHardwareMonitor',
    'OverwolfBrowser',
    'Overwolf',

    # ---- Xbox / Windows game infrastructure ----
    'XboxApp',
    'XboxGameBarWidgets',
    'GameBar',
    'GamingServices',
    'XboxPcApp',

    # ---- NVIDIA / AMD driver utilities ----
    'nvcontainer',
    'NvDisplay.Container',
    'NvTelemetryContainer',
    'NVDisplay.ContainerLocalSystem',
    'RadeonSoftware',
    'RadeonSettings',
    'AMDRSSrcExt',

    # ---- System processes that must never be touched ----
    'System',
    'smss',
    'csrss',
    'wininit',
    'winlogon',
    'lsass',
    'services',
    'svchost',
    'Registry',
    'MsMpEng',              # Windows Defender
    'NisSrv'                # Windows Defender Network Inspection
)

# ---------------------------------------------------------------------------
# Public helper functions
# ---------------------------------------------------------------------------

function Get-EssentialServices {
    <#
    .SYNOPSIS
        Returns the list of essential Windows service names.
    #>
    return $Script:EssentialServices
}

function Get-ProtectedServices {
    <#
    .SYNOPSIS
        Returns the combined list of essential + protected service names.
    #>
    return ($Script:EssentialServices + $Script:ProtectedServices) | Select-Object -Unique
}

function Get-ProtectedProcesses {
    <#
    .SYNOPSIS
        Returns the list of protected process names (case-insensitive matching).
    #>
    return $Script:ProtectedProcesses
}

function Test-ServiceProtected {
    <#
    .SYNOPSIS
        Returns $true if the given service name is on the protected list.
    .PARAMETER ServiceName
        The service short name to test.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ServiceName
    )
    $allProtected = Get-ProtectedServices
    return $allProtected -icontains $ServiceName
}

function Test-ProcessProtected {
    <#
    .SYNOPSIS
        Returns $true if the given process name is on the protected list.
    .PARAMETER ProcessName
        The process name (without .exe) to test.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ProcessName
    )
    $allProtected = Get-ProtectedProcesses
    # Strip .exe if present
    $name = $ProcessName -replace '\.exe$', ''
    return $allProtected -icontains $name
}

Export-ModuleMember -Function `
    Get-EssentialServices, `
    Get-ProtectedServices, `
    Get-ProtectedProcesses, `
    Test-ServiceProtected, `
    Test-ProcessProtected
