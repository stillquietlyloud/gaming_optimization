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

it 'config/settings.json AutoRestoreAtLogon is false (rollback permanently disabled)' {
    $cfg  = Join-Path $RepoRoot 'config\settings.json'
    $json = Get-Content $cfg -Raw | ConvertFrom-Json
    Assert-True ($json.AutoRestoreAtLogon -eq $false) 'AutoRestoreAtLogon must be false on a console OS'
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
