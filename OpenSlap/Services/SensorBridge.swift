// SensorBridge.swift — Connects the app to the privileged daemon
// OpenSlap – macOS accelerometer-based slap detection
//
// This is the app-side counterpart to the daemon's socket server.
// It maintains a persistent connection to the daemon and translates
// incoming impact events into the app's event system.
//
// In mock mode (for development), it generates synthetic impacts
// without needing the daemon or root access.

import Foundation
import Combine

final class SensorBridge: ObservableObject {

    // MARK: - Published State

    /// Whether we're connected to the daemon.
    @Published var isDaemonConnected: Bool = false

    /// Whether the physical sensor is streaming data.
    @Published var isSensorActive: Bool = false

    /// Measured sample rate from the sensor (for diagnostics).
    @Published var sampleRate: Double = 0

    /// Whether we're in mock mode (synthetic events for development).
    @Published var isMockMode: Bool = false

    // MARK: - Events

    /// Publisher for impact events. The AudioManager subscribes to this.
    let impactPublisher = PassthroughSubject<SlapEvent, Never>()

    /// A lightweight event type for the app layer (decoupled from the socket protocol).
    struct SlapEvent {
        let force: Double   // g-force (gravity removed)
        let x: Double
        let y: Double
        let z: Double
        let timestamp: Date
    }

    // MARK: - Private

    private let socketClient = SocketClient()
    private var mockTimer: DispatchSourceTimer?
    private var cancellables = Set<AnyCancellable>()

    init() {
        setupSocketCallbacks()
    }

    deinit {
        disconnect()
    }

    // MARK: - Connection Management

    /// Connect to the daemon's Unix socket.
    func connect() {
        guard !isMockMode else { return }
        socketClient.connect()
    }

    /// Disconnect from the daemon.
    func disconnect() {
        socketClient.disconnect()
        stopMockMode()
    }

    /// Send updated detection settings to the daemon.
    func sendConfig(sensitivity: Double, enabled: Bool, cooldownMs: Int) {
        let msg = SocketMessage.config(sensitivity: sensitivity, enabled: enabled, cooldownMs: cooldownMs)
        socketClient.send(msg)
    }

    // MARK: - Mock Mode

    /// Start generating synthetic impact events for development/testing.
    /// This allows working on the UI and audio without root access or hardware.
    func startMockMode() {
        stopMockMode()
        isMockMode = true
        isDaemonConnected = true
        isSensorActive = true
        sampleRate = 400.0

        // Generate random impacts at random intervals (1-5 seconds).
        // Forces follow a realistic distribution: mostly light taps (2-4g)
        // with occasional hard slaps (6-12g).
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        let interval = Double.random(in: 1.0...4.0)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.generateMockImpact()
            // Randomize the next interval
            let nextInterval = Double.random(in: 1.0...5.0)
            timer.schedule(deadline: .now() + nextInterval, repeating: nextInterval)
        }
        timer.resume()
        mockTimer = timer

        print("[SensorBridge] Mock mode started — generating synthetic impacts")
    }

    func stopMockMode() {
        mockTimer?.cancel()
        mockTimer = nil
        if isMockMode {
            isMockMode = false
            isDaemonConnected = false
            isSensorActive = false
        }
    }

    // MARK: - Private

    /// Called when connection state changes — resend config so daemon
    /// always has the current settings even if the initial send was lost.
    var onConnected: (() -> Void)?

    private func setupSocketCallbacks() {
        socketClient.onConnectionChange = { [weak self] connected in
            DispatchQueue.main.async {
                self?.isDaemonConnected = connected
                if connected {
                    self?.onConnected?()
                } else {
                    self?.isSensorActive = false
                    self?.sampleRate = 0
                }
            }
        }

        socketClient.onMessage = { [weak self] message in
            switch message.type {
            case .impact:
                guard let force = message.force else { return }
                let event = SlapEvent(
                    force: force,
                    x: message.x ?? 0,
                    y: message.y ?? 0,
                    z: message.z ?? 0,
                    timestamp: Date(timeIntervalSince1970: message.timestamp ?? Date().timeIntervalSince1970)
                )
                DispatchQueue.main.async {
                    self?.impactPublisher.send(event)
                }

            case .status:
                DispatchQueue.main.async {
                    self?.isSensorActive = message.sensorConnected ?? false
                    self?.sampleRate = message.sampleRate ?? 0
                }

            case .ping, .config:
                break
            }
        }
    }

    private func generateMockImpact() {
        // Generate a force with a realistic distribution:
        // Log-normal-ish: most slaps are moderate, occasional big ones.
        let base = Double.random(in: 2.0...5.0)
        let spike = Double.random(in: 0...1) > 0.8 ? Double.random(in: 3.0...8.0) : 0
        let force = base + spike

        // Random axis distribution (slaps tend to be mostly Z-axis: into the laptop)
        let z = force * Double.random(in: 0.6...0.95)
        let remaining = force - abs(z)
        let x = remaining * Double.random(in: -1.0...1.0)
        let y = remaining * Double.random(in: -1.0...1.0)

        let event = SlapEvent(
            force: force,
            x: x,
            y: y,
            z: z,
            timestamp: Date()
        )

        DispatchQueue.main.async { [weak self] in
            self?.impactPublisher.send(event)
        }
    }
}
