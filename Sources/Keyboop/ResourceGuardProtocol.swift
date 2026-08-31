import Foundation
import Darwin

enum ResourceGuardLaunchMode: Equatable {
    case application
    case persistent(parentPID: pid_t)
    case legacy(parentPID: pid_t)
    case invalid
}

/// Parse helper argv before AppKit exists. Any helper-looking but malformed/unsupported invocation
/// must fail closed instead of accidentally launching a second menu-bar application.
enum ResourceGuardLaunchPolicy {
    static func parse(_ arguments: [String]) -> ResourceGuardLaunchMode {
        let globe = arguments.indices.filter { arguments[$0] == "--globe-guard" }
        let v3 = arguments.indices.filter { arguments[$0] == "--resource-guard-v3" }
        let v2 = arguments.indices.filter { arguments[$0] == "--resource-guard-v2" }
        guard !globe.isEmpty || !v3.isEmpty || !v2.isEmpty else { return .application }
        // v2 was an internal draft with no safe persistent lifecycle. Treat every invocation as
        // unsupported; retaining its name only prevents old argv from falling through to AppKit.
        guard v2.isEmpty, globe.count == 1, v3.count <= 1,
              globe[0] == 1, arguments.count >= 3,
              let parent = pid_t(arguments[2]), parent > 1 else { return .invalid }
        if let marker = v3.first {
            guard marker == 3, arguments.count == 8,
                  !arguments[4].isEmpty,
                  let seconds = UInt64(arguments[5]), seconds > 0,
                  let micros = UInt64(arguments[6]), micros < 1_000_000,
                  !arguments[7].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .invalid
            }
            return .persistent(parentPID: parent)
        }
        return arguments.count == 3 ? .legacy(parentPID: parent) : .invalid
    }
}

enum ResourceGuardSingletonFailureAction: Equatable {
    case notifyPrimaryAndTerminate
    case exitRepairFailure
}

enum ResourceGuardSingletonFailurePolicy {
    static func action(explicitGlobeRepair: Bool) -> ResourceGuardSingletonFailureAction {
        explicitGlobeRepair ? .exitRepairFailure : .notifyPrimaryAndTerminate
    }
}

struct ResourceGuardCapability: OptionSet, Equatable {
    let rawValue: UInt8
    static let globe = ResourceGuardCapability(rawValue: 1 << 0)
    static let slap = ResourceGuardCapability(rawValue: 1 << 1)
}

enum ResourceGuardMessage: String, Codable {
    case hello
    case ready
    case addGlobe
    case dropGlobe
    /// Pre-READY migration for the old GUI-owned receipt. The authenticated parent may send this
    /// only after it has won the cross-build singleton and classified the exact legacy inode. The
    /// helper still owns the global restore, durable retirement marker and globe flock.
    case repairLegacyGlobe
    case acquireSlap
    case confirmSlapGrowth
    case releaseSlap
    case recoverSlap
    case normalExit
    case ok
    case busy
    case idleChanged
    case staleState
    case failed
}

struct ResourceGuardFrame: Codable, Equatable {
    static let version = 2
    static let maximumPayloadBytes = 1_024

    let version: Int
    let requestID: UInt64
    let session: String
    let message: ResourceGuardMessage
    let value: UInt64?

    init(requestID: UInt64,
         session: String,
         message: ResourceGuardMessage,
         value: UInt64? = nil) {
        self.version = Self.version
        self.requestID = requestID
        self.session = session
        self.message = message
        self.value = value
    }
}

/// PID alone is not an identity: macOS can recycle it. Receipts and helper arguments therefore
/// carry the exact kernel process birth time as well. `proc_bsdinfo` exposes both fields without
/// opening the target or asking for additional permissions.
struct ResourceGuardProcessIdentity: Codable, Equatable {
    let pid: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    var startedAt: Date {
        Date(timeIntervalSince1970:
            TimeInterval(startSeconds) + TimeInterval(startMicroseconds) / 1_000_000)
    }
}

/// Exact owner written into cross-build receipts. PID-only ownership is unsafe after PID reuse;
/// the boot id and per-helper session also prevent a receipt from another boot or another guard
/// connection from authorizing a restore.
struct ResourceGuardOwnershipIdentity: Codable, Equatable {
    let process: ResourceGuardProcessIdentity
    let bootID: String
    let session: String
}

/// Exact owner lookup is tri-state. Treating a transient lookup failure as either alive or dead
/// causes opposite global-state bugs: stealing a live receipt or retaining our flock forever.
enum ResourceGuardOwnerLiveness: Equatable {
    case alive
    case deadOrReused
    case unknown
}

