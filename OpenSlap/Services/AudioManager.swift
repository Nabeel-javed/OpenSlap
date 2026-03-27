// AudioManager.swift — Sound playback with dynamic volume and pitch
// OpenSlap – macOS accelerometer-based slap detection
//
// Uses AVAudioEngine for real-time pitch and rate control.
// Audio pipeline:
//   AVAudioPlayerNode → AVAudioUnitTimePitch → mainMixerNode → output
//
// All loaded audio files are converted to the engine's output format
// at load time so we never get format mismatch crashes at playback.

import AVFoundation
import Combine

final class AudioManager: ObservableObject {

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let pitchEffect = AVAudioUnitTimePitch()

    /// The canonical format for all audio in the engine.
    /// Set from the engine's output node so it matches the hardware.
    private var engineFormat: AVAudioFormat!

    /// Currently loaded sound files for the active mode, all converted to engineFormat.
    private var soundBuffers: [AVAudioPCMBuffer] = []

    /// Shuffle index tracking — cycle through all sounds before repeating.
    private var playOrder: [Int] = []
    private var playIndex: Int = 0

    /// Reference to settings for volume/pitch scaling decisions.
    private weak var settings: SettingsStore?

    /// For "sexy mode" — tracks recent slap timestamps to escalate intensity.
    private var recentSlapTimes: [Date] = []
    private let sexyModeWindow: TimeInterval = 300 // 5-minute rolling window

    @Published var isReady: Bool = false

    init() {
        setupAudioEngine()
    }

    // MARK: - Engine Setup

    private func setupAudioEngine() {
        engine.attach(playerNode)
        engine.attach(pitchEffect)

        // Use the engine's output format as the canonical format.
        // This ensures we never have a format mismatch between nodes.
        engineFormat = engine.outputNode.outputFormat(forBus: 0)

        engine.connect(playerNode, to: pitchEffect, format: engineFormat)
        engine.connect(pitchEffect, to: engine.mainMixerNode, format: engineFormat)

        do {
            try engine.start()
            isReady = true
            print("[AudioManager] Engine started: \(engineFormat.sampleRate)Hz, \(engineFormat.channelCount)ch")
        } catch {
            print("[AudioManager] Failed to start audio engine: \(error)")
            isReady = false
        }
    }

    // MARK: - Sound Loading

    /// Load sounds for a given mode. Call this when the mode changes.
    func loadSounds(for mode: SoundMode, customFolder: URL? = nil, settings: SettingsStore) {
        self.settings = settings
        soundBuffers.removeAll()

        let urls: [URL]
        switch mode {
        case .pain, .sexy, .halo:
            urls = bundledSoundURLs(for: mode)
        case .custom:
            urls = customSoundURLs(from: customFolder)
        }

        for url in urls {
            if let buffer = loadAndConvertAudioBuffer(from: url) {
                soundBuffers.append(buffer)
            }
        }

        reshufflePlayOrder()
        print("[AudioManager] Loaded \(soundBuffers.count) sounds for mode '\(mode.rawValue)'")

        if soundBuffers.isEmpty {
            print("[AudioManager] No audio files found! Add MP3/WAV/M4A files to the sounds directory.")
        }
    }

    /// Play a sound appropriate for the given slap force.
    func playSlap(force: Double) {
        guard !soundBuffers.isEmpty, isReady else { return }
        guard let settings else { return }

        let buffer = nextSoundBuffer()

        // Volume scaling: map force range (~0.1g to ~5g) to volume 0.3–1.0
        let baseVolume = settings.masterVolume
        let volume: Float
        if settings.volumeScaling {
            let normalized = clamp(force / 3.0, min: 0.1, max: 1.0)
            let logScaled = Float(log2(1.0 + normalized))
            volume = Float(baseVolume) * (0.3 + 0.7 * logScaled)
        } else {
            volume = Float(baseVolume)
        }

        // Pitch scaling: light → lower pitch, hard → higher pitch
        let pitchCents: Float
        if settings.pitchScaling {
            let normalized = clamp(force / 3.0, min: 0.0, max: 1.0)
            pitchCents = Float(-200.0 + 600.0 * normalized)
        } else {
            pitchCents = 0
        }

        // "Sexy mode" escalation based on recent slap frequency
        let escalatedVolume: Float
        let escalatedPitch: Float
        if settings.soundMode == .sexy {
            let frequency = updateAndGetSlapFrequency()
            let escalation = Float(clamp(frequency / 20.0, min: 0.0, max: 1.0))
            escalatedVolume = volume * (0.7 + 0.3 * escalation)
            escalatedPitch = pitchCents + Float(escalation * 200.0)
        } else {
            escalatedVolume = volume
            escalatedPitch = pitchCents
        }

        // Apply to the audio pipeline and play
        pitchEffect.pitch = escalatedPitch
        pitchEffect.rate = 1.0
        playerNode.volume = escalatedVolume

        playerNode.stop()
        playerNode.scheduleBuffer(buffer, at: nil, options: .interrupts)
        playerNode.play()
    }

