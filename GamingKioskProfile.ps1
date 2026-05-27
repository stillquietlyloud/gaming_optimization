#Requires -Version 5.1
<#
.SYNOPSIS
    Deploys or rolls back a Windows 11 gaming kiosk profile.

.DESCRIPTION
    Applies a reversible "gaming kiosk profile" focused on gaming performance
    and stability while keeping core compatibility intact.

    Key goals:
      - Keep Windows gaming stack defaults that improve compatibility
      - Optionally configure auto-logon and console launcher at sign-in
      - Optionally replace shell for full-screen console experience
      - Apply conservative/aggressive service and startup reductions
      - Persist state and generate rollback script for safe reversal
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Deploy', 'Status')]
    [string]$Mode = 'Deploy',

    [string]$ConfigPath = '',

    [switch]$NoPrompt
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $ScriptDir 'config\kiosk.settings.json'
}

$ProgramDataRoot = $env:ProgramData
$KioskRoot = Join-Path $ProgramDataRoot 'GamingOptimizer\kiosk'
$LogDir = Join-Path $KioskRoot 'logs'
$LogPath = Join-Path $LogDir ('kiosk_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.log')
$RunValueName = 'GamingKioskLauncher'

$UltimatePerfGuid = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$HighPerfGuid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'

$Defaults = @{
    Profile = 'DedicatedGaming'
    CreateRestorePoint = $true
    Launcher = @{
        Type = 'Playnite'
        Path = ''
        Arguments = ''
        SetAsShell = $false
        ConfigureRunAtLogon = $true
    }
    AutoLogon = @{
        Enabled = $false
        UserName = ''
        Password = ''
        Domain = ''
    }
    OptionalFeatures = @{
        DisableStartupApps = $true
        EnforceGamingOnlyStartup = $true
        DisableWidgets = $true
        DisableConsumerFeatures = $true
        DisableOneDrive = $false
        DisablePrintServicesIfUnused = $false
        DisableLocationServices = $true
        DisableDiagnosticServices = $false
        DisableRemoteRegistry = $true
        DisableFax = $true
        DisableRetailDemo = $true
        DisableTabletInput = $false
        DisableVbsAndHvci = $false
    }
    StartupDenyList = @('OneDrive','Teams','Skype','Spotify','Discord','Update','Adobe')
    StartupAllowList = @(
        'Steam',
        'Epic',
        'EpicGamesLauncher',
        'EpicWebHelper',
        'EADesktop',
        'EABackgroundService',
        'EA',
        'Ubisoft',
        'Uplay',
        'EasyAntiCheat',
        'BattlEye',
        'BEService',
        'vgc',
        'vgtray',
        'GameGuard',
        'RiotClient',
        'Riot Vanguard'
    )
    ServiceProfiles = @{
        Conservative = @('RemoteRegistry', 'Fax', 'RetailDemo')
        Aggressive = @(
            'RemoteRegistry', 'Fax', 'RetailDemo', 'MapsBroker', 'lfsvc',
            'WSearch', 'DiagTrack', 'dmwappushservice', 'WerSvc',
            'wercplsupport', 'DPS', 'WdiSystemHost', 'WdiServiceHost',
            'TabletInputService', 'PrintNotify', 'Spooler'
        )
        DedicatedGaming = @(
            'RemoteRegistry', 'Fax', 'RetailDemo', 'MapsBroker', 'lfsvc',
            'WSearch', 'DiagTrack', 'dmwappushservice', 'WerSvc',
            'wercplsupport', 'DPS', 'WdiSystemHost', 'WdiServiceHost',
            'TabletInputService', 'PrintNotify', 'Spooler'
        )
    }
    KeepServices = @(
        'Audiosrv','AudioEndpointBuilder','XboxGipSvc','XblAuthManager',
        'XblGameSave','XboxNetApiSvc','GamingServices','WinDefend','wuauserv',
        'UsoSvc','WaaSMedicSvc','BFE','mpssvc','Dhcp','Dnscache','NlaSvc',
        'RpcSs','DcomLaunch','EventLog','PlugPlay'
    )
    PowerPlan = @{
        Conservative = 'HighPerformance'
        Aggressive = 'UltimatePerformance'
        DedicatedGaming = 'UltimatePerformance'
    }
}

function Test-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = [Security.Principal.WindowsPrincipal]$id
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Directories {
    if (-not (Test-Path $KioskRoot)) { New-Item -ItemType Directory -Path $KioskRoot -Force | Out-Null }
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
}

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 's'), $Level, $Message
    Write-Host $line
    Add-Content -Path $LogPath -Value $line
}

