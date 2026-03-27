// OpenSlapApp.swift — Main application entry point
// OpenSlap – macOS accelerometer-based slap detection
//
// A menu-bar-only app (no dock icon). Uses SwiftUI's MenuBarExtra for
// the status item and a settings window for configuration.
//
// Service wiring lives in AppController (a shared ObservableObject)
// rather than in the App struct, because SwiftUI App.init() runs before
// @StateObject properties are fully available.

import SwiftUI
import AppKit
import Combine

@main
struct OpenSlapApp: App {

    @StateObject private var controller = AppController()

    var body: some Scene {
        // MARK: - Menu Bar

        MenuBarExtra {
            MenuBarView()
                .environmentObject(controller.settings)
                .environmentObject(controller.sensorBridge)
                .environmentObject(controller.audioManager)
                .environmentObject(controller.statsTracker)
                .environmentObject(controller.usbMonitor)
                .environmentObject(controller.comboTracker)
                .environmentObject(controller)
        } label: {
            MenuBarLabel(
                isConnected: controller.sensorBridge.isDaemonConnected,
                isMockMode: controller.sensorBridge.isMockMode,
                sessionCount: controller.statsTracker.sessionCount,
                comboCount: controller.comboTracker.currentCombo
            )
        }
        .menuBarExtraStyle(.window)

        // MARK: - Settings Window

        Settings {
            SettingsView()
                .environmentObject(controller.settings)
                .environmentObject(controller.sensorBridge)
                .environmentObject(controller.audioManager)
                .environmentObject(controller.statsTracker)
                .environmentObject(controller.usbMonitor)
        }

        // MARK: - Onboarding Window

        Window("Welcome to OpenSlap", id: "onboarding") {
            OnboardingView(onComplete: {
                controller.onOnboardingComplete()
            })
            .environmentObject(controller.settings)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

// MARK: - Menu Bar Label

/// The label shown in the macOS menu bar.
/// Uses SF Symbols for a native look that adapts to light/dark mode.
struct MenuBarLabel: View {
    let isConnected: Bool
    let isMockMode: Bool
    let sessionCount: Int
    let comboCount: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
            if comboCount >= 2 {
                // Show combo during active combo
                Text("x\(comboCount)")
                    .monospacedDigit()
                    .foregroundStyle(.orange)
            } else if sessionCount > 0 {
                Text("\(sessionCount)")
                    .monospacedDigit()
            }
        }
    }

    private var iconName: String {
        if comboCount >= 2 {
            return "hand.raised.fingers.spread.fill" // Active combo icon
        } else if isMockMode {
            return "hand.raised.fingers.spread.fill"
        } else if isConnected {
            return "hand.raised.fill"
        } else {
            return "hand.raised.slash"
        }
    }
}

// MARK: - App Controller

/// Central coordinator that owns all services and wires them together.
/// Extracted from the App struct because SwiftUI's App.init() doesn't
/// guarantee that @StateObject properties are accessible yet.
final class AppController: ObservableObject {

    let settings = SettingsStore()
    let sensorBridge = SensorBridge()
    let audioManager = AudioManager()
    let statsTracker = StatsTracker()
    let usbMonitor = USBMonitor()
    let comboTracker = ComboTracker()
    let screenFlash = ScreenFlash()

    @Published var needsOnboarding: Bool

    private var cancellables = Set<AnyCancellable>()

    init() {
        needsOnboarding = !settings.hasCompletedOnboarding

        wireUpServices()

        // When the daemon connection is (re)established, send current settings
        sensorBridge.onConnected = { [weak self] in
            guard let self else { return }
            sensorBridge.sendConfig(
                sensitivity: settings.sensitivity,
                enabled: settings.detectionEnabled,
                cooldownMs: settings.cooldownMs
            )
        }

        // Always try to connect to the daemon
        sensorBridge.connect()
    }

    func onOnboardingComplete() {
        settings.hasCompletedOnboarding = true
        needsOnboarding = false
        sensorBridge.connect()
    }

    /// Connect all services together.
    /// This is the "glue" that makes impact events flow from the sensor
    /// through detection to audio playback and stats tracking.
    private func wireUpServices() {
        // Load initial sound pack
        audioManager.loadSounds(for: settings.soundMode, customFolder: settings.customSoundFolder, settings: settings)

        // Core pipeline: impact → sound + stats + flash + combo
        sensorBridge.impactPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self, settings.detectionEnabled else { return }

                // 1. Track combo
                let combo = comboTracker.recordSlap(force: event.force)

                // 2. Play sound (combo multiplies the perceived force for louder audio)
                let comboBoost = 1.0 + Double(max(combo - 1, 0)) * 0.15
                audioManager.playSlap(force: event.force * comboBoost)

                // 3. Record stats
                statsTracker.recordSlap(force: event.force)

                // 4. Screen flash (combo makes it more intense)
                let flashForce = event.force * comboBoost
                screenFlash.flash(force: flashForce)
            }
            .store(in: &cancellables)

        // Combo milestone announcements — play the milestone text via TTS
        // for dramatic effect ("TRIPLE!", "UNSTOPPABLE!", etc.)
        comboTracker.comboMilestone
            .receive(on: DispatchQueue.main)
            .sink { event in
                // Use macOS speech synthesis for combo announcements
                let synth = NSSpeechSynthesizer()
                synth.rate = 200
                synth.startSpeaking(event.milestone.announcement)
            }
            .store(in: &cancellables)

        // Reload sounds when mode changes
        settings.$soundMode
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                guard let self else { return }
                audioManager.loadSounds(for: mode, customFolder: settings.customSoundFolder, settings: settings)
            }
            .store(in: &cancellables)

        // Reload sounds when custom folder changes (if in custom mode)
        settings.$customSoundFolder
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] folder in
                guard let self, settings.soundMode == .custom else { return }
                audioManager.loadSounds(for: .custom, customFolder: folder, settings: settings)
            }
            .store(in: &cancellables)

        // Send detection settings to daemon when they change.
        // No dropFirst — send the initial value too so the daemon
        // starts with the user's saved sensitivity.
        Publishers.CombineLatest3(
            settings.$sensitivity,
            settings.$detectionEnabled,
            settings.$cooldownMs
        )
        .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
        .sink { [weak self] sensitivity, enabled, cooldown in
            self?.sensorBridge.sendConfig(sensitivity: sensitivity, enabled: enabled, cooldownMs: cooldown)
        }
        .store(in: &cancellables)

        // USB Moaner: play sounds on USB events
        usbMonitor.onUSBEvent = { [weak self] in
            guard let self, settings.usbMoanerEnabled else { return }
            audioManager.playUSBSound()
        }

        // Start/stop USB monitoring based on setting
        if settings.usbMoanerEnabled {
            usbMonitor.start()
        }
        settings.$usbMoanerEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                if enabled { self?.usbMonitor.start() } else { self?.usbMonitor.stop() }
            }
            .store(in: &cancellables)
    }
}
