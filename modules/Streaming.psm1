#Requires -Version 5.1
<#
.SYNOPSIS
    Automates OBS Studio game streaming to YouTube within the GamingOptimizer pipeline.

.DESCRIPTION
    Functions exported:
      Read-StreamingConfig    – Load and validate config/streaming.json.
      Start-GameStream        – Inject the YouTube stream key into the OBS profile and
                                launch OBS in streaming mode.
      Stop-GameStream         – Gracefully stop OBS Studio.
      Watch-GameProcess       – Blocking loop: start streaming when a watched game
                                process appears, stop when it exits.
      Start-StreamingWatcher  – Spawn Watch-GameProcess as a hidden background process.
      Stop-StreamingWatcher   – Kill the background watcher and stop OBS.

.NOTES
    Requires OBS Studio 28+ (which supports --startstreaming on the CLI).
    The YouTube stream key is stored only in config/streaming.json (git-ignored)
    and is written transiently to the OBS profile's service.json before each launch.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:ModuleDir = if ($PSScriptRoot) { $PSScriptRoot } else {
    Split-Path $MyInvocation.MyCommand.Path -Parent
}

$Script:DefaultConfigPath = Join-Path $Script:ModuleDir '..\config\streaming.json'

$_ProgramData = if ($env:ProgramData) { $env:ProgramData } else {
    Join-Path ([System.IO.Path]::GetTempPath()) '.GamingOptimizer'
}
$Script:PidFilePath    = Join-Path $_ProgramData 'GamingOptimizer\streaming_watcher.pid'
$Script:OBSProcessName               = 'obs64'
$Script:PollIntervalMs               = 3000   # milliseconds between process-watch iterations
$Script:OBSGracefulShutdownTimeoutMs = 5000   # ms to wait for OBS to exit cleanly before force-kill

# Processes that must never be treated as a game in auto-detect mode.
$Script:AutoDetectExcludeProcesses = @(
    'explorer', 'shellexperiencehost', 'searchhost', 'cortana',
    'lockapp', 'logonui', 'dwm', 'obs64', 'obs32', 'obs',
    'applicationframehost', 'systemsettings', 'taskmgr',
    'mmc', 'regedit', 'cmd', 'powershell', 'pwsh',
    'winlogon', 'csrss', 'lsass', 'services', 'svchost'
)

# ---------------------------------------------------------------------------
# PRIVATE: Get-ProcessNameWithoutExtension
# ---------------------------------------------------------------------------
function Get-ProcessNameWithoutExtension {
    param([Parameter(Mandatory)] [string]$Name)
    return $Name -replace '\.exe$', ''
}
$Script:FullScreenDetectorSource = @'
using System;
using System.Runtime.InteropServices;
using System.Diagnostics;

public class GamingOptimizerFullScreenDetector {
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool   GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] static extern int    GetSystemMetrics(int nIndex);
    [DllImport("user32.dll")] static extern uint   GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    public static string GetFullScreenProcessName() {
        IntPtr hwnd = GetForegroundWindow();
        if (hwnd == IntPtr.Zero) return null;
        RECT rect;
        if (!GetWindowRect(hwnd, out rect)) return null;
        int sw = GetSystemMetrics(0); // SM_CXSCREEN
        int sh = GetSystemMetrics(1); // SM_CYSCREEN
        bool isFullScreen = rect.Left  <= 0  && rect.Top    <= 0
                         && rect.Right >= sw && rect.Bottom >= sh;
        if (!isFullScreen) return null;
        uint pid;
        GetWindowThreadProcessId(hwnd, out pid);
        try   { return Process.GetProcessById((int)pid).ProcessName; }
        catch { return null; }
    }
}
'@

