# OpenSlap

**Slap your MacBook. Hear it react.**

A native macOS menu bar app that uses your MacBook's built-in accelerometer to detect slaps and play funny audio reactions. Built entirely in Swift with IOKit, SwiftUI, and AVAudioEngine.

---

## IMPORTANT: Safety Disclaimer

> **Slapping your MacBook can damage the screen, hinges, trackpad, keyboard, or internal components and WILL void your warranty.** Repeated impacts may cause cumulative damage that isn't immediately visible. Use this app entirely at your own risk and expense.
>
> **The app itself does not damage your computer.** It only reads the accelerometer (a passive sensor) and plays audio through your speakers. The privileged daemon accesses only the motion sensor with minimal permissions.
>
> **Please be gentle.** This is meant to be fun, not destructive. A light tap is all you need. Don't actually slap your $2,000+ laptop like it owes you money.

---

## Features

- **Multi-algorithm impact detection** — Four independent algorithms (STA/LTA, CUSUM, kurtosis, magnitude threshold) vote on each potential slap for high accuracy and low false positives
- **Dynamic audio** — Volume and pitch scale with slap force (gentle tap = quiet, hard slap = loud)
- **Voice packs** — Pain (protest sounds), Sexy (escalating intensity based on recent frequency), Halo (game sounds), and Custom (your own MP3s)
- **Menu bar app** — Lives in your menu bar with no dock icon. Shows slap count and connection status
- **USB Moaner** — Optional mode that plays sounds when USB devices are plugged/unplugged
- **Slap statistics** — Session and lifetime counters, peak force tracking, fun titles
- **Mock mode** — Test everything without hardware or root access (great for development)
- **Launch at login** — Start automatically when you log in
- **Native macOS** — Pure Swift, SwiftUI, AppKit. Feels like a first-party Apple app

## Requirements

- **macOS 14.0 (Sonoma) or later**
- **Apple Silicon** (M1 Pro, M2, M3, M4 series). Intel Macs are not supported (no SPU accelerometer)
- **Xcode 16+** for building
- **XcodeGen** for project generation (`brew install xcodegen`)
- **Root access** for the sensor daemon (the accelerometer is not user-accessible via IOKit)

## Architecture

OpenSlap uses a split-privilege architecture for security:

```
┌─────────────────────────────────┐     Unix Socket      ┌─────────────────────────┐
│  OpenSlap.app (user-level)      │◄════════════════════►│  OpenSlapDaemon (root)   │
│                                 │  /var/run/openslap    │                         │
│  • SwiftUI menu bar UI          │      .sock            │  • IOKit HID sensor     │
│  • AVAudioEngine playback       │                       │  • Impact detection     │
│  • Settings & stats             │  JSON events ────►    │  • 4-algorithm voting   │
│  • USB monitoring               │  ◄──── Config msgs   │  • Minimal footprint    │
└─────────────────────────────────┘                       └─────────────────────────┘
```

**Why two processes?**
- Only the tiny daemon needs root — it reads the sensor and detects impacts
- The app runs as your normal user with no special privileges
- The daemon is ~200 lines of active code — small attack surface
- Communication uses a simple Unix socket with JSON messages

## Building

### 1. Generate the Xcode project

```bash
brew install xcodegen   # if you don't have it
cd /path/to/OpenSlap
xcodegen generate
```

### 2. Open in Xcode

```bash
open OpenSlap.xcodeproj
```

### 3. Build both targets

Select the **OpenSlap** scheme and build (Cmd+B).
Then select **OpenSlapDaemon** and build.

Or from the command line:
```bash
xcodebuild -scheme OpenSlap -configuration Release build
xcodebuild -scheme OpenSlapDaemon -configuration Release build
```

### 4. Install the daemon

```bash
sudo ./Scripts/install-daemon.sh
```

This copies the daemon binary to `/usr/local/bin/` and installs a LaunchDaemon plist so it starts automatically at boot.

### 5. Run the app

Launch `OpenSlap.app` from the build output or copy it to `/Applications/`.

### 6. Test with mock mode

Don't want to install the daemon yet? Click the hammer icon in the menu bar to enable **mock mode**, which generates synthetic slap events for testing the UI and audio.

## Adding Custom Sounds

1. Create a folder with your audio files (MP3, WAV, M4A, AAC, AIFF)
2. In OpenSlap settings (gear icon → Audio tab), select "Custom" mode
3. Click "Choose Folder" and select your sounds directory
4. Slap away!

Sounds are loaded on mode change. The app shuffles through all files in the folder without repeating until all have played.

### Built-in Sound Packs

The app ships with placeholder directories for each mode. Add your own files to:
- `OpenSlap/Resources/Sounds/pain/` — Protest sounds
- `OpenSlap/Resources/Sounds/sexy/` — Escalating reactions
- `OpenSlap/Resources/Sounds/halo/` — Game sound effects