    /// Play a sound for USB plug/unplug events (USB Moaner mode).
    func playUSBSound() {
        guard !soundBuffers.isEmpty, isReady else { return }
        guard let settings else { return }

        let buffer = nextSoundBuffer()
        pitchEffect.pitch = 0
        pitchEffect.rate = 1.0
        playerNode.volume = Float(settings.masterVolume) * 0.6
        playerNode.stop()
        playerNode.scheduleBuffer(buffer, at: nil, options: .interrupts)
        playerNode.play()
    }

    // MARK: - Private Helpers

    private func nextSoundBuffer() -> AVAudioPCMBuffer {
        if playIndex >= playOrder.count {
            reshufflePlayOrder()
        }
        let index = playOrder[playIndex]
        playIndex += 1
        return soundBuffers[index]
    }

    private func reshufflePlayOrder() {
        playOrder = Array(0..<soundBuffers.count).shuffled()
        playIndex = 0
    }

    /// Load an audio file and convert it to the engine's format.
    /// This is critical — AVAudioPlayerNode crashes if the buffer format
    /// doesn't match the format of the node connection. We convert at
    /// load time so playback is always safe and instant.
    private func loadAndConvertAudioBuffer(from url: URL) -> AVAudioPCMBuffer? {
        guard let audioFile = try? AVAudioFile(forReading: url) else {
            print("[AudioManager] Failed to open: \(url.lastPathComponent)")
            return nil
        }

        let sourceFormat = audioFile.processingFormat

        // If formats match, load directly
        if sourceFormat.sampleRate == engineFormat.sampleRate &&
           sourceFormat.channelCount == engineFormat.channelCount {
            let frameCount = AVAudioFrameCount(audioFile.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else { return nil }
            do {
                try audioFile.read(into: buffer)
                return buffer
            } catch {
                print("[AudioManager] Failed to read: \(url.lastPathComponent) — \(error)")
                return nil
            }
        }

        // Formats differ — use AVAudioConverter to resample/remix
        guard let converter = AVAudioConverter(from: sourceFormat, to: engineFormat) else {
            print("[AudioManager] Can't create converter for: \(url.lastPathComponent)")
            return nil
        }

        // Calculate output frame count after resampling
        let ratio = engineFormat.sampleRate / sourceFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(audioFile.length) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: engineFormat, frameCapacity: outputFrameCount) else {
            return nil
        }

        // Read the source file into a temporary buffer
        let sourceFrameCount = AVAudioFrameCount(audioFile.length)
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: sourceFrameCount) else {
            return nil
        }

        do {
            try audioFile.read(into: sourceBuffer)
        } catch {
            print("[AudioManager] Failed to read: \(url.lastPathComponent) — \(error)")
            return nil
        }

        // Convert
        var error: NSError?
        var inputConsumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        if let error {
            print("[AudioManager] Conversion failed for \(url.lastPathComponent): \(error)")
            return nil
        }

        return outputBuffer
    }

    /// Find bundled sound files for a built-in mode.
    private func bundledSoundURLs(for mode: SoundMode) -> [URL] {
        guard let resourcePath = Bundle.main.resourcePath else { return [] }
        let soundDir = URL(fileURLWithPath: resourcePath)
            .appendingPathComponent("Sounds")
            .appendingPathComponent(mode.rawValue.lowercased())
        return audioFiles(in: soundDir)
    }

    private func customSoundURLs(from folder: URL?) -> [URL] {
        guard let folder else { return [] }
        return audioFiles(in: folder)
    }

    private func audioFiles(in directory: URL) -> [URL] {
        let supportedExtensions = Set(["mp3", "wav", "m4a", "aac", "aif", "aiff", "caf"])
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return contents.filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func updateAndGetSlapFrequency() -> Double {
        let now = Date()
        recentSlapTimes.append(now)
        recentSlapTimes.removeAll { now.timeIntervalSince($0) > sexyModeWindow }
        return Double(recentSlapTimes.count) / (sexyModeWindow / 60.0)
    }

    private func clamp(_ value: Double, min: Double, max: Double) -> Double {
        Swift.min(Swift.max(value, min), max)
    }
}
