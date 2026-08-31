import Foundation
import IOKit
import IOKit.hid

/// One accelerometer reading in g. Only transient values live in memory; the stream is never logged
/// or written to disk.
struct SlapSample: Equatable {
    let x: Double
    let y: Double
    let z: Double
    let timestamp: TimeInterval

    /// The optional lid-angle sensor saw movement recently. A closing lid also produces an impact,
    /// so it is a useful fail-safe when that second SPU endpoint exists.
    var lidIsMoving = false
}

struct SlapEvent: Equatable {
    let timestamp: TimeInterval
    /// Dynamic acceleration peak after subtracting the slowly changing gravity vector.
    let amplitude: Double
    /// 0...1 value suitable for later sound-volume/animation feedback.
    let intensity: Double
}

private extension SlapSensitivity {
    /// Absolute floor in g. Balanced remains the conservative everyday mode; high deliberately
    /// reaches light taps. The adaptive noise gate may raise either floor on a vibrating desk.
    var impulseThreshold: Double {
        switch self {
        case .balanced: return 0.26
        case .high:     return 0.14
        }
    }
}

/// Pure, deterministic impulse classifier. It is separate from IOKit so traces can be replayed in
/// a simulator without a MacBook sensor or Input Monitoring permission.
struct SlapImpulseClassifier {
    struct Tuning {
        var impulseThreshold: Double
        var cooldown: TimeInterval = 0.90
        var warmup: TimeInterval = 0.35
        var settleWindow: TimeInterval = 0.12
        var lidQuietPeriod: TimeInterval = 0.35
        var adaptiveNoiseMultiplier: Double = 6.0

        static func standard(_ sensitivity: SlapSensitivity) -> Tuning {
            Tuning(impulseThreshold: sensitivity.impulseThreshold)
        }
    }

    private struct Vector {
        var x: Double
        var y: Double
        var z: Double

        static func -(lhs: Vector, rhs: Vector) -> Vector {
            Vector(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
        }

        var magnitude: Double { sqrt(x * x + y * y + z * z) }
    }

    private struct Candidate {
        let beganAt: TimeInterval
        var peak: Double
        let threshold: Double
    }

    private let tuning: Tuning
    private var gravity: Vector?
    private var previous: Vector?
    private var previousTimestamp: TimeInterval?
    private var warmUntil: TimeInterval = .greatestFiniteMagnitude
    private var cooldownUntil: TimeInterval = 0
    private var noiseEMA: Double = 0
    private var motionEMA: Double = 0
    private var candidate: Candidate?

    init(tuning: Tuning = .standard(.balanced)) {
        self.tuning = tuning
    }

    mutating func reset() {
        gravity = nil
        previous = nil
        previousTimestamp = nil
        warmUntil = .greatestFiniteMagnitude
        cooldownUntil = 0
        noiseEMA = 0
        motionEMA = 0
        candidate = nil
    }

    mutating func ingest(_ sample: SlapSample) -> SlapEvent? {
        guard sample.timestamp.isFinite,
              sample.x.isFinite, sample.y.isFinite, sample.z.isFinite else { return nil }

        let value = Vector(x: sample.x, y: sample.y, z: sample.z)
        // Corrupt reports should not become a very enthusiastic gesture.
        guard value.magnitude <= 32 else { return nil }

        guard let oldTime = previousTimestamp, let oldGravity = gravity, let oldValue = previous else {
            gravity = value
            previous = value
            previousTimestamp = sample.timestamp
            warmUntil = sample.timestamp + tuning.warmup
            return nil
        }

        let rawDT = sample.timestamp - oldTime
        guard rawDT > 0 else { return nil }
        // A gap means wake/resume or a stalled HID stream. Re-learn gravity instead of treating the
        // first fresh report as an impact.
        if rawDT > 0.25 {
            gravity = value
            previous = value
            previousTimestamp = sample.timestamp
            warmUntil = sample.timestamp + tuning.warmup
            candidate = nil
            motionEMA = 0
            noiseEMA = 0
            return nil
        }

        let dt = min(rawDT, 0.05)
        let dynamicVector = value - oldGravity
        let dynamic = dynamicVector.magnitude
        // Express sharpness as the delta that would have been observed at the classifier's
        // nominal 10 ms cadence. Without this normalization the same physical tap changes
        // sensitivity when firmware switches between (for example) 100 and 800 reports/s.
        // Scale up sub-cadence deltas. Longer intervals are not scaled down: an occasional delayed
        // callback must not hide an otherwise valid impulse (and gaps >250 ms reset above).
        let cadenceScale = rawDT < 0.010 ? min(0.010 / rawDT, 8.0) : 1.0
        let normalizedJerk = (value - oldValue).magnitude * cadenceScale
        let priorMotion = motionEMA

        // Gravity follows posture slowly. During a hard transient it follows even more slowly, so
        // the peak is not swallowed by its own baseline update.
        let gravityTau = dynamic < tuning.impulseThreshold * 0.65 ? 0.70 : 2.5
        let gravityAlpha = 1 - exp(-dt / gravityTau)
        gravity = Vector(
            x: oldGravity.x + (value.x - oldGravity.x) * gravityAlpha,
            y: oldGravity.y + (value.y - oldGravity.y) * gravityAlpha,
            z: oldGravity.z + (value.z - oldGravity.z) * gravityAlpha
        )
        previous = value
        previousTimestamp = sample.timestamp

        let motionAlpha = 1 - exp(-dt / 0.22)
        motionEMA += (dynamic - motionEMA) * motionAlpha
        if dynamic < tuning.impulseThreshold * 0.65 {
            let noiseAlpha = 1 - exp(-dt / 0.80)
            noiseEMA += (dynamic - noiseEMA) * noiseAlpha
        }

        if sample.lidIsMoving {
            // Do not let the eventual hinge impact inherit a quiet pre-window.
            candidate = nil
            warmUntil = sample.timestamp + tuning.lidQuietPeriod
            motionEMA = max(motionEMA, tuning.impulseThreshold)
            return nil
        }

        guard sample.timestamp >= warmUntil else { return nil }

        if var pending = candidate {
            pending.peak = max(pending.peak, dynamic)
            candidate = pending

            let age = sample.timestamp - pending.beganAt
            let settledBelow = max(pending.threshold * 0.55, pending.peak * 0.45)
            // A slap is an impulse: sharp attack followed by a fast decay. Picking the laptop up,
            // driving with it in a bag, and other sustained motion fail this confirmation stage.
            if age >= 0.012, dynamic <= settledBelow {
                candidate = nil
                cooldownUntil = sample.timestamp + tuning.cooldown
                let span = max(pending.threshold * 2.0, 0.001)
                let intensity = min(max((pending.peak - pending.threshold) / span, 0), 1)
                return SlapEvent(timestamp: sample.timestamp,
                                 amplitude: pending.peak,
                                 intensity: intensity)
            }
            if age > tuning.settleWindow { candidate = nil }
            return nil
        }

        guard sample.timestamp >= cooldownUntil else { return nil }

        let adaptiveThreshold = max(
            tuning.impulseThreshold,
            noiseEMA * tuning.adaptiveNoiseMultiplier + 0.04
        )
        let quietEnoughBeforeImpact = priorMotion <= tuning.impulseThreshold * 0.22
        let sharpEnough = normalizedJerk >= adaptiveThreshold * 0.55
        if quietEnoughBeforeImpact, sharpEnough, dynamic >= adaptiveThreshold {
            candidate = Candidate(beganAt: sample.timestamp,
                                  peak: dynamic,
                                  threshold: adaptiveThreshold)
        }
        return nil
    }
}

/// Reduces a high-rate HID stream to a stable classifier cadence while retaining the strongest
/// excursion in each time bucket. This is deliberately pure so the 800 Hz firmware case can be
/// replayed without touching IOKit.
struct SlapSampleCadenceReducer {
    private struct Vector {
        let x: Double
        let y: Double
        let z: Double

