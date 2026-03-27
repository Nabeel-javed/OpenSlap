// SensorReader.swift — IOKit HID accelerometer interface
// OpenSlap – macOS accelerometer-based slap detection
//
// Reads raw acceleration data from the Apple SPU (Sensor Processing Unit)
// via IOKit's HID framework. The SPU houses a Bosch BMI286 IMU on recent
// Apple Silicon MacBooks.
//
// WHY IOKit HID?
// Apple doesn't expose the laptop accelerometer through any public framework
// (CoreMotion is iOS/watchOS only). The only way to access it on macOS is
// through IOKit HID, which requires root privileges because the device is
// not in the user-accessible HID device list.
//
// HOW IT WORKS:
// 1. Create an IOHIDManager and match on the vendor-defined usage page (0xFF00)
//    with usage 3 (accelerometer).
// 2. Open the matched device and register an input report callback.
// 3. The sensor fires the callback at ~400 Hz with 22-byte reports.
// 4. We parse X/Y/Z from the report and convert from fixed-point to g-force.

import Foundation
import IOKit.hid

// MARK: - SensorReaderDelegate

protocol SensorReaderDelegate: AnyObject {
    /// Called at sensor rate (~400 Hz) with each new accelerometer sample.
    func sensorReader(_ reader: SensorReader, didReceiveSample sample: AccelerometerSample)

    /// Called once when the sensor is found and streaming, or when it disconnects.
    func sensorReader(_ reader: SensorReader, didChangeConnectionState connected: Bool)
}

// MARK: - SensorReader

/// Manages the IOKit HID connection to the MacBook's built-in accelerometer.
///
/// Must be created and used on a thread with an active CFRunLoop (typically the main thread).
/// The HID callbacks are delivered on whatever run loop the manager is scheduled on.
final class SensorReader {

    weak var delegate: SensorReaderDelegate?

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?

    /// Pre-allocated report buffer. IOKit writes incoming reports here.
    /// Must stay alive as long as the callback is registered.
    private var reportBuffer: UnsafeMutablePointer<UInt8>

    /// For measuring actual sample rate (diagnostic use).
    private var sampleCount: UInt64 = 0
    private var lastRateCheck: TimeInterval = 0
    private(set) var measuredSampleRate: Double = 0

    /// Mach timebase for converting mach_absolute_time to seconds.
    private let timebaseNumer: Double
    private let timebaseDenom: Double

    init() {
        // Allocate a buffer large enough for the expected report size.
        // We add padding in case future firmware sends larger reports.
        reportBuffer = .allocate(capacity: 64)
        reportBuffer.initialize(repeating: 0, count: 64)

        // Cache the Mach timebase info for timestamp conversion.
        // mach_absolute_time counts in hardware ticks; we need to convert
        // to seconds using the timebase ratio.
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebaseNumer = Double(info.numer)
        timebaseDenom = Double(info.denom)
    }

    deinit {
        stop()
        reportBuffer.deallocate()
    }

    // MARK: - Lifecycle

    /// Open the HID manager, find the accelerometer, and start streaming.
    /// Returns `true` if the sensor was found, `false` if no matching device exists.
    @discardableResult
    func start() -> Bool {
        guard manager == nil else { return device != nil }

        // Create the HID manager in the default allocation mode.
        // kIOHIDOptionsTypeNone means we don't request exclusive access —
        // we just want to read reports without preventing other clients.
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        // Build a matching dictionary that selects only the accelerometer.
        // On Apple Silicon MacBooks, the SPU exposes several HID devices on
        // vendor page 0xFF00. Usage 3 is the accelerometer, usage 5 is the
        // ambient light sensor, etc.
        let matchingDict: [String: Int] = [
            kIOHIDPrimaryUsagePageKey as String: OpenSlapConstants.sensorUsagePage,
            kIOHIDPrimaryUsageKey as String: OpenSlapConstants.sensorUsage
        ]

        IOHIDManagerSetDeviceMatching(mgr, matchingDict as CFDictionary)

        // Schedule on the current run loop. The callback will fire on this
        // thread's run loop, so make sure it's running (the daemon's main
        // function calls RunLoop.main.run()).
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        // Open the manager. This triggers device enumeration.
        let openResult = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            print("[SensorReader] IOHIDManagerOpen failed: 0x\(String(openResult, radix: 16))")
            print("[SensorReader] Are you running as root? IOKit HID access to the SPU requires elevated privileges.")
            manager = mgr
            delegate?.sensorReader(self, didChangeConnectionState: false)
            return false
        }