See `OpenSlap/Resources/Sounds/README.md` for suggested free sound sources.

## How It Works

### Sensor Access

The MacBook's accelerometer is part of Apple's SPU (Sensor Processing Unit), which houses a Bosch BMI286 IMU. The sensor appears as an IOKit HID device with vendor usage page `0xFF00` and usage `3`.

Reports are 22 bytes. Three axes of acceleration data are encoded as signed 32-bit little-endian integers at byte offsets 6, 10, and 14. Dividing by 65,536 converts from the BMI286's Q16.16 fixed-point format to g-force units.

### Impact Detection

Four algorithms process each sample independently:

| Algorithm | What it detects | Borrowed from |
|-----------|----------------|---------------|
| **STA/LTA** | Sudden energy spikes above background | Seismology (earthquake P-wave arrival) |
| **CUSUM** | Signal level shifts | Statistical process control |
| **Kurtosis** | "Spiky" distributions (few extreme values) | Signal processing |
| **Magnitude** | Raw acceleration above threshold | Direct measurement |

An impact is declared when **2+ algorithms agree** AND the estimated force exceeds the sensitivity threshold. This voting system dramatically reduces false positives from normal use (typing, bumping the desk, adjusting the screen).

### Force Estimation

Each algorithm estimates the impact force independently. The final force is a confidence-weighted average of the agreeing algorithms' estimates, giving more weight to algorithms with stronger signals.

## Uninstalling

```bash
# Remove the daemon
sudo ./Scripts/uninstall-daemon.sh

# Remove the app
rm -rf /Applications/OpenSlap.app

# Remove settings (optional)
defaults delete com.openslap.app
```

## Development

### Project Structure

```
OpenSlap/
├── Shared/                    # Types shared between app and daemon
│   ├── Constants.swift        # Socket path, sensor params, defaults
│   ├── ImpactEvent.swift      # Event types, JSON serialization
│   └── SocketProtocol.swift   # Unix socket server/client
├── OpenSlapDaemon/            # Privileged sensor daemon (runs as root)
│   ├── main.swift             # Entry point, wiring, run loop
│   ├── SensorReader.swift     # IOKit HID accelerometer interface
│   └── ImpactDetector.swift   # Multi-algorithm voting detector
├── OpenSlap/                  # User-facing SwiftUI app
│   ├── App/
│   │   └── OpenSlapApp.swift  # @main, MenuBarExtra, service wiring
│   ├── Services/
│   │   ├── AudioManager.swift # AVAudioEngine playback
│   │   ├── SensorBridge.swift # Socket client + mock mode
│   │   ├── SettingsStore.swift# UserDefaults-backed settings
│   │   ├── StatsTracker.swift # Session/lifetime statistics
│   │   └── USBMonitor.swift   # USB plug/unplug detection
│   └── Views/
│       ├── MenuBarView.swift  # Main popover UI
│       ├── SettingsView.swift # Settings window (tabbed)
│       ├── OnboardingView.swift # First-launch disclaimer
│       └── StatsView.swift    # Detailed statistics
├── Scripts/
│   ├── install-daemon.sh      # Install daemon as LaunchDaemon
│   └── uninstall-daemon.sh    # Remove daemon
├── project.yml                # XcodeGen project specification
├── README.md
└── LICENSE                    # MIT
```

### Mock Mode

For development without root access or Apple Silicon hardware, use mock mode:
- Click the hammer icon in the menu bar popover, OR
- The app enters mock mode automatically if the daemon isn't reachable

Mock mode generates realistic synthetic impacts with varied force distributions.

### Debugging the Daemon

```bash
# Run manually (see real-time output)
sudo /usr/local/bin/OpenSlapDaemon

# Check if it's running
sudo launchctl list | grep openslap

# View logs
cat /var/log/openslap-daemon.log

# Test the socket (requires socat)
socat - UNIX-CONNECT:/var/run/openslap.sock
```

## Contributing

Contributions welcome! Some ideas:
- More detection algorithms (wavelet transform, matched filtering)
- Gesture recognition (distinguish slap vs. knock vs. tap patterns)
- Visual reactions (screen flash, dock icon animation)
- Network mode (slap one Mac, play on another)
- Apple Watch integration (slap detection on wrist)
- Proper app notarization and distribution

## Acknowledgments

Inspired by the wave of viral MacBook slap apps. This is an independent, open-source, from-scratch implementation that shares no code with any other project.

The detection algorithms are adapted from established techniques in seismology (STA/LTA), statistical process control (CUSUM), and signal processing (kurtosis), applied to the specific problem of detecting laptop impacts.

## License

MIT License — see [LICENSE](LICENSE) for details.

---

*Don't break your expensive laptop. Seriously. A gentle tap is all you need. Your MacBook didn't do anything to deserve this.*