        func distance(to other: Vector) -> Double {
            let dx = x - other.x
            let dy = y - other.y
            let dz = z - other.z
            return sqrt(dx * dx + dy * dy + dz * dz)
        }
    }

    let interval: TimeInterval
    private var lastOutput: SlapSample?
    private var pending: SlapSample?
    private var pendingDistance = -Double.infinity
    private var lidMovedInBucket = false

    init(interval: TimeInterval = 0.008) {
        self.interval = interval
    }

    mutating func reset() {
        lastOutput = nil
        pending = nil
        pendingDistance = -.infinity
        lidMovedInBucket = false
    }

    mutating func ingest(_ sample: SlapSample) -> SlapSample? {
        guard interval > 0, sample.timestamp.isFinite else { return nil }
        guard let last = lastOutput else {
            lastOutput = sample
            return sample
        }

        let elapsed = sample.timestamp - last.timestamp
        guard elapsed > 0 else { return nil }
        if elapsed > 0.25 {
            reset()
            lastOutput = sample
            return sample
        }

        lidMovedInBucket = lidMovedInBucket || sample.lidIsMoving
        let reference = Vector(x: last.x, y: last.y, z: last.z)
        let value = Vector(x: sample.x, y: sample.y, z: sample.z)
        let distance = value.distance(to: reference)
        if pending == nil || distance >= pendingDistance {
            pending = sample
            pendingDistance = distance
        }

        guard elapsed >= interval, let strongest = pending else { return nil }
        let output = SlapSample(
            x: strongest.x,
            y: strongest.y,
            z: strongest.z,
            timestamp: sample.timestamp,
            lidIsMoving: lidMovedInBucket
        )
        lastOutput = output
        pending = nil
        pendingDistance = -.infinity
        lidMovedInBucket = false
        return output
    }
}

protocol SlapSampleSource: AnyObject {
    var onSample: ((SlapSample) -> Void)? { get set }
    var onAvailabilityChange: ((Bool) -> Void)? { get set }
    func start()
    func stop()
}

/// Opt-in gesture controller. Merely constructing it does not touch HID; `setEnabled(true)` does.
/// All public callbacks are delivered on the main thread.
final class SlapDetector {
    var onSlap: ((SlapEvent) -> Void)?
    var onAvailabilityChange: ((SlapDetectorAvailability) -> Void)?

    private(set) var isEnabled = false
    private(set) var availability: SlapDetectorAvailability = .disabled
    private(set) var sensitivity: SlapSensitivity

    private let source: SlapSampleSource
    private let processingQueue = DispatchQueue(label: "ru.keyboop.slap.classifier",
                                                qos: .userInitiated)
    private var classifier: SlapImpulseClassifier
    private var processingEnabled = false
    private var processingGeneration: UInt64 = 0
    private var deliveryGeneration: UInt64 = 0

    init(sensitivity: SlapSensitivity = .balanced,
         source: SlapSampleSource = SlapHIDSampleSource(),
         onSlap: ((SlapEvent) -> Void)? = nil) {
        self.sensitivity = sensitivity
        self.source = source
        self.classifier = SlapImpulseClassifier(tuning: .standard(sensitivity))
        self.onSlap = onSlap

        source.onSample = { [weak self] sample in
            self?.consume(sample)
        }
        source.onAvailabilityChange = { [weak self] available in
            self?.sourceAvailabilityChanged(available)
        }
    }

