// ImpactDetector.swift — Multi-algorithm slap/impact detection
// OpenSlap – macOS accelerometer-based slap detection
//
// Implements four independent detection algorithms that "vote" on whether
// an accelerometer event is an intentional slap. Requiring multiple algorithms
// to agree dramatically reduces false positives from normal laptop use
// (typing, closing the lid, bumping the desk, picking it up).
//
// The algorithms are borrowed from seismology and signal processing,
// adapted for the specific characteristics of laptop slaps:
//   - Very short duration (10-50ms)
//   - High peak acceleration (2-20g)
//   - Distinctive waveform (sharp spike + exponential decay from chassis ringing)
//   - Gravity bias (constant 1g in the Z axis)
//
// Each algorithm processes samples independently and returns a vote.
// The detector tallies votes and declares an impact if enough agree.

import Foundation

// MARK: - Detection Protocol

/// Each detection algorithm conforms to this protocol.
/// Algorithms are stateful (they maintain running statistics) and must
/// be called sequentially with each new sample.
protocol DetectionAlgorithm {
    /// Process one accelerometer sample and return a vote.
    mutating func processSample(_ sample: AccelerometerSample) -> DetectionVote
    /// Reset internal state (e.g., after config change).
    mutating func reset()
}

/// A single algorithm's opinion on whether the current sample is an impact.
struct DetectionVote {
    let isImpact: Bool
    /// Confidence in [0, 1]. Used to weight force estimation.
    let confidence: Double
    /// This algorithm's estimate of the impact force (in g, gravity-removed).
    let estimatedForce: Double
}

// MARK: - Impact Detector (Coordinator)

/// Coordinates multiple detection algorithms and applies cooldown logic.
/// This is the main entry point called by the daemon for each sensor sample.
final class ImpactDetector {

    /// Called when a confirmed impact is detected (after voting + cooldown).
    var onImpact: ((ImpactEvent) -> Void)?

    // Configuration (can be updated at runtime from the app)
    var minForceG: Double
    var cooldownMs: Int
    var voteThreshold: Int

    // Detection algorithms
    private var magnitudeDetector: MagnitudeThresholdDetector
    private var staltaDetector: STALTADetector
    private var cusumDetector: CUSUMDetector
    private var kurtosisDetector: KurtosisDetector

    // Cooldown state
    private var lastImpactTime: TimeInterval = 0

    init(
        minForceG: Double = OpenSlapConstants.defaultMinForceG,
        cooldownMs: Int = OpenSlapConstants.defaultCooldownMs,
        voteThreshold: Int = OpenSlapConstants.defaultVoteThreshold
    ) {
        self.minForceG = minForceG
        self.cooldownMs = cooldownMs
        self.voteThreshold = voteThreshold

        // Initialize each algorithm with tuned parameters.
        // Calibrated for ~800 Hz sample rate (measured on M-series MacBooks).
        self.magnitudeDetector = MagnitudeThresholdDetector(threshold: minForceG)
        self.staltaDetector = STALTADetector(
            staWindow: 40,    // ~50ms at 800 Hz — captures the slap impulse
            ltaWindow: 800,   // ~1s at 800 Hz — represents background vibration level
            triggerRatio: 2.5 // STA must be 2.5× the LTA to trigger
        )
        self.cusumDetector = CUSUMDetector(
            drift: 0.1,       // Allowable drift before accumulation starts
            threshold: 3.0    // Cumulative sum threshold for detection
        )
        self.kurtosisDetector = KurtosisDetector(
            windowSize: 100,  // ~125ms window for distribution analysis at 800 Hz
            kurtosisThreshold: 6.0  // Normal distribution has kurtosis 3; impacts >> 3
        )
    }

    private var debugSampleCount: UInt64 = 0

