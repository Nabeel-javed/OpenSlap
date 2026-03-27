// MenuBarView.swift — Menu bar popover content
// OpenSlap – macOS accelerometer-based slap detection
//
// The main interface shown when clicking the menu bar icon.
// Compact, information-dense, and fun — like a first-party Apple widget.

import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var sensorBridge: SensorBridge
    @EnvironmentObject var statsTracker: StatsTracker

    @State private var showStats = false

    var body: some View {
        VStack(spacing: 12) {
            // Header
            header

            Divider()

            // Status
            statusSection

            Divider()

            // Quick controls
            controlsSection

            Divider()

            // Bottom bar
            bottomBar
        }
        .padding(16)
        .frame(width: 300)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("OpenSlap")
                    .font(.headline)
                Text(statsTracker.slapperTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(statsTracker.sessionCount)")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("slaps today")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if sensorBridge.isMockMode {
                Text("MOCK")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.2))
                    .foregroundStyle(.orange)
                    .clipShape(Capsule())
            }
        }
    }

    private var statusColor: Color {
        if sensorBridge.isSensorActive || sensorBridge.isMockMode {
            return .green
        } else if sensorBridge.isDaemonConnected {
            return .yellow
        }
        return .red
    }

    private var statusText: String {
        if sensorBridge.isMockMode {
            return "Mock mode — generating test slaps"
        } else if sensorBridge.isSensorActive {
            return "Sensor active (\(Int(sensorBridge.sampleRate)) Hz)"
        } else if sensorBridge.isDaemonConnected {
            return "Daemon connected, sensor inactive"
        }
        return "Daemon not connected"
    }

    // MARK: - Controls

    private var controlsSection: some View {
        VStack(spacing: 10) {
            // Detection toggle
            Toggle(isOn: $settings.detectionEnabled) {
                Label("Detection Active", systemImage: "waveform.path")
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            // Mode picker
            HStack {
                Label("Mode", systemImage: settings.soundMode.icon)
                    .font(.caption)
                Spacer()
                Picker("", selection: $settings.soundMode) {
                    ForEach(SoundMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 120)
            }

            // Sensitivity slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Sensitivity", systemImage: "dial.low")
                        .font(.caption)
                    Spacer()
                    Text("\(String(format: "%.1f", settings.sensitivity))g")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.sensitivity, in: 0.05...2.0, step: 0.05)
                    .controlSize(.small)
                HStack {
                    Text("Light taps")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Hard slaps only")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // Quick stats
            if statsTracker.peakForceSession > 0 {
                HStack {
                    Label("Peak: \(String(format: "%.1f", statsTracker.peakForceSession))g",
                          systemImage: "arrow.up.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Label("\(String(format: "%.0f", statsTracker.currentRate))/min",
                          systemImage: "speedometer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            // Mock mode toggle (for development)
            Button {
                if sensorBridge.isMockMode {
                    sensorBridge.stopMockMode()
                    sensorBridge.connect()
                } else {
                    sensorBridge.disconnect()
                    sensorBridge.startMockMode()
                }
            } label: {
                Image(systemName: sensorBridge.isMockMode ? "hammer.fill" : "hammer")
                    .help("Toggle mock mode (for testing without hardware)")
            }
            .buttonStyle(.plain)
            .foregroundStyle(sensorBridge.isMockMode ? .orange : .secondary)

            // Stats
            Button {
                showStats.toggle()
            } label: {
                Image(systemName: "chart.bar")
                    .help("View detailed stats")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .popover(isPresented: $showStats) {
                StatsView()
                    .environmentObject(statsTracker)
            }

            Spacer()

            // Settings
            SettingsLink {
                Image(systemName: "gear")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            // Quit
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .help("Quit OpenSlap")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }
}
