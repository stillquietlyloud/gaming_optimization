# GamingOptimizer for Windows 11

A one-command optimization pipeline for Windows 11 (25H1 / 25H2) that
switches your system to a peak-gaming configuration, **automatically streams
your gameplay to YouTube via OBS Studio**, and **restores your original
settings at the next reboot / logon** — no permanent changes, no stability
risks.

---

## Features

| Category | What changes |
|---|---|
| **Power plan** | Activates *Ultimate Performance* |
| **Game Mode** | Enables Windows Game Mode (`AutoGameModeEnabled`) |
| **MMCSS** | Raises GPU Priority to 8, Scheduling Category to High |
| **HAGS** | Enables Hardware-Accelerated GPU Scheduling |
| **Power Throttling** | Disabled to prevent mid-game CPU frequency cuts |
| **Visual FX** | Disables desktop animations & transparency |
| **Network** | Disables Nagle algorithm; sets `NetworkThrottlingIndex` to unlimited |
| **Memory** | Keeps kernel pages in RAM (`DisablePagingExecutive`) |
| **Background services** | Temporarily stops SysMain, Windows Search, telemetry, etc. |
| **Launcher priorities** | Raises Steam, Epic, Battle.net, EA App, etc. to AboveNormal |
| **Fullscreen / GameDVR** | Disables Game DVR recording overhead; enables FSO |
| **Game streaming** | Auto-detects game launch → starts OBS Studio → streams to YouTube; stops when the game exits |
| **Auto-restore** | Registers a Scheduled Task to undo every change at next logon |

### What is **never** touched

* **Anti-cheat** — Easy Anti-Cheat (EAC), BattlEye, Riot Vanguard, PunkBuster, FACEIT, nProtect GameGuard
* **Game launchers** — Steam, Epic Games, Battle.net/Blizzard, EA App, GOG Galaxy, Ubisoft Connect, Xbox/GamePass
* **Overclocking / monitoring tools** — MSI Afterburner, RivaTuner (RTSS), HWiNFO, CPU-Z, GPU-Z, ThrottleStop, Intel XTU, AMD Ryzen Master, EVGA Precision X1, AIDA64
* **Core Windows services** — RPC, DCOM, WMI, LSA, network stack, audio, Windows Defender, Xbox services, etc.

No hardware modifications (overclocking, voltage changes) are ever performed.

---

## Requirements

* Windows 11 (build 22000 or later; optimised for 25H1 / 25H2)
* PowerShell 5.1 or later (included with Windows 11)
* Administrator privileges
* **For streaming**: OBS Studio 28+ and a YouTube Live stream key

---

## Quick start

### Option A — Double-click launcher (recommended)

1. Right-click `launcher\Start-GamingOptimizer.cmd` → **Run as administrator**
   *(the launcher can also self-elevate via UAC)*
2. Follow the on-screen prompt.

### Option B — PowerShell directly

```powershell
# From an elevated PowerShell window:
cd path\to\gaming_optimization

# Apply all optimizations (captures state first)
.\GamingOptimizer.ps1 -Mode Enable

# Check current status
.\GamingOptimizer.ps1 -Mode Status

# Restore original settings now (without waiting for reboot)
.\GamingOptimizer.ps1 -Mode Disable
```

### Option C — Game streaming mode

1. Copy `config\streaming.example.json` → `config\streaming.json` and fill in
   your YouTube stream key and OBS settings.
2. Set `"EnableStreaming": true` in `config\settings.json`.
3. Launch with `launcher\Start-GameStream.cmd` (Run as administrator).

