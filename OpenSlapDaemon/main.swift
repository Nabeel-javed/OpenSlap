// main.swift — OpenSlap privileged sensor daemon entry point
// OpenSlap – macOS accelerometer-based slap detection
//
// This daemon runs as root (via launchd) to access the MacBook's built-in
// accelerometer through IOKit HID. It:
//   1. Opens the SPU accelerometer device
//   2. Detects slap/impact events using multi-algorithm voting
//   3. Serves detected events to the user-facing app over a Unix socket
//
// PRIVILEGE MODEL:
// Only this small daemon needs root access. The main app runs as the normal
// user. This follows the principle of least privilege — the root process
// does the minimum necessary (read sensor, detect impacts) and nothing else.
//
// USAGE:
//   sudo ./OpenSlapDaemon          (manual testing)
//   Or installed as a LaunchDaemon  (normal operation)

import Foundation

// MARK: - Startup Banner

print("""
┌──────────────────────────────────────┐
│  OpenSlap Sensor Daemon v0.1         │
│  Accelerometer → Impact Detection    │
└──────────────────────────────────────┘
""")

// MARK: - Verify Privileges

// IOKit HID access to the SPU requires root. Fail early with a clear message
// rather than getting a cryptic IOReturn error later.
guard getuid() == 0 else {
    print("ERROR: This daemon must run as root to access the accelerometer.")
    print("Usage: sudo \(CommandLine.arguments[0])")
    print("")
    print("When installed as a LaunchDaemon, launchd runs it as root automatically.")
    exit(1)
}

// MARK: - Check Architecture

// The SPU sensor only exists on Apple Silicon Macs
#if !arch(arm64)
print("ERROR: OpenSlap requires Apple Silicon (M1 Pro or later).")
print("Intel Macs do not have the SPU accelerometer.")
exit(1)
#endif

// MARK: - Signal Handling

// Graceful shutdown on SIGTERM (sent by launchd on stop) and SIGINT (Ctrl-C)
let signalQueue = DispatchQueue(label: "com.openslap.signals")
func installSignalHandler(_ sig: Int32, action: @escaping () -> Void) {
    let source = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
    source.setEventHandler { action() }
    source.resume()
    signal(sig, SIG_IGN) // Ignore default handler; GCD will catch it
}

var shouldExit = false
installSignalHandler(SIGTERM) {
    print("\n[Daemon] Received SIGTERM, shutting down...")
    shouldExit = true
    CFRunLoopStop(CFRunLoopGetMain())
}
installSignalHandler(SIGINT) {
    print("\n[Daemon] Received SIGINT, shutting down...")
    shouldExit = true
    CFRunLoopStop(CFRunLoopGetMain())
}

// MARK: - Initialize Components

let socketServer = SocketServer()
let sensorReader = SensorReader()
let impactDetector = ImpactDetector()

// Wire up: sensor → detector → socket
// This is the core data pipeline:
//   HID callback (400 Hz) → ImpactDetector.processSample → (on impact) → SocketServer.send

/// Bridge between the SensorReader (delegate pattern) and the ImpactDetector.
final class SensorBridge: SensorReaderDelegate {
    let detector: ImpactDetector
    let server: SocketServer

    init(detector: ImpactDetector, server: SocketServer) {
        self.detector = detector
        self.server = server
    }

    func sensorReader(_ reader: SensorReader, didReceiveSample sample: AccelerometerSample) {
        detector.processSample(sample)
    }

    func sensorReader(_ reader: SensorReader, didChangeConnectionState connected: Bool) {
        let msg = SocketMessage.status(connected: connected, sampleRate: 0)
        server.send(msg)
    }
}

let bridge = SensorBridge(detector: impactDetector, server: socketServer)
sensorReader.delegate = bridge

// When an impact is detected, send it to the connected app
impactDetector.onImpact = { event in
    let msg = SocketMessage.impact(
        force: event.force,
        x: event.x,
        y: event.y,
        z: event.z
    )
    socketServer.send(msg)
    print("[Daemon] Impact detected: force=\(String(format: "%.2f", event.force))g "
        + "(x=\(String(format: "%.1f", event.x)), "
        + "y=\(String(format: "%.1f", event.y)), "
        + "z=\(String(format: "%.1f", event.z))) "
        + "[\(event.algorithmsTriggered) algorithms agreed]")
}

// Handle config updates from the app
socketServer.onMessage = { message in
    switch message.type {
    case .config:
        impactDetector.updateConfig(
            minForceG: message.sensitivity,
            cooldownMs: message.cooldownMs
        )
        print("[Daemon] Config updated: sensitivity=\(message.sensitivity ?? -1), cooldown=\(message.cooldownMs ?? -1)ms")
    case .ping:
        socketServer.send(.ping)
    default:
        break
    }
}

socketServer.onClientChange = { connected in
    print("[Daemon] App \(connected ? "connected" : "disconnected")")
    if connected {
        // Send current status to newly connected app.
        // Use sensorFound flag (not sampleRate, which may be 0 at startup).
        let status = SocketMessage.status(
            connected: sensorFound,
            sampleRate: sensorReader.measuredSampleRate
        )
        socketServer.send(status)
    }
}

// MARK: - Start Services

do {
    try socketServer.start()
    print("[Daemon] Socket server listening at \(OpenSlapConstants.socketPath)")
} catch {
    print("FATAL: Failed to start socket server: \(error)")
    exit(1)
}

let sensorFound = sensorReader.start()
if sensorFound {
    print("[Daemon] Accelerometer sensor is active and streaming.")
} else {
    print("WARNING: Accelerometer not found. Running in headless mode.")
    print("The daemon will stay alive waiting for the sensor to appear.")
    print("If you're developing, use the app's mock mode for testing.")
}

print("[Daemon] Ready. Waiting for the OpenSlap app to connect...")
print("")

// MARK: - Run Loop

// The main run loop is essential:
// 1. IOKit HID callbacks are delivered on this run loop
// 2. CFRunLoop keeps the process alive
// The run loop exits when we receive SIGTERM/SIGINT via CFRunLoopStop.
RunLoop.main.run()

// MARK: - Cleanup

print("[Daemon] Shutting down...")
sensorReader.stop()
socketServer.stop()
print("[Daemon] Goodbye.")
exit(0)
