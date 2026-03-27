// SettingsStore.swift — Persistent settings and preferences
// OpenSlap – macOS accelerometer-based slap detection
//
// Uses UserDefaults for simplicity. All settings are @Published so SwiftUI
// views automatically update when they change. Changes to detection parameters
// are sent to the daemon via the SensorBridge.

import SwiftUI
import Combine
import ServiceManagement

// MARK: - Sound Mode

/// The voice pack / sound theme for slap reactions.
enum SoundMode: String, CaseIterable, Identifiable, Codable {
    case pain   = "Pain"      // "Ow!", "Hey!", protest sounds
    case sexy   = "Sexy"      // Escalating moans based on frequency
    case halo   = "Halo"      // Game sounds (shields, grunts, etc.)
    case custom = "Custom"    // User-provided folder of audio files

    var id: String { rawValue }

    var description: String {
        switch self {
        case .pain:   return "Protest sounds — ows, ouches, and yelps"
        case .sexy:   return "Escalating intensity based on slap frequency"
        case .halo:   return "Game-inspired sound effects"
        case .custom: return "Your own sounds — drop in any MP3s"
        }
    }

    var icon: String {
        switch self {
        case .pain:   return "hand.raised.slash"
        case .sexy:   return "heart.fill"
        case .halo:   return "gamecontroller.fill"
        case .custom: return "folder.badge.plus"
        }
    }
}

// MARK: - Settings Store

/// Central settings store shared across the app via @EnvironmentObject.
final class SettingsStore: ObservableObject {

    // MARK: - Detection Settings

    /// Minimum slap force to trigger a sound (in g-force, 0.5 = very sensitive, 5.0 = hard slaps only).
    @Published var sensitivity: Double {
        didSet { UserDefaults.standard.set(sensitivity, forKey: "sensitivity") }
    }

    /// Cooldown between slap detections in milliseconds.
    @Published var cooldownMs: Int {
        didSet { UserDefaults.standard.set(cooldownMs, forKey: "cooldownMs") }
    }

    // MARK: - Audio Settings

    /// Active sound mode / voice pack.
    @Published var soundMode: SoundMode {
        didSet { UserDefaults.standard.set(soundMode.rawValue, forKey: "soundMode") }
    }

    /// Scale volume based on slap force (louder slap = louder sound).
    @Published var volumeScaling: Bool {
        didSet { UserDefaults.standard.set(volumeScaling, forKey: "volumeScaling") }
    }

    /// Scale playback speed/pitch based on force.
    @Published var pitchScaling: Bool {
        didSet { UserDefaults.standard.set(pitchScaling, forKey: "pitchScaling") }
    }

    /// Master volume (0.0 to 1.0).
    @Published var masterVolume: Double {
        didSet { UserDefaults.standard.set(masterVolume, forKey: "masterVolume") }
    }

    /// Path to the user's custom sounds folder.
    @Published var customSoundFolder: URL? {
        didSet {
            if let url = customSoundFolder {
                // Store as bookmark data so we retain sandbox access across launches.
                // Even though we don't sandbox the app (need daemon access), this is
                // good practice and future-proofs the code.
                if let bookmark = try? url.bookmarkData(options: .withSecurityScope) {
                    UserDefaults.standard.set(bookmark, forKey: "customSoundFolderBookmark")
                }
            } else {
                UserDefaults.standard.removeObject(forKey: "customSoundFolderBookmark")
            }
        }
    }

    // MARK: - Feature Toggles

    /// Whether slap detection is active (the "master switch").
    @Published var detectionEnabled: Bool {
        didSet { UserDefaults.standard.set(detectionEnabled, forKey: "detectionEnabled") }
    }

    /// Play sounds when USB devices are plugged/unplugged.
    @Published var usbMoanerEnabled: Bool {
        didSet { UserDefaults.standard.set(usbMoanerEnabled, forKey: "usbMoanerEnabled") }
    }

    /// Detect keyboard slams (aggressive typing / slamming the keyboard).
    @Published var keyboardSlamMode: Bool {
        didSet { UserDefaults.standard.set(keyboardSlamMode, forKey: "keyboardSlamMode") }
    }

    /// Launch OpenSlap when the user logs in.
    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
            updateLoginItem()
        }
    }

    // MARK: - Onboarding

    /// Whether the onboarding/disclaimer has been shown and accepted.
    @Published var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }

    // MARK: - Init

    init() {
        let defaults = UserDefaults.standard

        // Load saved values with sensible defaults
        self.sensitivity = defaults.object(forKey: "sensitivity") as? Double
            ?? OpenSlapConstants.defaultMinForceG
        self.cooldownMs = defaults.object(forKey: "cooldownMs") as? Int
            ?? OpenSlapConstants.defaultCooldownMs
        self.soundMode = SoundMode(rawValue: defaults.string(forKey: "soundMode") ?? "")
            ?? .pain
        self.volumeScaling = defaults.object(forKey: "volumeScaling") as? Bool ?? true
        self.pitchScaling = defaults.object(forKey: "pitchScaling") as? Bool ?? true
        self.masterVolume = defaults.object(forKey: "masterVolume") as? Double ?? 0.8
        self.detectionEnabled = defaults.object(forKey: "detectionEnabled") as? Bool ?? true
        self.usbMoanerEnabled = defaults.object(forKey: "usbMoanerEnabled") as? Bool ?? false
        self.keyboardSlamMode = defaults.object(forKey: "keyboardSlamMode") as? Bool ?? false
        self.launchAtLogin = defaults.object(forKey: "launchAtLogin") as? Bool ?? false
        self.hasCompletedOnboarding = defaults.object(forKey: "hasCompletedOnboarding") as? Bool ?? false

        // Restore custom sound folder from bookmark
        if let bookmarkData = defaults.data(forKey: "customSoundFolderBookmark") {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, bookmarkDataIsStale: &isStale) {
                _ = url.startAccessingSecurityScopedResource()
                self.customSoundFolder = url
            }
        }
    }

    // MARK: - Launch at Login

    private func updateLoginItem() {
        let service = SMAppService.mainApp
        do {
            if launchAtLogin {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            print("[Settings] Failed to update login item: \(error)")
        }
    }
}
