// StatsTracker.swift — Slap statistics and fun counters
// OpenSlap – macOS accelerometer-based slap detection
//
// Tracks session and lifetime slap stats. Persisted to UserDefaults.

import Foundation
import Combine

// MARK: - Leaderboard Entry

/// A single entry in the force leaderboard.
struct LeaderboardEntry: Codable, Identifiable {
    let id: UUID
    let force: Double
    let date: Date

    init(force: Double, date: Date = Date()) {
        self.id = UUID()
        self.force = force
        self.date = date
    }
}

final class StatsTracker: ObservableObject {

    // MARK: - Published Stats

    /// Total slaps detected this session (since app launch).
    @Published private(set) var sessionCount: Int = 0

    /// Total slaps detected across all sessions.
    @Published private(set) var lifetimeCount: Int = 0

    /// Hardest slap ever recorded (in g-force).
    @Published private(set) var peakForceEver: Double = 0

    /// Hardest slap this session.
    @Published private(set) var peakForceSession: Double = 0

    /// Average slap force this session.
    @Published private(set) var averageForceSession: Double = 0

    /// Timestamp of the first ever slap.
    @Published private(set) var firstSlapDate: Date?

    /// Current slaps-per-minute rate (rolling 1-minute window).
    @Published private(set) var currentRate: Double = 0

    /// Top 10 hardest slaps ever, sorted by force descending.
    @Published private(set) var leaderboard: [LeaderboardEntry] = []

    // MARK: - Internal State

    private var sessionForces: [Double] = []
    private var recentTimestamps: [Date] = []
    private var rateTimer: Timer?
    private let maxLeaderboardSize = 10

    init() {
        loadLifetimeStats()
        loadLeaderboard()
        startRateTimer()
    }

    // MARK: - Recording

    /// Record a new slap event. Returns true if it made the leaderboard.
    @discardableResult
    func recordSlap(force: Double) -> Bool {
        let now = Date()

        sessionCount += 1
        lifetimeCount += 1
        sessionForces.append(force)
        recentTimestamps.append(now)

        if force > peakForceSession {
            peakForceSession = force
        }
        if force > peakForceEver {
            peakForceEver = force
        }

        averageForceSession = sessionForces.reduce(0, +) / Double(sessionForces.count)

        if firstSlapDate == nil {
            firstSlapDate = now
        }

        // Check if this slap makes the leaderboard
        let madeLeaderboard = updateLeaderboard(force: force, date: now)

        saveLifetimeStats()
        return madeLeaderboard
    }

    /// Reset session stats (on app relaunch).
    func resetSession() {
        sessionCount = 0
        peakForceSession = 0
        averageForceSession = 0
        sessionForces.removeAll()
        recentTimestamps.removeAll()
    }

    /// Reset all stats (user action).
    func resetAll() {
        resetSession()
        lifetimeCount = 0
        peakForceEver = 0
        firstSlapDate = nil
        leaderboard = []
        saveLifetimeStats()
        saveLeaderboard()
    }

    // MARK: - Leaderboard

    /// Insert a slap into the leaderboard if it qualifies.
    private func updateLeaderboard(force: Double, date: Date) -> Bool {
        let entry = LeaderboardEntry(force: force, date: date)

        if leaderboard.count < maxLeaderboardSize {
            leaderboard.append(entry)
            leaderboard.sort { $0.force > $1.force }
            saveLeaderboard()
            return true
        }

        // Check if this beat the weakest entry on the board
        if let weakest = leaderboard.last, force > weakest.force {
            leaderboard.removeLast()
            leaderboard.append(entry)
            leaderboard.sort { $0.force > $1.force }
            saveLeaderboard()
            return true
        }

        return false
    }

    /// The minimum force needed to get on the leaderboard.
    var leaderboardThreshold: Double {
        if leaderboard.count < maxLeaderboardSize { return 0 }
        return leaderboard.last?.force ?? 0
    }

    private func saveLeaderboard() {
        if let data = try? JSONEncoder().encode(leaderboard) {
            UserDefaults.standard.set(data, forKey: "stats.leaderboard")
        }
    }

    private func loadLeaderboard() {
        if let data = UserDefaults.standard.data(forKey: "stats.leaderboard"),
           let entries = try? JSONDecoder().decode([LeaderboardEntry].self, from: data) {
            leaderboard = entries.sorted { $0.force > $1.force }
        }
    }

    // MARK: - Fun Stats

    /// A fun description of the user's slapping habits.
    var slapperTitle: String {
        switch lifetimeCount {
        case 0:        return "Pacifist"
        case 1...10:   return "Curious Tapper"
        case 11...50:  return "Slap Apprentice"
        case 51...200: return "Certified Slapper"
        case 201...500: return "Slap Enthusiast"
        case 501...1000: return "Professional Slapper"
        case 1001...5000: return "Slap Master"
        default:       return "Laptop Abuse Specialist"
        }
    }

    /// Estimated total energy delivered to the laptop (very approximate, for fun).
    /// Assumes ~0.5 kg effective mass and converts g-force to joules.
    var estimatedEnergyJoules: Double {
        let totalForceG = sessionForces.reduce(0, +)
        // E ≈ 0.5 * m * v², approximating v from impulse
        // This is wildly inaccurate but fun to show
        return totalForceG * 9.81 * 0.001 // Rough order of magnitude
    }

    /// Export stats as a formatted string for sharing.
    func exportStats() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium

        var lines = [
            "OpenSlap Stats Export",
            "═══════════════════════",
            "",
            "Title: \(slapperTitle)",
            "Lifetime slaps: \(lifetimeCount)",
            "Session slaps: \(sessionCount)",
            "Peak force (ever): \(String(format: "%.1f", peakForceEver))g",
            "Peak force (session): \(String(format: "%.1f", peakForceSession))g",
            "Average force: \(String(format: "%.1f", averageForceSession))g",
        ]
        if let firstDate = firstSlapDate {
            lines.append("Slapping since: \(dateFormatter.string(from: firstDate))")
        }
        lines.append("")
        lines.append("Generated by OpenSlap — don't break your expensive laptop!")
        return lines.joined(separator: "\n")
    }

    // MARK: - Persistence

    private func saveLifetimeStats() {
        let defaults = UserDefaults.standard
        defaults.set(lifetimeCount, forKey: "stats.lifetimeCount")
        defaults.set(peakForceEver, forKey: "stats.peakForceEver")
        if let firstDate = firstSlapDate {
            defaults.set(firstDate, forKey: "stats.firstSlapDate")
        }
    }

    private func loadLifetimeStats() {
        let defaults = UserDefaults.standard
        lifetimeCount = defaults.integer(forKey: "stats.lifetimeCount")
        peakForceEver = defaults.double(forKey: "stats.peakForceEver")
        firstSlapDate = defaults.object(forKey: "stats.firstSlapDate") as? Date
    }

    // MARK: - Rate Calculation

    private func startRateTimer() {
        // Update the slaps-per-minute rate every second
        rateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateRate()
        }
    }

    private func updateRate() {
        let now = Date()
        // Keep only the last 60 seconds of timestamps
        recentTimestamps.removeAll { now.timeIntervalSince($0) > 60 }
        currentRate = Double(recentTimestamps.count) // slaps in last minute
    }
}
