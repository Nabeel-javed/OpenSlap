// ComboTracker.swift — Tracks rapid slap combos
// OpenSlap – macOS accelerometer-based slap detection
//
// Detects when slaps happen in quick succession and assigns combo levels.
// 3 slaps in 2 seconds = COMBO x3, etc. Combos trigger escalating
// feedback (the AudioManager and ScreenFlash can react to combo level).

import Foundation
import Combine

final class ComboTracker: ObservableObject {

    // MARK: - Published State

    /// Current combo count (0 = no active combo, 1 = single slap, 2+ = combo)
    @Published private(set) var currentCombo: Int = 0

    /// Highest combo achieved this session
    @Published private(set) var bestCombo: Int = 0

    /// Highest combo ever (persisted)
    @Published private(set) var bestComboEver: Int = 0

    /// Whether a combo is currently active (for UI display)
    @Published private(set) var isComboActive: Bool = false

    // MARK: - Configuration

    /// Maximum time between slaps to maintain the combo (seconds).
    /// If no slap arrives within this window, the combo resets.
    let comboWindowSeconds: TimeInterval = 2.0

    // MARK: - Internal State

    private var lastSlapTime: Date?
    private var comboResetTimer: Timer?

    /// Fires when a combo milestone is reached (3, 5, 10, etc.)
    let comboMilestone = PassthroughSubject<ComboEvent, Never>()

    init() {
        bestComboEver = UserDefaults.standard.integer(forKey: "stats.bestComboEver")
    }

    // MARK: - Recording

    /// Call this each time a slap is detected. Returns the current combo level.
    @discardableResult
    func recordSlap(force: Double) -> Int {
        let now = Date()

        // Check if this slap continues an existing combo
        if let last = lastSlapTime, now.timeIntervalSince(last) <= comboWindowSeconds {
            currentCombo += 1
        } else {
            // Too slow — reset and start a new combo
            currentCombo = 1
        }

        lastSlapTime = now
        isComboActive = currentCombo >= 2

        // Update best records
        if currentCombo > bestCombo {
            bestCombo = currentCombo
        }
        if currentCombo > bestComboEver {
            bestComboEver = currentCombo
            UserDefaults.standard.set(bestComboEver, forKey: "stats.bestComboEver")
        }

        // Fire milestones at specific combo counts
        if let milestone = ComboMilestone(rawValue: currentCombo) {
            comboMilestone.send(ComboEvent(combo: currentCombo, milestone: milestone, force: force))
        }

        // Reset the combo timeout timer
        comboResetTimer?.invalidate()
        comboResetTimer = Timer.scheduledTimer(withTimeInterval: comboWindowSeconds, repeats: false) { [weak self] _ in
            self?.resetCombo()
        }

        return currentCombo
    }

    func resetCombo() {
        currentCombo = 0
        isComboActive = false
    }

    func resetSession() {
        bestCombo = 0
        resetCombo()
    }
}

// MARK: - Combo Types

/// Milestone thresholds for special feedback.
enum ComboMilestone: Int, CaseIterable {
    case double = 2      // "Double!"
    case triple = 3      // "Triple!"
    case quad = 4        // "Quad!"
    case penta = 5       // "Penta kill!"
    case mega = 7        // "Mega combo!"
    case ultra = 10      // "UNSTOPPABLE!"
    case godlike = 15    // "GODLIKE!"
    case legendary = 20  // "LEGENDARY!"

    var announcement: String {
        switch self {
        case .double:    return "Double!"
        case .triple:    return "Triple!"
        case .quad:      return "Quad!"
        case .penta:     return "Penta kill!"
        case .mega:      return "Mega combo!"
        case .ultra:     return "UNSTOPPABLE!"
        case .godlike:   return "GODLIKE!"
        case .legendary: return "LEGENDARY!"
        }
    }
}

/// Event fired when a combo milestone is reached.
struct ComboEvent {
    let combo: Int
    let milestone: ComboMilestone
    let force: Double
}