    func setEnabled(_ enabled: Bool) {
        onMain { [weak self] in self?.setEnabledOnMain(enabled) }
    }

    func setSensitivity(_ sensitivity: SlapSensitivity) {
        onMain { [weak self] in
            guard let self, self.sensitivity != sensitivity else { return }
            self.sensitivity = sensitivity
            let generation = self.deliveryGeneration
            self.processingQueue.sync {
                self.classifier = SlapImpulseClassifier(tuning: .standard(sensitivity))
                self.processingGeneration = generation
            }
        }
    }

    /// Explicit lifecycle hook for applicationWillTerminate and settings teardown.
    func shutdown() {
        if Thread.isMainThread {
            setEnabledOnMain(false)
        } else {
            DispatchQueue.main.sync { [weak self] in self?.setEnabledOnMain(false) }
        }
    }

    deinit {
        source.onSample = nil
        source.onAvailabilityChange = nil
        source.stop()
    }

    private func setEnabledOnMain(_ enabled: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        deliveryGeneration &+= 1
        let generation = deliveryGeneration
        processingQueue.sync {
            classifier.reset()
            processingEnabled = enabled
            processingGeneration = generation
        }
        if enabled {
            setAvailability(.checking)
            source.start()
        } else {
            source.stop()
            setAvailability(.disabled)
        }
    }

    private func consume(_ sample: SlapSample) {
        processingQueue.async { [weak self] in
            guard let self, self.processingEnabled else { return }
            let generation = self.processingGeneration
            guard let event = self.classifier.ingest(sample) else { return }
            // Only the finished gesture crosses to main. Hundreds of hardware callbacks and all
            // classifier math stay off the UI run loop.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isEnabled, self.deliveryGeneration == generation else { return }
                self.onSlap?(event)
            }
        }
    }

    private func sourceAvailabilityChanged(_ available: Bool) {
        onMain { [weak self] in
            guard let self, self.isEnabled else { return }
            self.setAvailability(available ? .available : .unavailable)
        }
    }

    private func setAvailability(_ value: SlapDetectorAvailability) {
        guard availability != value else { return }
        availability = value
        onAvailabilityChange?(value)
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() }
        else { DispatchQueue.main.async(execute: block) }
    }
}

// MARK: - Apple SPU HID source

enum SlapHIDReportParser {
    static func acceleration(_ bytes: [UInt8]) -> (x: Double, y: Double, z: Double)? {
        bytes.withUnsafeBufferPointer { acceleration($0) }
    }

    static func acceleration(_ bytes: UnsafeBufferPointer<UInt8>)
        -> (x: Double, y: Double, z: Double)? {
        guard bytes.count == 22 else { return nil }
        let scale = 1.0 / 65_536.0
        return (
            Double(signedInt32LE(bytes, at: 6)) * scale,
            Double(signedInt32LE(bytes, at: 10)) * scale,
            Double(signedInt32LE(bytes, at: 14)) * scale
        )
    }

    static func lidAngle(_ bytes: UnsafeBufferPointer<UInt8>) -> Double? {
        guard bytes.count >= 3, bytes[0] == 1 else { return nil }
        let raw = (UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)) & 0x01ff
        return Double(raw)
    }

    private static func signedInt32LE(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> Int32 {
        let raw = UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
        return Int32(bitPattern: raw)
    }
}

/// Reads only two anonymous hardware streams: acceleration and (when present) lid angle. It never
/// records them, never logs values, and never asks for a new permission. An unavailable/denied HID
/// endpoint simply reports `false` and the rest of Keyboop continues normally.
final class SlapHIDSampleSource: SlapSampleSource {
    var onSample: ((SlapSample) -> Void)? {
        get {
            callbackLock.lock()
            defer { callbackLock.unlock() }
            return sampleHandler
        }
        set {
            callbackLock.lock()
            sampleHandler = newValue
            callbackLock.unlock()
        }
    }

    var onAvailabilityChange: ((Bool) -> Void)? {
        get {
            callbackLock.lock()
            defer { callbackLock.unlock() }
            return availabilityHandler
        }
        set {
            callbackLock.lock()
            availabilityHandler = newValue
            callbackLock.unlock()
        }
    }

    private enum SensorKind {
        case accelerometer
        case lid

        var usagePage: Int {
            switch self {
            case .accelerometer: return 0xff00
            case .lid:           return 0x0020
            }
        }

        var usage: Int {
            switch self {
            case .accelerometer: return 3
            case .lid:           return 138
            }
        }
    }

    private final class CallbackBox {
        weak var owner: SlapHIDSampleSource?
        let kind: SensorKind

        init(owner: SlapHIDSampleSource, kind: SensorKind) {
            self.owner = owner
            self.kind = kind
        }
    }

    private struct OpenedManager {
        let manager: IOHIDManager
        let box: CallbackBox
        let runLoop: CFRunLoop
    }

    /// A direct-device fallback is created only after the manager path found the exact endpoint but
    /// delivered no reports. Service handles and the report buffer have explicit ownership because
    /// the C callback keeps using all three until synchronous teardown.
    private final class DirectHIDSession {
        let deviceService: io_service_t
        let driverService: io_service_t
        let device: IOHIDDevice
        let box: CallbackBox
        let runLoop: CFRunLoop
        let reportBuffer: UnsafeMutablePointer<UInt8>
        var guardLeaseAcquired = false
        var isOpen = false
        var isScheduled = false
        var servicesWereReleased = false