/// Pure fail-closed gate for the helper-owned marker which retires one exact legacy App-Data inode.
/// A marker is not a wildcard tombstone: changed metadata or unknown owner identity makes the old
/// receipt authoritative again. A later legitimate System Settings choice does not: the marker was
/// written only after a restore proof, so the immutable App-Data inode stays retired thereafter.
enum ResourceGuardLegacyRetirementPolicy {
    static func mayWriteMarker(exactFingerprint: Bool, restoreVerified: Bool) -> Bool {
        exactFingerprint && restoreVerified
    }

    static func accepts(exactFingerprint: Bool,
                        ownerIsOurs: Bool,
                        ownerLiveness: ResourceGuardOwnerLiveness) -> Bool {
        guard exactFingerprint else { return false }
        return ownerIsOurs || ownerLiveness == .deadOrReused
    }
}

/// Pure journal-resume decision. An explicit `-2` repair is a one-shot request to restore the
/// macOS default, not a permanent policy: a later valid non-zero user choice wins and is recorded
/// truthfully instead of being overwritten on every retry.
enum ResourceGuardGlobeRepairResolution: Equatable {
    case applyTarget
    case alreadyMatches
    case preserveUserOverride(Int)
    case blocked
}

enum ResourceGuardGlobeRepairPolicy {
    static func resolve(live: Int?, target: Int) -> ResourceGuardGlobeRepairResolution {
        guard target == -2 || (1...3).contains(target) else { return .blocked }
        if live == 0 { return .applyTarget }
        if (target == -2 && live == nil) || live == target { return .alreadyMatches }
        if let live, (1...3).contains(live) { return .preserveUserOverride(live) }
        return .blocked
    }
}

/// Result of adopting an existing cross-build globe receipt under the helper's already-held
/// global flock. Unsupported data is deliberately distinct from "no receipt": it must remain on
/// disk and block mutations until a compatible build can understand it.
enum PersistentGlobeReceiptAdoption: Equatable {
    case none
    case adopted
    /// A durable helper repair journal exists. It is authority for safe-direction recovery, but
    /// READY/exit remain blocked until the shared cleanup path has completed it.
    case recovering
    /// Only the old GUI-provenance receipt exists and the helper is denied access to its bytes.
    /// It blocks READY while the watched parent lives, but it is not helper-owned cleanup work:
    /// after exact parent exit the helper must leave the inode/system value untouched and unlock so
    /// a later authenticated GLOBEFIX parent can perform the journaled migration.
    case protectedLegacy
    case ownedElsewhere
    case blocked
}

/// Result of the helper-owned acquire transaction. `active` means receipt+system mutation are both
/// durably complete; `noMutation` means the live system was already `.nothing` without a receipt;
/// the latter must never leave a capability or flock behind.
enum PersistentGlobeArmResult: Equatable {
    case active
    case noMutation
    case ownedElsewhere
    case blocked
}

/// The high-level globe transaction is kept as a tiny pure decision so the production branch that
/// sees a pre-existing `.nothing` cannot silently strand a helper lease again.
enum ResourceGuardGlobeReconcilePlan: Equatable {
    case take(previous: Int)
    case adopt(previous: Int)
    case noMutation

    static func make(currentIsNothing: Bool,
                     takePrevious: Int,
                     receiptPrevious: Int?) -> ResourceGuardGlobeReconcilePlan {
        if !currentIsNothing {
            return .take(previous: takePrevious)
        }
        if let previous = receiptPrevious { return .adopt(previous: previous) }
        return .noMutation
    }
}

/// Shared receipt and the live system value are authorities; bundle-local defaults are only a
/// cache/legacy migration hint and must never override either across Dev/Prod builds.
enum ResourceGuardGlobePreviousAuthority {
    static func forNewTake(systemRaw: Int?) -> Int { systemRaw ?? -2 }

    static func forRelease(sharedReceipt: Int?, pendingDurableClear: Int?) -> Int? {
        sharedReceipt ?? pendingDurableClear
    }
}

enum ResourceGuardProtocolIO {
    enum ReadResult {
        case frame(ResourceGuardFrame)
        case eof
        case invalid
    }

    static func write(_ frame: ResourceGuardFrame, to descriptor: Int32) -> Bool {
        guard let payload = try? JSONEncoder().encode(frame),
              !payload.isEmpty, payload.count <= ResourceGuardFrame.maximumPayloadBytes else {
            return false
        }
        var size = UInt32(payload.count).bigEndian
        let headerOK = withUnsafeBytes(of: &size) { writeAll($0, to: descriptor) }
        return headerOK && payload.withUnsafeBytes { writeAll($0, to: descriptor) }
    }