    /// Feed a new accelerometer sample to all detection algorithms.
    func processSample(_ sample: AccelerometerSample) {
        debugSampleCount += 1

        // Check cooldown: ignore if we recently fired
        let cooldownSeconds = Double(cooldownMs) / 1000.0
        if (sample.timestamp - lastImpactTime) < cooldownSeconds {
            _ = magnitudeDetector.processSample(sample)
            _ = staltaDetector.processSample(sample)
            _ = cusumDetector.processSample(sample)
            _ = kurtosisDetector.processSample(sample)
            return
        }

        // Collect votes from all algorithms
        let votes: [DetectionVote] = [
            magnitudeDetector.processSample(sample),
            staltaDetector.processSample(sample),
            cusumDetector.processSample(sample),
            kurtosisDetector.processSample(sample),
        ]

        let yesVotes = votes.filter(\.isImpact)
        let yesCount = yesVotes.count

        // Require minimum number of agreeing algorithms
        guard yesCount >= voteThreshold else { return }

        // Compute the force estimate as the confidence-weighted average
        // of individual algorithm estimates. This gives more weight to
        // algorithms that are more "sure" about the impact.
        let totalConfidence = yesVotes.reduce(0.0) { $0 + $1.confidence }
        let weightedForce: Double
        if totalConfidence > 0 {
            weightedForce = yesVotes.reduce(0.0) {
                $0 + $1.estimatedForce * $1.confidence
            } / totalConfidence
        } else {
            weightedForce = yesVotes.map(\.estimatedForce).max() ?? sample.magnitude
        }

        // Apply minimum force threshold
        guard weightedForce >= minForceG else { return }

        lastImpactTime = sample.timestamp

        let event = ImpactEvent(
            force: weightedForce,
            x: sample.x,
            y: sample.y,
            z: sample.z,
            timestamp: Date().timeIntervalSince1970,
            algorithmsTriggered: yesCount
        )

        onImpact?(event)
    }

    /// Update configuration at runtime (called when app sends new settings).
    func updateConfig(minForceG: Double? = nil, cooldownMs: Int? = nil) {
        if let f = minForceG {
            self.minForceG = f
            magnitudeDetector.threshold = f
        }
        if let c = cooldownMs {
            self.cooldownMs = c
        }
    }
}

/// Impact event with additional metadata for the app.
struct ImpactEvent {
    let force: Double     // Estimated force in g (gravity-removed)
    let x: Double         // Peak X acceleration
    let y: Double         // Peak Y acceleration
    let z: Double         // Peak Z acceleration
    let timestamp: TimeInterval  // Unix timestamp
    let algorithmsTriggered: Int // How many algorithms agreed
}

// MARK: - Algorithm 1: Magnitude Threshold
//
// The simplest algorithm: compute the total acceleration magnitude,
// subtract gravity, and check if it exceeds a threshold.
//
// WHY: Fast, easy to understand, and catches the obvious cases.
// WEAKNESS: Can trigger on rapid orientation changes (picking up the laptop)
// because the gravity vector shifts quickly. That's why we need other algorithms.

struct MagnitudeThresholdDetector: DetectionAlgorithm {
    var threshold: Double

    /// Exponential moving average of magnitude for gravity estimation.
    /// We can't just assume gravity is in the Z axis because the laptop
    /// might be tilted. The EMA adapts to the current orientation.
    private var gravityEstimate: Double = 1.0
    /// EMA smoothing factor. Small α = slow adaptation = stable gravity estimate.
    /// 0.001 at 400 Hz gives a ~2.5 second time constant.
    private let alpha: Double = 0.001

    init(threshold: Double) {
        self.threshold = threshold
    }

    mutating func processSample(_ sample: AccelerometerSample) -> DetectionVote {
        let mag = sample.magnitude

        // Update gravity estimate with exponential moving average.
        // This slowly tracks the true gravity vector so that when the laptop
        // is tilted, we don't see a constant offset as "force".
        gravityEstimate = gravityEstimate * (1.0 - alpha) + mag * alpha

        // The "excess" force above gravity is what we care about.
        // A stationary laptop has excess ≈ 0, a slap has excess >> 0.
        let excess = mag - gravityEstimate

        if excess > threshold {
            return DetectionVote(isImpact: true, confidence: min(excess / (threshold * 3.0), 1.0), estimatedForce: excess)
        }
        return DetectionVote(isImpact: false, confidence: 0, estimatedForce: 0)
    }

    mutating func reset() {
        gravityEstimate = 1.0
    }
}

// MARK: - Algorithm 2: STA/LTA (Short-Term Average / Long-Term Average)
//
// Borrowed from seismology where it's the standard method for detecting
// earthquake P-wave arrivals. The idea:
//
//   ratio = (average energy over short window) / (average energy over long window)
//
// When the ratio spikes, something sudden happened. "Energy" here is just
// the squared magnitude of the acceleration signal.
//
// WHY: Adapts to varying background vibration levels. A laptop on a shaky
// desk has higher LTA, so only truly sharp impacts trigger. On a stable desk,
// even lighter taps register.
//
// PARAMETERS:
//   - STA window: ~50ms — captures the impulsive energy of a slap
//   - LTA window: ~1s — represents the ambient vibration floor
//   - Trigger ratio: 3.5 — empirically tuned; seismology typically uses 3-5

