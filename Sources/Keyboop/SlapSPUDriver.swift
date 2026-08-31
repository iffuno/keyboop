import Foundation
import IOKit

/// The BMI282-backed Apple SPU driver treats all six writes below as commands. In particular,
/// `ReportInterval` remains `0` in IORegistry even after an accepted `8000` command, so none of
/// these keys can be used as readable ownership state.
enum SlapSPUCommand: String, CaseIterable, Equatable {
    case intervalOn
    case powerOn
    case reportingOn
    case reportingOff
    case powerOff
    case intervalOff

    var key: String {
        switch self {
        case .intervalOn, .intervalOff: return "ReportInterval"
        case .powerOn, .powerOff:       return "SensorPropertyPowerState"
        case .reportingOn, .reportingOff:
            return "SensorPropertyReportingState"
        }
    }

    var value: Int32 {
        switch self {
        case .intervalOn: return 8_000 // microseconds, observed delivery ~= 125...133 Hz
        case .powerOn, .reportingOn: return 1
        case .reportingOff, .powerOff, .intervalOff: return 0
        }
    }
}

/// Pure policy shared with SlapSim. The helper owns all writes; the app only proves that borrowing
/// an otherwise idle stream is safe and consumes manager reports.
enum SlapSPUBorrowPlanner {
    static let activationOrder: [SlapSPUCommand] = [.intervalOn, .powerOn, .reportingOn]
    static let shutdownOrder: [SlapSPUCommand] = [.reportingOff, .powerOff, .intervalOff]

    static func provesIdle(first: UInt64?, second: UInt64?) -> Bool {
        guard let first, let second else { return false }
        return first == second
    }

    static func ownsActivation(after results: [IOReturn]) -> Bool {
        results.count == activationOrder.count
            && results.allSatisfy { $0 == kIOReturnSuccess }
    }
}

/// Narrow IOKit surface used by both the in-app idle probe and the crash-surviving helper. Every
/// operation is restricted to one exact built-in Apple usage-page 0xff00 / usage 3 driver.
enum SlapSPUDriver {
    typealias ResultObserver = (_ attempt: Int, _ command: SlapSPUCommand,
                                _ result: IOReturn) -> Void

    static func copyExactAccelerometerDriver() -> io_service_t? {
        guard let device = copyExactAccelerometerDevice() else { return nil }
        defer { IOObjectRelease(device) }
        var matches: [io_service_t] = []
        guard collectExactDrivers(below: device, into: &matches), matches.count == 1,
              serviceIdentity(matches[0]) != nil else {
            matches.forEach { IOObjectRelease($0) }
            return nil
        }
        return matches[0]
    }

    /// Stable, boot-local identity for the one exact driver this type is allowed to inspect. The
    /// property filter is repeated here so callers cannot accidentally turn a generic registry
    /// handle into an identity accepted by the SPU lease machinery.
    static func serviceIdentity(_ driver: io_registry_entry_t) -> UInt64? {
        guard driver != 0,
              IOObjectConformsTo(driver, "AppleSPUHIDDriver") != 0,
              isExactAccelerometer(driver) else { return nil }
        var identity: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(driver, &identity) == kIOReturnSuccess,
              identity != 0 else { return nil }
        return identity
    }

    /// Read-only diagnostic state. This is intentionally not used as ownership state because the
    /// BMI282-backed driver keeps exposing `0` after accepting the ON command.
    static func reportInterval(_ driver: io_registry_entry_t) -> Int? {
        guard serviceIdentity(driver) != nil else { return nil }
        return integer(driver, key: "ReportInterval")
    }