    static func read(from descriptor: Int32, timeout: TimeInterval? = nil) -> ReadResult {
        let deadline = timeout.map { ProcessInfo.processInfo.systemUptime + max($0, 0) }
        var size: UInt32 = 0
        let header = withUnsafeMutableBytes(of: &size) {
            readExactly($0, from: descriptor, deadline: deadline)
        }
        switch header {
        case .eof: return .eof
        case .failure: return .invalid
        case .success: break
        }
        let length = Int(UInt32(bigEndian: size))
        guard length > 0, length <= ResourceGuardFrame.maximumPayloadBytes else { return .invalid }
        var payload = Data(count: length)
        let body = payload.withUnsafeMutableBytes {
            readExactly($0, from: descriptor, deadline: deadline)
        }
        guard case .success = body,
              let frame = try? JSONDecoder().decode(ResourceGuardFrame.self, from: payload),
              frame.version == ResourceGuardFrame.version else { return .invalid }
        return .frame(frame)
    }

    static func waitUntilReadable(_ descriptor: Int32, timeout: TimeInterval) -> Bool {
        var item = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
        let milliseconds = Int32(max(1, min(timeout * 1_000, Double(Int32.max))))
        return Darwin.poll(&item, 1, milliseconds) > 0
    }

    private enum ExactRead { case success, eof, failure }

    private static func readExactly(_ bytes: UnsafeMutableRawBufferPointer,
                                    from descriptor: Int32,
                                    deadline: TimeInterval?) -> ExactRead {
        var offset = 0
        while offset < bytes.count {
            if let deadline {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0, waitUntilReadable(descriptor, timeout: remaining) else {
                    return .failure
                }
            }
            let count = Darwin.read(
                descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset
            )
            if count == 0 { return offset == 0 ? .eof : .failure }
            if count < 0 {
                if errno == EINTR { continue }
                return .failure
            }
            offset += count
        }
        return .success
    }

    private static func writeAll(_ bytes: UnsafeRawBufferPointer,
                                 to descriptor: Int32) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(
                descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset
            )
            if count < 0 {
                if errno == EINTR { continue }
                return false
            }
            guard count > 0 else { return false }
            offset += count
        }
        return true
    }
}

/// The pipe is private, but frames are still authenticated with a per-spawn nonce and must be
/// strictly ordered. Keeping this reducer pure lets us fuzz malformed/replayed requests without
/// launching the helper or touching system state.
struct ResourceGuardRequestValidator {
    let session: String
    private(set) var nextRequestID: UInt64 = 1

    mutating func accepts(_ frame: ResourceGuardFrame) -> Bool {
        guard !session.isEmpty,
              frame.version == ResourceGuardFrame.version,
              frame.session == session,
              frame.requestID == nextRequestID else { return false }
        nextRequestID &+= 1
        return nextRequestID != 0
    }
}

/// A crash report is eligible only when it names the exact watched process and was written in a
/// narrow window around that process' death. This prevents an older Keyboop crash (including one
/// from another build) from turning a later Force Quit into an unwanted relaunch.
enum ResourceGuardCrashReportPolicy {
    static let secondsBeforeDeath: TimeInterval = 4
    static let secondsAfterDeath: TimeInterval = 10

    static func matches(reportPID: pid_t?,
                        reportDate: Date,
                        parentPID: pid_t,
                        parentStartedAt: Date,
                        parentDiedAt: Date) -> Bool {
        guard reportPID == parentPID else { return false }
        let lower = max(parentStartedAt.timeIntervalSince1970 - 1,
                        parentDiedAt.timeIntervalSince1970 - secondsBeforeDeath)
        let upper = parentDiedAt.timeIntervalSince1970 + secondsAfterDeath
        let stamp = reportDate.timeIntervalSince1970
        return stamp >= lower && stamp <= upper
    }
}

/// Pure capability reducer used by protocol tests and mirrored by the helper server.
struct ResourceGuardCapabilityState: Equatable {
    private(set) var capabilities: ResourceGuardCapability = []

    mutating func acquired(_ capability: ResourceGuardCapability) {
        capabilities.insert(capability)
    }

    mutating func released(_ capability: ResourceGuardCapability, cleanupSucceeded: Bool) {
        if cleanupSucceeded { capabilities.remove(capability) }
    }

    var isEmpty: Bool { capabilities.isEmpty }

    var crashCleanupOrder: [ResourceGuardCapability] {
        var result: [ResourceGuardCapability] = []
        if capabilities.contains(.slap) { result.append(.slap) }
        if capabilities.contains(.globe) { result.append(.globe) }
        return result
    }

    mutating func apply(_ message: ResourceGuardMessage,
                        cleanupSucceeded: Bool = true) {
        switch message {
        case .addGlobe: acquired(.globe)
        case .dropGlobe: released(.globe, cleanupSucceeded: cleanupSucceeded)
        case .acquireSlap: acquired(.slap)
        case .releaseSlap: released(.slap, cleanupSucceeded: cleanupSucceeded)
        case .hello, .ready, .confirmSlapGrowth, .repairLegacyGlobe,
             .recoverSlap, .normalExit,
             .ok, .busy, .idleChanged, .staleState, .failed:
            break
        }
    }
}