struct STALTADetector: DetectionAlgorithm {
    let staWindow: Int
    let ltaWindow: Int
    let triggerRatio: Double

    /// Circular buffer of squared magnitude values for windowed averaging.
    private var energyBuffer: [Double] = []
    private var bufferIndex: Int = 0
    private var bufferFull: Bool = false

    init(staWindow: Int, ltaWindow: Int, triggerRatio: Double) {
        self.staWindow = staWindow
        self.ltaWindow = ltaWindow
        self.triggerRatio = triggerRatio
        self.energyBuffer = [Double](repeating: 0, count: ltaWindow)
    }

    mutating func processSample(_ sample: AccelerometerSample) -> DetectionVote {
        // Compute energy: squared magnitude minus expected gravity (1g² = 1).
        // Subtracting 1 centers the energy around 0 for a stationary laptop.
        let energy = sample.magnitude * sample.magnitude

        // Store in circular buffer
        energyBuffer[bufferIndex] = energy
        bufferIndex = (bufferIndex + 1) % ltaWindow
        if bufferIndex == 0 { bufferFull = true }

        // Don't compute until we have at least one full LTA window
        guard bufferFull else {
            return DetectionVote(isImpact: false, confidence: 0, estimatedForce: 0)
        }

        // Compute LTA: average energy over the full window
        let lta = energyBuffer.reduce(0, +) / Double(ltaWindow)

        // Compute STA: average energy over the most recent `staWindow` samples
        var staSum = 0.0
        for i in 0..<staWindow {
            let idx = (bufferIndex - 1 - i + ltaWindow) % ltaWindow
            staSum += energyBuffer[idx]
        }
        let sta = staSum / Double(staWindow)

        // Avoid division by zero (no vibration at all = perfectly silent)
        guard lta > 1e-6 else {
            return DetectionVote(isImpact: false, confidence: 0, estimatedForce: 0)
        }

        let ratio = sta / lta

        if ratio > triggerRatio {
            // Estimate force from the peak energy in the STA window
            let peakEnergy = (0..<staWindow).map { i -> Double in
                let idx = (bufferIndex - 1 - i + ltaWindow) % ltaWindow
                return energyBuffer[idx]
            }.max() ?? sta

            let estimatedForce = sqrt(peakEnergy) - 1.0  // Remove gravity
            let confidence = min((ratio - triggerRatio) / (triggerRatio * 2.0), 1.0)

            return DetectionVote(isImpact: true, confidence: confidence, estimatedForce: max(estimatedForce, 0))
        }

        return DetectionVote(isImpact: false, confidence: 0, estimatedForce: 0)
    }

    mutating func reset() {
        energyBuffer = [Double](repeating: 0, count: ltaWindow)
        bufferIndex = 0
        bufferFull = false
    }
}

// MARK: - Algorithm 3: CUSUM (Cumulative Sum)
//
// A classic change-point detection algorithm from statistical process control.
// It accumulates the sum of deviations above a baseline, resetting to zero
// when the sum goes negative. When the cumulative sum exceeds a threshold,
// a "change point" (impact) is detected.
//
// WHY: Excellent at detecting sudden shifts in signal level, even when the
// shift is modest. Complements magnitude threshold by catching softer slaps
// that might not cross the threshold individually but show a clear shift
// in the signal's character.
//
// MATH:
//   S(n) = max(0, S(n-1) + |x(n)| - μ - ν)
//   where μ = running mean, ν = drift allowance
//   Trigger when S(n) > h (threshold)

struct CUSUMDetector: DetectionAlgorithm {
    let drift: Double       // ν: allowable drift before accumulation starts
    let threshold: Double   // h: cumulative sum trigger threshold

    private var cusumHigh: Double = 0   // Upward cusum
    private var meanEstimate: Double = 1.0  // Running mean of magnitude
    private let alpha: Double = 0.005   // EMA factor for mean
    private var sampleCount: Int = 0

    init(drift: Double, threshold: Double) {
        self.drift = drift
        self.threshold = threshold
    }