        init(deviceService: io_service_t,
             driverService: io_service_t,
             device: IOHIDDevice,
             box: CallbackBox,
             runLoop: CFRunLoop) {
            self.deviceService = deviceService
            self.driverService = driverService
            self.device = device
            self.box = box
            self.runLoop = runLoop
            reportBuffer = .allocate(capacity: 22)
            reportBuffer.initialize(repeating: 0, count: 22)
        }

        deinit {
            assert(servicesWereReleased, "direct HID service handles escaped teardown")
            reportBuffer.deinitialize(count: 22)
            reportBuffer.deallocate()
        }
    }

    private let callbackLock = NSLock()
    private var sampleHandler: ((SlapSample) -> Void)?
    private var availabilityHandler: ((Bool) -> Void)?
    private let lifecycle = NSCondition()
    private var workerThread: Thread?
    private var workerRunLoop: CFRunLoop?
    private var workerIsStarting = false
    private var workerIsStopping = false
    private var opened: [OpenedManager] = []
    private var directSession: DirectHIDSession?
    private var running = false
    private var lastAvailability: Bool?
    private var lastLidAngle: Double?
    private var lidMovingUntil: TimeInterval = 0
    private var accelEndpointPresent = false
    private var accelEndpointWasChecked = false
    private var receivedValidAccelReport = false
    private var availabilityTimer: Timer?
    private var watchdogTimer: Timer?
    private var lastValidAccelReportAt: TimeInterval?
    private var cadenceReducer = SlapSampleCadenceReducer()
    private var diagnosticReportCount = 0
    private var diagnosticReducedCount = 0
    private var diagnosticReportWindowStartedAt: TimeInterval?
    private var diagnosticRateWasLogged = false
    private var diagnosticCallbackErrorWasLogged = false
    private var directAttemptCount = 0
    private var directRetryNotBefore: TimeInterval = 0
    private let maximumDirectAttempts = 3
    private let diagnosticsEnabled = ProcessInfo.processInfo.environment["KEYBOOP_SLAP_DIAG"] == "1"
    private static let startupPublicationBudget: TimeInterval = 1.0
    private static let stopBudget: TimeInterval = 3.0

    func start() {
        lifecycle.lock()
        guard workerThread == nil, !workerIsStarting, !workerIsStopping else {
            lifecycle.unlock()
            return
        }
        workerIsStarting = true
        let thread = Thread { [weak self] in self?.workerMain() }
        thread.name = "Keyboop slap HID"
        thread.qualityOfService = .userInitiated
        workerThread = thread
        thread.start()
        // Publishing the worker run loop makes an immediate disable deterministic.
        let deadline = Date().addingTimeInterval(Self.startupPublicationBudget)
        while workerIsStarting {
            if !lifecycle.wait(until: deadline) { break }
        }
        let timedOut = workerIsStarting
        lifecycle.unlock()
        if timedOut { diagnostic("worker run loop publication timed out") }
    }

    func stop() {
        let deadline = Date().addingTimeInterval(Self.stopBudget)
        lifecycle.lock()
        while workerIsStarting {
            if !lifecycle.wait(until: deadline) { break }
        }
        if workerIsStarting {
            // The thread may still publish later. Marking it as stopping makes workerMain skip all
            // HID setup when that happens, while this caller remains bounded.
            workerIsStopping = true
            lifecycle.unlock()
            diagnostic("stop timed out waiting for worker startup; teardown remains requested")
            return
        }
        if workerIsStopping {
            while workerThread != nil {
                if !lifecycle.wait(until: deadline) { break }
            }
            let timedOut = workerThread != nil
            lifecycle.unlock()
            if timedOut { diagnostic("stop timed out behind an in-flight teardown") }
            return
        }
        guard let thread = workerThread, let runLoop = workerRunLoop else {
            lifecycle.unlock()
            return
        }
        workerIsStopping = true
        if Thread.current === thread {
            lifecycle.unlock()
            stopOnWorker()
            CFRunLoopStop(runLoop)
            return
        }

        let finished = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            self?.stopOnWorker()
            CFRunLoopStop(runLoop)
            finished.signal()
        }
        CFRunLoopWakeUp(runLoop)
        lifecycle.unlock()
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0,
              finished.wait(timeout: .now() + remaining) == .success else {
            diagnostic("stop deadline expired; worker owns deferred teardown")
            return
        }