function Merge-Hashtable {
    param([hashtable]$Base, [object]$Override)
    if ($null -eq $Override) { return $Base }

    if ($Override -isnot [System.Collections.IDictionary]) {
        return $Override
    }

    foreach ($k in $Override.Keys) {
        if ($Base.ContainsKey($k) -and ($Base[$k] -is [hashtable]) -and ($Override[$k] -is [System.Collections.IDictionary])) {
            $Base[$k] = Merge-Hashtable -Base $Base[$k] -Override $Override[$k]
        } else {
            $Base[$k] = $Override[$k]
        }
    }
    return $Base
}

function ConvertFrom-PSObjectToHashtable {
    param([Parameter(Mandatory)][object]$InputObject)

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [string] -or $InputObject -is [ValueType]) { return $InputObject }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $hash = @{}
        foreach ($key in $InputObject.Keys) {
            $hash[$key] = ConvertFrom-PSObjectToHashtable -InputObject $InputObject[$key]
        }
        return $hash
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $arr = @()
        foreach ($item in $InputObject) {
            $arr += (ConvertFrom-PSObjectToHashtable -InputObject $item)
        }
        return $arr
    }

    $objHash = @{}
    foreach ($p in $InputObject.PSObject.Properties) {
        $objHash[$p.Name] = ConvertFrom-PSObjectToHashtable -InputObject $p.Value
    }
    return $objHash
}

function Read-Config {
    $cfg = @{}
    foreach ($k in $Defaults.Keys) { $cfg[$k] = $Defaults[$k] }

    if (Test-Path $ConfigPath) {
        $raw = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
        $raw = ConvertFrom-PSObjectToHashtable -InputObject $raw
        $cfg = Merge-Hashtable -Base $cfg -Override $raw
    }

    $validProfiles = @('Conservative','Aggressive','DedicatedGaming')
    if ($validProfiles -notcontains $cfg.Profile) {
        throw "Invalid profile '$($cfg.Profile)'. Use Conservative, Aggressive, or DedicatedGaming."
    }
    if (-not $cfg.ServiceProfiles.ContainsKey($cfg.Profile)) {
        throw "ServiceProfiles is missing profile '$($cfg.Profile)'."
    }
    if (-not $cfg.PowerPlan.ContainsKey($cfg.Profile)) {
        throw "PowerPlan is missing profile '$($cfg.Profile)'."
    }
    return $cfg
}

function Set-RegValue {
    param([string]$Path,[string]$Name,$Value,[string]$Type='DWord')
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force
}

function Resolve-PowerPlanGuid {
    param([string]$Name)
    switch ($Name) {
        'UltimatePerformance' { return $UltimatePerfGuid }
        'HighPerformance'     { return $HighPerfGuid }
        default {
            if ($Name -match '^[0-9a-fA-F\-]{36}$') { return $Name }
            throw "Unsupported power plan '$Name'."
        }
    }
}

function Set-GamingDefaults {
    Set-RegValue 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1
    Set-RegValue 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1

    Set-RegValue 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
    Set-RegValue 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehaviorMode' 2
    Set-RegValue 'HKCU:\System\GameConfigStore' 'GameDVR_HonorUserFSEBehaviorMode' 1
    Set-RegValue 'HKCU:\System\GameConfigStore' 'GameDVR_DXGIHonorFSEWindowsCompatible' 1
}

function Set-PowerPlan {
    param([hashtable]$Config)
    $planName = $Config.PowerPlan[$Config.Profile]
    $guid = Resolve-PowerPlanGuid -Name $planName

    if ($guid -eq $UltimatePerfGuid) {
        $exists = (& powercfg /list 2>$null | Select-String $UltimatePerfGuid)
        if (-not $exists) { & powercfg /duplicatescheme $UltimatePerfGuid 2>$null | Out-Null }
    }
    & powercfg /setactive $guid 2>$null
    Write-Log "Activated power plan: $planName ($guid)"
}

