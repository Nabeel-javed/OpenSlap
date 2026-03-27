// ImpactEvent.swift — Shared data types for daemon↔app communication
// OpenSlap – macOS accelerometer-based slap detection
//
// All messages between the daemon and app are newline-delimited JSON
// using these Codable types. This keeps the protocol simple, debuggable
// (you can test with `socat`), and avoids XPC code-signing complexity.

import Foundation

// MARK: - Accelerometer Sample (Internal to Daemon)

/// A single reading from the accelerometer, converted to g-force.
/// The daemon produces these at ~400 Hz; they never cross the socket boundary.
struct AccelerometerSample: Sendable {
    let x: Double    // g-force, lateral (left/right)
    let y: Double    // g-force, longitudinal (toward/away from screen)
    let z: Double    // g-force, vertical (into/out of desk)
    let timestamp: TimeInterval  // mach_absolute_time converted to seconds

    /// Total acceleration magnitude. When stationary, this ≈ 1.0g (gravity).
    var magnitude: Double {
        (x * x + y * y + z * z).squareRoot()
    }
}

// MARK: - Socket Messages

/// Discriminator for socket messages. Using a flat tagged-union style
/// because it's trivial to parse in any language and debug with `jq`.
struct SocketMessage: Codable, Sendable {
    enum MessageKind: String, Codable, Sendable {
        case impact    // daemon → app: slap detected
        case status    // daemon → app: sensor status update
        case config    // app → daemon: configuration change
        case ping      // either direction: keepalive
    }

    let type: MessageKind

    // -- Impact fields (present when type == .impact) --
    /// Estimated impact force in g, after gravity removal.
    var force: Double?
    /// Per-axis peak values during the impact, in g.
    var x: Double?
    var y: Double?
    var z: Double?
    /// Unix timestamp of the impact.
    var timestamp: Double?

    // -- Status fields (present when type == .status) --
    /// Whether the sensor hardware was found and is streaming.
    var sensorConnected: Bool?
    /// Measured sample rate in Hz (for diagnostics).
    var sampleRate: Double?

    // -- Config fields (present when type == .config) --
    /// Detection sensitivity: minimum force threshold in g.
    var sensitivity: Double?
    /// Whether detection is active.
    var enabled: Bool?
    /// Cooldown between detections in milliseconds.
    var cooldownMs: Int?

    // MARK: - Convenience Factories

    static func impact(force: Double, x: Double, y: Double, z: Double) -> SocketMessage {
        SocketMessage(
            type: .impact,
            force: force, x: x, y: y, z: z,
            timestamp: Date().timeIntervalSince1970
        )
    }

    static func status(connected: Bool, sampleRate: Double) -> SocketMessage {
        SocketMessage(type: .status, sensorConnected: connected, sampleRate: sampleRate)
    }

    static func config(sensitivity: Double, enabled: Bool, cooldownMs: Int) -> SocketMessage {
        SocketMessage(type: .config, sensitivity: sensitivity, enabled: enabled, cooldownMs: cooldownMs)
    }

    static var ping: SocketMessage {
        SocketMessage(type: .ping)
    }
}

// MARK: - JSON Serialization Helpers

extension SocketMessage {
    /// Encode to a single line of JSON + newline delimiter.
    /// We use newline-delimited JSON (NDJSON) so the receiver can split
    /// on '\n' without needing a length-prefix framing protocol.
    func serialized() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [] // compact, single line
        var data = try encoder.encode(self)
        data.append(0x0A) // newline
        return data
    }

    /// Decode from a single line of JSON (newline already stripped).
    static func deserialize(from data: Data) throws -> SocketMessage {
        let decoder = JSONDecoder()
        return try decoder.decode(SocketMessage.self, from: data)
    }
}
