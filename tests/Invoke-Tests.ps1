#Requires -Version 5.1
<#
.SYNOPSIS
    Self-contained tests for the GamingOptimizer modules.
    No external test framework required – runs on any machine with PS 5.1+.

.DESCRIPTION
    Tests are grouped into sections matching the main modules:
      1. ProtectedItems  – list contents and helper functions
      2. Optimizations   – registry/service helper validation

    Because the optimizer targets Windows APIs, tests that require actual
    system calls (Set-Service, powercfg, Register-ScheduledTask) are
    SKIPPED when NOT running as Administrator or when running in a
    non-Windows environment (CI / Linux runner).

    Exit code: 0 = all tests passed, 1 = one or more failures.

.EXAMPLE
    .\tests\Invoke-Tests.ps1
    .\tests\Invoke-Tests.ps1 -Verbose
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest

$ScriptDir  = Split-Path $MyInvocation.MyCommand.Path -Parent
$RepoRoot   = Split-Path $ScriptDir -Parent
$ModulesDir = Join-Path $RepoRoot 'modules'

# ---------------------------------------------------------------------------
# Tiny test harness
# ---------------------------------------------------------------------------
$Script:Passed  = 0
$Script:Failed  = 0
$Script:Skipped = 0

function it {
    param([string]$Description, [scriptblock]$Test)
    try {
        & $Test
        $Script:Passed++
        Write-Host "  [PASS] $Description" -ForegroundColor Green
    } catch {
        $Script:Failed++
        Write-Host "  [FAIL] $Description" -ForegroundColor Red
        Write-Host "         $_" -ForegroundColor DarkRed
    }
}

function skip {
    param([string]$Description, [string]$Reason)
    $Script:Skipped++
    Write-Host "  [SKIP] $Description ($Reason)" -ForegroundColor DarkYellow
}

function Assert-True  { param($v, $msg = '') if (-not $v) { throw ($msg ? $msg : "Expected TRUE but got: $v") } }
function Assert-False { param($v, $msg = '') if ($v)      { throw ($msg ? $msg : "Expected FALSE but got: $v") } }
function Assert-Equal { param($a, $b, $msg='') if ($a -ne $b) { throw ($msg ? $msg : "Expected '$b' but got '$a'") } }
function Assert-NotNull { param($v, $msg='') if ($null -eq $v) { throw ($msg ? $msg : 'Value should not be null') } }
function Assert-Contains { param($col, $item, $msg='') if ($col -notcontains $item) { throw ($msg ? $msg : "Collection does not contain '$item'") } }

$IsWindowsOS  = ($PSVersionTable.Platform -eq 'Win32NT') -or ($null -eq $PSVersionTable.Platform)
$IsAdmin      = if ($IsWindowsOS) {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
} else { $false }

# ---------------------------------------------------------------------------
# ── MODULE 1: ProtectedItems ──────────────────────────────────────────────
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '━━━ ProtectedItems module ━━━' -ForegroundColor Cyan

Import-Module (Join-Path $ModulesDir 'ProtectedItems.psm1') -Force

it 'Get-EssentialServices returns a non-empty array' {
    $services = Get-EssentialServices
    Assert-True ($services.Count -gt 0) 'Essential services list should not be empty'
}

it 'Get-EssentialServices contains RpcSs' {
    Assert-Contains (Get-EssentialServices) 'RpcSs'
}

it 'Get-EssentialServices contains WinDefend' {
    Assert-Contains (Get-EssentialServices) 'WinDefend'
}

it 'Get-EssentialServices contains Audiosrv (audio needed by games)' {
    Assert-Contains (Get-EssentialServices) 'Audiosrv'
}

it 'Get-ProtectedServices includes essential + protected items' {
    $all = Get-ProtectedServices
    Assert-Contains $all 'RpcSs'
    Assert-Contains $all 'EasyAntiCheat'
    Assert-Contains $all 'BEService'
}

it 'Get-ProtectedServices contains Steam Client Service' {
    Assert-Contains (Get-ProtectedServices) 'Steam Client Service'
}

it 'Get-ProtectedServices contains MSI Afterburner' {
    Assert-Contains (Get-ProtectedServices) 'MSIAfterburner'
}

it 'Get-ProtectedProcesses returns a non-empty array' {
    Assert-True ((Get-ProtectedProcesses).Count -gt 0)
}

it 'Get-ProtectedProcesses contains steam' {
    Assert-Contains (Get-ProtectedProcesses) 'steam'
}

