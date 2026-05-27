# GamingOptimizer for Windows 11

A one-command optimization pipeline that turns a fresh Windows 11 Pro install
into a **dedicated gaming console**. Run the script once and your system is
permanently optimized for peak gaming performance, with optional automatic
YouTube streaming via OBS Studio.

This is designed for a dedicated gaming NVMe — optimizations are applied once
and persist across reboots. There is no revert path by design.

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
| **Background services** | Stops SysMain, Windows Search, telemetry, etc. |
| **Launcher priorities** | Raises Steam, Epic, Battle.net, EA App, etc. to AboveNormal |
| **Fullscreen / GameDVR** | Disables Game DVR recording overhead; enables FSO |
| **Game streaming** | Auto-detects game launch → starts OBS Studio → streams to YouTube; stops when the game exits |
| **Kiosk profile** | Full console experience: auto-logon, shell replacement, startup filtering |

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

# Apply all optimizations (permanent)
.\GamingOptimizer.ps1 -Mode Enable

# Check current status
.\GamingOptimizer.ps1 -Mode Status
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

### Gaming kiosk profile deployment (persistent console setup)

Use this when you want a permanent console-like daily mode on Windows 11 Pro
installed on a dedicated NVMe drive. Optimizations are applied once and
persist — there is no rollback path.

```powershell
# Deploy with default DedicatedGaming profile (console-like mode)
.\GamingKioskProfile.ps1 -Mode Deploy

# Show kiosk status
.\GamingKioskProfile.ps1 -Mode Status
```

Configuration file:

`config\kiosk.settings.json`

Key options include:
- `Profile`: `Conservative`, `Aggressive`, or `DedicatedGaming`
- Launcher setup (`Playnite` fullscreen or `Steam` Big Picture)
- Optional auto-logon for a dedicated gaming account
- Optional shell replacement for full console UX
- Configurable startup deny list (`StartupDenyList`) for noisy background apps
- Optional startup allow list (`StartupAllowList`) + `EnforceGamingOnlyStartup` for gaming-only boot entries
- Conditional low-risk service toggles (print/location/diagnostics/etc.)
- Optional VBS/HVCI disable (only when validated for your game/anti-cheat set)

> ⚠️ `AutoLogon` stores credentials in plaintext Winlogon registry values.
> Use only on physically secured, dedicated gaming systems.

---

## How it works

```
┌─────────────────────────────────────────────────────────────────┐
│  GamingOptimizer.ps1  (orchestrator)                            │
│                                                                 │
│  Enable mode (one-time, permanent)                              │
│  ──────────────────────────────────                             │
│  1. Enable-GamingOptimizations                                  │
│     (registry tweaks, power plan, services, priorities)         │
│  2. Start-StreamingWatcher                                      │
│     (if EnableStreaming=true in config)                          │
│                                                                 │
│  Status mode                                                    │
│  ───────────                                                    │
│  Show current optimization state                                │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│  GamingKioskProfile.ps1  (full console deployment)              │
│                                                                 │
│  Deploy mode                                                    │
│  ───────────                                                    │
│  1. Apply gaming defaults (Game Mode, DVR, FSO)                 │
│  2. Set Ultimate Performance power plan                         │
│  3. Disable startup noise (deny list, optional allow list)      │
│  4. Apply Explorer policies (clean desktop UX)                  │
│  5. Optional: auto-logon, shell replacement, service stops      │
│  6. Optional: security tuning (VBS/HVCI disable)                │
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

All optimizations are permanent — they persist across reboots.
This is by design for a dedicated gaming console OS.

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
├── GamingKioskProfile.ps1           ← Persistent kiosk profile deploy
├── GamingOptimizer.ps1              ← Main entry point / orchestrator
├── config/
│   ├── settings.json                ← User-tunable configuration
│   ├── kiosk.settings.json          ← Kiosk profile settings (Conservative/Aggressive/DedicatedGaming)
│   └── streaming.example.json       ← Template for streaming credentials
├── launcher/
│   ├── Start-GamingOptimizer.cmd    ← UAC-elevating batch launcher
│   ├── Start-GamingKioskProfile.cmd ← Kiosk deploy launcher
│   └── Start-GameStream.cmd         ← Streaming mode launcher (optimizes + streams)
├── modules/
│   ├── ProtectedItems.psm1          ← Lists of protected services & processes
│   ├── Optimizations.psm1           ← Apply all gaming tweaks (permanent)
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

## Compatibility validation matrix (recommended after kiosk deploy)

- Launchers/sign-in: Steam, Epic, Battle.net, EA App, Ubisoft Connect
- Game Pass/Xbox app sign-in and install/update flow
- Anti-cheat game checks: EAC, BattlEye, Riot Vanguard
- Controller hot-plug, audio device switching, sleep/wake resume

---

## Operational model for daily use

- Keep a scheduled patch window for Windows + launcher updates
- Pin tested GPU/chipset driver versions and update deliberately
- Use kiosk mode for daily play; administer via the desktop OS on the other NVMe

---

## Safety notes

* **Permanent optimizations**: changes are applied once and persist across
  reboots. This OS is a dedicated game console — there is no revert path.
* **No hardware changes**: no overclocking, no voltage tweaks, no firmware
  interaction.
* **Anti-cheat friendly**: Defender, secure-boot, kernel integrity, and all
  anti-cheat services remain untouched.
* **Stream privacy**: When OBS is configured with Game Capture and Application
  Audio Capture as recommended, only the game window and its audio are
  streamed. Verify your OBS scene collection setup before going live. The
  YouTube stream key is stored in a git-ignored file and written to the OBS
  profile's `service.json` before each launch (it persists in the profile
  directory between sessions).

---

## License

See [LICENSE](LICENSE).