# ---------------------------------------------------------------------------
# PUBLIC: Read-StreamingConfig
# ---------------------------------------------------------------------------
function Read-StreamingConfig {
    <#
    .SYNOPSIS
        Loads and validates config/streaming.json.

    .PARAMETER ConfigPath
        Full path to streaming.json. Defaults to config/streaming.json next to
        the modules directory.

    .OUTPUTS
        [hashtable] Validated streaming configuration.
    #>
    param(
        [string]$ConfigPath = $Script:DefaultConfigPath
    )

    if (-not (Test-Path $ConfigPath)) {
        throw ("Streaming config not found at '$ConfigPath'. " +
               "Copy config\streaming.example.json to config\streaming.json " +
               "and fill in your credentials.")
    }

    $raw = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
    $cfg = @{}
    $raw.PSObject.Properties |
        Where-Object { $_.Name -notlike '_*' } |
        ForEach-Object { $cfg[$_.Name] = $_.Value }

    if ([string]::IsNullOrWhiteSpace($cfg['YouTubeStreamKey']) -or
        $cfg['YouTubeStreamKey'] -eq 'xxxx-xxxx-xxxx-xxxx-xxxx') {
        throw ("YouTubeStreamKey must be set to a valid value (not empty or the placeholder) in '$ConfigPath'.")
    }

    if ([string]::IsNullOrWhiteSpace($cfg['OBSPath'])) {
        throw "OBSPath is missing or empty in '$ConfigPath'."
    }

    if (-not (Test-Path $cfg['OBSPath'])) {
        throw "OBS executable not found at '$($cfg['OBSPath'])'. Update OBSPath in '$ConfigPath'."
    }

    if (-not $cfg['OBSProfileName'])     { $cfg['OBSProfileName']    = 'YouTubeGame' }
    if (-not $cfg['OBSSceneCollection']) { $cfg['OBSSceneCollection'] = 'GameStreamOnly' }
    if ($null -eq $cfg['GameProcessNames']) { $cfg['GameProcessNames'] = @() }

    return $cfg
}