it 'Get-ProtectedProcesses contains EasyAntiCheat' {
    Assert-Contains (Get-ProtectedProcesses) 'EasyAntiCheat'
}

it 'Get-ProtectedProcesses contains lsass (system process)' {
    Assert-Contains (Get-ProtectedProcesses) 'lsass'
}

it 'Test-ServiceProtected returns TRUE for RpcSs' {
    Assert-True (Test-ServiceProtected 'RpcSs')
}

it 'Test-ServiceProtected returns TRUE for EasyAntiCheat' {
    Assert-True (Test-ServiceProtected 'EasyAntiCheat')
}

it 'Test-ServiceProtected returns TRUE case-insensitively' {
    Assert-True (Test-ServiceProtected 'easyanticheat')
    Assert-True (Test-ServiceProtected 'RPCSS')
    Assert-True (Test-ServiceProtected 'windefend')
}

it 'Test-ServiceProtected returns FALSE for SysMain (stoppable service)' {
    Assert-False (Test-ServiceProtected 'SysMain')
}

it 'Test-ServiceProtected returns FALSE for WSearch (stoppable service)' {
    Assert-False (Test-ServiceProtected 'WSearch')
}

it 'Test-ProcessProtected returns TRUE for steam' {
    Assert-True (Test-ProcessProtected 'steam')
}

it 'Test-ProcessProtected strips .exe suffix' {
    Assert-True (Test-ProcessProtected 'steam.exe')
    Assert-True (Test-ProcessProtected 'EasyAntiCheat.exe')
}

it 'Test-ProcessProtected returns FALSE for notepad' {
    Assert-False (Test-ProcessProtected 'notepad')
}

it 'Test-ProcessProtected returns TRUE for MSIAfterburner (OC tool)' {
    Assert-True (Test-ProcessProtected 'MSIAfterburner')
}

it 'Test-ProcessProtected returns TRUE for HWiNFO64 (monitoring tool)' {
    Assert-True (Test-ProcessProtected 'HWiNFO64')
}

it 'Get-ProtectedServices returns unique values only' {
    $all = Get-ProtectedServices
    $unique = $all | Select-Object -Unique
    Assert-Equal $all.Count $unique.Count 'Protected services list has duplicates'
}

# ---------------------------------------------------------------------------
# ── MODULE 2: Optimizations ───────────────────────────────────────────────
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '━━━ Optimizations module ━━━' -ForegroundColor Cyan

Import-Module (Join-Path $ModulesDir 'Optimizations.psm1') -Force

it 'Optimizations module exports Enable-GamingOptimizations' {
    $cmd = Get-Command Enable-GamingOptimizations -ErrorAction SilentlyContinue
    Assert-NotNull $cmd 'Enable-GamingOptimizations should be exported'
}

it 'Disable-GamingOptimizations is NOT exported (rollback permanently removed)' {
    $cmd = Get-Command Disable-GamingOptimizations -ErrorAction SilentlyContinue
    Assert-True ($null -eq $cmd) 'Disable-GamingOptimizations should not be exported on a console OS'
}

if ($IsWindowsOS -and $IsAdmin) {
    it 'Enable-GamingOptimizations runs without throwing' {
        Enable-GamingOptimizations
    }

    it 'MMCSS Games profile GPU Priority is 8 after Enable' {
        Enable-GamingOptimizations
        $val = (Get-ItemProperty `
            'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' `
            -Name 'GPU Priority' -ErrorAction SilentlyContinue).'GPU Priority'
        Assert-Equal $val 8
    }

    it 'MMCSS Games profile Priority is 6 after Enable' {
        $val = (Get-ItemProperty `
            'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' `
            -Name 'Priority' -ErrorAction SilentlyContinue).Priority
        Assert-Equal $val 6
    }

    it 'NetworkThrottlingIndex is 0xFFFFFFFF after Enable' {
        $val = (Get-ItemProperty `
            'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' `
            -Name 'NetworkThrottlingIndex' -ErrorAction SilentlyContinue).NetworkThrottlingIndex
        Assert-Equal $val 0xFFFFFFFF
    }

    it 'DisablePagingExecutive is 1 after Enable' {
        $val = (Get-ItemProperty `
            'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' `
            -Name 'DisablePagingExecutive' -ErrorAction SilentlyContinue).DisablePagingExecutive
        Assert-Equal $val 1
    }

} else {
    skip 'Enable-GamingOptimizations runs without throwing'    'Requires Admin on Windows'
    skip 'MMCSS Games profile GPU Priority is 8 after Enable' 'Requires Admin on Windows'
    skip 'MMCSS Games profile Priority is 6 after Enable'     'Requires Admin on Windows'
    skip 'NetworkThrottlingIndex is 0xFFFFFFFF after Enable'  'Requires Admin on Windows'
    skip 'DisablePagingExecutive is 1 after Enable'           'Requires Admin on Windows'
}