    private static func copyExactAccelerometerDevice() -> io_service_t? {
        guard let matching = IOServiceMatching("AppleSPUHIDDevice") else { return nil }
        var iterator: io_iterator_t = 0
        // IOServiceGetMatchingServices consumes `matching`, including its failure path.
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
                == kIOReturnSuccess else { return nil }

        var matches: [io_service_t] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            if isExactAccelerometer(service) { matches.append(service) }
            else { IOObjectRelease(service) }
        }
        IOObjectRelease(iterator)
        guard matches.count == 1 else {
            matches.forEach { IOObjectRelease($0) }
            return nil
        }
        return matches[0]
    }

    @discardableResult
    private static func collectExactDrivers(below parent: io_registry_entry_t,
                                            into matches: inout [io_service_t]) -> Bool {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(parent, kIOServicePlane, &iterator)
                == kIOReturnSuccess else { return false }
        var succeeded = true
        while true {
            let child = IOIteratorNext(iterator)
            guard child != 0 else { break }
            if IOObjectConformsTo(child, "AppleSPUHIDDriver") != 0 {
                if isExactAccelerometer(child) { matches.append(child) }
                else { IOObjectRelease(child) }
            } else {
                if !collectExactDrivers(below: child, into: &matches) { succeeded = false }
                IOObjectRelease(child)
            }
        }
        IOObjectRelease(iterator)
        return succeeded
    }

    static func eventCount(_ driver: io_registry_entry_t) -> SlapSPUEventCounter? {
        guard let state = copyProperty(driver, key: "DebugState") as? NSDictionary else {
            return nil
        }
        return SlapSPUEventCounterPolicy.counter(in: state)
    }

    /// Samples several consecutive windows on the same exact registry service. `nil` is distinct
    /// from `false`: it means the service disappeared, changed identity, the counter reset, or a
    /// read failed, and therefore no stable-stream conclusion is safe.
    static func streamIsRising(_ driver: io_registry_entry_t,
                               proofWindow: TimeInterval = 0.16,
                               proofWindows: Int = 3) -> Bool? {
        counterTrend(driver, proofWindow: proofWindow, proofWindows: proofWindows,
                     requireZeroReportInterval: false)?.isRising
    }

    /// A stable counter across several windows proves that Keyboop is not about to interrupt an
    /// already-running consumer. The final count is also the baseline against which activation must
    /// show growth.
    static func proveIdle(_ driver: io_registry_entry_t,
                          proofWindow: TimeInterval = 0.25,
                          proofWindows: Int = 6) -> SlapSPUEventCounterCursor? {
        // A visible non-zero interval rejects immediately. `0` is only a hint (BMI282 also exposes
        // it after ON), never the proof: the proof is the same registry identity and a monotonic
        // event counter that remains exactly stable for the complete 1.5-second observation.
        guard let trend = counterTrend(
            driver, proofWindow: proofWindow, proofWindows: proofWindows,
            requireZeroReportInterval: true
        ), !trend.isRising else { return nil }
        return trend.lastCursor
    }

    @discardableResult
    static func write(_ command: SlapSPUCommand,
                      to driver: io_registry_entry_t) -> IOReturn {
        IORegistryEntrySetCFProperty(
            driver, command.key as CFString, NSNumber(value: command.value)
        )
    }

    /// The helper is the sole writer. A partial ON pass is never ownership: the caller must run
    /// `shutDownAndProve` while retaining its cross-build lock and receipt.
    static func activate(_ driver: io_registry_entry_t,
                         observer: ResultObserver? = nil) -> Bool {
        var results: [IOReturn] = []
        for command in SlapSPUBorrowPlanner.activationOrder {
            let result = write(command, to: driver)
            results.append(result)
            observer?(1, command, result)
            if result != kIOReturnSuccess { break }
        }
        return SlapSPUBorrowPlanner.ownsActivation(after: results)
    }

    /// Repeats the complete paired sequence. Success means every command returned success during
    /// the same ordered pass; partial success is never treated as an adequate shutdown.
    static func shutDown(_ driver: io_registry_entry_t,
                         attempts: Int = 6,
                         retryDelay: TimeInterval = 0.02,
                         observer: ResultObserver? = nil) -> Bool {
        let count = max(attempts, 1)
        for attempt in 1...count {
            var passSucceeded = true
            for command in SlapSPUBorrowPlanner.shutdownOrder {
                let result = write(command, to: driver)
                observer?(attempt, command, result)
                if result != kIOReturnSuccess { passSucceeded = false }
            }
            if passSucceeded { return true }
            if attempt < count { Thread.sleep(forTimeInterval: retryDelay) }
        }
        return false
    }

    static func waitForEventGrowth(_ driver: io_registry_entry_t,
                                   after baseline: SlapSPUEventCounterCursor,
                                   timeout: TimeInterval = 0.8) -> Bool {
        let expectedIdentity = baseline.registryEntryID
        guard serviceIdentity(driver) == expectedIdentity else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + max(timeout, 0)
        var chain = SlapSPUEventCounterChain(baseline: baseline.counter)
        repeat {
            guard serviceIdentity(driver) == expectedIdentity,
                  let current = eventCount(driver) else { return false }
            guard chain.observe(current) else { return false }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                return chain.observedSampleCount >= 3 && chain.risingSampleCount >= 2
            }
            Thread.sleep(forTimeInterval: 0.02)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return chain.observedSampleCount >= 3 && chain.risingSampleCount >= 2
    }

    static func proveStopped(_ driver: io_registry_entry_t,
                             after anchor: SlapSPUEventCounterCursor,
                             settleDelay: TimeInterval = 0.12,
                             proofWindow: TimeInterval = 0.20,
                             proofWindows: Int = 5) -> Bool {
        Thread.sleep(forTimeInterval: boundedDelay(settleDelay, maximum: 1.0))
        guard let first = eventCursor(driver),
              first.registryEntryID == anchor.registryEntryID,
              SlapSPUEventCounterPolicy.monotonicStep(
                from: anchor.counter, to: first.counter
              ) != nil else {
            return false
        }
        guard let trend = counterTrend(
            driver, proofWindow: proofWindow, proofWindows: proofWindows,
            requireZeroReportInterval: true, initialCounter: first.counter,
            expectedServiceIdentity: anchor.registryEntryID
        ) else { return false }
        return !trend.isRising
    }

    /// An accepted command pass is necessary but not sufficient on BMI282. Only a stable event
    /// counter proves the write-only OFF commands actually stopped delivery.
    static func shutDownAndProve(_ driver: io_registry_entry_t,
                                 attempts: Int = 3,
                                 observer: ResultObserver? = nil) -> Bool {
        for attempt in 1...max(attempts, 1) {
            // Always send OFF even if the read-only anchor is unavailable. Such a pass cannot be
            // accepted, but a later outer attempt takes a fresh anchor and repeats the complete
            // OFF sequence before it may remove the durable receipt.
            let anchor = eventCursor(driver)
            guard shutDown(driver, attempts: 2, retryDelay: 0.015, observer: observer) else {
                continue
            }
            if let anchor, proveStopped(driver, after: anchor) {
                return true
            }
            if attempt < attempts { Thread.sleep(forTimeInterval: 0.02) }
        }
        return false
    }

    static func release(_ driver: io_object_t) {
        guard driver != 0 else { return }
        IOObjectRelease(driver)
    }

    private static func isExactAccelerometer(_ entry: io_registry_entry_t) -> Bool {
        integer(entry, key: "PrimaryUsagePage") == 0xff00
            && integer(entry, key: "PrimaryUsage") == 3
            && integer(entry, key: "VendorID") == 1452
            && boolean(entry, key: "Built-In") == true
            && string(entry, key: "Transport") == "SPU"
    }

    private static func counterTrend(_ driver: io_registry_entry_t,
                                     proofWindow: TimeInterval,
                                     proofWindows: Int,
                                     requireZeroReportInterval: Bool,
                                     initialCounter: SlapSPUEventCounter? = nil,
                                     expectedServiceIdentity: UInt64? = nil)
        -> (isRising: Bool, lastCursor: SlapSPUEventCounterCursor)? {
        guard let expectedIdentity = expectedServiceIdentity ?? serviceIdentity(driver),
              serviceIdentity(driver) == expectedIdentity,
              !requireZeroReportInterval || integer(driver, key: "ReportInterval") == 0,
              let first = initialCounter ?? eventCount(driver) else { return nil }

        var previous = first
        let windowCount = min(max(proofWindows, 2), 8)
        let delay = boundedDelay(proofWindow, minimum: 0.01, maximum: 1.0)
        for _ in 0..<windowCount {
            Thread.sleep(forTimeInterval: delay)
            guard serviceIdentity(driver) == expectedIdentity,
                  !requireZeroReportInterval || integer(driver, key: "ReportInterval") == 0,
                  let current = eventCount(driver),
                  let step = SlapSPUEventCounterPolicy.monotonicStep(
                    from: previous, to: current
                  ) else { return nil }
            if step == .rising {
                return (true, SlapSPUEventCounterCursor(
                    registryEntryID: expectedIdentity, counter: current
                ))
            }
            previous = current
        }
        return (false, SlapSPUEventCounterCursor(
            registryEntryID: expectedIdentity, counter: previous
        ))
    }

    private static func eventCursor(_ driver: io_registry_entry_t)
        -> SlapSPUEventCounterCursor? {
        guard let identity = serviceIdentity(driver),
              let counter = eventCount(driver),
              serviceIdentity(driver) == identity else { return nil }
        return SlapSPUEventCounterCursor(registryEntryID: identity, counter: counter)
    }

    private static func boundedDelay(_ value: TimeInterval,
                                     minimum: TimeInterval = 0,
                                     maximum: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return maximum }
        return min(max(value, minimum), maximum)
    }

    private static func copyProperty(_ entry: io_registry_entry_t,
                                     key: String) -> CFTypeRef? {
        IORegistryEntryCreateCFProperty(
            entry, key as CFString, kCFAllocatorDefault, IOOptionBits(0)
        )?.takeRetainedValue()
    }

    private static func integer(_ entry: io_registry_entry_t, key: String) -> Int? {
        (copyProperty(entry, key: key) as? NSNumber)?.intValue
    }

    private static func boolean(_ entry: io_registry_entry_t, key: String) -> Bool? {
        (copyProperty(entry, key: key) as? NSNumber)?.boolValue
    }

    private static func string(_ entry: io_registry_entry_t, key: String) -> String? {
        copyProperty(entry, key: key) as? String
    }
}
