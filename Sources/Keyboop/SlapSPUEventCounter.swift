import Foundation
import CoreFoundation

/// One validated sample from the exact accelerometer driver's `DebugState` dictionary.
///
/// BMI282 exposes both a short-lived `_num_events` value and the boot/wake monotonic
/// `_num_events_after_wake`. The source travels with the value so a property disappearing or
/// appearing mid-proof cannot silently switch counter domains.
struct SlapSPUEventCounter: Equatable {
    enum Source: Equatable {
        case afterWake
        case legacy
    }

    let source: Source
    let value: UInt64
}

/// Boot-local registry identity and counter domain captured as one proof cursor. It is never
/// serialized or reused by a replacement helper.
struct SlapSPUEventCounterCursor: Equatable {
    let registryEntryID: UInt64
    let counter: SlapSPUEventCounter
}

enum SlapSPUEventCounterStep: Equatable {
    case stable
    case rising
}

/// Stateful monotonic-chain validation. Growth is not accepted until the caller has observed its
/// complete proof window; a later reset/source switch invalidates earlier growth in that window.
struct SlapSPUEventCounterChain {
    private(set) var previous: SlapSPUEventCounter
    private(set) var risingSampleCount = 0
    private(set) var observedSampleCount = 0

    var sawGrowth: Bool { risingSampleCount > 0 }

    init(baseline: SlapSPUEventCounter) {
        previous = baseline
    }

    mutating func observe(_ current: SlapSPUEventCounter) -> Bool {
        guard let step = SlapSPUEventCounterPolicy.monotonicStep(
            from: previous, to: current
        ) else { return false }
        observedSampleCount += 1
        if step == .rising { risingSampleCount += 1 }
        previous = current
        return true
    }
}

/// Pure parsing/trend policy used by the production driver and fixture tests.
enum SlapSPUEventCounterPolicy {
    static let monotonicKey = "_num_events_after_wake"
    static let legacyKey = "_num_events"

    /// Prefer the BMI282 boot/wake monotonic counter whenever the key exists. A malformed primary
    /// value is an error, not permission to fall back to the reset-prone legacy counter. Legacy is
    /// accepted only when the primary key is genuinely absent, for older compatible drivers.
    static func counter(in debugState: NSDictionary) -> SlapSPUEventCounter? {
        if let raw = debugState[monotonicKey] {
            guard let value = unsignedInteger(raw) else { return nil }
            return SlapSPUEventCounter(source: .afterWake, value: value)
        }
        guard let raw = debugState[legacyKey],
              let value = unsignedInteger(raw) else { return nil }
        return SlapSPUEventCounter(source: .legacy, value: value)
    }

    /// `nil` is deliberately distinct from `.stable`: it means reset, wraparound or a counter
    /// source change. None of those can prove either ownership growth or a stopped stream.
    static func monotonicStep(from previous: SlapSPUEventCounter,
                              to current: SlapSPUEventCounter)
        -> SlapSPUEventCounterStep? {
        guard previous.source == current.source,
              current.value >= previous.value else { return nil }
        return current.value == previous.value ? .stable : .rising
    }

    private static func unsignedInteger(_ raw: Any) -> UInt64? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        // IORegistry counters are integral CFNumbers. Parsing their canonical decimal text avoids
        // `uint64Value` wrapping negatives or silently truncating floating-point fixtures.
        return UInt64(number.stringValue)
    }
}