The streaming watcher runs in the background, automatically starts OBS when a
game is detected, and stops OBS when the game exits. See
[Streaming configuration](#streaming-configuration) below for details.

### Non-interactive / scripted use

```powershell
.\GamingOptimizer.ps1 -Mode Enable -NoPrompt
```

---

## How it works

```
┌─────────────────────────────────────────────────────────────────┐
│  GamingOptimizer.ps1  (orchestrator)                            │
│                                                                 │
│  Enable mode                     Disable mode (or at logon)     │
│  ─────────────────                ────────────────────────────  │
│  1. Save-SystemState  ──────────► 1. Disable-GamingOptimizations│
│     (snapshot to JSON)            2. Stop-StreamingWatcher       │
│  2. Enable-GamingOptimizations    3. Restore-SystemState        │
│  3. Register-RestoreTask             (from JSON snapshot)        │
│     (runs at next logon)          4. Remove-RestoreTask          │
│  4. Start-StreamingWatcher        5. Delete snapshot file        │
│     (if EnableStreaming=true)                                    │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│  Streaming.psm1  (game-stream automation)                       │
│                                                                 │
│  Watch-GameProcess (background loop)                            │
│  ────────────────────────────────────                           │
│  Poll for game process ──► Start-GameStream (inject key, OBS)   │
│  Poll for game exit    ──► Stop-GameStream  (graceful OBS stop) │
│                                                                 │
│  Auto-detect mode: any new full-screen app = game               │
│  Watch-list mode:  only named processes from streaming.json     │
└─────────────────────────────────────────────────────────────────┘
```

State is saved to `%ProgramData%\GamingOptimizer\system_state.json`.
The Scheduled Task (`GamingOptimizer_Restore`) runs as **SYSTEM** at the
next logon and calls `GamingOptimizer.ps1 -Mode Disable -NoPrompt`,
then removes itself.

---

## Configuration

Edit `config\settings.json` to enable or disable individual optimizations:

```jsonc
{
  "EnableHAGS":               true,   // Hardware-Accelerated GPU Scheduling
  "DisablePowerThrottling":   true,   // Prevent CPU frequency cuts
  "DisableVisualEffects":     true,   // Disable desktop animations
  "NetworkOptimizations":     true,   // Disable Nagle, set throttling index
  "StopNonEssentialServices": true,   // Stop SysMain, WSearch, telemetry…
  "BoostLauncherPriorities":  true,   // Raise launcher process priority
  "MmcssGamingProfile":       true,   // MMCSS Games scheduler profile
  "GameMode":                 true,   // Windows Game Mode
  "FullscreenOptimizations":  true,   // Game DVR off, FSO on
  "PowerPlan":                "UltimatePerformance",
  "LogLevel":                 "Normal",   // Silent | Normal | Verbose
  "AutoRestoreAtLogon":       true,   // Register startup restore task
  "EnableStreaming":          false,   // Enable OBS game-streaming automation
  "StreamingConfigPath":      ""      // Override path to streaming.json
}
```

### Streaming configuration

To enable automatic YouTube streaming when a game is detected:

1. Copy `config\streaming.example.json` to `config\streaming.json`.
2. Fill in the fields:

```jsonc
{
  "YouTubeStreamKey":   "xxxx-xxxx-xxxx-xxxx-xxxx",  // YouTube Studio → Go Live → Stream key
  "OBSPath":            "C:\\Program Files\\obs-studio\\bin\\64bit\\obs64.exe",
  "OBSProfileName":     "YouTubeGame",               // OBS profile configured for YouTube
  "OBSSceneCollection": "GameStreamOnly",            // Scene collection using Game Capture
  "GameProcessNames":   []                           // Empty = auto-detect full-screen apps
}
```

| Field | Description |
|---|---|
| `YouTubeStreamKey` | Your YouTube Live stream key (never committed — `streaming.json` is git-ignored). |
| `OBSPath` | Full path to `obs64.exe`. |
| `OBSProfileName` | OBS profile pre-configured to stream to YouTube RTMP. The stream key is injected automatically. |
| `OBSSceneCollection` | OBS scene collection that should use **Game Capture** (not Display Capture) and **Application Audio Capture** scoped to the game executable only. When configured this way, your webcam, desktop, and non-game audio are not captured. |
| `GameProcessNames` | List of process names to watch (e.g. `["cs2.exe", "Overwatch.exe"]`). Leave empty `[]` to auto-detect any new full-screen application. |

> **Privacy by design**: When you set up OBS with Game Capture and
> Application Audio Capture (as recommended above), only the game window and
> its audio are streamed. Desktop content, other applications, microphone, and
> webcam are excluded by the scene collection configuration — ensure you verify
> your OBS setup before going live. The YouTube stream key is stored only in
> `config\streaming.json` (git-ignored) and is written to the OBS profile's
> `service.json` before each launch; it persists in the OBS profile directory
> between sessions.

---

## Project structure

```
gaming_optimization/
├── GamingOptimizer.ps1              ← Main entry point / orchestrator
├── config/
│   ├── settings.json                ← User-tunable configuration
│   └── streaming.example.json       ← Template for streaming credentials
├── launcher/
│   ├── Start-GamingOptimizer.cmd    ← UAC-elevating batch launcher
│   └── Start-GameStream.cmd         ← Streaming mode launcher (optimizes + streams)
├── modules/
│   ├── ProtectedItems.psm1          ← Lists of protected services & processes
│   ├── StateCapture.psm1            ← Snapshot & restore system state
│   ├── Optimizations.psm1           ← Apply / revert all gaming tweaks
│   └── Streaming.psm1              ← OBS game-streaming automation
└── tests/
    └── Invoke-Tests.ps1             ← Self-contained test suite
```

---

## Running tests

```powershell
# From any PowerShell session (some tests require Admin):
.\tests\Invoke-Tests.ps1

# Verbose output:
.\tests\Invoke-Tests.ps1 -Verbose
```

Tests that require Administrator privileges or a live Windows environment
are automatically skipped when run in CI or without elevation.

---

## Safety notes

* **Reboot-safe**: every change is captured before it is made; the Scheduled
  Task reverts everything at the next logon even if you forget to run
  `-Mode Disable`.
* **No hardware changes**: no overclocking, no voltage tweaks, no firmware
  interaction.
* **Anti-cheat friendly**: Defender, secure-boot, kernel integrity, and all
  anti-cheat services remain untouched.
* **Idempotent disable**: running `-Mode Disable` when no state file exists
  still safely reverts known registry tweaks.
* **Stream privacy**: When OBS is configured with Game Capture and Application
  Audio Capture as recommended, only the game window and its audio are
  streamed. Verify your OBS scene collection setup before going live. The
  YouTube stream key is stored in a git-ignored file and written to the OBS
  profile's `service.json` before each launch (it persists in the profile
  directory between sessions).

---

## License

See [LICENSE](LICENSE).