# ---------------------------------------------------------------------------
# ── CONFIG FILE ───────────────────────────────────────────────────────────
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '━━━ Configuration file ━━━' -ForegroundColor Cyan

it 'config/settings.json exists' {
    $cfg = Join-Path $RepoRoot 'config\settings.json'
    Assert-True (Test-Path $cfg) 'settings.json should exist'
}

it 'config/settings.json is valid JSON' {
    $cfg = Join-Path $RepoRoot 'config\settings.json'
    $json = Get-Content $cfg -Raw | ConvertFrom-Json
    Assert-NotNull $json
}

it 'config/settings.json contains EnableHAGS key' {
    $cfg  = Join-Path $RepoRoot 'config\settings.json'
    $json = Get-Content $cfg -Raw | ConvertFrom-Json
    Assert-NotNull $json.EnableHAGS
}

it 'config/settings.json does not contain dead AutoRestoreAtLogon key' {
    $cfg  = Join-Path $RepoRoot 'config\settings.json'
    $json = Get-Content $cfg -Raw | ConvertFrom-Json
    Assert-True ($null -eq $json.PSObject.Properties['AutoRestoreAtLogon']) `
        'AutoRestoreAtLogon should be removed (rollback permanently disabled)'
}

it 'config/kiosk.settings.json exists' {
    $cfg = Join-Path $RepoRoot 'config\kiosk.settings.json'
    Assert-True (Test-Path $cfg) 'kiosk.settings.json should exist'
}

it 'config/kiosk.settings.json is valid JSON' {
    $cfg = Join-Path $RepoRoot 'config\kiosk.settings.json'
    $json = Get-Content $cfg -Raw | ConvertFrom-Json
    Assert-NotNull $json
}

it 'config/kiosk.settings.json CreateRestorePoint is false (rollback permanently disabled)' {
    $cfg = Join-Path $RepoRoot 'config\kiosk.settings.json'
    $json = Get-Content $cfg -Raw | ConvertFrom-Json
    Assert-True ($json.CreateRestorePoint -eq $false) 'CreateRestorePoint must be false on a console OS'
}

it 'config/kiosk.settings.json contains Profile key' {
    $cfg = Join-Path $RepoRoot 'config\kiosk.settings.json'
    $json = Get-Content $cfg -Raw | ConvertFrom-Json
    Assert-NotNull $json.Profile
}

it 'config/kiosk.settings.json supports DedicatedGaming profile' {
    $cfg = Join-Path $RepoRoot 'config\kiosk.settings.json'
    $json = Get-Content $cfg -Raw | ConvertFrom-Json
    Assert-NotNull $json.ServiceProfiles.DedicatedGaming
    Assert-NotNull $json.PowerPlan.DedicatedGaming
}

it 'config/kiosk.settings.json contains StartupAllowList for gaming-only mode' {
    $cfg = Join-Path $RepoRoot 'config\kiosk.settings.json'
    $json = Get-Content $cfg -Raw | ConvertFrom-Json
    Assert-True ($json.StartupAllowList.Count -gt 0) 'StartupAllowList should include launcher/anti-cheat patterns'
}

it 'config/kiosk.settings.json enables gaming-only startup mode by default' {
    $cfg = Join-Path $RepoRoot 'config\kiosk.settings.json'
    $json = Get-Content $cfg -Raw | ConvertFrom-Json
    Assert-True ($json.OptionalFeatures.EnforceGamingOnlyStartup -eq $true) 'EnforceGamingOnlyStartup should default to true'
}

it 'GamingKioskProfile.ps1 exists' {
    $scriptPath = Join-Path $RepoRoot 'GamingKioskProfile.ps1'
    Assert-True (Test-Path $scriptPath) 'GamingKioskProfile.ps1 should exist'
}

it 'config/settings.json contains EnableStreaming key' {
    $cfg  = Join-Path $RepoRoot 'config\settings.json'
    $json = Get-Content $cfg -Raw | ConvertFrom-Json
    Assert-NotNull ($json.PSObject.Properties['EnableStreaming']) 'EnableStreaming key should exist in settings.json'
}

it 'config/streaming.example.json exists' {
    $cfg = Join-Path $RepoRoot 'config\streaming.example.json'
    Assert-True (Test-Path $cfg) 'streaming.example.json should exist'
}

it 'config/streaming.example.json is valid JSON' {
    $cfg  = Join-Path $RepoRoot 'config\streaming.example.json'
    $json = Get-Content $cfg -Raw | ConvertFrom-Json
    Assert-NotNull $json
}

it 'config/streaming.example.json contains YouTubeStreamKey key' {
    $cfg  = Join-Path $RepoRoot 'config\streaming.example.json'
    $json = Get-Content $cfg -Raw | ConvertFrom-Json
    Assert-NotNull $json.YouTubeStreamKey
}

it 'config/streaming.json is not tracked in git (git-ignored)' {
    $gitignore = Join-Path $RepoRoot '.gitignore'
    Assert-True (Test-Path $gitignore) '.gitignore should exist'
    $content = Get-Content $gitignore -Raw
    Assert-True ($content -match 'streaming\.json') '.gitignore should exclude streaming.json'
}

# ---------------------------------------------------------------------------
# ── MODULE 4: Streaming ───────────────────────────────────────────────────
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '━━━ Streaming module ━━━' -ForegroundColor Cyan

Import-Module (Join-Path $ModulesDir 'Streaming.psm1') -Force

it 'Streaming module exports Read-StreamingConfig' {
    Assert-NotNull (Get-Command Read-StreamingConfig -ErrorAction SilentlyContinue) `
        'Read-StreamingConfig should be exported'
}