# ---------------------------------------------------------------------------
# PRIVATE: Set-OBSStreamKey – write the stream key into the OBS profile
# ---------------------------------------------------------------------------
function Set-OBSStreamKey {
    param(
        [Parameter(Mandatory)] [string]$ProfileName,
        [Parameter(Mandatory)] [string]$StreamKey
    )

    $profileDir  = Join-Path $env:APPDATA "obs-studio\basic\profiles\$ProfileName"
    $serviceFile = Join-Path $profileDir 'service.json'

    if (-not (Test-Path $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
        Write-Verbose "[Streaming] Created OBS profile directory: $profileDir"
    }

    # Minimal YouTube RTMP service definition understood by OBS.
    $serviceJson = @"
{
    "settings": {
        "key": "$StreamKey",
        "server": "rtmp://a.rtmp.youtube.com/live2"
    },
    "type": "rtmp_custom"
}
"@

    Set-Content -Path $serviceFile -Value $serviceJson -Encoding UTF8 -Force
    Write-Verbose "[Streaming] Stream key written to OBS profile: $serviceFile"
}

# ---------------------------------------------------------------------------
# PUBLIC: Start-GameStream
# ---------------------------------------------------------------------------
function Start-GameStream {
    <#
    .SYNOPSIS
        Injects the YouTube stream key into the OBS profile and launches OBS
        in streaming mode, capturing only game video and audio.

    .PARAMETER StreamConfig
        Hashtable returned by Read-StreamingConfig.

    .PARAMETER GameProcess
        Name of the game process that triggered the stream (informational).
    #>
    param(
        [Parameter(Mandatory)] [hashtable]$StreamConfig,
        [string]$GameProcess = ''
    )

    # Inject stream key into OBS profile before launching OBS.
    Set-OBSStreamKey -ProfileName $StreamConfig['OBSProfileName'] `
                     -StreamKey   $StreamConfig['YouTubeStreamKey']

    $obsArgs = @(
        '--profile',    $StreamConfig['OBSProfileName'],
        '--collection', $StreamConfig['OBSSceneCollection'],
        '--startstreaming',
        '--minimize-to-tray'
    )

    $gameLabel = if ($GameProcess) { " (game: $GameProcess)" } else { '' }
    Write-Host "[Streaming] Starting OBS Studio and beginning YouTube stream$gameLabel…" `
        -ForegroundColor Cyan
    Write-Verbose "[Streaming] OBS: $($StreamConfig['OBSPath'])  Args: $($obsArgs -join ' ')"

    Start-Process -FilePath $StreamConfig['OBSPath'] -ArgumentList $obsArgs
}

# ---------------------------------------------------------------------------
# PUBLIC: Stop-GameStream
# ---------------------------------------------------------------------------
function Stop-GameStream {
    <#
    .SYNOPSIS
        Gracefully stops OBS Studio. Falls back to a hard kill if OBS does not
        exit within 5 seconds.
    #>
    $obsProcs = Get-Process -Name $Script:OBSProcessName -ErrorAction SilentlyContinue
    if (-not $obsProcs) {
        Write-Verbose '[Streaming] OBS Studio is not running.'
        return
    }

    foreach ($proc in $obsProcs) {
        try {
            $proc.CloseMainWindow() | Out-Null
            if (-not $proc.WaitForExit($Script:OBSGracefulShutdownTimeoutMs)) {
                $proc.Kill()
            }
            Write-Verbose "[Streaming] OBS Studio stopped (PID $($proc.Id))."
        } catch {
            Write-Warning "[Streaming] Could not stop OBS (PID $($proc.Id)): $_"
        }
    }

    Write-Host '[Streaming] OBS Studio stopped.' -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# PRIVATE: Get-FullScreenProcess (Windows only)
# ---------------------------------------------------------------------------
function Get-FullScreenProcess {
    if ($null -eq $PSVersionTable.Platform -or $PSVersionTable.Platform -eq 'Win32NT') {
        if (-not ([System.Management.Automation.PSTypeName]'GamingOptimizerFullScreenDetector').Type) {
            Add-Type -TypeDefinition $Script:FullScreenDetectorSource -Language CSharp `
                     -ErrorAction SilentlyContinue
        }
        try {
            return [GamingOptimizerFullScreenDetector]::GetFullScreenProcessName()
        } catch {
            return $null
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# PUBLIC: Watch-GameProcess  (blocking loop – intended for a background process)
# ---------------------------------------------------------------------------
function Watch-GameProcess {
    <#
    .SYNOPSIS
        Polls for game processes. Starts streaming when a watched game is
        detected and stops when the game exits.

    .DESCRIPTION
        This function runs an infinite loop and is designed to be executed in
        a hidden background process spawned by Start-StreamingWatcher.

        If GameProcessNames in the config is non-empty, only those specific
        process names are watched. If the list is empty, any new full-screen
        application (excluding known desktop/system processes) is treated as a
        game.

    .PARAMETER StreamConfig
        Hashtable returned by Read-StreamingConfig.
    #>
    param(
        [Parameter(Mandatory)] [hashtable]$StreamConfig
    )

    $watchList  = @($StreamConfig['GameProcessNames'] | Where-Object { $_ })
    $autoDetect = ($watchList.Count -eq 0)
    $streaming  = $false
    $activeGame = $null

    Write-Host '[Streaming] Game watcher started.' -ForegroundColor Cyan
    if ($autoDetect) {
        Write-Host '[Streaming] Auto-detect mode: monitoring for full-screen applications.' `
            -ForegroundColor DarkCyan
    } else {
        Write-Host "[Streaming] Watching for: $($watchList -join ', ')" -ForegroundColor DarkCyan
    }

    while ($true) {
        Start-Sleep -Milliseconds $Script:PollIntervalMs

        if ($streaming) {
            # Stop streaming when the active game process exits.
            $cleanName   = Get-ProcessNameWithoutExtension $activeGame
            $gameRunning = [bool](Get-Process -Name $cleanName -ErrorAction SilentlyContinue)

            if (-not $gameRunning) {
                Write-Host "[Streaming] Game '$activeGame' has exited. Stopping stream." `
                    -ForegroundColor Yellow
                Stop-GameStream
                $streaming  = $false
                $activeGame = $null
            }
        } else {
            # Look for a game to stream.
            $foundGame = $null

            if ($autoDetect) {
                $candidate = Get-FullScreenProcess
                if ($candidate -and
                    ($Script:AutoDetectExcludeProcesses -notcontains $candidate.ToLower())) {
                    $foundGame = $candidate
                }
            } else {
                foreach ($name in $watchList) {
                    $cleanName = Get-ProcessNameWithoutExtension $name
                    if (Get-Process -Name $cleanName -ErrorAction SilentlyContinue) {
                        $foundGame = $cleanName
                        break
                    }
                }
            }

            if ($foundGame) {
                Write-Host "[Streaming] Game detected: '$foundGame'. Starting stream." `
                    -ForegroundColor Green
                Start-GameStream -StreamConfig $StreamConfig -GameProcess $foundGame
                $streaming  = $true
                $activeGame = $foundGame
            }
        }
    }
}

# ---------------------------------------------------------------------------
# PUBLIC: Start-StreamingWatcher
# ---------------------------------------------------------------------------
function Start-StreamingWatcher {
    <#
    .SYNOPSIS
        Validates the streaming config and spawns Watch-GameProcess as a hidden
        background PowerShell process.

    .PARAMETER ConfigPath
        Full path to streaming.json. Defaults to config/streaming.json.
    #>
    param(
        [string]$ConfigPath = $Script:DefaultConfigPath
    )

    # Validate config first so any errors surface immediately in the foreground.
    $null = Read-StreamingConfig -ConfigPath $ConfigPath

    # Resolve absolute path for the background process.
    $absConfig = (Resolve-Path $ConfigPath).Path
    $modulePath = Join-Path $Script:ModuleDir 'Streaming.psm1'

    # Build a self-contained script block for the background process.
    $psBlock = @"
Import-Module '$($modulePath -replace "'", "''")' -Force
`$cfg = Read-StreamingConfig -ConfigPath '$($absConfig -replace "'", "''")'
Watch-GameProcess -StreamConfig `$cfg
"@

    $encodedCmd = [Convert]::ToBase64String(
        [System.Text.Encoding]::Unicode.GetBytes($psBlock))

    Write-Host '[Streaming] Starting background game watcher…' -ForegroundColor Cyan

    # Use the running PowerShell executable so the watcher uses the same edition (5.1 / 7+).
    $psExe = (Get-Process -Id $PID).MainModule.FileName

    $proc = Start-Process -FilePath $psExe `
        -ArgumentList "-NonInteractive -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedCmd" `
        -WindowStyle Hidden `
        -PassThru

    # Persist the watcher PID so Stop-StreamingWatcher can clean it up.
    $pidDir = Split-Path $Script:PidFilePath -Parent
    if (-not (Test-Path $pidDir)) {
        New-Item -ItemType Directory -Path $pidDir -Force | Out-Null
    }
    "$($proc.Id)" | Set-Content -Path $Script:PidFilePath -Force

    Write-Host "[Streaming] Game watcher running (PID $($proc.Id))." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# PUBLIC: Stop-StreamingWatcher
# ---------------------------------------------------------------------------
function Stop-StreamingWatcher {
    <#
    .SYNOPSIS
        Stops the background game-watcher process and OBS Studio.
    #>
    if (Test-Path $Script:PidFilePath) {
        $watcherPid = $null
        try {
            $watcherPid = [int](Get-Content $Script:PidFilePath -Raw -ErrorAction SilentlyContinue)
        } catch {}

        if ($watcherPid) {
            $watcherProc = Get-Process -Id $watcherPid -ErrorAction SilentlyContinue
            if ($watcherProc) {
                try {
                    $watcherProc.Kill()
                    Write-Verbose "[Streaming] Watcher process stopped (PID $watcherPid)."
                } catch {
                    Write-Warning "[Streaming] Could not kill watcher (PID $watcherPid): $_"
                }
            }
        }

        Remove-Item $Script:PidFilePath -Force -ErrorAction SilentlyContinue
    }

    Stop-GameStream
}

Export-ModuleMember -Function `
    Read-StreamingConfig, `
    Start-GameStream, `
    Stop-GameStream, `
    Watch-GameProcess, `
    Start-StreamingWatcher, `
    Stop-StreamingWatcher
