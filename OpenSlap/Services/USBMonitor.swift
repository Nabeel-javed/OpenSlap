// USBMonitor.swift — USB device plug/unplug detection
// OpenSlap – macOS accelerometer-based slap detection
//
// "USB Moaner" mode: plays a random sound when a USB device is connected
// or disconnected. Uses IOKit notifications for reliable detection of
// any USB device (drives, peripherals, hubs, etc.).

import Foundation
import IOKit
import IOKit.usb

final class USBMonitor: ObservableObject {

    /// Called when a USB device is plugged in or removed.
    var onUSBEvent: (() -> Void)?

    @Published private(set) var isMonitoring: Bool = false

    private var notifyPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0

    deinit {
        stop()
    }

    /// Start monitoring USB device events.
    func start() {
        guard !isMonitoring else { return }

        let matchingDict = IOServiceMatching(kIOUSBDeviceClassName)
        notifyPort = IONotificationPortCreate(kIOMainPortDefault)

        guard let notifyPort else {
            print("[USBMonitor] Failed to create notification port")
            return
        }

        let runLoopSource = IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)

        // Register for device connection events
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Device added
        let addResult = IOServiceAddMatchingNotification(
            notifyPort,
            kIOFirstMatchNotification,
            matchingDict,
            usbDeviceCallback,
            selfPtr,
            &addedIterator
        )

        if addResult == kIOReturnSuccess {
            // Drain the initial iterator (required by IOKit — existing devices are "matched"
            // immediately, and we must iterate them to arm the notification for future events)
            drainIterator(addedIterator)
        } else {
            print("[USBMonitor] Failed to register for USB additions: \(addResult)")
        }

        // Device removed — need a fresh matching dict (IOKit consumes it)
        let removeMatchingDict = IOServiceMatching(kIOUSBDeviceClassName)
        let removeResult = IOServiceAddMatchingNotification(
            notifyPort,
            kIOTerminatedNotification,
            removeMatchingDict,
            usbDeviceCallback,
            selfPtr,
            &removedIterator
        )

        if removeResult == kIOReturnSuccess {
            drainIterator(removedIterator)
        } else {
            print("[USBMonitor] Failed to register for USB removals: \(removeResult)")
        }

        isMonitoring = true
        print("[USBMonitor] Monitoring USB events")
    }

    /// Stop monitoring.
    func stop() {
        if addedIterator != 0 {
            IOObjectRelease(addedIterator)
            addedIterator = 0
        }
        if removedIterator != 0 {
            IOObjectRelease(removedIterator)
            removedIterator = 0
        }
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
        isMonitoring = false
    }

    /// Called from the C callback when a USB event fires.
    fileprivate func handleUSBEvent(iterator: io_iterator_t) {
        drainIterator(iterator)
        DispatchQueue.main.async { [weak self] in
            self?.onUSBEvent?()
        }
    }

    /// Drain all entries from an IOKit iterator.
    /// This is required: IOKit won't send future notifications until
    /// the current matches are consumed.
    private func drainIterator(_ iterator: io_iterator_t) {
        while case let device = IOIteratorNext(iterator), device != 0 {
            IOObjectRelease(device)
        }
    }
}

// C-compatible callback for IOKit notifications.
private func usbDeviceCallback(
    refCon: UnsafeMutableRawPointer?,
    iterator: io_iterator_t
) {
    guard let refCon else { return }
    let monitor = Unmanaged<USBMonitor>.fromOpaque(refCon).takeUnretainedValue()
    monitor.handleUSBEvent(iterator: iterator)
}