it 'Streaming module exports Start-GameStream' {
    Assert-NotNull (Get-Command Start-GameStream -ErrorAction SilentlyContinue) `
        'Start-GameStream should be exported'
}

it 'Streaming module exports Stop-GameStream' {
    Assert-NotNull (Get-Command Stop-GameStream -ErrorAction SilentlyContinue) `
        'Stop-GameStream should be exported'
}

it 'Streaming module exports Watch-GameProcess' {
    Assert-NotNull (Get-Command Watch-GameProcess -ErrorAction SilentlyContinue) `
        'Watch-GameProcess should be exported'
}

it 'Streaming module exports Start-StreamingWatcher' {
    Assert-NotNull (Get-Command Start-StreamingWatcher -ErrorAction SilentlyContinue) `
        'Start-StreamingWatcher should be exported'
}

it 'Streaming module exports Stop-StreamingWatcher' {
    Assert-NotNull (Get-Command Stop-StreamingWatcher -ErrorAction SilentlyContinue) `
        'Stop-StreamingWatcher should be exported'
}

it 'Read-StreamingConfig throws when config file does not exist' {
    $threw = $false
    try {
        Read-StreamingConfig -ConfigPath 'C:\nonexistent\streaming.json'
    } catch {
        $threw = $true
    }
    Assert-True $threw 'Read-StreamingConfig should throw for a missing file'
}

it 'Read-StreamingConfig throws when YouTubeStreamKey is the placeholder' {
    $tmpFile = [System.IO.Path]::GetTempFileName()
    try {
        @{
            YouTubeStreamKey = 'xxxx-xxxx-xxxx-xxxx-xxxx'
            OBSPath          = 'C:\Program Files\obs-studio\bin\64bit\obs64.exe'
        } | ConvertTo-Json | Set-Content -Path $tmpFile -Encoding UTF8
        $threw = $false
        try {
            Read-StreamingConfig -ConfigPath $tmpFile
        } catch {
            $threw = $true
        }
        Assert-True $threw 'Read-StreamingConfig should throw for placeholder stream key'
    } finally {
        Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
    }
}

it 'Read-StreamingConfig throws when YouTubeStreamKey is empty' {
    $tmpFile = [System.IO.Path]::GetTempFileName()
    try {
        @{
            YouTubeStreamKey = ''
            OBSPath          = 'C:\obs\obs64.exe'
        } | ConvertTo-Json | Set-Content -Path $tmpFile -Encoding UTF8
        $threw = $false
        try {
            Read-StreamingConfig -ConfigPath $tmpFile
        } catch {
            $threw = $true
        }
        Assert-True $threw 'Read-StreamingConfig should throw for empty stream key'
    } finally {
        Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
    }
}

it 'Read-StreamingConfig throws when OBSPath does not exist on disk' {
    $tmpFile = [System.IO.Path]::GetTempFileName()
    try {
        @{
            YouTubeStreamKey = 'real-key-value'
            OBSPath          = 'C:\nonexistent\obs64.exe'
        } | ConvertTo-Json | Set-Content -Path $tmpFile -Encoding UTF8
        $threw = $false
        try {
            Read-StreamingConfig -ConfigPath $tmpFile
        } catch {
            $threw = $true
        }
        Assert-True $threw 'Read-StreamingConfig should throw when OBS exe is not found'
    } finally {
        Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
    }
}

it 'Stop-GameStream does not throw when OBS is not running' {
    # OBS is not installed in the test environment; function should exit cleanly.
    Stop-GameStream
}

# ---------------------------------------------------------------------------
# ── GAMING KIOSK PROFILE BEHAVIORAL TESTS ─────────────────────────────────
# ---------------------------------------------------------------------------

# Extract helper functions from the kiosk script for unit testing.
# We parse the script AST to avoid executing the top-level param/main logic.
$kioskScriptPath = Join-Path $RepoRoot 'GamingKioskProfile.ps1'
$kioskAst = [System.Management.Automation.Language.Parser]::ParseFile($kioskScriptPath, [ref]$null, [ref]$null)
$kioskFunctions = $kioskAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)

# Define kiosk-level variables needed by the extracted functions
$UltimatePerfGuid = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$HighPerfGuid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'

foreach ($fn in $kioskFunctions) {
    if ($fn.Name -in @('Merge-Hashtable', 'ConvertFrom-PSObjectToHashtable', 'Resolve-PowerPlanGuid')) {
        . ([ScriptBlock]::Create($fn.Extent.Text))
    }
}

it 'Resolve-PowerPlanGuid returns correct GUID for UltimatePerformance' {
    $result = Resolve-PowerPlanGuid -Name 'UltimatePerformance'
    Assert-True ($result -eq 'e9a42b02-d5df-448d-aa00-03f14749eb61') `
        "Expected UltimatePerformance GUID, got: $result"
}