        // Do not permit a new start until the old callback context is completely gone. If the
        // deadline wins, workerThread remains published and start() therefore continues to fail
        // closed until workerMain broadcasts the real exit.
        lifecycle.lock()
        while workerThread != nil {
            if !lifecycle.wait(until: deadline) { break }
        }
        let timedOut = workerThread != nil
        lifecycle.unlock()
        if timedOut { diagnostic("stop block finished but worker exit missed the deadline") }
    }

    deinit {
        stop()
    }

    private func workerMain() {
        autoreleasepool {
            // A private port keeps this thread's run loop alive between sparse HID callbacks.
            let keepAlive = Port()
            RunLoop.current.add(keepAlive, forMode: .default)
            let runLoop = CFRunLoopGetCurrent()

            lifecycle.lock()
            workerRunLoop = runLoop
            workerIsStarting = false
            let shouldStart = !workerIsStopping
            lifecycle.broadcast()
            lifecycle.unlock()

            if shouldStart {
                startOnWorker()
                CFRunLoopRun()
                if running { stopOnWorker() }
            }

            lifecycle.lock()
            workerRunLoop = nil
            workerThread = nil
            workerIsStopping = false
            lifecycle.broadcast()
            lifecycle.unlock()
        }
    }

    private func startOnWorker() {
        guard !running, directSession == nil, opened.isEmpty else { return }
        running = true
        // A fresh enable starts a fresh availability handshake. Otherwise a previous `false` would
        // suppress the callback and leave the controller stuck in `.checking` forever.
        lastAvailability = nil
        lastLidAngle = nil
        lidMovingUntil = 0
        accelEndpointPresent = false
        accelEndpointWasChecked = false
        receivedValidAccelReport = false
        availabilityTimer?.invalidate()
        availabilityTimer = nil
        lastValidAccelReportAt = nil
        cadenceReducer.reset()
        diagnosticReportCount = 0
        diagnosticReducedCount = 0
        diagnosticReportWindowStartedAt = nil
        diagnosticRateWasLogged = false
        diagnosticCallbackErrorWasLogged = false
        directAttemptCount = 0
        directRetryNotBefore = 0
        diagnostic("starting manager path")

        #if arch(arm64)
        if let accel = openManager(.accelerometer) { opened.append(accel) }
        // Optional. Its absence never disables the gesture; it only removes the lid-motion guard.
        if let lid = openManager(.lid) { opened.append(lid) }
        recomputeAvailability()
        #else
        diagnostic("unsupported architecture")
        publishAvailability(false)
        #endif

    }

    private func stopOnWorker() {
        guard running || !opened.isEmpty || directSession != nil else { return }
        running = false
        availabilityTimer?.invalidate()
        availabilityTimer = nil
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        if let directSession {
            teardownDirect(directSession)
            self.directSession = nil
        }
        opened.forEach(teardownManager)
        opened.removeAll()
        resetStreamState()
        diagnostic("stopped")
        publishAvailability(false)
    }

    private func resetStreamState() {
        lastLidAngle = nil
        lidMovingUntil = 0
        accelEndpointPresent = false
        accelEndpointWasChecked = false
        receivedValidAccelReport = false
        lastValidAccelReportAt = nil
        cadenceReducer.reset()
        diagnosticReportCount = 0
        diagnosticReducedCount = 0
        diagnosticReportWindowStartedAt = nil
        diagnosticRateWasLogged = false
        diagnosticCallbackErrorWasLogged = false
    }

    private func openManager(_ kind: SensorKind) -> OpenedManager? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let runLoop = CFRunLoopGetCurrent() else {
            diagnostic("\(kind) manager: worker run loop unavailable")
            return nil
        }
        let box = CallbackBox(owner: self, kind: kind)
        let context = Unmanaged.passUnretained(box).toOpaque()
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDDeviceUsagePageKey as String: kind.usagePage,
            kIOHIDDeviceUsageKey as String: kind.usage,
            kIOHIDVendorIDKey as String: 1452,       // Apple, not an external vendor-page lookalike
            kIOHIDBuiltInKey as String: true,
            kIOHIDTransportKey as String: "SPU",
        ] as CFDictionary)
        IOHIDManagerRegisterInputReportCallback(manager, Self.reportCallback, context)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.deviceChangedCallback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.deviceChangedCallback, context)
        IOHIDManagerScheduleWithRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(
                manager, runLoop, CFRunLoopMode.defaultMode.rawValue
            )
            let closeResult = IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            diagnosticResult("\(kind) manager open", result)
            diagnosticResult("\(kind) manager close after failed open", closeResult)
            return nil
        }
        diagnostic("\(kind) manager opened")
        return OpenedManager(manager: manager, box: box, runLoop: runLoop)
    }

    private func handleReport(kind: SensorKind,
                              result: IOReturn,
                              report: UnsafeMutablePointer<UInt8>?,
                              length: CFIndex) {
        guard running else { return }
        guard result == kIOReturnSuccess else {
            if !diagnosticCallbackErrorWasLogged {
                diagnosticCallbackErrorWasLogged = true
                diagnosticResult("input report callback", result)
            }
            return
        }
        guard let report, length > 0 else { return }
        let bytes = UnsafeBufferPointer(start: report, count: length)
        let now = ProcessInfo.processInfo.systemUptime
        switch kind {
        case .accelerometer:
            guard let value = SlapHIDReportParser.acceleration(bytes) else { return }
            diagnosticReportCount += 1
            lastValidAccelReportAt = now
            if !receivedValidAccelReport {
                receivedValidAccelReport = true
                directAttemptCount = 0
                directRetryNotBefore = 0
                availabilityTimer?.invalidate()
                availabilityTimer = nil
                diagnosticReportWindowStartedAt = now
                armWatchdog()
                diagnostic(directSession == nil
                           ? "first valid accelerometer report received (manager)"
                           : "first valid accelerometer report received (direct)")
                publishAvailability(true)
            }

            let rawSample = SlapSample(x: value.x, y: value.y, z: value.z,
                                       timestamp: now, lidIsMoving: now < lidMovingUntil)
            if let reduced = cadenceReducer.ingest(rawSample) {
                diagnosticReducedCount += 1
                emitSample(reduced)
            }
            if diagnosticsEnabled, !diagnosticRateWasLogged,
               let began = diagnosticReportWindowStartedAt, now - began >= 2.0 {
                diagnosticRateWasLogged = true
                let elapsed = max(now - began, 0.001)
                let rawRate = Double(max(diagnosticReportCount - 1, 0)) / elapsed
                let reducedRate = Double(max(diagnosticReducedCount - 1, 0)) / elapsed
                diagnostic("delivery rate raw≈\(Int(rawRate.rounded()))/s classifier≈\(Int(reducedRate.rounded()))/s")
            }
        case .lid:
            guard let angle = SlapHIDReportParser.lidAngle(bytes) else { return }
            if let previous = lastLidAngle, abs(angle - previous) >= 1.5 {
                // Covers the whole close/open motion and the hinge impact immediately after it.
                lidMovingUntil = now + 0.80
            }
            lastLidAngle = angle
        }
    }

    private func recomputeAvailability() {
        guard running, directSession == nil else { return }
        let present = opened.contains { item in
            item.box.kind == .accelerometer
                && ((IOHIDManagerCopyDevices(item.manager) as? Set<IOHIDDevice>)?.isEmpty == false)
        }
        guard !accelEndpointWasChecked || present != accelEndpointPresent else { return }
        accelEndpointWasChecked = true
        accelEndpointPresent = present
        diagnostic(present ? "Apple built-in SPU accelerometer endpoint found"
                           : "Apple built-in SPU accelerometer endpoint absent")
        availabilityTimer?.invalidate()
        availabilityTimer = nil
        if !present {
            receivedValidAccelReport = false
            lastValidAccelReportAt = nil
            cadenceReducer.reset()
            disarmWatchdog()
            if lastAvailability == true {
                directAttemptCount = 0
                directRetryNotBefore = 0
                publishAvailability(false)
            }
            // IOHIDManager may be denied while the exact registry-backed IOHIDDevice remains
            // openable. Give enumeration one short beat, then try the same tightly filtered direct
            // path; unsupported Macs fail softly without touching any driver.
            scheduleDirectFallback(after: 0.35,
                                   reason: "manager endpoint unavailable; probing exact direct path")
            return
        }
        guard !receivedValidAccelReport else { return }
        // A matching registry node is not enough: permissions or a sleeping SPU can still produce
        // zero reports. Only a valid 22-byte report means "available" to the UI.
        scheduleDirectFallback(
            after: 2.5,
            reason: "manager endpoint found, but no report arrived; trying exact direct path"
        )
    }

    private func scheduleDirectFallback(after baseDelay: TimeInterval,
                                        reason: String) {
        guard directAttemptCount < maximumDirectAttempts else {
            diagnostic("direct retry budget exhausted; passive manager remains active")
            publishAvailability(false)
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let delay = max(baseDelay, directRetryNotBefore - now)
        let timer = Timer(timeInterval: max(delay, 0.01), repeats: false) { [weak self] _ in
            guard let self, self.running, self.directSession == nil,
                  !self.receivedValidAccelReport else { return }
            self.diagnostic(reason)
            self.startDirectFallback()
        }
        RunLoop.current.add(timer, forMode: .default)
        availabilityTimer = timer
    }

    private func startDirectFallback() {
        guard running, directSession == nil, !receivedValidAccelReport else { return }
        guard directAttemptCount < maximumDirectAttempts else {
            diagnostic("direct retry budget exhausted")
            publishAvailability(false)
            return
        }
        directAttemptCount += 1
        let backoff = 0.75 * pow(2.0, Double(directAttemptCount - 1))
        directRetryNotBefore = ProcessInfo.processInfo.systemUptime + min(backoff, 3.0)
        availabilityTimer?.invalidate()
        availabilityTimer = nil

        // The manager can begin delivering as soon as the driver is woken. Remove only its
        // accelerometer manager before any property write; the optional lid guard stays live.
        var keptManagers: [OpenedManager] = []
        for item in opened {
            if item.box.kind == .accelerometer { teardownManager(item) }
            else { keptManagers.append(item) }
        }
        opened = keptManagers

        guard let deviceService = copyExactAccelerometerService() else {
            diagnostic("direct path: exact AppleSPUHIDDevice unavailable")
            recoverPassiveManagerAfterDirectFailure()
            return
        }
        guard let driverService = copyExactOwningDriver(below: deviceService) else {
            releaseIOObject(deviceService, operation: "release direct device service")
            diagnostic("direct path: exact owning AppleSPUHIDDriver unavailable")
            recoverPassiveManagerAfterDirectFailure()
            return
        }
        guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, deviceService) else {
            releaseIOObject(driverService, operation: "release direct driver after create failure")
            releaseIOObject(deviceService, operation: "release direct device after create failure")
            diagnostic("direct path: IOHIDDeviceCreate returned nil")
            recoverPassiveManagerAfterDirectFailure()
            return
        }
        guard let directRunLoop = CFRunLoopGetCurrent() else {
            releaseIOObject(driverService, operation: "release direct driver without run loop")
            releaseIOObject(deviceService, operation: "release direct device without run loop")
            diagnostic("direct path: worker run loop unavailable")
            recoverPassiveManagerAfterDirectFailure()
            return
        }

        let box = CallbackBox(owner: self, kind: .accelerometer)
        let session = DirectHIDSession(
            deviceService: deviceService,
            driverService: driverService,
            device: device,
            box: box,
            runLoop: directRunLoop
        )
        directSession = session
        let context = Unmanaged.passUnretained(box).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device, session.reportBuffer, 22, Self.reportCallback, context
        )
        IOHIDDeviceRegisterRemovalCallback(device, Self.directRemovalCallback, context)
        IOHIDDeviceScheduleWithRunLoop(
            device, session.runLoop, CFRunLoopMode.defaultMode.rawValue
        )
        session.isScheduled = true

        // Only the crash-surviving helper owns global SPU commands, its cross-build lock and the
        // durable receipt. This process remains a report consumer, never a driver-state owner.
        guard GlobeGuard.acquireSlap() else {
            diagnostic("direct path: resource guard refused the SPU lease")
            teardownDirect(session)
            directSession = nil
            recoverPassiveManagerAfterDirectFailure()
            return
        }
        session.guardLeaseAcquired = true

        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            diagnosticResult("direct IOHIDDeviceOpen", openResult)
            teardownDirect(session)
            directSession = nil
            recoverPassiveManagerAfterDirectFailure()
            return
        }
        session.isOpen = true

        // Availability requires both a valid app-side endpoint and helper-side counter growth over
        // the idle baseline. This is synchronous only on the private HID worker, never on AppKit.
        guard GlobeGuard.confirmSlapGrowth() else {
            diagnostic("direct path: resource guard could not prove event growth")
            teardownDirect(session)
            directSession = nil
            recoverPassiveManagerAfterDirectFailure()
            return
        }

        diagnostic("direct fallback armed for exact built-in Apple accelerometer")
        guard !receivedValidAccelReport else { return }
        let timer = Timer(timeInterval: 2.5, repeats: false) { [weak self] _ in
            guard let self, self.running, let session = self.directSession,
                  !self.receivedValidAccelReport else { return }
            self.diagnostic("direct path produced no valid report; unavailable")
            self.teardownDirect(session)
            self.directSession = nil
            self.recoverPassiveManagerAfterDirectFailure()
        }
        RunLoop.current.add(timer, forMode: .default)
        availabilityTimer = timer
    }

    private func teardownDirect(_ session: DirectHIDSession) {
        IOHIDDeviceRegisterInputReportCallback(
            session.device, session.reportBuffer, 22, nil, nil
        )
        IOHIDDeviceRegisterRemovalCallback(session.device, nil, nil)
        if session.isScheduled {
            IOHIDDeviceUnscheduleFromRunLoop(
                session.device, session.runLoop, CFRunLoopMode.defaultMode.rawValue
            )
            session.isScheduled = false
        }

        if session.isOpen {
            let closeResult = IOHIDDeviceClose(
                session.device, IOOptionBits(kIOHIDOptionsTypeNone)
            )
            diagnosticResult("direct IOHIDDeviceClose", closeResult)
            session.isOpen = false
        }

        // OFF is intentionally after IOHIDDeviceClose: only then can the helper prove the global
        // event counter stable. SIGKILL closes this device in the kernel before the helper wakes.
        if session.guardLeaseAcquired {
            let released = GlobeGuard.releaseSlap()
            diagnostic(released ? "resource guard proved SPU stopped"
                                : "resource guard retained unresolved SPU receipt")
            session.guardLeaseAcquired = false
        }

        releaseIOObject(session.driverService, operation: "release direct driver service")
        releaseIOObject(session.deviceService, operation: "release direct device service")
        session.servicesWereReleased = true
    }

    /// A transient wake/enumeration race must not permanently remove the passive manager. Reopen
    /// it after every failed direct transaction; the shared retry budget/backoff prevents loops.
    private func recoverPassiveManagerAfterDirectFailure() {
        guard running, directSession == nil else { return }
        publishAvailability(false)
        availabilityTimer?.invalidate()
        availabilityTimer = nil
        receivedValidAccelReport = false
        lastValidAccelReportAt = nil
        cadenceReducer.reset()
        disarmWatchdog()

        if !opened.contains(where: { $0.box.kind == .accelerometer }),
           let accel = openManager(.accelerometer) {
            opened.append(accel)
        }
        accelEndpointWasChecked = false
        accelEndpointPresent = false
        recomputeAvailability()
    }

    private func watchdogTick() {
        guard running, receivedValidAccelReport, let last = lastValidAccelReportAt else { return }
        let silentFor = ProcessInfo.processInfo.systemUptime - last
        guard silentFor >= 3.5 else { return }
        diagnostic("watchdog: accelerometer stream stalled; reopening after wake")
        publishAvailability(false)
        restartManagerPath()
    }

    private func armWatchdog() {
        guard watchdogTimer == nil else { return }
        let watchdog = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.watchdogTick()
        }
        RunLoop.current.add(watchdog, forMode: .default)
        watchdogTimer = watchdog
    }

    private func disarmWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    private func restartManagerPath() {
        availabilityTimer?.invalidate()
        availabilityTimer = nil
        disarmWatchdog()
        if let directSession {
            teardownDirect(directSession)
            self.directSession = nil
        }
        opened.forEach(teardownManager)
        opened.removeAll()
        resetStreamState()
        directAttemptCount = 0
        directRetryNotBefore = 0

        #if arch(arm64)
        if let accel = openManager(.accelerometer) { opened.append(accel) }
        if let lid = openManager(.lid) { opened.append(lid) }
        recomputeAvailability()
        #else
        publishAvailability(false)
        #endif
    }

    private func handleDirectRemoval(result: IOReturn) {
        guard running, let session = directSession else { return }
        diagnosticResult("direct device removal callback", result)
        availabilityTimer?.invalidate()
        availabilityTimer = nil
        teardownDirect(session)
        directSession = nil
        publishAvailability(false)
        restartManagerPath()
    }

    private func copyExactAccelerometerService() -> io_service_t? {
        guard let matching = IOServiceMatching("AppleSPUHIDDevice") else {
            diagnostic("IOServiceMatching AppleSPUHIDDevice returned nil")
            return nil
        }
        var iterator: io_iterator_t = 0
        // IOServiceGetMatchingServices consumes `matching` even when it fails.
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == kIOReturnSuccess else {
            diagnosticResult("enumerate AppleSPUHIDDevice", result)
            return nil
        }

        var matches: [io_service_t] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            if isExactAccelerometer(service) { matches.append(service) }
            else { releaseIOObject(service, operation: "release unmatched SPU HID device") }
        }
        releaseIOObject(iterator, operation: "release SPU HID device iterator")
        guard matches.count == 1 else {
            matches.forEach { releaseIOObject($0, operation: "release ambiguous SPU HID device") }
            diagnostic("direct path device match count=\(matches.count)")
            return nil
        }
        diagnostic("direct path resolved one exact AppleSPUHIDDevice")
        return matches[0]
    }

    private func copyExactOwningDriver(below device: io_service_t) -> io_service_t? {
        var matches: [io_service_t] = []
        let traversalSucceeded = collectExactDrivers(below: device, into: &matches)
        guard traversalSucceeded else {
            matches.forEach { releaseIOObject($0, operation: "release driver after traversal failure") }
            diagnostic("direct path owning-driver traversal failed")
            return nil
        }
        guard matches.count == 1 else {
            matches.forEach { releaseIOObject($0, operation: "release ambiguous SPU HID driver") }
            diagnostic("direct path owning driver match count=\(matches.count)")
            return nil
        }
        diagnostic("direct path resolved one exact owning AppleSPUHIDDriver")
        return matches[0]
    }

    @discardableResult
    private func collectExactDrivers(below parent: io_registry_entry_t,
                                     into matches: inout [io_service_t]) -> Bool {
        var iterator: io_iterator_t = 0
        let result = IORegistryEntryGetChildIterator(parent, kIOServicePlane, &iterator)
        guard result == kIOReturnSuccess else {
            diagnosticResult("enumerate owning driver children", result)
            return false
        }

        var succeeded = true
        while true {
            let child = IOIteratorNext(iterator)
            guard child != 0 else { break }
            if IOObjectConformsTo(child, "AppleSPUHIDDriver") != 0 {
                if isExactAccelerometer(child) { matches.append(child) }
                else { releaseIOObject(child, operation: "release non-accelerometer SPU driver") }
            } else {
                if !collectExactDrivers(below: child, into: &matches) { succeeded = false }
                releaseIOObject(child, operation: "release traversed registry child")
            }
        }
        releaseIOObject(iterator, operation: "release owning driver iterator")
        return succeeded
    }

    private func isExactAccelerometer(_ entry: io_registry_entry_t) -> Bool {
        registryInteger(entry, key: "PrimaryUsagePage") == 0xff00
            && registryInteger(entry, key: "PrimaryUsage") == 3
            && registryInteger(entry, key: "VendorID") == 1452
            && registryBool(entry, key: "Built-In") == true
            && registryString(entry, key: "Transport") == "SPU"
    }

    private func copyRegistryProperty(_ entry: io_registry_entry_t,
                                      key: String) -> CFTypeRef? {
        IORegistryEntryCreateCFProperty(
            entry, key as CFString, kCFAllocatorDefault, IOOptionBits(0)
        )?.takeRetainedValue()
    }

    private func registryInteger(_ entry: io_registry_entry_t, key: String) -> Int? {
        (copyRegistryProperty(entry, key: key) as? NSNumber)?.intValue
    }

    private func registryBool(_ entry: io_registry_entry_t, key: String) -> Bool? {
        (copyRegistryProperty(entry, key: key) as? NSNumber)?.boolValue
    }

    private func registryString(_ entry: io_registry_entry_t, key: String) -> String? {
        copyRegistryProperty(entry, key: key) as? String
    }

    private func releaseIOObject(_ object: io_object_t, operation: String) {
        guard object != 0 else { return }
        let result = IOObjectRelease(object)
        diagnosticResult(operation, result)
    }

    private func teardownManager(_ item: OpenedManager) {
        IOHIDManagerRegisterInputReportCallback(item.manager, nil, nil)
        IOHIDManagerRegisterDeviceMatchingCallback(item.manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(item.manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(
            item.manager, item.runLoop, CFRunLoopMode.defaultMode.rawValue
        )
        let result = IOHIDManagerClose(item.manager, IOOptionBits(kIOHIDOptionsTypeNone))
        diagnosticResult("manager close \(item.box.kind)", result)
    }

    private func publishAvailability(_ available: Bool) {
        guard available != lastAvailability else { return }
        lastAvailability = available
        callbackLock.lock()
        let callback = availabilityHandler
        callbackLock.unlock()
        callback?(available)
    }

    private func emitSample(_ sample: SlapSample) {
        callbackLock.lock()
        let callback = sampleHandler
        callbackLock.unlock()
        callback?(sample)
    }

    private func diagnostic(_ message: String) {
        guard diagnosticsEnabled else { return }
        // Explicit developer hook. No axes, angles, device serials, paths or user activity enter it.
        NSLog("Keyboop slap[diag]: %@", message)
    }

    private func diagnosticResult(_ operation: String, _ result: IOReturn) {
        guard diagnosticsEnabled else { return }
        let code = UInt32(bitPattern: result)
        diagnostic("\(operation): 0x\(String(format: "%08x", code))")
    }

    private static let reportCallback: IOHIDReportCallback = {
        context, result, _, _, _, report, length in
        guard let context else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
        box.owner?.handleReport(kind: box.kind, result: result, report: report, length: length)
    }

    private static let deviceChangedCallback: IOHIDDeviceCallback = {
        context, result, _, _ in
        guard let context else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
        guard box.kind == .accelerometer else { return }
        if result != kIOReturnSuccess {
            box.owner?.diagnosticResult("manager device callback", result)
        }
        box.owner?.recomputeAvailability()
    }

    private static let directRemovalCallback: IOHIDCallback = { context, result, _ in
        guard let context else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
        box.owner?.handleDirectRemoval(result: result)
    }
}