function Disable-StartupNoise {
    param([hashtable]$Config)
    if (-not $Config.OptionalFeatures.DisableStartupApps) { return }

    $denyList = @($Config.StartupDenyList)
    $allowList = @($Config.StartupAllowList)
    $enforceGamingOnly = [bool]$Config.OptionalFeatures.EnforceGamingOnlyStartup

    $denyList = @($denyList | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $allowList = @($allowList | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })

    if ($denyList.Count -eq 0 -and (-not $enforceGamingOnly -or $allowList.Count -eq 0)) { return }

    foreach ($hive in @('HKCU','HKLM')) {
        $path = "${hive}:\Software\Microsoft\Windows\CurrentVersion\Run"
        $props = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        foreach ($prop in $props.PSObject.Properties) {
            if ($prop.Name -match '^PS') { continue }

            if ($enforceGamingOnly -and $allowList.Count -gt 0) {
                if ($prop.Name -ieq $RunValueName) { continue }

                $isAllowed = $false
                foreach ($pattern in $allowList) {
                    if ($prop.Name -like "*$pattern*" -or ([string]$prop.Value) -like "*$pattern*") {
                        $isAllowed = $true
                        break
                    }
                }

                if (-not $isAllowed) {
                    Remove-ItemProperty -Path $path -Name $prop.Name -ErrorAction SilentlyContinue
                    Write-Log "Removed non-gaming startup entry: $hive/$($prop.Name)"
                }
            } else {
                foreach ($pattern in $denyList) {
                    if ($prop.Name -like "*$pattern*" -or ([string]$prop.Value) -like "*$pattern*") {
                        Remove-ItemProperty -Path $path -Name $prop.Name -ErrorAction SilentlyContinue
                        Write-Log "Removed startup entry: $hive/$($prop.Name)"
                        break
                    }
                }
            }
        }
    }
}

function Apply-ExplorerPolicies {
    param([hashtable]$Config)

    if ($Config.OptionalFeatures.DisableWidgets) {
        Set-RegValue 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarDa' 0
        Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
        Write-Log 'Disabled widgets/news policy.'
    }

    if ($Config.OptionalFeatures.DisableConsumerFeatures) {
        Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
        Write-Log 'Disabled Windows consumer features.'
    }

    if ($Config.OptionalFeatures.DisableOneDrive) {
        Stop-Process -Name OneDrive -Force -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'OneDrive' -ErrorAction SilentlyContinue
        Write-Log 'Disabled OneDrive auto-start (process stopped for current session).'
    }
}

function Set-Launcher {
    param([hashtable]$Config)

    $launcherPath = [string]$Config.Launcher.Path
    if (-not $launcherPath) {
        switch ($Config.Launcher.Type) {
            'Steam' {
                $launcherPath = "${env:ProgramFiles(x86)}\Steam\steam.exe"
                if (-not (Test-Path $launcherPath)) { $launcherPath = "$env:ProgramFiles\Steam\steam.exe" }
                if (-not $Config.Launcher.Arguments) { $Config.Launcher.Arguments = '-bigpicture' }
            }
            default {
                $launcherPath = "$env:ProgramFiles\Playnite\Playnite.FullscreenApp.exe"
            }
        }
    }

    if (-not (Test-Path $launcherPath)) {
        Write-Log "Launcher path does not exist: $launcherPath" 'WARN'
        return
    }

    $cmd = '"' + $launcherPath + '"'
    if ($Config.Launcher.Arguments) {
        $cmd += ' ' + [string]$Config.Launcher.Arguments
    }

    if ($Config.Launcher.ConfigureRunAtLogon) {
        Set-RegValue 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' $RunValueName $cmd -Type String
        Write-Log "Configured launcher at logon: $cmd"
    }

    if ($Config.Launcher.SetAsShell) {
        Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' 'Shell' $cmd -Type String
        Write-Log 'Configured launcher as shell replacement.'
    }
}

function Set-AutoLogon {
    param([hashtable]$Config)
    if (-not $Config.AutoLogon.Enabled) { return }

    if (-not $Config.AutoLogon.UserName -or -not $Config.AutoLogon.Password) {
        Write-Log 'AutoLogon enabled but UserName/Password missing; skipping.' 'WARN'
        return
    }

    Write-Log 'AutoLogon enabled: DefaultPassword will be stored unencrypted under HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon.' 'WARN'

    $path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-RegValue $path 'AutoAdminLogon' '1' -Type String
    Set-RegValue $path 'DefaultUserName' ([string]$Config.AutoLogon.UserName) -Type String
    Set-RegValue $path 'DefaultPassword' ([string]$Config.AutoLogon.Password) -Type String
    if ($Config.AutoLogon.Domain) {
        Set-RegValue $path 'DefaultDomainName' ([string]$Config.AutoLogon.Domain) -Type String
    }

    Write-Log "Configured autologon for user '$($Config.AutoLogon.UserName)'."
}

function Apply-OptionalSecurityTuning {
    param([hashtable]$Config)
    if (-not $Config.OptionalFeatures.DisableVbsAndHvci) { return }

    Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity' 0
    Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' 0
    Write-Log 'Disabled VBS/HVCI (requires reboot to fully apply).'
}

