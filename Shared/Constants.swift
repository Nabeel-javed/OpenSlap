// Constants.swift — Shared constants between daemon and app
// OpenSlap – macOS accelerometer-based slap detection
//
// These constants define the communication contract and sensor parameters
// shared by both the privileged daemon and the user-facing app.

import Foundation

enum OpenSlapConstants {

    // MARK: - IPC

    /// Unix domain socket path for daemon↔app communication.
    /// Lives in /var/run because the daemon runs as root and needs a stable,
    /// well-known location that survives app restarts.
    static let socketPath = "/var/run/openslap.sock"

    /// Maximum message size we'll accept over the socket (16 KB).
    /// Impact events are tiny (~200 bytes), but this gives headroom for
    /// config messages with custom sound paths.
    static let maxMessageSize = 16_384

    // MARK: - Sensor Hardware

    /// HID vendor-defined usage page for Apple's SPU (Sensor Processing Unit).
    /// Apple uses the vendor page 0xFF00 for internal sensors that aren't
    /// exposed through standard HID usage tables.
    static let sensorUsagePage: Int = 0xFF00

    /// HID usage ID for the accelerometer within the SPU.
    /// Usage 3 maps to the Bosch BMI286 IMU's acceleration output.
    static let sensorUsage: Int = 3

    /// Expected report length in bytes from the accelerometer.
    /// The BMI286 sends 22-byte reports containing header + 3-axis data + metadata.
    static let reportLength: Int = 22

    /// Byte offsets for X, Y, Z acceleration values within the 22-byte report.
    /// Each axis is a signed 32-bit little-endian integer.
    /// Report layout (observed): [header 6B] [X 4B] [Y 4B] [Z 4B] [tail 4B]
    static let xOffset = 6
    static let yOffset = 10
    static let zOffset = 14

    /// Conversion factor from raw sensor units to g-force.
    /// The BMI286 uses a 16.16 fixed-point format: the raw Int32 value
    /// divided by 65536 gives acceleration in g (where 1g ≈ 9.81 m/s²).
    static let rawToGForce: Double = 65536.0

    // MARK: - Detection Defaults

    /// Minimum force (in g) to register as an intentional slap.
    /// This is the EXCESS above gravity — a value of 0.3 means total
    /// acceleration must exceed ~1.3g. Calibrated from real sensor data.
    static let defaultMinForceG: Double = 0.08

    /// Cooldown between detected slaps, in milliseconds.
    /// Prevents a single slap from triggering multiple events due to
    /// mechanical ringing / vibration decay in the chassis.
    static let defaultCooldownMs: Int = 400

    /// Number of algorithms that must agree before we declare an impact.
    /// 1 = very sensitive (any algorithm), 2 = balanced, 3+ = conservative.
    static let defaultVoteThreshold: Int = 1

    // MARK: - App Identifiers

    static let appBundleID = "com.openslap.app"
    static let daemonLabel = "com.openslap.daemon"
    static let daemonMachService = "com.openslap.daemon.xpc"
}
