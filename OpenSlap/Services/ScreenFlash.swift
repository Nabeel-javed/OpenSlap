// ScreenFlash.swift — Visual feedback overlay on slap
// OpenSlap – macOS accelerometer-based slap detection
//
// Shows a red flash overlay when a slap is detected.
// Uses NSWindow with direct backgroundColor animation.

import AppKit

final class ScreenFlash {

    private var flashWindows: [FlashWindow] = []

    /// Flash all screens with intensity proportional to slap force.
    func flash(force: Double) {
        let intensity = min(max(force / 2.0, 0.1), 1.0)

        DispatchQueue.main.async { [self] in
            if flashWindows.isEmpty {
                createWindows()
            }
            for w in flashWindows {
                w.triggerFlash(intensity: intensity)
            }
        }
    }

    private func createWindows() {
        for screen in NSScreen.screens {
            let w = FlashWindow(screen: screen)
            flashWindows.append(w)
        }
    }
}

// MARK: - Flash Window

private class FlashWindow: NSPanel {

    private var fadeTimer: Timer?

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = NSColor.red.withAlphaComponent(0)
        self.ignoresMouseEvents = true
        self.hasShadow = false
        self.hidesOnDeactivate = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.animationBehavior = .none
        self.isReleasedWhenClosed = false

        self.orderFrontRegardless()
    }

    func triggerFlash(intensity: Double) {
        fadeTimer?.invalidate()

        let alpha = CGFloat(intensity * 0.6)
        self.backgroundColor = NSColor.red.withAlphaComponent(alpha)

        // Fade out over 350ms in steps
        var remaining = alpha
        let steps = 12
        let decrement = remaining / CGFloat(steps)

        fadeTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            remaining -= decrement
            if remaining <= 0 {
                remaining = 0
                timer.invalidate()
            }
            self.backgroundColor = NSColor.red.withAlphaComponent(remaining)
        }
    }
}