it 'Resolve-PowerPlanGuid returns correct GUID for HighPerformance' {
    $result = Resolve-PowerPlanGuid -Name 'HighPerformance'
    Assert-True ($result -eq '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c') `
        "Expected HighPerformance GUID, got: $result"
}

it 'Resolve-PowerPlanGuid passes through a raw GUID string' {
    $customGuid = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
    $result = Resolve-PowerPlanGuid -Name $customGuid
    Assert-True ($result -eq $customGuid) `
        "Expected passthrough of custom GUID, got: $result"
}

it 'Resolve-PowerPlanGuid throws for invalid plan name' {
    $threw = $false
    try { Resolve-PowerPlanGuid -Name 'NotARealPlan' } catch { $threw = $true }
    Assert-True $threw 'Should throw for unsupported power plan name'
}

it 'Merge-Hashtable deep-merges nested keys' {
    $base = @{ a = @{ x = 1; y = 2 }; b = 'keep' }
    $override = @{ a = @{ y = 99; z = 3 } }
    $result = Merge-Hashtable -Base $base -Override $override
    Assert-True ($result.a.x -eq 1) 'Base key a.x should be preserved'
    Assert-True ($result.a.y -eq 99) 'Override key a.y should replace base'
    Assert-True ($result.a.z -eq 3) 'New key a.z should be added'
    Assert-True ($result.b -eq 'keep') 'Unrelated key b should be preserved'
}

it 'Merge-Hashtable returns base when override is null' {
    $base = @{ a = 1 }
    $result = Merge-Hashtable -Base $base -Override $null
    Assert-True ($result.a -eq 1) 'Base should be returned unchanged'
}

# ---------------------------------------------------------------------------
# ── SUMMARY ───────────────────────────────────────────────────────────────
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' -ForegroundColor Cyan
$totalColor = if ($Script:Failed -gt 0) { 'Red' } else { 'Green' }
Write-Host ("  Results: {0} passed, {1} failed, {2} skipped" -f `
    $Script:Passed, $Script:Failed, $Script:Skipped) -ForegroundColor $totalColor
Write-Host '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' -ForegroundColor Cyan
Write-Host ''

exit ($Script:Failed -gt 0 ? 1 : 0)
