<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/chip-Apple%20Silicon-orange?style=flat-square" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/swift-5.10-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift">
  <img src="https://img.shields.io/badge/license-MIT-green?style=flat-square" alt="License">
</p>

# OpenSlap

**Slap your MacBook. Hear it react.**

OpenSlap is a native macOS menu bar app that turns your MacBook into an interactive sound board — powered by the laptop's built-in accelerometer. Give it a tap, a slap, or a full palm strike and it plays a sound that matches the intensity. Light tap? Quiet "ow." Full send? Screaming.

Built from scratch in Swift using IOKit HID, SwiftUI, and AVAudioEngine. No Electron. No web views. No dependencies. Just ~4,200 lines of pure native macOS code.

> **This is a fun project.** It was born from the viral wave of MacBook slap apps. This implementation is 100% original, open-source, and shares no code with any other project.

---

## Demo

```
You:        *gentle tap on palm rest*
OpenSlap:   🔊 "ow."

You:        *firm slap*
OpenSlap:   🔊 "HEY! STOP THAT!"

You:        *absolute unit of a slap*
OpenSlap:   🔊 💀
```

The volume and pitch of the sound scale dynamically with how hard you hit. The app keeps a running slap counter in the menu bar and tracks your lifetime stats. You earn titles like "Curious Tapper," "Certified Slapper," and eventually "Laptop Abuse Specialist."

---

## Safety Disclaimer