function Stop-SelectedServices {
    param([hashtable]$Config)

    $targets = @($Config.ServiceProfiles[$Config.Profile])

    if (-not $Config.OptionalFeatures.DisablePrintServicesIfUnused) {
        $targets = $targets | Where-Object { $_ -notin @('Spooler','PrintNotify') }
    }
    if (-not $Config.OptionalFeatures.DisableLocationServices) {
        $targets = $targets | Where-Object { $_ -ne 'lfsvc' }
    }
    if (-not $Config.OptionalFeatures.DisableDiagnosticServices) {
        $targets = $targets | Where-Object { $_ -notin @('DiagTrack','WerSvc','wercplsupport','DPS','WdiSystemHost','WdiServiceHost') }
    }
    if (-not $Config.OptionalFeatures.DisableRemoteRegistry) { $targets = $targets | Where-Object { $_ -ne 'RemoteRegistry' } }
    if (-not $Config.OptionalFeatures.DisableFax) { $targets = $targets | Where-Object { $_ -ne 'Fax' } }
    if (-not $Config.OptionalFeatures.DisableRetailDemo) { $targets = $targets | Where-Object { $_ -ne 'RetailDemo' } }
    if (-not $Config.OptionalFeatures.DisableTabletInput) { $targets = $targets | Where-Object { $_ -ne 'TabletInputService' } }

    foreach ($svcName in ($targets | Select-Object -Unique)) {
        if ($Config.KeepServices -contains $svcName) {
            Write-Log "Skipped keep-service: $svcName"
            continue
        }

        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if (-not $svc) { continue }

        try {
            if ($svc.Status -ne 'Stopped') {
                Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
            }
            Set-Service -Name $svcName -StartupType Manual -ErrorAction SilentlyContinue
            Write-Log "Adjusted service: $svcName"
        } catch {
            Write-Log "Could not modify service '$svcName': $_" 'WARN'
        }
    }
}

function Show-Status {
    Write-Host ''
    Write-Host '--- Gaming Kiosk Profile Status ---' -ForegroundColor Cyan
    Write-Host '  Mode          : PERMANENT GAMING CONSOLE (rollback disabled)' -ForegroundColor Yellow
    $shell = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name 'Shell' -ErrorAction SilentlyContinue).Shell
    Write-Host "  Winlogon Shell: $(if ($shell) { $shell } else { 'explorer.exe (default)' })"
    $launcher = (Get-ItemProperty -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $RunValueName -ErrorAction SilentlyContinue).$RunValueName
    Write-Host "  Launcher run  : $(if ($launcher) { $launcher } else { 'Not configured' })"
    $planOut = & powercfg /getactivescheme 2>$null
    Write-Host "  Power plan    : $planOut"
    Write-Host ''
}

function Invoke-Deploy {
    $cfg = Read-Config

    if (-not $NoPrompt) {
        $ans = Read-Host "Deploy gaming kiosk profile '$($cfg.Profile)'? [Y/n]"
        if ($ans -match '^[Nn]') {
            Write-Log 'Deployment aborted by user.'
            return
        }
    }

    Set-GamingDefaults
    Set-PowerPlan -Config $cfg
    Disable-StartupNoise -Config $cfg
    Apply-ExplorerPolicies -Config $cfg
    Stop-SelectedServices -Config $cfg
    Apply-OptionalSecurityTuning -Config $cfg
    Set-Launcher -Config $cfg
    Set-AutoLogon -Config $cfg

    Write-Log "Gaming kiosk profile '$($cfg.Profile)' deployed successfully."
    Write-Log 'Recommended next steps: validate launchers, anti-cheat titles, controller hot-plug, audio switch, and sleep/wake.'
}

if (-not (Test-Administrator)) {
    Write-Error 'GamingKioskProfile must be run as Administrator.'
    exit 1
}

try {
    if (-not $ProgramDataRoot) {
        throw 'ProgramData environment variable ($env:ProgramData) is not set. Verify system environment variables.'
    }

    Ensure-Directories

    if (-not ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)) {
        throw 'This script supports Windows only.'
    }

    $productName = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'ProductName' -ErrorAction SilentlyContinue).ProductName
    if ($productName -and $productName -notmatch 'Windows 11') {
        Write-Log "Detected '$productName'. Script is designed for Windows 11." 'WARN'
    }
    if ($productName -and $productName -notmatch 'Pro') {
        Write-Log "Detected edition '$productName'. Recommended target is Windows 11 Pro." 'WARN'
    }

    switch ($Mode) {
        'Deploy'   { Invoke-Deploy }
        'Status'   { Show-Status }
    }
} catch {
    Write-Log "Fatal error: $_" 'ERROR'
    throw
}