    mutating func processSample(_ sample: AccelerometerSample) -> DetectionVote {
        let mag = sample.magnitude
        sampleCount += 1

        // Update running mean estimate
        meanEstimate = meanEstimate * (1.0 - alpha) + mag * alpha

        // Accumulate: deviation above (mean + drift)
        // The drift parameter prevents slow-changing signals (like tilting)
        // from building up the cusum.
        let deviation = mag - meanEstimate - drift
        cusumHigh = max(0, cusumHigh + deviation)

        if cusumHigh > threshold {
            let force = mag - meanEstimate  // Instantaneous excess over baseline
            let confidence = min(cusumHigh / (threshold * 3.0), 1.0)

            // Reset after triggering to prevent retriggering on decay
            cusumHigh = 0

            return DetectionVote(isImpact: true, confidence: confidence, estimatedForce: max(force, 0))
        }

        return DetectionVote(isImpact: false, confidence: 0, estimatedForce: 0)
    }

    mutating func reset() {
        cusumHigh = 0
        meanEstimate = 1.0
        sampleCount = 0
    }
}

// MARK: - Algorithm 4: Kurtosis / Peak Detection
//
// Kurtosis measures the "tailedness" of a probability distribution.
// A normal (Gaussian) distribution has kurtosis = 3. Impact signals have
// very high kurtosis because a few extreme samples dominate the distribution.
//
// We compute the excess kurtosis (kurtosis - 3) over a rolling window.
// When it spikes, the window contains an impact-like event.
//
// WHY: Kurtosis is independent of the signal's scale (amplitude), making it
// robust against different sensitivity settings. It specifically detects the
// "spiky" nature of impacts versus the more uniform energy of noise.
//
// We also do simple peak detection: if any sample in the window exceeds
// N standard deviations, that reinforces the kurtosis signal.

struct KurtosisDetector: DetectionAlgorithm {
    let windowSize: Int
    let kurtosisThreshold: Double  // Excess kurtosis threshold

    /// Circular buffer for the rolling window.
    private var buffer: [Double]
    private var bufferIndex: Int = 0
    private var bufferFull: Bool = false

    init(windowSize: Int, kurtosisThreshold: Double) {
        self.windowSize = windowSize
        self.kurtosisThreshold = kurtosisThreshold
        self.buffer = [Double](repeating: 0, count: windowSize)
    }

    mutating func processSample(_ sample: AccelerometerSample) -> DetectionVote {
        let mag = sample.magnitude

        buffer[bufferIndex] = mag
        bufferIndex = (bufferIndex + 1) % windowSize
        if bufferIndex == 0 { bufferFull = true }

        guard bufferFull else {
            return DetectionVote(isImpact: false, confidence: 0, estimatedForce: 0)
        }

        // Compute mean
        let mean = buffer.reduce(0, +) / Double(windowSize)

        // Compute variance and 4th central moment
        var m2: Double = 0  // sum of (x - mean)²
        var m4: Double = 0  // sum of (x - mean)⁴
        var peak: Double = 0

        for value in buffer {
            let diff = value - mean
            let diff2 = diff * diff
            m2 += diff2
            m4 += diff2 * diff2
            peak = max(peak, value)
        }

        let variance = m2 / Double(windowSize)
        guard variance > 1e-6 else {
            return DetectionVote(isImpact: false, confidence: 0, estimatedForce: 0)
        }

        // Kurtosis = E[(X-μ)⁴] / σ⁴  (the "true" kurtosis)
        // Excess kurtosis = kurtosis - 3  (0 for normal distribution)
        let kurtosis = (m4 / Double(windowSize)) / (variance * variance)
        let excessKurtosis = kurtosis - 3.0

        // Also check if the peak is a statistical outlier (> 3σ from mean)
        let stdDev = variance.squareRoot()
        let peakZScore = (peak - mean) / stdDev

        let isKurtosisHigh = excessKurtosis > kurtosisThreshold
        let isPeakOutlier = peakZScore > 4.0  // 4σ is very unusual

        if isKurtosisHigh && isPeakOutlier {
            let estimatedForce = peak - 1.0  // Remove gravity
            let confidence = min(excessKurtosis / (kurtosisThreshold * 3.0), 1.0)
            return DetectionVote(isImpact: true, confidence: confidence, estimatedForce: max(estimatedForce, 0))
        }

        return DetectionVote(isImpact: false, confidence: 0, estimatedForce: 0)
    }

    mutating func reset() {
        buffer = [Double](repeating: 0, count: windowSize)
        bufferIndex = 0
        bufferFull = false
    }
}