> **Slapping your MacBook can damage the screen, hinges, trackpad, keyboard, or internal components and WILL void your warranty.** Repeated impacts may cause cumulative damage that isn't immediately visible.
>
> **Use this app entirely at your own risk and expense.**
>
> **The software itself causes zero damage.** It passively reads the accelerometer (a sensor that's already running) and plays audio through your speakers. That's it. The damage risk comes from *you physically hitting your laptop* — which, to be clear, we are not recommending. A gentle tap is all you need.

---

## Features

### Core
- **Real-time slap detection** at 800 Hz using the MacBook's built-in Bosch BMI286 IMU accelerometer
- **Multi-algorithm voting system** — four independent detection algorithms must agree before triggering, dramatically reducing false positives from typing, desk bumps, or screen adjustments
- **Dynamic audio scaling** — volume and pitch change based on impact force (logarithmic curve tuned to human hearing perception)
- **Adjustable sensitivity** — slider from "detects a light tap" to "requires a hard slap," sent to the daemon in real-time

### Voice Packs
| Pack | Description | Sounds |
|------|------------|--------|
| **Pain** | Protest sounds — "Ow!", "Hey! Stop that!", "Rude!", "That hurt!" | 8 clips |
| **Sexy** | Escalating reactions — intensity increases based on slap frequency over a 5-minute rolling window | 8 clips |
| **Halo** | Game sounds — "Headshot!", "Shield down!", "Critical hit!", grunts | 8 clips |
| **Custom** | Your own sounds — point it at any folder of MP3/WAV/M4A/AAC files | Unlimited |

### UI & UX
- **Menu bar app** — lives in the status bar, no dock icon, zero visual clutter
- **Slap counter** in the menu bar that updates in real-time
- **Session and lifetime statistics** — peak force, average force, slaps per minute, fun titles
- **Dark mode and light mode** support via SF Symbols
- **Onboarding screen** with safety disclaimers on first launch
- **Settings window** with tabbed interface (General, Audio, Features, About)
- **Export stats** to text file for sharing

### Extras
- **USB Moaner mode** — plays a random sound when USB devices are plugged in or unplugged
- **Keyboard Slam detection** option (lower threshold for aggressive typing)
- **Mock mode** — generates fake slap events for development and testing without root access or hardware
- **Launch at login** support via SMAppService

---

## Requirements

| Requirement | Details |
|-------------|---------|
| **macOS** | 14.0 (Sonoma) or later |
| **Chip** | Apple Silicon only — M1 Pro, M2, M3, M4 series. The SPU accelerometer does not exist on Intel Macs or base M1. |
| **Xcode** | 16.0+ (for building from source) |
| **XcodeGen** | For generating the `.xcodeproj` from `project.yml`. Install: `brew install xcodegen` |
| **Root access** | The sensor daemon requires `sudo` — Apple does not expose the accelerometer to unprivileged processes |

---

## Quick Start

### 1. Clone and generate the Xcode project

```bash
git clone https://github.com/YOUR_USERNAME/OpenSlap.git
cd OpenSlap
brew install xcodegen    # if you don't have it
xcodegen generate
```

### 2. Build both targets

**From the command line:**
```bash
# Set Xcode as the active developer directory (one-time)
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

# Build
xcodebuild -scheme OpenSlapDaemon -configuration Release -arch arm64 CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme OpenSlap -configuration Release -arch arm64 CODE_SIGNING_ALLOWED=NO build
```

**From Xcode:**
1. Open `OpenSlap.xcodeproj`
2. Select the `OpenSlapDaemon` scheme → Build (⌘B)
3. Select the `OpenSlap` scheme → Build (⌘B)

### 3. Run

```bash
# Terminal 1: Start the sensor daemon (requires root for IOKit HID access)
sudo ./build/Release/OpenSlapDaemon

# Terminal 2 (or just double-click): Launch the app
open ./build/Release/OpenSlap.app
```

### 4. Slap your MacBook

Look for the hand icon (✋) in your menu bar. Give your laptop a tap. If the counter goes up and you hear audio — you're in business.

### 5. (Optional) Install daemon as a background service

If you want the daemon to start automatically at boot:

```bash
sudo ./Scripts/install-daemon.sh
```

To remove it later:
```bash
sudo ./Scripts/uninstall-daemon.sh
```

---

## How It Works

### Architecture

OpenSlap uses a **split-privilege architecture** for security. Only the tiny daemon runs as root — the main app runs as your normal user.

```
┌──────────────────────────────────┐                    ┌──────────────────────────────┐
│                                  │   Unix Domain      │                              │
│  OpenSlap.app                    │   Socket            │  OpenSlapDaemon              │
│  (runs as your user)             │   /var/run/         │  (runs as root)              │
│                                  │   openslap.sock     │                              │
│  ┌────────────────────────┐      │                    │  ┌────────────────────────┐   │
│  │ SwiftUI Menu Bar UI    │      │  Impact events     │  │ IOKit HID              │   │
│  │ Settings & Stats       │◄─────┼────────────────────┼──│ Accelerometer Reader   │   │
│  │ Onboarding             │      │  (JSON over socket) │  │ @ 800 Hz               │   │
│  └────────────────────────┘      │                    │  └──────────┬─────────────┘   │
│                                  │                    │             │                 │
│  ┌────────────────────────┐      │  Config messages   │  ┌──────────▼─────────────┐   │
│  │ AVAudioEngine          │      │  (sensitivity,     │  │ Impact Detector        │   │
│  │ Dynamic pitch/volume   │──────┼──cooldown, etc.)───┼─►│ 4-algorithm voting     │   │
│  │ Sound pack manager     │      │                    │  │ STA/LTA + CUSUM +      │   │
│  └────────────────────────┘      │                    │  │ Kurtosis + Magnitude   │   │
│                                  │                    │  └────────────────────────┘   │
└──────────────────────────────────┘                    └──────────────────────────────┘
```

**Why two processes?**
- The daemon is tiny (~250 lines of active code) — minimal attack surface
- The app never touches IOKit or needs elevated privileges
- They communicate over a Unix domain socket with newline-delimited JSON — simple, debuggable, no special entitlements needed
- If the daemon crashes, the app stays running and reconnects automatically

### Sensor Access

The MacBook's accelerometer is part of Apple's **SPU (Sensor Processing Unit)**, which houses a **Bosch BMI286 IMU**. It's not exposed through any public Apple framework (CoreMotion is iOS/watchOS only). The only way to access it on macOS is through IOKit HID, which requires root.

The sensor appears as an HID device:
- **Vendor usage page:** `0xFF00` (Apple vendor-defined)
- **Usage:** `3` (accelerometer)
- **Vendor ID:** `0x05AC` (Apple)
- **Report size:** 22 bytes at ~800 Hz

**Report format (22 bytes):**
```
Offset  Size  Type         Description
──────  ────  ──────────── ──────────────────────────────────
 0       1    uint8        Report ID
 1       1    uint8        Flags / sequence number
 2-5     4    uint32       Sensor timestamp (not used)
 6-9     4    int32 LE     X acceleration (Q16.16 fixed-point)
10-13    4    int32 LE     Y acceleration (Q16.16 fixed-point)
14-17    4    int32 LE     Z acceleration (Q16.16 fixed-point)
18-21    4    —            Reserved / padding
```

The Q16.16 format means dividing the raw `Int32` by 65,536 gives acceleration in **g-force** units (1g ≈ 9.81 m/s²). A stationary laptop reads approximately `(0, 0, -1)g` — pure gravity in the Z axis.

### Impact Detection

Four independent algorithms process each accelerometer sample and **vote** on whether it's an impact:

#### 1. STA/LTA (Short-Term Average / Long-Term Average)
Borrowed from **seismology** — this is literally the algorithm used to detect earthquake P-wave arrivals. It compares the average signal energy over a short window (~50ms) to a long window (~1s). When the ratio spikes above a threshold, something sudden happened.

**Why it's good for slaps:** Adapts to ambient vibration. On a shaky desk, only hard slaps trigger. On a solid desk, light taps register.

#### 2. CUSUM (Cumulative Sum)
From **statistical process control** (factory quality monitoring). Accumulates deviations above a baseline. Small consistent deviations build up over time; sudden large deviations trigger immediately.

**Why it's good for slaps:** Catches both sharp impacts and sustained pressure changes that magnitude threshold alone might miss.

#### 3. Kurtosis / Peak Detection
From **signal processing**. Measures the "tailedness" of the signal distribution in a rolling window. A normal distribution has kurtosis = 3; impact signals have kurtosis >> 3 because a few extreme samples dominate.

**Why it's good for slaps:** Scale-independent — works regardless of absolute amplitude. Specifically detects the "spiky" waveform signature of impacts.

#### 4. Magnitude Threshold
The simplest algorithm. Computes total acceleration magnitude, subtracts gravity (tracked via exponential moving average), and checks if the excess exceeds a threshold.

**Why it's needed:** The other algorithms can be fooled by non-impact events. This one provides a hard floor — if total force doesn't exceed the minimum, it's not a slap regardless of what other algorithms think.

#### Voting
An impact is declared when **the configured number of algorithms agree** (default: 1, configurable). The estimated force is a confidence-weighted average of the agreeing algorithms' estimates. A cooldown period (default: 400ms) prevents a single slap from triggering multiple events due to mechanical ringing in the chassis.

### Audio Pipeline

```
AVAudioFile (.m4a) ──► AVAudioConverter ──► AVAudioPCMBuffer (engine format)
                         (at load time)            │
                                                   ▼
                    AVAudioPlayerNode ──► AVAudioUnitTimePitch ──► Output
                    (volume scaling)      (pitch scaling)
```

All audio files are **converted to the engine's native format at load time** to prevent format mismatch crashes. Volume follows a logarithmic curve (matches human hearing perception). Pitch shifts by up to ±600 cents (one tritone) based on force.

---

## Adding Custom Sounds

1. Create a folder anywhere on your Mac with audio files
2. Click the menu bar icon → gear icon → **Audio** tab
3. Select **Custom** mode
4. Click **Choose Folder** and pick your directory

**Supported formats:** MP3, WAV, M4A, AAC, AIFF, CAF

The app shuffles through all files without repeating (like a deck of cards) until every sound has played once, then reshuffles.

---

## Configuration

All settings are accessible from the menu bar popover and the Settings window (gear icon).

| Setting | Range | Default | What it does |
|---------|-------|---------|-------------|
| **Sensitivity** | 0.05g – 2.0g | 0.08g | Minimum force to register a slap. Lower = more sensitive. |
| **Cooldown** | 100ms – 2000ms | 400ms | Minimum time between detections. Prevents double-triggers. |
| **Sound Mode** | Pain / Sexy / Halo / Custom | Pain | Which voice pack to use. |
| **Volume Scaling** | On / Off | On | Scale volume based on slap force. |
| **Pitch Scaling** | On / Off | On | Scale pitch based on slap force. |
| **Master Volume** | 0% – 100% | 80% | Overall volume level. |
| **USB Moaner** | On / Off | Off | Play sounds on USB plug/unplug events. |
| **Detection Active** | On / Off | On | Master switch for slap detection. |

Settings are persisted in UserDefaults and survive app restarts.

---

## Project Structure

```
OpenSlap/
│
├── Shared/                              # Shared between app and daemon
│   ├── Constants.swift                  # Socket path, sensor params, defaults
│   ├── ImpactEvent.swift                # Message types, JSON serialization
│   └── SocketProtocol.swift             # Unix domain socket server & client
│
├── OpenSlapDaemon/                      # Privileged sensor daemon (root)
│   ├── main.swift                       # Entry point, signal handling, pipeline wiring
│   ├── SensorReader.swift               # IOKit HID accelerometer interface
│   ├── ImpactDetector.swift             # 4-algorithm voting detection engine
│   ├── Info.plist                       # Bundle metadata
│   └── com.openslap.daemon.plist        # LaunchDaemon plist template
│
├── OpenSlap/                            # User-facing SwiftUI app
│   ├── App/
│   │   └── OpenSlapApp.swift            # @main, MenuBarExtra, AppController
│   ├── Services/
│   │   ├── AudioManager.swift           # AVAudioEngine playback with format conversion
│   │   ├── SensorBridge.swift           # Socket client, mock mode, event publisher
│   │   ├── SettingsStore.swift          # UserDefaults-backed @Published settings
│   │   ├── StatsTracker.swift           # Session/lifetime slap statistics
│   │   └── USBMonitor.swift             # IOKit USB plug/unplug notifications
│   ├── Views/
│   │   ├── MenuBarView.swift            # Main popover (controls, status, quick stats)
│   │   ├── SettingsView.swift           # Tabbed settings window
│   │   ├── OnboardingView.swift         # First-launch safety disclaimer
│   │   └── StatsView.swift              # Detailed statistics popover
│   └── Resources/
│       ├── Assets.xcassets/             # App icon, asset catalog
│       └── Sounds/                      # Bundled voice packs
│           ├── pain/    (8 .m4a files)
│           ├── sexy/    (8 .m4a files)
│           └── halo/    (8 .m4a files)
│
├── Scripts/
│   ├── install-daemon.sh                # Install daemon as LaunchDaemon
│   └── uninstall-daemon.sh              # Uninstall daemon
│
├── project.yml                          # XcodeGen project specification
├── LICENSE                              # MIT
└── README.md
```

---

## Development

### Building from source

```bash
git clone https://github.com/YOUR_USERNAME/OpenSlap.git
cd OpenSlap
brew install xcodegen
xcodegen generate
xcodebuild -scheme OpenSlapDaemon -configuration Debug build
xcodebuild -scheme OpenSlap -configuration Debug build
```

### Mock mode (no hardware needed)

For development and testing without root access or Apple Silicon:

1. Launch the app (no daemon needed)
2. Click the **hammer icon** (🔨) in the menu bar popover
3. The app generates realistic synthetic impacts every 1–5 seconds

Mock impacts follow a realistic force distribution: mostly light taps (2–4g) with occasional hard slaps (6–12g), biased toward the Z axis like real slaps.

### Debugging the daemon

```bash
# Run in foreground with live output
sudo ./build/OpenSlapDaemon

# You'll see:
# [SensorReader] #1: x=+0.015g  y=-0.019g  z=-0.999g  mag=1.000g
# [Daemon] App connected
# [Daemon] Impact detected: force=0.42g [2 algorithms agreed]
# [Daemon] Config updated: sensitivity=0.15, cooldown=400ms
```

### Testing the socket manually

```bash
# Listen to events (requires socat)
socat - UNIX-CONNECT:/var/run/openslap.sock

# You'll see JSON like:
# {"type":"impact","force":0.42,"x":0.1,"y":0.05,"z":0.38,"timestamp":1711468800.123}
```

### Adding a new detection algorithm

1. Create a struct conforming to `DetectionAlgorithm` in `ImpactDetector.swift`
2. Implement `processSample(_:) -> DetectionVote` and `reset()`
3. Add an instance to `ImpactDetector.init()` and include it in the `votes` array
4. Done — the voting system handles the rest

### Adding a new voice pack

1. Create a directory under `OpenSlap/Resources/Sounds/yourpack/`
2. Add audio files (any format: MP3, WAV, M4A, AAC, AIFF, CAF)
3. Add the case to the `SoundMode` enum in `SettingsStore.swift`
4. The AudioManager loads sounds based on the mode's `rawValue.lowercased()` directory name

---

## Uninstalling

```bash
# If you installed the daemon as a LaunchDaemon:
sudo ./Scripts/uninstall-daemon.sh

# Remove the app
rm -rf /path/to/OpenSlap.app

# Remove saved settings and stats (optional)
defaults delete com.openslap.app
```

If you only ran the daemon manually with `sudo`, there's nothing to uninstall — just quit the app and Ctrl-C the daemon.

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| **"Daemon not connected"** | Make sure the daemon is running: `sudo ./build/OpenSlapDaemon`. Check that `/var/run/openslap.sock` exists. |
| **Daemon says "No accelerometer device found"** | Your Mac may not have the SPU sensor. Requires Apple Silicon M1 Pro or later. Use mock mode for testing. |
| **Daemon says "must run as root"** | Run with `sudo`. IOKit HID access to the SPU requires root privileges. |
| **No sound plays** | Check that your volume isn't muted. Check the Audio tab in settings — make sure a mode is selected and master volume > 0%. |
| **Too sensitive (triggers from typing)** | Move the sensitivity slider to the right (higher threshold) in the menu bar popover. |
| **Not sensitive enough** | Move the sensitivity slider to the left. Default is 0.08g which should detect light taps. |
| **App doesn't appear in menu bar** | The app has `LSUIElement=true` (no dock icon). Look for the ✋ hand icon in the menu bar, not the dock. |
| **Xcode build fails** | Run `xcodegen generate` first. Make sure you have Xcode 16+ and have accepted the license (`sudo xcodebuild -license accept`). |

---

## Contributing

Contributions are welcome! Here are some ideas for future work:

- **Better sounds** — The bundled sounds are text-to-speech placeholders. Real audio reactions would make this 10x better.
- **More detection algorithms** — Wavelet transform, matched filtering, or machine learning-based detection.
- **Gesture recognition** — Distinguish between slaps, knocks, taps, and typing patterns.
- **Visual reactions** — Screen flash, dock icon bounce, or menu bar animation on impact.
- **Network mode** — Slap one Mac, play the sound on another Mac over the local network.
- **Proper code signing & notarization** — DMG distribution without Gatekeeper warnings.
- **Homebrew formula** — `brew install openslap` for easy installation.
- **SwiftUI previews** — Add preview providers for all views.
- **Unit tests** — Test the detection algorithms with recorded accelerometer data.

### Submitting Changes

1. Fork the repo
2. Create a feature branch: `git checkout -b my-feature`
3. Make your changes
4. Build and test: `xcodebuild -scheme OpenSlap build`
5. Commit with a descriptive message
6. Push and open a pull request

---

## Known Limitations

- **Requires root** — There is no way around this on macOS. Apple does not expose the laptop accelerometer through any unprivileged API.
- **Apple Silicon only** — Intel Macs don't have the SPU sensor. The base M1 (non-Pro) may also lack it.
- **No App Store distribution** — The app requires a privileged daemon and is not sandboxed, so it cannot be distributed through the Mac App Store.
- **Text-to-speech sounds** — The bundled sounds are generated via macOS `say` command. They work but aren't exactly viral-video quality. Replace them with real audio for a better experience.

---

## Acknowledgments

- Inspired by the wave of viral MacBook slap apps that swept social media
- Detection algorithms adapted from established techniques in **seismology** (STA/LTA), **statistical process control** (CUSUM), and **signal processing** (kurtosis)
- Built with Apple's IOKit, SwiftUI, AVFoundation, and ServiceManagement frameworks
- This is an independent, from-scratch implementation — no code was copied from any other project

---

## License

MIT License — see [LICENSE](LICENSE) for details.

You are free to use, modify, and distribute this software. Attribution is appreciated but not required.

---

<p align="center">
  <i>Don't break your expensive laptop. Seriously. A gentle tap is all you need.<br>Your MacBook didn't do anything to deserve this.</i>
</p>
