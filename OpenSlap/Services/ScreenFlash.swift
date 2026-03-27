// ScreenFlash.swift — Visual feedback overlay on slap
// OpenSlap – macOS accelerometer-based slap detection
//
// Creates a borderless, transparent, click-through window that covers the
// entire screen. On slap, it flashes a red vignette that fades out.
// The flash intensity scales with slap force — light tap = subtle glow,
// hard slap = dramatic red flash.

import AppKit

final class ScreenFlash {

    private var overlayWindow: NSWindow?
    private var overlayView: FlashOverlayView?

    /// Flash the screen with an intensity proportional to the slap force.
    /// - Parameter force: Impact force in g (0.1 = barely visible, 2.0+ = full red)
    func flash(force: Double) {
        DispatchQueue.main.async { [self] in
            let intensity = min(max(force / 2.0, 0.05), 1.0)
            ensureWindow()
            overlayView?.flash(intensity: intensity)
        }
    }

    // MARK: - Window Setup

    private func ensureWindow() {
        guard overlayWindow == nil else { return }

        // Get the main screen bounds
        guard let screen = NSScreen.main else { return }
        let frame = screen.frame

        // Create a borderless, transparent, non-interactive window
        let window = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver          // Above everything
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true      // Click-through
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = FlashOverlayView(frame: frame)
        window.contentView = view
        window.orderFrontRegardless()

        overlayWindow = window
        overlayView = view
    }
}

// MARK: - Flash Overlay View

/// Custom NSView that draws a red vignette and animates its opacity.
private class FlashOverlayView: NSView {

    private var currentIntensity: CGFloat = 0
    private var animationTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.isOpaque = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func flash(intensity: Double) {
        // Cancel any existing fade-out
        animationTimer?.invalidate()

        currentIntensity = CGFloat(intensity)
        needsDisplay = true

        // Fade out over ~300ms (roughly 10 steps at 30ms each)
        var remaining = currentIntensity
        let step = remaining / 10.0

        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            remaining -= step
            if remaining <= 0 {
                remaining = 0
                timer.invalidate()
            }
            self.currentIntensity = remaining
            self.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard currentIntensity > 0 else {
            NSColor.clear.setFill()
            dirtyRect.fill()
            return
        }

        // Draw a radial vignette: transparent center, red edges.
        // This looks like the screen "reacting" to being hit rather
        // than just a flat red overlay.
        let ctx = NSGraphicsContext.current?.cgContext
        guard let ctx else { return }

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let maxRadius = hypot(bounds.width, bounds.height) / 2.0

        // Inner radius: ~60% of screen is clear (the center stays readable)
        let innerRadius = maxRadius * 0.6
        let outerRadius = maxRadius

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let alpha = currentIntensity * 0.6  // Max 60% opacity at full force

        let colors = [
            CGColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 0),        // Center: transparent
            CGColor(red: 1.0, green: 0.0, blue: 0.0, alpha: alpha),     // Edge: red
        ] as CFArray

        let locations: [CGFloat] = [0.0, 1.0]

        guard let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: colors,
            locations: locations
        ) else { return }

        ctx.drawRadialGradient(
            gradient,
            startCenter: center, startRadius: innerRadius,
            endCenter: center, endRadius: outerRadius,
            options: [.drawsAfterEndLocation]
        )
    }
}