        // Get the set of matched devices. We expect at least one accelerometer.
        guard let deviceSet = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>,
              !deviceSet.isEmpty else {
            print("[SensorReader] No accelerometer device found.")
            print("[SensorReader] This Mac may not have a compatible SPU sensor.")
            print("[SensorReader] Supported: MacBook Pro/Air with M1 Pro or later (M2/M3/M4 series).")
            manager = mgr
            delegate?.sensorReader(self, didChangeConnectionState: false)
            return false
        }

        // Log matched devices for diagnostics
        for (i, dev) in deviceSet.enumerated() {
            let product = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "Unknown"
            let reportSize = IOHIDDeviceGetProperty(dev, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? -1
            print("[SensorReader] Device \(i): \(product) (reportSize=\(reportSize))")
        }

        // Select the actual accelerometer: Apple vendor (0x05AC) with 22-byte reports.
        // Other devices on the same usage page (like the keyboard/trackpad) are not
        // accelerometers and won't produce the data we expect.
        let accelDevice: IOHIDDevice
        if let appleAccel = deviceSet.first(where: { dev in
            let vendor = IOHIDDeviceGetProperty(dev, kIOHIDVendorIDKey as CFString) as? Int ?? 0
            let reportSize = IOHIDDeviceGetProperty(dev, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
            return vendor == 0x05AC && reportSize == OpenSlapConstants.reportLength
        }) {
            accelDevice = appleAccel
        } else {
            // Fallback: pick the device with the smallest report size >= 18 bytes
            // (accelerometer reports are compact; keyboards send larger reports)
            let candidates = deviceSet.filter { dev in
                let size = IOHIDDeviceGetProperty(dev, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
                return size >= 18
            }.sorted { dev1, dev2 in
                let s1 = IOHIDDeviceGetProperty(dev1, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 999
                let s2 = IOHIDDeviceGetProperty(dev2, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 999
                return s1 < s2
            }
            guard let fallback = candidates.first else {
                print("[SensorReader] No suitable accelerometer device found among matches.")
                manager = mgr
                delegate?.sensorReader(self, didChangeConnectionState: false)
                return false
            }
            accelDevice = fallback
        }

        let product = IOHIDDeviceGetProperty(accelDevice, kIOHIDProductKey as CFString) as? String ?? "Unknown"
        let maxReport = IOHIDDeviceGetProperty(accelDevice, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? -1
        print("[SensorReader] Selected sensor: \(product) (maxReportSize=\(maxReport))")

        device = accelDevice
        manager = mgr

        // Register the input report callback.
        //
        // IOKit HID callbacks use a C function pointer, which in Swift must be
        // a @convention(c) closure that captures no context. We pass `self` through
        // the void* context parameter using Unmanaged to bridge the reference.
        //
        // SAFETY: We use passUnretained because `self` (SensorReader) owns the
        // manager and thus outlives the callback registration. When stop() is
        // called, we unschedule the manager before any deallocation.
        let context = Unmanaged.passUnretained(self).toOpaque()

        IOHIDDeviceRegisterInputReportCallback(
            accelDevice,
            reportBuffer,
            64,                 // buffer size
            hidReportCallback,  // C function defined below
            context
        )

        lastRateCheck = currentTimestamp()
        delegate?.sensorReader(self, didChangeConnectionState: true)
        print("[SensorReader] Accelerometer streaming started.")

        return true
    }

    /// Stop reading and release IOKit resources.
    func stop() {
        if let dev = device {
            IOHIDDeviceRegisterInputReportCallback(dev, reportBuffer, 64, nil, nil)
            device = nil
        }
        if let mgr = manager {
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            manager = nil
        }
        delegate?.sensorReader(self, didChangeConnectionState: false)
    }

    // MARK: - Report Parsing

    /// Parse a raw 22-byte HID report into an AccelerometerSample.
    ///
    /// Report layout (22 bytes, observed on M2/M3 MacBooks):
    /// ```
    /// Offset  Size  Description
    /// ------  ----  -----------
    ///  0       1    Report ID
    ///  1       1    Flags / sequence
    ///  2-5     4    Timestamp (sensor clock, not used — we use mach time instead)
    ///  6-9     4    X acceleration (signed Int32, little-endian, fixed-point Q16.16)
    /// 10-13    4    Y acceleration (signed Int32, little-endian, fixed-point Q16.16)
    /// 14-17    4    Z acceleration (signed Int32, little-endian, fixed-point Q16.16)
    /// 18-21    4    Padding / reserved
    /// ```
    ///
    /// The Q16.16 format means the upper 16 bits are the integer part and the lower
    /// 16 bits are the fractional part. Dividing by 65536 (2^16) converts to a
    /// floating-point value in g-force units.
    func parseReport(_ report: UnsafePointer<UInt8>, length: Int) -> AccelerometerSample? {
        // Reject unexpectedly short reports
        guard length >= 18 else {
            return nil
        }

        // Read signed 32-bit little-endian integers at the documented offsets.
        // We use withMemoryRebound to reinterpret the byte pointer as Int32.
        let rawX = readInt32LE(report, offset: OpenSlapConstants.xOffset)
        let rawY = readInt32LE(report, offset: OpenSlapConstants.yOffset)
        let rawZ = readInt32LE(report, offset: OpenSlapConstants.zOffset)

        // Convert from Q16.16 fixed-point to g-force
        let scale = OpenSlapConstants.rawToGForce
        return AccelerometerSample(
            x: Double(rawX) / scale,
            y: Double(rawY) / scale,
            z: Double(rawZ) / scale,
            timestamp: currentTimestamp()
        )
    }

    // MARK: - Internal Callback Handler

    /// Called by the C callback trampoline for each HID report.
    func handleReport(_ report: UnsafePointer<UInt8>, length: Int) {
        sampleCount += 1

        guard let sample = parseReport(report, length: length) else { return }

        // Log startup samples and periodic status
        if sampleCount <= 3 {
            print("[SensorReader] #\(sampleCount): x=\(String(format: "%+.3f", sample.x))g  y=\(String(format: "%+.3f", sample.y))g  z=\(String(format: "%+.3f", sample.z))g  mag=\(String(format: "%.3f", sample.magnitude))g")
        } else if sampleCount % 8000 == 0 {
            print("[SensorReader] Streaming: \(String(format: "%.0f", measuredSampleRate))Hz  mag=\(String(format: "%.3f", sample.magnitude))g")
        }

        // Update sample rate measurement every 1000 samples
        if sampleCount % 1000 == 0 {
            let now = currentTimestamp()
            let elapsed = now - lastRateCheck
            if elapsed > 0 {
                measuredSampleRate = 1000.0 / elapsed
                lastRateCheck = now
            }
        }

        delegate?.sensorReader(self, didReceiveSample: sample)
    }

    // MARK: - Helpers

    /// Read a signed 32-bit little-endian integer from a byte buffer at the given offset.
    private func readInt32LE(_ buffer: UnsafePointer<UInt8>, offset: Int) -> Int32 {
        // Construct the Int32 manually from individual bytes to avoid alignment issues.
        // ARM processors can handle unaligned access, but being explicit is safer.
        let b0 = Int32(buffer[offset])
        let b1 = Int32(buffer[offset + 1]) << 8
        let b2 = Int32(buffer[offset + 2]) << 16
        let b3 = Int32(buffer[offset + 3]) << 24
        return b0 | b1 | b2 | b3
    }

    /// Current time in seconds (monotonic, high precision).
    private func currentTimestamp() -> TimeInterval {
        let machTime = mach_absolute_time()
        return Double(machTime) * timebaseNumer / timebaseDenom / 1_000_000_000.0
    }
}

// MARK: - C Callback Trampoline

/// IOKit HID requires a C-compatible function pointer for the report callback.
/// Swift closures that capture context can't be used directly, so we use this
/// global function as a trampoline that recovers the SensorReader from the
/// void* context parameter.
private func hidReportCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    reportLength: CFIndex
) {
    guard let context else { return }
    let reader = Unmanaged<SensorReader>.fromOpaque(context).takeUnretainedValue()
    reader.handleReport(report, length: reportLength)
}
