#Requires -Version 5.1
<#
.SYNOPSIS
    Self-contained tests for the GamingOptimizer modules.
    No external test framework required – runs on any machine with PS 5.1+.

.DESCRIPTION
    Tests are grouped into sections matching the three main modules:
      1. ProtectedItems  – list contents and helper functions
      2. StateCapture    – Save / Restore / task registration logic
      3. Optimizations   – registry/service helper validation

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
# ── MODULE 2: StateCapture ────────────────────────────────────────────────
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '━━━ StateCapture module ━━━' -ForegroundColor Cyan

Import-Module (Join-Path $ModulesDir 'StateCapture.psm1') -Force

it 'Get-StateFilePath returns a non-empty string' {
    $path = Get-StateFilePath
    Assert-True ($path.Length -gt 0) 'StateFilePath should not be empty'
}

it 'Get-StateFilePath returns a .json path' {
    Assert-True ((Get-StateFilePath) -like '*.json')
}

it 'Test-StateExists returns a boolean' {
    $result = Test-StateExists
    Assert-True (($result -eq $true) -or ($result -eq $false))
}

if ($IsWindowsOS -and $IsAdmin) {
    it 'Save-SystemState creates the state file' {
        # Remove any pre-existing state
        $path = Get-StateFilePath
        if (Test-Path $path) { Remove-Item $path -Force }

        $saved = Save-SystemState
        Assert-True (Test-Path $saved) 'State file should exist after Save-SystemState'
    }

    it 'Save-SystemState state file is valid JSON' {
        $path = Get-StateFilePath
        Assert-True (Test-Path $path)
        $json = Get-Content $path -Raw | ConvertFrom-Json
        Assert-NotNull $json
    }

    it 'Saved state contains required top-level keys' {
        $path = Get-StateFilePath
        $json = Get-Content $path -Raw | ConvertFrom-Json
        Assert-NotNull $json.CapturedAt
        Assert-NotNull $json.Services
        Assert-NotNull $json.Registry
    }

    it 'Saved state CapturedAt is a parseable date' {
        $path = Get-StateFilePath
        $json = Get-Content $path -Raw | ConvertFrom-Json
        $dt = [datetime]$json.CapturedAt
        Assert-True ($dt -ne $null)
    }

    it 'Saved state Services is an array' {
        $path = Get-StateFilePath
        $json = Get-Content $path -Raw | ConvertFrom-Json
        Assert-True ($json.Services -is [array] -or $json.Services.GetType().Name -match 'Object')
    }

    it 'Test-StateExists returns TRUE after Save-SystemState' {
        Assert-True (Test-StateExists)
    }

    it 'Restore-SystemState runs without error' {
        # Just verify it does not throw; state will be restored from the file saved above
        Restore-SystemState
    }

    it 'Test-StateExists is still TRUE after Restore-SystemState (file untouched by restore)' {
        # StateCapture.Restore only changes settings; the file itself is cleaned up by the orchestrator
        Assert-True (Test-StateExists)
    }

    # Clean up state file after tests
    $stateFile = Get-StateFilePath
    if (Test-Path $stateFile) { Remove-Item $stateFile -Force }

} else {
    skip 'Save-SystemState creates the state file'    'Requires Admin on Windows'
    skip 'Save-SystemState state file is valid JSON'  'Requires Admin on Windows'
    skip 'Saved state contains required top-level keys' 'Requires Admin on Windows'
    skip 'Saved state CapturedAt is a parseable date'  'Requires Admin on Windows'
    skip 'Saved state Services is an array'            'Requires Admin on Windows'
    skip 'Test-StateExists returns TRUE after Save-SystemState' 'Requires Admin on Windows'
    skip 'Restore-SystemState runs without error'      'Requires Admin on Windows'
    skip 'Test-StateExists is still TRUE after Restore-SystemState' 'Requires Admin on Windows'
}

# ---------------------------------------------------------------------------
# ── MODULE 3: Optimizations ───────────────────────────────────────────────
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '━━━ Optimizations module ━━━' -ForegroundColor Cyan

Import-Module (Join-Path $ModulesDir 'Optimizations.psm1') -Force

it 'Optimizations module exports Enable-GamingOptimizations' {
    $cmd = Get-Command Enable-GamingOptimizations -ErrorAction SilentlyContinue
    Assert-NotNull $cmd 'Enable-GamingOptimizations should be exported'
}

it 'Optimizations module exports Disable-GamingOptimizations' {
    $cmd = Get-Command Disable-GamingOptimizations -ErrorAction SilentlyContinue
    Assert-NotNull $cmd 'Disable-GamingOptimizations should be exported'
}

if ($IsWindowsOS -and $IsAdmin) {
    it 'Enable-GamingOptimizations runs without throwing' {
        Enable-GamingOptimizations
    }

    it 'Disable-GamingOptimizations runs without throwing' {
        Disable-GamingOptimizations
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

    it 'Disable-GamingOptimizations resets MMCSS GPU Priority to 2' {
        Disable-GamingOptimizations
        $val = (Get-ItemProperty `
            'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' `
            -Name 'GPU Priority' -ErrorAction SilentlyContinue).'GPU Priority'
        Assert-Equal $val 2
    }

    it 'Disable-GamingOptimizations resets NetworkThrottlingIndex to 10' {
        $val = (Get-ItemProperty `
            'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' `
            -Name 'NetworkThrottlingIndex' -ErrorAction SilentlyContinue).NetworkThrottlingIndex
        Assert-Equal $val 10
    }
} else {
    skip 'Enable-GamingOptimizations runs without throwing'            'Requires Admin on Windows'
    skip 'Disable-GamingOptimizations runs without throwing'           'Requires Admin on Windows'
    skip 'MMCSS Games profile GPU Priority is 8 after Enable'         'Requires Admin on Windows'
    skip 'MMCSS Games profile Priority is 6 after Enable'             'Requires Admin on Windows'
    skip 'NetworkThrottlingIndex is 0xFFFFFFFF after Enable'          'Requires Admin on Windows'
    skip 'DisablePagingExecutive is 1 after Enable'                   'Requires Admin on Windows'
    skip 'Disable-GamingOptimizations resets MMCSS GPU Priority to 2' 'Requires Admin on Windows'
    skip 'Disable-GamingOptimizations resets NetworkThrottlingIndex'  'Requires Admin on Windows'
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

it 'config/settings.json contains AutoRestoreAtLogon key' {
    $cfg  = Join-Path $RepoRoot 'config\settings.json'
    $json = Get-Content $cfg -Raw | ConvertFrom-Json
    Assert-NotNull $json.AutoRestoreAtLogon
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
