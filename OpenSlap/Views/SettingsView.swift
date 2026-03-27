// SettingsView.swift — App settings window
// OpenSlap – macOS accelerometer-based slap detection
//
// Full settings panel with tabbed interface following Apple HIG.

import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var sensorBridge: SensorBridge
    @EnvironmentObject var audioManager: AudioManager
    @EnvironmentObject var statsTracker: StatsTracker
    @EnvironmentObject var usbMonitor: USBMonitor

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gear") }
                .environmentObject(settings)
                .environmentObject(sensorBridge)

            AudioTab()
                .tabItem { Label("Audio", systemImage: "speaker.wave.2") }
                .environmentObject(settings)

            FeaturesTab()
                .tabItem { Label("Features", systemImage: "sparkles") }
                .environmentObject(settings)
                .environmentObject(statsTracker)

            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
                .environmentObject(statsTracker)
        }
        .frame(width: 480, height: 400)
    }
}

// MARK: - General Tab

struct GeneralTab: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var sensorBridge: SensorBridge

    var body: some View {
        Form {
            Section("Detection") {
                Toggle("Enable slap detection", isOn: $settings.detectionEnabled)

                VStack(alignment: .leading) {
                    HStack {
                        Text("Sensitivity")
                        Spacer()
                        Text("\(String(format: "%.1f", settings.sensitivity))g")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.sensitivity, in: 0.05...2.0, step: 0.05)
                    Text("Lower values detect lighter taps. Higher values require harder slaps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading) {
                    HStack {
                        Text("Cooldown")
                        Spacer()
                        Text("\(settings.cooldownMs)ms")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: Binding(
                        get: { Double(settings.cooldownMs) },
                        set: { settings.cooldownMs = Int($0) }
                    ), in: 100...2000, step: 50)
                    Text("Minimum time between detected slaps. Prevents double-triggers from vibration.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Daemon") {
                HStack {
                    Circle()
                        .fill(sensorBridge.isDaemonConnected ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(sensorBridge.isDaemonConnected ? "Connected" : "Not connected")
                    Spacer()
                    if sensorBridge.isMockMode {
                        Text("Mock mode active")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                if !sensorBridge.isDaemonConnected && !sensorBridge.isMockMode {
                    Text("The OpenSlap daemon must be running with root privileges. See README for installation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Audio Tab

struct AudioTab: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var isDraggingFolder = false

    var body: some View {
        Form {
            Section("Sound Mode") {
                Picker("Voice Pack", selection: $settings.soundMode) {
                    ForEach(SoundMode.allCases) { mode in
                        HStack {
                            Image(systemName: mode.icon)
                            Text(mode.rawValue)
                        }
                        .tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(settings.soundMode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Volume & Pitch") {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Master Volume")
                        Spacer()
                        Text("\(Int(settings.masterVolume * 100))%")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.masterVolume, in: 0...1)
                }

                Toggle("Scale volume by slap force", isOn: $settings.volumeScaling)
                Toggle("Scale pitch by slap force", isOn: $settings.pitchScaling)
            }

            if settings.soundMode == .custom {
                Section("Custom Sounds Folder") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let folder = settings.customSoundFolder {
                            HStack {
                                Image(systemName: "folder.fill")
                                Text(folder.lastPathComponent)
                                Spacer()
                                Button("Change") { pickFolder() }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        } else {
                            Text("Drop a folder here or click to browse")
                                .frame(maxWidth: .infinity, minHeight: 60)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                                        .foregroundStyle(isDraggingFolder ? .blue : .secondary)
                                )
                                .onTapGesture { pickFolder() }
                        }

                        Text("Add MP3, WAV, M4A, or AAC files to your folder.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder containing your sound files"

        if panel.runModal() == .OK {
            settings.customSoundFolder = panel.url
        }
    }
}

// MARK: - Features Tab

struct FeaturesTab: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var statsTracker: StatsTracker

    var body: some View {
        Form {
            Section("Extra Modes") {
                Toggle(isOn: $settings.usbMoanerEnabled) {
                    VStack(alignment: .leading) {
                        Text("USB Moaner")
                        Text("Play a sound when USB devices are connected or disconnected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: $settings.keyboardSlamMode) {
                    VStack(alignment: .leading) {
                        Text("Keyboard Slam Detection")
                        Text("React to aggressive typing (lower sensitivity threshold)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Data") {
                Button("Export Slap Stats") {
                    exportStats()
                }
                .buttonStyle(.bordered)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func exportStats() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "openslap-stats.txt"

        if panel.runModal() == .OK, let url = panel.url {
            let content = statsTracker.exportStats()
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - About Tab

struct AboutTab: View {
    @EnvironmentObject var statsTracker: StatsTracker

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            Text("OpenSlap")
                .font(.title.bold())

            Text("v0.1.0")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Slap your MacBook. Hear it react.")
                .font(.subheadline)

            Divider()

            VStack(spacing: 4) {
                Text("Lifetime slaps: \(statsTracker.lifetimeCount)")
                Text("Title: \(statsTracker.slapperTitle)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Divider()

            VStack(spacing: 4) {
                Text("Open source — MIT License")
                Text("Don't break your expensive laptop!")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}
