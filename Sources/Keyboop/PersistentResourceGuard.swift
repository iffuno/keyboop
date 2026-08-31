import Foundation
import Darwin
import IOKit

// MARK: - Injectable system boundary

/// The server is intentionally written against this narrow boundary. Production delegates to the
/// exact Apple SPU driver and GlobeKey; the subprocess harness injects a file-backed fake into the
/// very same state machine, so it can exercise crashes and partial command failures without ever
/// writing to live hardware.
protocol PersistentResourceGuardBackend: AnyObject {
    func armGlobe() -> PersistentGlobeArmResult
    func restoreGlobe() -> Bool
    func repairLegacyGlobe(previous: Int) -> Bool
    func hasGlobeReceipt() -> Bool
    func adoptGlobeReceipt() -> PersistentGlobeReceiptAdoption
    func copyAccelerometerDriver() -> io_service_t?
    func deviceIdentity(_ driver: io_registry_entry_t) -> UInt64?
    func proveIdle(_ driver: io_registry_entry_t) -> SlapSPUEventCounterCursor?
    func activate(_ driver: io_registry_entry_t) -> Bool
    func waitForGrowth(_ driver: io_registry_entry_t,
                       after baseline: SlapSPUEventCounterCursor) -> Bool
    func shutDownAndProve(_ driver: io_registry_entry_t) -> Bool
    func releaseDriver(_ driver: io_object_t)
    func allowReceiptWrite() -> Bool
    func allowReceiptRemoval() -> Bool
    func allowReceiptDirectoryScan() -> Bool
}

#if !RESOURCE_GUARD_TESTING
private final class LivePersistentResourceGuardBackend: PersistentResourceGuardBackend {
    func armGlobe() -> PersistentGlobeArmResult { GlobeKey.armFromPersistentHelper() }
    func restoreGlobe() -> Bool { GlobeKey.release() }
    func repairLegacyGlobe(previous: Int) -> Bool {
        GlobeKey.repairLegacyFromPersistentHelper(previous: previous)
    }
    func hasGlobeReceipt() -> Bool { GlobeKey.hasGuardReceipt }
    func adoptGlobeReceipt() -> PersistentGlobeReceiptAdoption {
        GlobeKey.adoptReceiptForPersistentHelper()
    }
    func copyAccelerometerDriver() -> io_service_t? {
        SlapSPUDriver.copyExactAccelerometerDriver()
    }
    func deviceIdentity(_ driver: io_registry_entry_t) -> UInt64? {
        SlapSPUDriver.serviceIdentity(driver)
    }
    func proveIdle(_ driver: io_registry_entry_t) -> SlapSPUEventCounterCursor? {
        SlapSPUDriver.proveIdle(driver)
    }
    func activate(_ driver: io_registry_entry_t) -> Bool {
        SlapSPUDriver.activate(driver)
    }
    func waitForGrowth(_ driver: io_registry_entry_t,
                       after baseline: SlapSPUEventCounterCursor) -> Bool {
        SlapSPUDriver.waitForEventGrowth(driver, after: baseline)
    }
    func shutDownAndProve(_ driver: io_registry_entry_t) -> Bool {
        SlapSPUDriver.shutDownAndProve(driver, attempts: 1)
    }
    func releaseDriver(_ driver: io_object_t) { SlapSPUDriver.release(driver) }
    func allowReceiptWrite() -> Bool { true }
    func allowReceiptRemoval() -> Bool { true }
    func allowReceiptDirectoryScan() -> Bool { true }
}
#endif

private enum PersistentGuardProcessLookup {
    case identity(ResourceGuardProcessIdentity)
    case goneOrReused
    case unknown
}

private func persistentGuardProcessLookup(_ pid: pid_t,
                                          expected: ResourceGuardProcessIdentity? = nil)
    -> PersistentGuardProcessLookup {
    guard pid > 1 else { return .goneOrReused }
    var info = proc_bsdinfo()
    let size = proc_pidinfo(
        pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)
    )
    if size == Int32(MemoryLayout<proc_bsdinfo>.size) {
        let identity = ResourceGuardProcessIdentity(
            pid: pid,
            startSeconds: UInt64(info.pbi_start_tvsec),
            startMicroseconds: UInt64(info.pbi_start_tvusec)
        )
        if let expected, identity != expected { return .goneOrReused }
        return .identity(identity)
    }
    if kill(pid, 0) == 0 || errno == EPERM { return .unknown }
    return errno == ESRCH ? .goneOrReused : .unknown
}

private func persistentGuardProcessIdentity(_ pid: pid_t) -> ResourceGuardProcessIdentity? {
    guard case let .identity(identity) = persistentGuardProcessLookup(pid) else { return nil }
    return identity
}

private func persistentGuardParentPID(_ pid: pid_t) -> pid_t? {
    var info = proc_bsdinfo()
    let size = proc_pidinfo(
        pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)
    )
    return size == Int32(MemoryLayout<proc_bsdinfo>.size) ? pid_t(info.pbi_ppid) : nil
}

private func persistentGuardExecutablePath(_ pid: pid_t) -> String? {
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
    return String(cString: path)
}

private func persistentGuardBootSessionID() -> String? {
#if RESOURCE_GUARD_TESTING
    if ProcessInfo.processInfo.environment["KEYBOOP_RG_TEST_BOOT_UNAVAILABLE"] == "1" {
        return nil
    }
    if let value = ProcessInfo.processInfo.environment["KEYBOOP_RG_TEST_BOOT_ID"] {
        return value
    }
#endif
    var size = 0
    guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else {
        return nil
    }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return nil }
    return String(cString: bytes)
}

@discardableResult
private func persistentGuardSetCloseOnExec(_ descriptor: Int32) -> Bool {
    let flags = fcntl(descriptor, F_GETFD)
    return flags >= 0 && fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0
}

private func persistentGuardArguments(_ pid: pid_t) -> [String]? {
    var mib = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
          size > MemoryLayout<Int32>.size, size <= 1_048_576 else { return nil }
    var bytes = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, u_int(mib.count), &bytes, &size, nil, 0) == 0 else { return nil }
    let argc: Int32 = bytes.withUnsafeBytes { raw in
        raw.loadUnaligned(as: Int32.self)
    }
    guard argc > 0, argc < 256 else { return nil }
    var offset = MemoryLayout<Int32>.size
    while offset < size, bytes[offset] != 0 { offset += 1 } // executable path
    while offset < size, bytes[offset] == 0 { offset += 1 }
    var result: [String] = []
    for _ in 0..<argc {
        guard offset < size else { return nil }
        let start = offset
        while offset < size, bytes[offset] != 0 { offset += 1 }
        guard offset > start,
              let value = String(bytes: bytes[start..<offset], encoding: .utf8) else { return nil }
        result.append(value)
        while offset < size, bytes[offset] == 0 { offset += 1 }
    }
    return result
}

private func persistentGuardWaitForExit(_ identity: ResourceGuardProcessIdentity,
                                        timeout: TimeInterval) -> Bool {
    switch persistentGuardProcessLookup(identity.pid, expected: identity) {
    case .goneOrReused: return true
    case .identity, .unknown: break
    }
    let queue = kqueue()
    guard queue >= 0 else { return false }
    defer { close(queue) }
    var change = kevent(
        ident: UInt(identity.pid), filter: Int16(EVFILT_PROC),
        flags: UInt16(EV_ADD | EV_ONESHOT), fflags: UInt32(NOTE_EXIT), data: 0, udata: nil
    )
    guard kevent(queue, &change, 1, nil, 0, nil) == 0 else {
        if case .goneOrReused = persistentGuardProcessLookup(
            identity.pid, expected: identity
        ) { return true }
        return false
    }
    var event = kevent()
    var interval = timespec(
        tv_sec: Int(timeout.rounded(.down)),
        tv_nsec: Int((timeout - timeout.rounded(.down)) * 1_000_000_000)
    )
    let count = kevent(queue, nil, 0, &event, 1, &interval)
    return count == 1 && event.filter == Int16(EVFILT_PROC)
        && (event.fflags & UInt32(NOTE_EXIT)) != 0
}

private struct PersistentGuardHelperMetadata: Codable {
    let version: Int
    let helper: ResourceGuardProcessIdentity
    let parent: ResourceGuardProcessIdentity
    let bootID: String
    let session: String
}

/// One helper starts after the cross-build single-instance lock and stays asleep for the complete
/// lifetime of that app. Resource leases are independent, but dropping the final lease never exits
/// the helper; only a clean `normalExit` or the exact watched parent's NOTE_EXIT can do that.
enum PersistentResourceGuard {
    static let flag = "--resource-guard-v3"
    private static let lock = NSRecursiveLock()
    private static var connection: PersistentGuardConnection?
    private static var shouldRun = false
    private static var wantsGlobe = false
    private static var pendingLegacyGlobeRepair: Int?
    private static var reconnectScheduled = false
    private static var reconnectDelay: TimeInterval = 0.15

#if RESOURCE_GUARD_TESTING
    static var testingBackendFactory: (() -> PersistentResourceGuardBackend)?
#endif

    static var isHelperProcess: Bool {
        CommandLine.arguments.contains(flag)
    }

    private static var supportDirectory: URL {
#if RESOURCE_GUARD_TESTING
        if let path = ProcessInfo.processInfo.environment["KEYBOOP_RESOURCE_GUARD_TEST_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
#endif
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Keyboop", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static var metadataURL: URL {
        let bundleID = Bundle.main.bundleIdentifier ?? "ru.keyboop.app"
        return supportDirectory.appendingPathComponent("resource-guard-v3-\(bundleID).json")
    }

    @discardableResult
    static func start() -> Bool {
        guard !isHelperProcess else { return false }
        lock.lock(); defer { lock.unlock() }
        shouldRun = true
        guard let current = connectionLocked() else {
            scheduleReconnectLocked()
            return false
        }
        guard !current.transportBroken else { return false }
        if let previous = pendingLegacyGlobeRepair {
            let repair = current.exchange(
                .repairLegacyGlobe, value: encodeGlobePrevious(previous)
            )
            if repair == .ok { pendingLegacyGlobeRepair = nil }
            else {
                if repair == nil, current.isExactlyAlive { current.transportBroken = true }
                scheduleReconnectLocked()
                return false
            }
        }
        if current.isReady { return true }
        let response = current.exchange(.hello)
        current.isReady = response == .ready
        if response == .staleState {
            kbLog("resource-сторож: завершает recovery системных ресурсов (🌐/BMI282)")
            scheduleReconnectLocked()
        } else if response == nil {
            if current.isExactlyAlive {
                // A timed-out response may still arrive. Reusing this framed stream would pair it
                // with the next request ID, so detach permanently and let this exact helper wait
                // for NOTE_EXIT; never spawn a duplicate while it remains alive.
                current.transportBroken = true
            } else {
                invalidateLocked(current)
            }
        }
        return current.isReady
    }

    static func ensureGlobe(legacyPID: pid_t?, previous: Int? = nil) -> Bool {
        guard !isHelperProcess else { return false }
        lock.lock(); defer { lock.unlock() }
        shouldRun = true
        wantsGlobe = true
        guard start() else { return false }
        connection?.rememberLegacy(pid: legacyPID)
        // `previous` is retained only as a source-compatible label for older call sites. The GUI
        // never supplies authority: the helper reads the live system value inside its flock.
        let response = sendLocked(.addGlobe)
        if response != .ok {
            wantsGlobe = false
            kbLog("resource-сторож: не принял аренду 🌐 — системную роль не меняю")
        }
        return response == .ok
    }

    static func globeReceiptOwner() -> ResourceGuardOwnershipIdentity? {
        if isHelperProcess {
            let arguments = CommandLine.arguments
            guard let index = arguments.firstIndex(of: flag), index + 4 < arguments.count,
                  let globeIndex = arguments.firstIndex(of: GlobeGuard.flag),
                  globeIndex + 1 < arguments.count,
                  let parentPID = pid_t(arguments[globeIndex + 1]),
                  let seconds = UInt64(arguments[index + 2]),
                  let micros = UInt64(arguments[index + 3]) else { return nil }
            return ResourceGuardOwnershipIdentity(
                process: ResourceGuardProcessIdentity(
                    pid: parentPID, startSeconds: seconds, startMicroseconds: micros
                ),
                bootID: arguments[index + 4], session: arguments[index + 1]
            )
        }
        lock.lock(); defer { lock.unlock() }
        guard let current = connection, current.isReady, current.isExactlyAlive else { return nil }
        return ResourceGuardOwnershipIdentity(
            process: current.parentIdentity, bootID: current.bootID, session: current.session
        )
    }

    static func globeHelperIdentity() -> ResourceGuardProcessIdentity? {
        if isHelperProcess { return persistentGuardProcessIdentity(getpid()) }
        lock.lock(); defer { lock.unlock() }
        guard let current = connection, current.isExactlyAlive else { return nil }
        return current.helperIdentity
    }

    static func helperMayRestoreGlobe(ownedBy owner: ResourceGuardOwnershipIdentity) -> Bool {
        guard isHelperProcess,
              let index = CommandLine.arguments.firstIndex(of: flag),
              index + 4 < CommandLine.arguments.count,
              let globeIndex = CommandLine.arguments.firstIndex(of: GlobeGuard.flag),
              globeIndex + 1 < CommandLine.arguments.count,
              let watchedParentPID = pid_t(CommandLine.arguments[globeIndex + 1]),
              let seconds = UInt64(CommandLine.arguments[index + 2]),
              let micros = UInt64(CommandLine.arguments[index + 3]) else { return false }
        let expected = ResourceGuardProcessIdentity(
            pid: watchedParentPID, startSeconds: seconds, startMicroseconds: micros
        )
        // A replacement helper for the same exact still-live parent legitimately has a new
        // session nonce. The receipt keeps the creating session for audit, while authority is the
        // exact parent birth identity + boot and the held cross-build globe flock.
        return owner.process == expected && owner.bootID == CommandLine.arguments[index + 4]
    }

    static func helperWatchesProcess(_ pid: pid_t) -> Bool {
        guard isHelperProcess,
              let index = CommandLine.arguments.firstIndex(of: GlobeGuard.flag),
              index + 1 < CommandLine.arguments.count,
              let watched = pid_t(CommandLine.arguments[index + 1]) else { return false }
        return watched == pid
    }

    static func exactOwnerLiveness(_ owner: ResourceGuardOwnershipIdentity)
        -> ResourceGuardOwnerLiveness {
        guard let currentBoot = persistentGuardBootSessionID() else {
            // A transient sysctl failure is not authority to overwrite another build's receipt.
            return .unknown
        }
        guard currentBoot == owner.bootID else { return .deadOrReused }
        switch persistentGuardProcessLookup(owner.process.pid, expected: owner.process) {
        case .identity: return .alive
        case .goneOrReused: return .deadOrReused
        case .unknown: return .unknown
        }
    }

    static func ownerIsExactlyAlive(_ owner: ResourceGuardOwnershipIdentity) -> Bool {
        // Compatibility wrapper for conservative callers: only exact dead/reused is false.
        exactOwnerLiveness(owner) != .deadOrReused
    }

    static func retryGlobeReconcile() {
        guard !isHelperProcess else { return }
        lock.lock()
        reconnectDelay = min(reconnectDelay, 0.20)
        scheduleReconnectLocked()
        lock.unlock()
    }

    /// Runs after the caller has acquired Keyboop's cross-build singleton and before ordinary
    /// helper startup. The GUI may perform only the safe-direction readable-legacy restore; the
    /// helper owns retirement/unreadable GLOBEFIX under the global globe flock.
    @discardableResult
    static func prepareLegacyGlobeBeforeStart(explicitRepair: Bool) -> Bool {
        guard !isHelperProcess else { return false }
        let plan: GlobeLegacyMigrationPlan
        switch persistentGuardAcquireLock(PersistentGuardPaths.globeLock) {
        case let .acquired(fd):
            plan = GlobeKey.prepareLegacyMigration(explicitRepair: explicitRepair)
            persistentGuardUnlock(fd)
        case .busy:
            kbLog("globe migration: общий lock занят живым/зависшим helper — ничего не трогаю")
            return false
        case .failed:
            kbLog("globe migration: не открыл общий lock — fail closed")
            return false
        }
        switch plan {
        case .none:
            return true
        case let .blocked(reason):
            kbLog("globe migration: blocked (\(reason))")
            return false
        case let .repair(previous):
            lock.lock()
            shouldRun = true
            pendingLegacyGlobeRepair = previous
            let deadline = ProcessInfo.processInfo.systemUptime + (explicitRepair ? 20.0 : 4.0)
            var succeeded = false
            repeat {
                guard let current = connectionLocked(), !current.transportBroken else { break }
                let response = current.exchange(
                    .repairLegacyGlobe, value: encodeGlobePrevious(previous)
                )
                if response == .ok {
                    pendingLegacyGlobeRepair = nil
                    succeeded = true
                    break
                }
                if response == nil, current.isExactlyAlive {
                    current.transportBroken = true
                    break
                }
                if ProcessInfo.processInfo.systemUptime < deadline {
                    lock.unlock()
                    Thread.sleep(forTimeInterval: 0.12)
                    lock.lock()
                }
            } while ProcessInfo.processInfo.systemUptime < deadline
            if !succeeded { scheduleReconnectLocked() }
            lock.unlock()
            kbLog(succeeded
                ? "globe migration: helper подтвердил restore+retire"
                : "globe migration: helper продолжает retry; запуск fail closed")
            return succeeded
        }
    }

    @discardableResult
    static func repairGlobeSystem(previous: Int) -> Bool {
        guard !isHelperProcess else { return false }
        lock.lock(); defer { lock.unlock() }
        shouldRun = true
        pendingLegacyGlobeRepair = previous
        guard let current = connectionLocked(), !current.transportBroken else {
            scheduleReconnectLocked()
            return false
        }
        let response = current.exchange(
            .repairLegacyGlobe, value: encodeGlobePrevious(previous)
        )
        if response == .ok { pendingLegacyGlobeRepair = nil }
        else { scheduleReconnectLocked() }
        return response == .ok
    }

    @discardableResult
    static func dropGlobe(repairPrevious: Int? = nil) -> Bool {
        guard !isHelperProcess else { return false }
        lock.lock(); defer { lock.unlock() }
        wantsGlobe = false
        shouldRun = true
        // Absence of a client connection is not proof that no helper-owned receipt/global state
        // exists. Spawn/recover and require an authenticated ACK instead of falsely reporting done.
        guard start() else {
            scheduleReconnectLocked()
            return false
        }
        let response = sendLocked(.dropGlobe)
        if response != .ok {
            kbLog("resource-сторож: не подтвердил снятие аренды 🌐")
            scheduleReconnectLocked()
        }
        return response == .ok
    }

    static func acquireSlap() -> Bool {
        guard !isHelperProcess else { return false }
        lock.lock(); defer { lock.unlock() }
        guard start() else { return false }
        let response = sendLocked(.acquireSlap)
        switch response {
        case .ok: return true
        case .busy: kbLog("шлепок: датчик занят другой сборкой Keyboop")
        case .idleChanged: kbLog("шлепок: обнаружен уже активный поток — не вмешиваюсь")
        case .staleState: kbLog("шлепок: сторож продолжает безопасную остановку старого потока")
        default: kbLog("шлепок: сторож не смог включить датчик")
        }
        return false
    }

    static func confirmSlapGrowth() -> Bool {
        guard !isHelperProcess else { return false }
        lock.lock(); defer { lock.unlock() }
        return sendLocked(.confirmSlapGrowth) == .ok
    }

    @discardableResult
    static func releaseSlap() -> Bool {
        guard !isHelperProcess else { return false }
        lock.lock(); defer { lock.unlock() }
        let response = sendLocked(.releaseSlap)
        if response != .ok {
            kbLog("шлепок: OFF ещё не доказан; сторож удерживает lock/receipt и повторяет")
        }
        return response == .ok
    }

    static func finishNormally() {
        guard !isHelperProcess else { return }
        lock.lock(); defer { lock.unlock() }
        wantsGlobe = false
        reconnectScheduled = false
        reconnectDelay = 0.15
        // A helper may have died just before quit. Make a bounded synchronous effort to spawn its
        // replacement so receipt-first recovery is not deferred to the next app launch.
        var current = connection
        if current == nil || current?.isExactlyAlive == false {
            for attempt in 0..<3 where current == nil || current?.isExactlyAlive == false {
                current = connectionLocked()
                if current == nil, attempt < 2 { Thread.sleep(forTimeInterval: 0.08) }
            }
        }
        shouldRun = false
        guard let current else { return }
        if !current.isReady, !current.transportBroken {
            let response = current.exchange(.hello)
            current.isReady = response == .ready
            if response == nil, current.isExactlyAlive {
                // A late hello response would desynchronise the next request. On termination the
                // exact helper can safely wait for NOTE_EXIT instead of reusing this stream.
                current.transportBroken = true
            }
        }
        if !current.transportBroken {
            let response = current.exchange(.normalExit)
            if response == nil, current.isExactlyAlive { current.transportBroken = true }
        }
        current.close()
        connection = nil
        // The helper removes metadata only after every OFF/restore proof succeeds. In particular,
        // a failed OFF keeps running past the parent's exit with its global lock and receipt.
    }

#if RESOURCE_GUARD_TESTING
    static var testHelperPID: pid_t? {
        lock.lock(); defer { lock.unlock() }
        return connection?.process.processIdentifier
    }
    static var testDescriptorsAreCloseOnExec: Bool {
        lock.lock(); defer { lock.unlock() }
        return connection?.descriptorsAreCloseOnExec ?? false
    }
    static func testBreakIPC() {
        lock.lock(); connection?.breakTransportForTest(); lock.unlock()
    }
    static func testBreakIPCWithPartialFrame() {
        lock.lock(); connection?.breakTransportWithPartialFrameForTest(); lock.unlock()
    }
    static func testBreakIPCWithBadFrame() {
        lock.lock(); connection?.breakTransportWithBadFrameForTest(); lock.unlock()
    }
    static func testBootLookupFailureIsConservative() -> Bool {
        guard let identity = persistentGuardProcessIdentity(getpid()) else { return false }
        setenv("KEYBOOP_RG_TEST_BOOT_UNAVAILABLE", "1", 1)
        defer { unsetenv("KEYBOOP_RG_TEST_BOOT_UNAVAILABLE") }
        return ownerIsExactlyAlive(ResourceGuardOwnershipIdentity(
            process: identity, bootID: "test-boot", session: "fixture"
        ))
    }
#endif

    private static func encodeGlobePrevious(_ previous: Int?) -> UInt64? {
        previous.map { UInt64(bitPattern: Int64($0)) }
    }

    private static func sendLocked(_ message: ResourceGuardMessage,
                                   value: UInt64? = nil) -> ResourceGuardMessage? {
        guard let current = connectionLocked(), current.isReady, !current.transportBroken else {
            return nil
        }
        guard let response = current.exchange(message, value: value) else {
            if current.isExactlyAlive {
                // EOF/timeout while the exact parent is alive is not a crash signal. Keep the
                // original helper and its leases; it will act only on verified NOTE_EXIT.
                current.transportBroken = true
            } else {
                invalidateLocked(current)
            }
            return nil
        }
        if response == .ok, message == .addGlobe { current.retireLegacyIfNeeded() }
        return response
    }

    private static func connectionLocked() -> PersistentGuardConnection? {
        if let current = connection, current.isExactlyAlive { return current }
        if let current = connection { invalidateLocked(current) }
        guard let created = PersistentGuardConnection.spawn(
            executable: Bundle.main.executableURL,
            parentPID: ProcessInfo.processInfo.processIdentifier
        ) else {
            kbLog("resource-сторож: не запустился")
            return nil
        }
        connection = created
        writeMetadata(created)
        kbLog("resource-сторож: запущен (pid \(created.process.processIdentifier))")
        return created
    }

    private static func invalidateLocked(_ current: PersistentGuardConnection) {
        guard connection === current else { return }
        current.close()
        connection = nil
        scheduleReconnectLocked()
    }

    fileprivate static func helperExited(session: String) {
        lock.lock()
        if let current = connection, current.session == session {
            current.close()
            connection = nil
            scheduleReconnectLocked()
        }
        lock.unlock()
    }

    private static func scheduleReconnectLocked() {
        guard shouldRun, !reconnectScheduled else { return }
        reconnectScheduled = true
        let delay = reconnectDelay
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            var replayGlobe = false
            lock.lock()
            reconnectScheduled = false
            guard shouldRun else { lock.unlock(); return }
            guard let current = connectionLocked() else {
                reconnectDelay = min(max(reconnectDelay * 1.8, 0.25), 5.0)
                scheduleReconnectLocked()
                lock.unlock()
                return
            }
            // Never duplicate a live helper merely because its private transport detached.
            guard !current.transportBroken else { lock.unlock(); return }
            if let previous = pendingLegacyGlobeRepair {
                let repair = current.exchange(
                    .repairLegacyGlobe, value: encodeGlobePrevious(previous)
                )
                if repair == .ok { pendingLegacyGlobeRepair = nil }
                else {
                    if repair == nil, current.isExactlyAlive { current.transportBroken = true }
                    reconnectDelay = min(max(reconnectDelay * 1.8, 0.25), 5.0)
                    scheduleReconnectLocked()
                    lock.unlock()
                    return
                }
            }
            if !current.isReady {
                let response = current.exchange(.hello)
                current.isReady = response == .ready
                if response == nil {
                    if current.isExactlyAlive { current.transportBroken = true }
                    else { invalidateLocked(current) }
                    lock.unlock()
                    return
                }
            }
            if current.isReady {
                reconnectDelay = 0.15
                // Re-run the complete high-level transaction: a bare addGlobe would acquire the
                // flock but skip receipt adoption/take/restore after delayed READY or replacement.
                replayGlobe = true
            } else {
                reconnectDelay = min(max(reconnectDelay * 1.8, 0.25), 5.0)
                scheduleReconnectLocked()
            }
            lock.unlock()
            if replayGlobe {
                DispatchQueue.main.async { GlobeKey.reconcile() }
            }
        }
    }

    private static func writeMetadata(_ connection: PersistentGuardConnection) {
        guard let data = try? JSONEncoder().encode(PersistentGuardHelperMetadata(
                version: 3, helper: connection.helperIdentity, parent: connection.parentIdentity,
                bootID: connection.bootID, session: connection.session
              )) else { return }
        try? data.write(to: metadataURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        _ = chmod(metadataURL.path, mode_t(0o600))
    }

    static func runIfRequested(parentPID: pid_t) -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: flag) else { return false }
        guard index + 4 < args.count,
              let seconds = UInt64(args[index + 2]),
              let micros = UInt64(args[index + 3]) else { return true }
        let session = args[index + 1]
        let expectedParent = ResourceGuardProcessIdentity(
            pid: parentPID, startSeconds: seconds, startMicroseconds: micros
        )
        let bootID = args[index + 4]
        guard !session.isEmpty, parentPID > 1, getppid() == parentPID,
              persistentGuardProcessIdentity(parentPID) == expectedParent,
              persistentGuardBootSessionID() == bootID,
              let helperIdentity = persistentGuardProcessIdentity(getpid()) else { return true }

        // A replacement helper may be spawned after AppDelegate has installed SIG_IGN. Never
        // inherit that policy accidentally. v3 deliberately ignores ordinary termination signals:
        // it exits through authenticated IPC or exact NOTE_EXIT, so SIGTERM cannot strand SPU ON.
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)
        guard persistentGuardSetCloseOnExec(STDIN_FILENO),
              persistentGuardSetCloseOnExec(STDOUT_FILENO),
              let watcher = PersistentGuardParentWatcher(identity: expectedParent) else { return true }
        _ = fcntl(STDOUT_FILENO, F_SETNOSIGPIPE, 1)

#if RESOURCE_GUARD_TESTING
        guard let backend = testingBackendFactory?() else { return true }
#else
        let backend: PersistentResourceGuardBackend = LivePersistentResourceGuardBackend()
#endif
        PersistentGuardServer(
            parentIdentity: expectedParent, helperIdentity: helperIdentity,
            bootID: bootID, session: session,
            watcher: watcher, backend: backend
        ).run()
        removeMetadataIfOwned(session: session)
        Thread.sleep(forTimeInterval: 0.2)
        return true
    }

    /// Rolling-update bridge for an old parent which still spawns `--globe-guard <pid>`. It uses the
    /// same exact watcher and cross-build flock as v3; the former unguarded PID-only fallback could
    /// restore another live build's keyboard role after PID reuse.
    static func runLegacyGlobeIfRequested(parentPID: pid_t) -> Bool {
        let arguments = CommandLine.arguments
        guard arguments.contains(GlobeGuard.flag), !arguments.contains(flag),
              !arguments.contains("--resource-guard-v2") else { return false }
        guard parentPID > 1, getppid() == parentPID else {
            kbLog("legacy globe bridge: parent PID/PPID authorization failed"); return true
        }
        guard let parent = persistentGuardProcessIdentity(parentPID) else {
            kbLog("legacy globe bridge: parent birth identity unavailable"); return true
        }
        guard let parentArguments = persistentGuardArguments(parentPID) else {
            kbLog("legacy globe bridge: parent argv unavailable"); return true
        }
        guard !parentArguments.contains(GlobeGuard.flag),
              !parentArguments.contains(flag),
              !parentArguments.contains("--resource-guard-v2") else {
            kbLog("legacy globe bridge: parent argv is another helper"); return true
        }
        let parentExecutable = persistentGuardExecutablePath(parentPID).map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
        }
        let helperExecutable = Bundle.main.executableURL?
            .resolvingSymlinksInPath().standardizedFileURL.path
        guard parentExecutable != nil, parentExecutable == helperExecutable else {
            kbLog("legacy globe bridge: parent executable mismatch"); return true
        }
        guard let bootID = persistentGuardBootSessionID() else {
            kbLog("legacy globe bridge: boot identity unavailable"); return true
        }
        guard let watcher = PersistentGuardParentWatcher(identity: parent) else {
            kbLog("legacy globe bridge: NOTE_EXIT registration failed"); return true
        }
        resetLegacySignalPolicy()
        let acquisition = persistentGuardAcquireLock(PersistentGuardPaths.globeLock)
        guard case let .acquired(lockFD) = acquisition else {
            kbLog(acquisition.isBusy
                ? "legacy globe bridge: global flock занят — receipt не трогаю"
                : "legacy globe bridge: global flock I/O failure — receipt не трогаю")
            return true
        }
        defer { persistentGuardUnlock(lockFD) }
        let startedAt = parent.startedAt
        while !watcher.consumeVerifiedExit() {
            var descriptor = pollfd(
                fd: watcher.descriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0
            )
            let result = Darwin.poll(&descriptor, 1, -1)
            if result < 0, errno != EINTR { return true }
        }
        let diedAt = Date()
        let cleanupDeadline = ProcessInfo.processInfo.systemUptime + 2.0
        var restored = false
        while ProcessInfo.processInfo.systemUptime < cleanupDeadline {
            if GlobeKey.releaseLegacyV1(watchedParent: parent, bootID: bootID) {
                restored = true
                break
            }
            Thread.sleep(forTimeInterval: 0.20)
        }
        if restored {
            GlobeGuard.handleCrash(
                parentPID: parentPID, livedSince: startedAt, diedAt: diedAt
            )
        } else {
            // An App-Data-protected v1 receipt can be unreadable to this child after its old parent
            // dies. Do not become another orphan lock-holder: preserve receipt+raw, release the flock
            // through `defer`, and let an explicit singleton GLOBEFIX parent journal the migration.
            kbLog("legacy globe bridge: restore не доказан; receipt/raw сохранены, flock отпускаю")
        }
        Thread.sleep(forTimeInterval: 0.2)
        return true
    }

    static func resetLegacySignalPolicy() {
        signal(SIGTERM, SIG_DFL)
        signal(SIGINT, SIG_DFL)
        signal(SIGHUP, SIG_DFL)
        signal(SIGPIPE, SIG_IGN)
    }

    private static func removeMetadataIfOwned(session: String) {
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(PersistentGuardHelperMetadata.self, from: data),
              metadata.session == session else { return }
        _ = unlink(metadataURL.path)
    }
}

// MARK: - Parent-side connection

private final class PersistentGuardConnection {
    let process: Process
    let session: String
    let parentIdentity: ResourceGuardProcessIdentity
    let bootID: String
    let executablePath: String
    let helperIdentity: ResourceGuardProcessIdentity
    var isReady = false
    var transportBroken = false

    private let requests: FileHandle
    private let responses: FileHandle
    private var nextRequestID: UInt64 = 1
    private var closed = false
    private var legacyPID: pid_t?
    private var legacyIdentity: ResourceGuardProcessIdentity?

    var isExactlyAlive: Bool {
        switch persistentGuardProcessLookup(helperIdentity.pid, expected: helperIdentity) {
        case .identity, .unknown:
            // A transient proc_pidinfo failure is not authority to abandon a live helper and spawn
            // a duplicate. The framed exchange/termination handler will resolve its real state.
            return true
        case .goneOrReused:
            return false
        }
    }

    private init(process: Process, session: String,
                 requests: FileHandle, responses: FileHandle,
                 parentIdentity: ResourceGuardProcessIdentity, bootID: String,
                 executablePath: String, helperIdentity: ResourceGuardProcessIdentity) {
        self.process = process
        self.session = session
        self.requests = requests
        self.responses = responses
        self.parentIdentity = parentIdentity
        self.bootID = bootID
        self.executablePath = executablePath
        self.helperIdentity = helperIdentity
    }

    static func spawn(executable: URL?, parentPID: pid_t) -> PersistentGuardConnection? {
        guard let executable,
              let parentIdentity = persistentGuardProcessIdentity(parentPID),
              let bootID = persistentGuardBootSessionID() else { return nil }
        let requestPipe = Pipe()
        let responsePipe = Pipe()
        let all = [requestPipe.fileHandleForReading, requestPipe.fileHandleForWriting,
                   responsePipe.fileHandleForReading, responsePipe.fileHandleForWriting]
        guard all.allSatisfy({ persistentGuardSetCloseOnExec($0.fileDescriptor) }) else {
            all.forEach { $0.closeFile() }
            return nil
        }
        let session = UUID().uuidString.lowercased()
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            GlobeGuard.flag, String(parentPID), PersistentResourceGuard.flag, session,
            String(parentIdentity.startSeconds), String(parentIdentity.startMicroseconds), bootID
        ]
        process.standardInput = requestPipe
        process.standardOutput = responsePipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in
            PersistentResourceGuard.helperExited(session: session)
        }
        do { try process.run() } catch {
            all.forEach { $0.closeFile() }
            return nil
        }
        requestPipe.fileHandleForReading.closeFile()
        responsePipe.fileHandleForWriting.closeFile()
        let writer = requestPipe.fileHandleForWriting
        let reader = responsePipe.fileHandleForReading
        guard persistentGuardSetCloseOnExec(writer.fileDescriptor),
              persistentGuardSetCloseOnExec(reader.fileDescriptor) else {
            writer.closeFile(); reader.closeFile()
            // Never signal a post-spawn PID whose exact birth identity was not established. The
            // child either fails its argv/parent gates or sees EOF after any receipt-first recovery
            // and waits for this parent's exact NOTE_EXIT without accepting new app requests.
            return nil
        }
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        var helper: ResourceGuardProcessIdentity?
        let identityDeadline = ProcessInfo.processInfo.systemUptime + 0.20
        repeat {
            helper = persistentGuardProcessIdentity(process.processIdentifier)
            if helper != nil { break }
            Thread.sleep(forTimeInterval: 0.01)
        } while ProcessInfo.processInfo.systemUptime < identityDeadline
        guard let helper else {
            writer.closeFile(); reader.closeFile()
            return nil
        }
        return PersistentGuardConnection(
            process: process, session: session, requests: writer, responses: reader,
            parentIdentity: parentIdentity, bootID: bootID, executablePath: executable.path,
            helperIdentity: helper
        )
    }

    func exchange(_ message: ResourceGuardMessage, value: UInt64? = nil) -> ResourceGuardMessage? {
        guard !closed, !transportBroken, isExactlyAlive, nextRequestID != 0 else { return nil }
        let requestID = nextRequestID
        nextRequestID &+= 1
        let frame = ResourceGuardFrame(
            requestID: requestID, session: session, message: message, value: value
        )
        guard ResourceGuardProtocolIO.write(frame, to: requests.fileDescriptor) else { return nil }
        let timeout: TimeInterval = message == .hello ? 3.0 : 3.5
        guard case let .frame(response) = ResourceGuardProtocolIO.read(
            from: responses.fileDescriptor, timeout: timeout
        ), response.session == session, response.requestID == requestID else { return nil }
        return response.message
    }

    func rememberLegacy(pid: pid_t?) {
        guard legacyPID == nil, let pid, pid > 1, pid != process.processIdentifier,
              let identity = persistentGuardProcessIdentity(pid),
              persistentGuardParentPID(pid) == parentIdentity.pid,
              persistentGuardExecutablePath(pid) == executablePath,
              isExactLegacyInvocation(pid) else { return }
        legacyPID = pid
        legacyIdentity = identity
    }

    func retireLegacyIfNeeded() {
        guard let pid = legacyPID, let identity = legacyIdentity else { return }
        legacyPID = nil
        legacyIdentity = nil
        guard persistentGuardProcessIdentity(pid) == identity,
              persistentGuardParentPID(pid) == parentIdentity.pid,
              persistentGuardExecutablePath(pid) == executablePath,
              isExactLegacyInvocation(pid) else { return }
        _ = kill(pid, SIGTERM)
        if !persistentGuardWaitForExit(identity, timeout: 0.8),
           persistentGuardProcessIdentity(pid) == identity,
           isExactLegacyInvocation(pid) {
            _ = kill(pid, SIGKILL)
            _ = persistentGuardWaitForExit(identity, timeout: 0.8)
        }
    }

    private func isExactLegacyInvocation(_ pid: pid_t) -> Bool {
        guard let args = persistentGuardArguments(pid), args.count == 3 else { return false }
        return args[0] == executablePath
            && args[1] == GlobeGuard.flag
            && args[2] == String(parentIdentity.pid)
    }

    func close() {
        guard !closed else { return }
        closed = true
        requests.closeFile()
        responses.closeFile()
    }

#if RESOURCE_GUARD_TESTING
    var descriptorsAreCloseOnExec: Bool {
        [requests.fileDescriptor, responses.fileDescriptor].allSatisfy {
            let flags = fcntl($0, F_GETFD)
            return flags >= 0 && (flags & FD_CLOEXEC) != 0
        }
    }
    func breakTransportForTest() {
        transportBroken = true
        requests.closeFile()
        responses.closeFile()
    }
    func breakTransportWithPartialFrameForTest() {
        guard !closed, !transportBroken else { return }
        var partial = UInt16(12).bigEndian
        _ = withUnsafeBytes(of: &partial) {
            Darwin.write(requests.fileDescriptor, $0.baseAddress, $0.count)
        }
        transportBroken = true
        requests.closeFile()
        responses.closeFile()
    }
    func breakTransportWithBadFrameForTest() {
        guard !closed, !transportBroken else { return }
        _ = ResourceGuardProtocolIO.write(ResourceGuardFrame(
            requestID: nextRequestID + 9, session: "wrong-session", message: .dropGlobe
        ), to: requests.fileDescriptor)
        transportBroken = true
        requests.closeFile()
        responses.closeFile()
    }
#endif

    deinit { close() }
}

// MARK: - Helper-side parent watcher

private final class PersistentGuardParentWatcher {
    let descriptor: Int32
    private let identity: ResourceGuardProcessIdentity
    private var alreadyExited: Bool

    init?(identity: ResourceGuardProcessIdentity) {
        self.identity = identity
        descriptor = kqueue()
        guard descriptor >= 0, persistentGuardSetCloseOnExec(descriptor) else {
            if descriptor >= 0 { close(descriptor) }
            return nil
        }
        switch persistentGuardProcessLookup(identity.pid, expected: identity) {
        case .identity:
            alreadyExited = false
        case .goneOrReused:
            alreadyExited = true
            return
        case .unknown:
            // A transient lookup failure before registration is not proof of death. Fail startup
            // closed; the app may retry a fresh helper without any global lease.
            close(descriptor)
            return nil
        }
        var change = kevent(
            ident: UInt(identity.pid), filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_CLEAR), fflags: UInt32(NOTE_EXIT), data: 0, udata: nil
        )
        if kevent(descriptor, &change, 1, nil, 0, nil) != 0 {
            switch persistentGuardProcessLookup(identity.pid, expected: identity) {
            case .goneOrReused:
                alreadyExited = true
            case .identity, .unknown:
                close(descriptor)
                return nil
            }
        } else {
            switch persistentGuardProcessLookup(identity.pid, expected: identity) {
            case .goneOrReused:
                // Exact loss after successful registration closes the narrow race: this kqueue
                // was registered while the expected process existed.
                alreadyExited = true
            case .identity, .unknown:
                break
            }
        }
    }

    func consumeVerifiedExit() -> Bool {
        if alreadyExited { return true }
        var event = kevent()
        var zero = timespec(tv_sec: 0, tv_nsec: 0)
        let count = kevent(descriptor, nil, 0, &event, 1, &zero)
        if count == 1, event.filter == Int16(EVFILT_PROC),
           (event.fflags & UInt32(NOTE_EXIT)) != 0 {
            alreadyExited = true
            return true
        }
        // After successful registration only NOTE_EXIT is authority. A transient proc_pidinfo
        // failure must never restore global state under a still-live parent.
        return false
    }

    deinit { close(descriptor) }
}

// MARK: - Durable global leases

private struct PersistentGuardReceiptPathScan {
    let urls: [URL]
    let isComplete: Bool
}

private enum PersistentGuardPaths {
    static var directory: URL {
#if RESOURCE_GUARD_TESTING
        if let path = ProcessInfo.processInfo.environment["KEYBOOP_RESOURCE_GUARD_TEST_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
#endif
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Keyboop", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static var globeLock: URL { directory.appendingPathComponent("resource-guard-globe.lock") }
    static var slapLock: URL { directory.appendingPathComponent("resource-guard-spu.lock") }
    static var slapReceipt: URL {
        directory.appendingPathComponent("resource-guard-spu-receipt-v3.json")
    }
    static var legacySlapReceipts: [URL] {
        [
            directory.appendingPathComponent("resource-guard-spu-receipt-v2.json"),
            directory.appendingPathComponent("resource-guard-spu-receipt.json"),
            directory.appendingPathComponent("slap-spu-receipt.json"),
        ]
    }
    static var knownSlapReceipts: [URL] { [slapReceipt] + legacySlapReceipts }
    static var slapReceiptScan: PersistentGuardReceiptPathScan {
        var urls = knownSlapReceipts
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )
        } catch {
            return PersistentGuardReceiptPathScan(urls: urls, isComplete: false)
        }
        urls.append(contentsOf: entries.filter {
            $0.lastPathComponent.hasPrefix("resource-guard-spu-receipt")
                && $0.pathExtension == "json"
        })
        var seen = Set<String>()
        return PersistentGuardReceiptPathScan(
            urls: urls.filter { seen.insert($0.standardizedFileURL.path).inserted },
            isComplete: true
        )
    }
}

private enum PersistentGuardLockAcquisition {
    case acquired(Int32)
    case busy
    case failed

    var isBusy: Bool {
        if case .busy = self { return true }
        return false
    }
}

private func persistentGuardAcquireLock(_ url: URL) -> PersistentGuardLockAcquisition {
#if RESOURCE_GUARD_TESTING
    let forcedFailure = PersistentGuardPaths.directory
        .appendingPathComponent("force-lock-open-failure-\(url.lastPathComponent)")
    if FileManager.default.fileExists(atPath: forcedFailure.path) { return .failed }
#endif
    let fd = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
    guard fd >= 0 else { return .failed }
    guard fchmod(fd, mode_t(0o600)) == 0 else {
        close(fd)
        return .failed
    }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
        let lockError = errno
        close(fd)
        return lockError == EWOULDBLOCK || lockError == EAGAIN ? .busy : .failed
    }
    return .acquired(fd)
}

private func persistentGuardUnlock(_ fd: Int32) {
    guard fd >= 0 else { return }
    _ = flock(fd, LOCK_UN)
    close(fd)
}

private func persistentGuardPathMayExist(_ url: URL) -> Bool {
    var info = stat()
    if lstat(url.path, &info) == 0 { return true }
    return errno != ENOENT
}

private struct PersistentSPUReceipt: Codable {
    static let version = 3
    let version: Int
    let bootID: String
    let deviceRegistryID: UInt64
    let helper: ResourceGuardProcessIdentity
    let parent: ResourceGuardProcessIdentity
    let session: String
    let createdAt: TimeInterval

    var isSemanticallyValid: Bool {
        version == Self.version
            && !bootID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && deviceRegistryID != 0
            && helper.pid > 1 && helper.startSeconds > 0
            && helper.startMicroseconds < 1_000_000
            && parent.pid > 1 && parent.startSeconds > 0
            && parent.startMicroseconds < 1_000_000
            && !session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && createdAt.isFinite && createdAt > 0
    }
}

private struct PersistentSPUReceiptFile {
    let url: URL
    let receipt: PersistentSPUReceipt?
    let declaredVersion: Int?
    let isJSONEnvelope: Bool
    let isRecognizedLegacy: Bool

    var isUnsupported: Bool {
        if let declaredVersion {
            return declaredVersion > PersistentSPUReceipt.version
                || (declaredVersion == PersistentSPUReceipt.version
                    && receipt?.isSemanticallyValid != true)
                || (declaredVersion < PersistentSPUReceipt.version && !isRecognizedLegacy)
        }
        return isJSONEnvelope || !isRecognizedLegacy
    }
}

private final class PersistentSPULease {
    let lockFD: Int32
    var driver: io_service_t?
    var deviceID: UInt64?
    var baseline: SlapSPUEventCounterCursor?
    var activationComplete = false
    var growthProven = false
    var cleanupPending = true
    var identityReceiptReady = false
    var stoppedProven = false

    init(lockFD: Int32, driver: io_service_t? = nil, deviceID: UInt64? = nil,
         baseline: SlapSPUEventCounterCursor? = nil) {
        self.lockFD = lockFD
        self.driver = driver
        self.deviceID = deviceID
        self.baseline = baseline
    }
}

// MARK: - Persistent server

private final class PersistentGuardServer {
    private let parentIdentity: ResourceGuardProcessIdentity
    private let helperIdentity: ResourceGuardProcessIdentity
    private let parentPID: pid_t
    private let bootID: String
    private let session: String
    private let watcher: PersistentGuardParentWatcher
    private let backend: PersistentResourceGuardBackend
    private var validator: ResourceGuardRequestValidator
    private var state = ResourceGuardCapabilityState()
    private var globeLockFD: Int32?
    private var globeCleanupPending = false
    private var startupGlobeBlocked = false
    private var globeOwnedElsewhere = false
    private var protectedLegacyOnly = false
    private var legacyRepairPrevious: Int?
    private var slapLease: PersistentSPULease?
    private var startupRecoveryBlocked = false
    private var transportDetached = false
    private var normalExitRequested = false
    private var parentExitedAt: Date?
    private var analyzeCrashAfterCleanup = false
    private var nextRetryAt: TimeInterval = 0
    private var retryDelay: TimeInterval = 0.10

    init(parentIdentity: ResourceGuardProcessIdentity,
         helperIdentity: ResourceGuardProcessIdentity,
         bootID: String,
         session: String,
         watcher: PersistentGuardParentWatcher,
         backend: PersistentResourceGuardBackend) {
        self.parentIdentity = parentIdentity
        self.helperIdentity = helperIdentity
        self.parentPID = parentIdentity.pid
        self.bootID = bootID
        self.session = session
        self.watcher = watcher
        self.backend = backend
        validator = ResourceGuardRequestValidator(session: session)
    }

    func run() {
        prepareGlobeRecoveryIfNeeded()
        prepareStartupRecoveryIfNeeded()
        while true {
            if watcher.consumeVerifiedExit(), parentExitedAt == nil {
                beginParentExit()
            }

            retryCleanupIfDue(force: false)
            if mayExitNow {
                finishCrashAnalysisIfNeeded()
                return
            }

            let timeout = cleanupNeedsRetry ? millisecondsUntilRetry : -1
            var descriptors = [
                pollfd(fd: watcher.descriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
            ]
            if !transportDetached, parentExitedAt == nil {
                descriptors.append(pollfd(
                    fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0
                ))
            }
            let result = descriptors.withUnsafeMutableBufferPointer { buffer in
                Darwin.poll(buffer.baseAddress, nfds_t(buffer.count), timeout)
            }
            if result < 0 {
                if errno == EINTR { continue }
                transportDetached = true
                continue
            }
            if result == 0 { continue }

            if descriptors[0].revents != 0 { continue } // consume NOTE_EXIT at top of loop
            guard descriptors.count > 1, descriptors[1].revents != 0 else { continue }
            switch ResourceGuardProtocolIO.read(from: STDIN_FILENO, timeout: 1.5) {
            case .eof, .invalid:
                // A broken private channel is not evidence that the exact watched process died.
                // Keep every lease untouched and wait on its already-registered NOTE_EXIT.
                transportDetached = true
            case let .frame(frame):
                guard validator.accepts(frame) else {
                    transportDetached = true
                    continue
                }
                let responseMessage = handle(frame)
                let response = ResourceGuardFrame(
                    requestID: frame.requestID, session: session, message: responseMessage
                )
                if !ResourceGuardProtocolIO.write(response, to: STDOUT_FILENO) {
                    transportDetached = true
                }
            }
        }
    }

    private var startupIsReady: Bool {
        !startupRecoveryBlocked && !startupGlobeBlocked
    }

    private var cleanupNeedsRetry: Bool {
        startupRecoveryBlocked || startupGlobeBlocked
            || slapLease?.cleanupPending == true || globeCleanupPending
            || legacyRepairPrevious != nil
    }

    /// An active healthy slap lease deliberately has a receipt, but that receipt is not a cleanup
    /// request. Only an explicitly pending lease, or a receipt discovered without an in-memory lease
    /// during startup/replacement, participates in SPU-before-globe teardown ordering.
    private var needsSlapCleanup: Bool {
        if let lease = slapLease { return lease.cleanupPending }
        return startupRecoveryBlocked || hasAnyReceipt
    }

    private var mayExitNow: Bool {
        guard normalExitRequested || parentExitedAt != nil else { return false }
        return !cleanupNeedsRetry
            && !state.capabilities.contains(.slap)
            && !state.capabilities.contains(.globe)
            && !hasAnyReceipt
            && slapLease == nil
            && globeLockFD == nil
            && !globeCleanupPending
            && legacyRepairPrevious == nil
    }

    private var millisecondsUntilRetry: Int32 {
        let remaining = max(nextRetryAt - ProcessInfo.processInfo.systemUptime, 0.01)
        return Int32(min(remaining * 1_000, 2_000))
    }

    private func decodeGlobePrevious(_ value: UInt64?) -> Int? {
        guard let value else { return nil }
        let signed = Int64(bitPattern: value)
        guard signed == -2 || (1...3).contains(signed) else { return nil }
        return Int(signed)
    }

    private func handle(_ frame: ResourceGuardFrame) -> ResourceGuardMessage {
        let message = frame.message
        if message == .hello {
            retryCleanupIfDue(force: true)
            return startupIsReady ? .ready : .staleState
        }
        guard startupIsReady || message == .releaseSlap || message == .recoverSlap
                || message == .repairLegacyGlobe || message == .normalExit else {
            return .staleState
        }

        switch message {
        case .addGlobe:
            prepareGlobeRecoveryIfNeeded()
            if state.capabilities.contains(.globe) {
                switch backend.armGlobe() {
                case .active:
                    return .ok
                case .noMutation:
                    releaseGlobeLockAndState()
                    return .ok
                case .ownedElsewhere:
                    analyzeCrashAfterCleanup = false
                    releaseGlobeLockAndState()
                    globeOwnedElsewhere = true
                    return .busy
                case .blocked:
                    globeCleanupPending = true
                    nextRetryAt = 0
                    return .staleState
                }
            }
            if startupGlobeBlocked { return .staleState }
            if globeOwnedElsewhere { return .busy }
            let acquisition = persistentGuardAcquireLock(PersistentGuardPaths.globeLock)
            guard case let .acquired(fd) = acquisition else {
                return acquisition.isBusy ? .busy : .failed
            }
            globeLockFD = fd
            switch backend.armGlobe() {
            case .active:
                state.acquired(.globe)
                return .ok
            case .noMutation:
                persistentGuardUnlock(fd)
                globeLockFD = nil
                return .ok
            case .ownedElsewhere:
                persistentGuardUnlock(fd)
                globeLockFD = nil
                globeOwnedElsewhere = true
                return .busy
            case .blocked:
                if backend.hasGlobeReceipt() {
                    state.acquired(.globe)
                    globeCleanupPending = true
                    nextRetryAt = 0
                    return .staleState
                }
                persistentGuardUnlock(fd)
                globeLockFD = nil
                return .failed
            }

        case .dropGlobe:
            prepareGlobeRecoveryIfNeeded()
            if globeOwnedElsewhere { return .ok }
            if startupGlobeBlocked { return .staleState }
            guard state.capabilities.contains(.globe) else { return .ok }
            globeCleanupPending = true
            nextRetryAt = 0
            // A live globe-only drop is independent from a healthy slap lease. If SPU teardown is
            // already pending, however, use the unified retry path so its receipt-first OFF proof
            // completes before the global keyboard role is restored.
            if needsSlapCleanup {
                retryCleanupIfDue(force: true)
                return globeCleanupPending ? .staleState : .ok
            }
            return cleanupGlobeOnce() ? .ok : .staleState

        case .repairLegacyGlobe:
            guard let previous = decodeGlobePrevious(frame.value) else { return .failed }
            // Queue this globe cleanup behind receipt-first SPU OFF. Calling the backend directly
            // here would repeat the old ordering bug whenever hello was stale because of BMI282.
            if state.capabilities.contains(.globe) {
                globeCleanupPending = true
                nextRetryAt = 0
            }
            if globeOwnedElsewhere { return .busy }
            if globeLockFD == nil {
                let acquisition = persistentGuardAcquireLock(PersistentGuardPaths.globeLock)
                guard case let .acquired(fd) = acquisition else {
                    return acquisition.isBusy ? .busy : .failed
                }
                globeLockFD = fd
            }
            legacyRepairPrevious = previous
            protectedLegacyOnly = false
            startupGlobeBlocked = true
            nextRetryAt = 0
            retryCleanupIfDue(force: true)
            return legacyRepairPrevious == nil && !startupGlobeBlocked ? .ok : .staleState

        case .acquireSlap:
            return acquireSlap()

        case .confirmSlapGrowth:
            guard let lease = slapLease, !lease.cleanupPending,
                  lease.activationComplete, let driver = lease.driver,
                  let baseline = lease.baseline else { return .staleState }
            if lease.growthProven { return .ok }
            guard let deviceID = lease.deviceID,
                  backend.deviceIdentity(driver) == deviceID,
                  backend.waitForGrowth(driver, after: baseline) else {
                lease.cleanupPending = true
                let cleaned = cleanupSlapOnce()
                return cleaned ? .failed : .staleState
            }
            lease.growthProven = true
            return .ok

        case .releaseSlap, .recoverSlap:
            prepareStartupRecoveryIfNeeded()
            if let lease = slapLease { lease.cleanupPending = true }
            return cleanupSlapOnce() && !hasAnyReceipt ? .ok : .staleState

        case .normalExit:
            normalExitRequested = true
            prepareStartupRecoveryIfNeeded()
            if let lease = slapLease { lease.cleanupPending = true }
            if state.capabilities.contains(.globe) { globeCleanupPending = true }
            retryCleanupIfDue(force: true)
            return mayExitNow ? .ok : .staleState

        case .hello, .ready, .ok, .busy, .idleChanged, .staleState, .failed:
            return .failed
        }
    }

    private func acquireSlap() -> ResourceGuardMessage {
        prepareStartupRecoveryIfNeeded()
        guard startupIsReady else { return .staleState }
        if state.capabilities.contains(.slap) {
            return slapLease?.cleanupPending == false ? .ok : .staleState
        }
        let acquisition = persistentGuardAcquireLock(PersistentGuardPaths.slapLock)
        guard case let .acquired(lockFD) = acquisition else {
            return acquisition.isBusy ? .busy : .failed
        }
        guard !hasAnyReceipt else {
            let lease = PersistentSPULease(lockFD: lockFD)
            slapLease = lease
            startupRecoveryBlocked = true
            prepareReceiptRecovery(lease)
            return .staleState
        }
        guard let driver = backend.copyAccelerometerDriver() else {
            persistentGuardUnlock(lockFD)
            return .failed
        }
        guard let deviceID = backend.deviceIdentity(driver) else {
            backend.releaseDriver(driver)
            persistentGuardUnlock(lockFD)
            return .failed
        }
        guard let baseline = backend.proveIdle(driver) else {
            backend.releaseDriver(driver)
            persistentGuardUnlock(lockFD)
            return .idleChanged
        }
        let lease = PersistentSPULease(
            lockFD: lockFD, driver: driver, deviceID: deviceID, baseline: baseline
        )
        let receipt = PersistentSPUReceipt(
            version: PersistentSPUReceipt.version,
            bootID: bootID,
            deviceRegistryID: deviceID,
            helper: helperIdentity,
            parent: parentIdentity,
            session: session,
            createdAt: Date().timeIntervalSince1970
        )
        guard writeReceipt(receipt) else {
            if hasAnyReceipt {
                // Rename may have succeeded while its directory fsync failed. Keep the same flock
                // and exact helper alive until that receipt is durably removed; no ON command was
                // issued, so hardware is already proven stopped.
                lease.identityReceiptReady = true
                lease.stoppedProven = true
                lease.cleanupPending = true
                slapLease = lease
                startupRecoveryBlocked = true
                return .staleState
            }
            backend.releaseDriver(driver)
            persistentGuardUnlock(lockFD)
            return .failed
        }
        lease.identityReceiptReady = true
        slapLease = lease
        state.acquired(.slap)
        lease.cleanupPending = false
        guard backend.activate(driver) else {
            lease.cleanupPending = true
            return cleanupSlapOnce() ? .failed : .staleState
        }
        lease.activationComplete = true
        return .ok
    }

    private func beginParentExit() {
        prepareGlobeRecoveryIfNeeded()
        let hadGlobe = state.capabilities.contains(.globe)
        parentExitedAt = Date()
        analyzeCrashAfterCleanup = hadGlobe && !normalExitRequested
        transportDetached = true
        prepareStartupRecoveryIfNeeded()
        if let lease = slapLease { lease.cleanupPending = true }
        if hadGlobe { globeCleanupPending = true }
        nextRetryAt = 0
    }

    private func retryCleanupIfDue(force: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || cleanupNeedsRetry && now >= nextRetryAt else { return }
        var allClean = true
        prepareGlobeRecoveryIfNeeded()
        if startupGlobeBlocked { allClean = false }
        prepareStartupRecoveryIfNeeded()
        var slapClean = true
        if needsSlapCleanup {
            slapClean = cleanupSlapOnce()
            allClean = slapClean && allClean
        }
        // Global cleanup order is deliberate: the sensor is stopped before a possibly slower
        // CFPreferences/TIS restore and before crash-report scanning/relaunch.
        if globeCleanupPending {
            if slapClean { allClean = cleanupGlobeOnce() && allClean }
            else { allClean = false }
        }
        if legacyRepairPrevious != nil {
            if slapClean && !globeCleanupPending {
                allClean = repairLegacyGlobeOnce() && allClean
            } else {
                allClean = false
            }
        }
        if allClean {
            retryDelay = 0.10
            nextRetryAt = 0
        } else {
            nextRetryAt = now + retryDelay
            retryDelay = min(retryDelay * 1.7, 2.0)
        }
    }

    private func prepareGlobeRecoveryIfNeeded() {
        if legacyRepairPrevious != nil { return }
        if state.capabilities.contains(.globe) {
            startupGlobeBlocked = false
            globeOwnedElsewhere = false
            return
        }
        if startupGlobeBlocked, let fd = globeLockFD {
            applyGlobeAdoption(on: fd)
            return
        }
        guard globeLockFD == nil else { return }
        guard backend.hasGlobeReceipt() else {
            startupGlobeBlocked = false
            globeOwnedElsewhere = false
            return
        }
        switch persistentGuardAcquireLock(PersistentGuardPaths.globeLock) {
        case let .acquired(fd):
            globeLockFD = fd
            applyGlobeAdoption(on: fd)
        case .busy:
            // The receipt is protected by another live helper. It is not ours to adopt or restore.
            globeOwnedElsewhere = true
            startupGlobeBlocked = false
        case .failed:
            // An I/O/permission failure is not proof that another helper owns the receipt. Keep
            // READY and exit blocked and retry until ownership can actually be classified.
            globeOwnedElsewhere = false
            startupGlobeBlocked = true
        }
    }

    private func applyGlobeAdoption(on fd: Int32) {
        switch backend.adoptGlobeReceipt() {
        case .none:
            persistentGuardUnlock(fd)
            if globeLockFD == fd { globeLockFD = nil }
            startupGlobeBlocked = false
            globeOwnedElsewhere = false
        case .adopted:
            state.acquired(.globe)
            protectedLegacyOnly = false
            if normalExitRequested || parentExitedAt != nil { globeCleanupPending = true }
            startupGlobeBlocked = false
            globeOwnedElsewhere = false
        case .recovering:
            state.acquired(.globe)
            protectedLegacyOnly = false
            globeCleanupPending = true
            startupGlobeBlocked = true
            globeOwnedElsewhere = false
            nextRetryAt = 0
        case .protectedLegacy:
            globeOwnedElsewhere = false
            protectedLegacyOnly = true
            if normalExitRequested || parentExitedAt != nil {
                // No helper-owned receipt or mutation exists. Preserve the protected legacy inode
                // and raw value byte-for-byte, then make the flock available to explicit GLOBEFIX.
                persistentGuardUnlock(fd)
                if globeLockFD == fd { globeLockFD = nil }
                startupGlobeBlocked = false
                protectedLegacyOnly = false
                kbLog("globe: protected legacy оставлен без изменений после выхода parent")
            } else {
                startupGlobeBlocked = true
            }
        case .ownedElsewhere:
            persistentGuardUnlock(fd)
            if globeLockFD == fd { globeLockFD = nil }
            startupGlobeBlocked = false
            globeOwnedElsewhere = true
        case .blocked:
            // Keep the same flock and retry. Dropping it here would leave an unsupported or
            // not-yet-durable receipt unguarded during this exact parent's lifetime.
            startupGlobeBlocked = true
            globeOwnedElsewhere = false
        }
    }

    private func prepareStartupRecoveryIfNeeded() {
        // An active runtime lease also has a receipt; it must not make a helper that already sent
        // READY look like startup recovery became blocked again.
        guard slapLease == nil else { return }
        guard hasAnyReceipt else { startupRecoveryBlocked = false; return }
        guard case let .acquired(lockFD) = persistentGuardAcquireLock(
            PersistentGuardPaths.slapLock
        ) else {
            // Another exact helper may still own the receipt. We are not READY: a second helper
            // must never accept mutations while ownership (or even lock-file I/O) is unproven.
            startupRecoveryBlocked = true
            return
        }
        let lease = PersistentSPULease(lockFD: lockFD)
        slapLease = lease
        startupRecoveryBlocked = true
        prepareReceiptRecovery(lease)
    }

    private func prepareReceiptRecovery(_ lease: PersistentSPULease) {
        let scan = receiptPathScan
        guard scan.isComplete else { return }
        let files = receiptFiles(in: scan)
        guard !files.isEmpty else {
            guard flushReceiptDirectory() else { return }
            finishSlapCleanup(lease)
            return
        }
        // A future envelope or malformed current-version envelope may carry semantics this build
        // does not understand. Preserve it under the same flock and block READY/mutations.
        guard !files.contains(where: \.isUnsupported) else { return }
        let valid = files.compactMap(\.receipt).filter(\.isSemanticallyValid)
        if valid.count == files.count, valid.allSatisfy({ $0.bootID != bootID }) {
            // SPU command state does not survive a boot. A receipt from another boot is an audit
            // trace, not authority to issue OFF to today's device. This shortcut is legal only
            // when EVERY existing receipt says old boot; one unknown/v2/current file requires OFF.
            guard removeAllReceipts() else { return }
            finishSlapCleanup(lease)
            return
        }
        if lease.driver == nil { lease.driver = backend.copyAccelerometerDriver() }
        guard let driver = lease.driver else { return }
        guard let currentID = backend.deviceIdentity(driver) else {
            backend.releaseDriver(driver)
            lease.driver = nil
            lease.stoppedProven = false
            return
        }
        let expectedIDs = Set(valid.filter { $0.bootID == bootID }.map(\.deviceRegistryID))
        if !expectedIDs.isEmpty,
           (expectedIDs.count != 1 || expectedIDs.first != currentID) {
            backend.releaseDriver(driver)
            lease.driver = nil
            lease.stoppedProven = false
            return
        }
        lease.deviceID = currentID
        lease.cleanupPending = true

        // Upgrade truncated/v2 receipts before the first OFF command. This preserves the old
        // safety path while ensuring every command in the new build is covered by boot/device/
        // parent/session identity.
        let everyFileAlreadyExact = files.allSatisfy { file in
            guard let receipt = file.receipt else { return false }
            return receipt.isSemanticallyValid
                && receipt.bootID == bootID
                && receipt.deviceRegistryID == currentID
        }
        if !everyFileAlreadyExact {
            let upgraded = PersistentSPUReceipt(
                version: PersistentSPUReceipt.version,
                bootID: bootID,
                deviceRegistryID: currentID,
                helper: helperIdentity,
                parent: parentIdentity,
                session: session,
                createdAt: Date().timeIntervalSince1970
            )
            guard writeReceipt(upgraded) else { return }
        }
        lease.identityReceiptReady = true
    }

    @discardableResult
    private func cleanupSlapOnce() -> Bool {
        prepareStartupRecoveryIfNeeded()
        guard let lease = slapLease else {
            startupRecoveryBlocked = hasAnyReceipt
            return !startupRecoveryBlocked
        }
        guard lease.cleanupPending else { return false }
        if lease.driver == nil || !lease.identityReceiptReady {
            prepareReceiptRecovery(lease)
        }
        guard lease.identityReceiptReady, let driver = lease.driver else { return false }
        if let expected = lease.deviceID, backend.deviceIdentity(driver) != expected {
            backend.releaseDriver(driver)
            lease.driver = nil
            // OFF proof belongs to this exact live registry handle. If it disappeared or changed,
            // reacquisition must run a fresh complete OFF+counter proof before deleting receipts.
            lease.stoppedProven = false
            return false
        }
        if !lease.stoppedProven {
            guard backend.shutDownAndProve(driver) else { return false }
            lease.stoppedProven = true
        }
        guard removeAllReceipts() else {
            // A stop proof is intentionally single-use across a durability delay. Sleep/wake or
            // same-ID reactivation can happen before the next unlink retry; require another full
            // anchored OFF pass instead of deleting the receipt on stale Boolean state.
            lease.stoppedProven = false
            return false
        }
        state.released(.slap, cleanupSucceeded: true)
        finishSlapCleanup(lease)
        return true
    }

    private func finishSlapCleanup(_ lease: PersistentSPULease) {
        if let driver = lease.driver { backend.releaseDriver(driver); lease.driver = nil }
        persistentGuardUnlock(lease.lockFD)
        if slapLease === lease { slapLease = nil }
        startupRecoveryBlocked = hasAnyReceipt
    }

    private func cleanupGlobeOnce() -> Bool {
        guard globeCleanupPending else { return true }
        // A receipt can be replaced/migrated after this helper acquired its globe capability. Run
        // the same exact-owner classification again at cleanup time while we still hold the global
        // flock. Dead/reused owners are durably adopted; live or unclassifiable owners stay blocked.
        switch backend.adoptGlobeReceipt() {
        case .none, .adopted, .recovering:
            break
        case .protectedLegacy:
            // This capability can only predate the helper-exclusive protocol. It is not authority
            // to touch GUI-protected bytes; leave cleanup blocked until normal exit relinquishes the
            // non-mutating startup hold in `applyGlobeAdoption`.
            return false
        case .ownedElsewhere:
            // The exact live foreign owner is now responsible for the shared receipt/system state.
            // Preserve both byte-for-byte, but relinquish only our stale capability and flock.
            analyzeCrashAfterCleanup = false
            releaseGlobeLockAndState()
            return true
        case .blocked:
            return false
        }
        guard backend.restoreGlobe() else { return false }
        releaseGlobeLockAndState()
        globeCleanupPending = false
        return true
    }

    private func repairLegacyGlobeOnce() -> Bool {
        guard let previous = legacyRepairPrevious else { return true }
        guard let fd = globeLockFD else {
            switch persistentGuardAcquireLock(PersistentGuardPaths.globeLock) {
            case let .acquired(acquired):
                globeLockFD = acquired
                startupGlobeBlocked = true
                return repairLegacyGlobeOnce()
            case .busy:
                globeOwnedElsewhere = true
                return false
            case .failed:
                startupGlobeBlocked = true
                return false
            }
        }
        guard backend.repairLegacyGlobe(previous: previous) else {
            startupGlobeBlocked = true
            return false
        }
        legacyRepairPrevious = nil
        protectedLegacyOnly = false
        globeOwnedElsewhere = false
        // The exact protected inode is now either gone or covered by the helper-owned marker.
        // Re-scan under the same flock before releasing it; an unexpected canonical/unknown file
        // remains blocked and is never hidden by the successful repair command.
        switch backend.adoptGlobeReceipt() {
        case .none:
            persistentGuardUnlock(fd)
            if globeLockFD == fd { globeLockFD = nil }
            startupGlobeBlocked = false
            return true
        case .adopted:
            state.acquired(.globe)
            startupGlobeBlocked = false
            if normalExitRequested || parentExitedAt != nil { globeCleanupPending = true }
            return !globeCleanupPending
        case .recovering:
            state.acquired(.globe)
            globeCleanupPending = true
            startupGlobeBlocked = true
            return false
        case .ownedElsewhere:
            persistentGuardUnlock(fd)
            if globeLockFD == fd { globeLockFD = nil }
            startupGlobeBlocked = false
            globeOwnedElsewhere = true
            return true
        case .protectedLegacy, .blocked:
            startupGlobeBlocked = true
            return false
        }
    }

    private func releaseGlobeLockAndState() {
        state.released(.globe, cleanupSucceeded: true)
        if let fd = globeLockFD { persistentGuardUnlock(fd); globeLockFD = nil }
        globeCleanupPending = false
    }

    private var hasAnyReceipt: Bool {
        let scan = receiptPathScan
        return !scan.isComplete || scan.urls.contains {
            persistentGuardPathMayExist($0)
        }
    }

    private var receiptPathScan: PersistentGuardReceiptPathScan {
        guard backend.allowReceiptDirectoryScan() else {
            return PersistentGuardReceiptPathScan(
                urls: PersistentGuardPaths.knownSlapReceipts, isComplete: false
            )
        }
        return PersistentGuardPaths.slapReceiptScan
    }

    private func receiptFiles(in scan: PersistentGuardReceiptPathScan)
        -> [PersistentSPUReceiptFile] {
        scan.urls.compactMap { url in
            guard persistentGuardPathMayExist(url) else { return nil }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber, size.intValue > 0,
                  size.intValue <= 16_384,
                  let data = try? Data(contentsOf: url) else {
                return PersistentSPUReceiptFile(
                    url: url, receipt: nil, declaredVersion: nil,
                    isJSONEnvelope: true, isRecognizedLegacy: false
                )
            }
            let jsonValue = try? JSONSerialization.jsonObject(with: data)
            let object = jsonValue as? [String: Any]
            let declared = (object?["version"] as? NSNumber)?.intValue
            let legacyHelper = (object?["helperPID"] as? NSNumber)?.int32Value
            let legacyParent = (object?["parentPID"] as? NSNumber)?.int32Value
            let legacySession = object?["session"] as? String
            let legacyCreated = (object?["createdAt"] as? NSNumber)?.doubleValue
            let recognizedLegacy = declared == 2
                && (legacyHelper ?? 0) > 1 && (legacyParent ?? 0) > 1
                && legacySession?.isEmpty == false
                && legacyCreated?.isFinite == true && (legacyCreated ?? 0) > 0
            return PersistentSPUReceiptFile(
                url: url,
                receipt: try? JSONDecoder().decode(PersistentSPUReceipt.self, from: data),
                declaredVersion: declared,
                isJSONEnvelope: jsonValue != nil,
                isRecognizedLegacy: recognizedLegacy
            )
        }
    }

    private func writeReceipt(_ receipt: PersistentSPUReceipt) -> Bool {
        guard backend.allowReceiptWrite(),
              let data = try? JSONEncoder().encode(receipt) else { return false }
        var template = Array(
            PersistentGuardPaths.directory.appendingPathComponent(".resource-guard-spu.XXXXXX")
                .path.utf8CString
        )
        let fd = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard fd >= 0 else { return false }
        let temporary = String(cString: template)
        var succeeded = fchmod(fd, mode_t(0o600)) == 0
        if succeeded {
            succeeded = data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return false }
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { return false }
                    offset += count
                }
                return true
            }
        }
        if succeeded { succeeded = fsync(fd) == 0 }
        if close(fd) != 0 { succeeded = false }
        if succeeded {
            succeeded = rename(temporary, PersistentGuardPaths.slapReceipt.path) == 0
        }
        if succeeded { succeeded = flushReceiptDirectory() }
        else { _ = unlink(temporary) }
        return succeeded
    }

    private func removeAllReceipts() -> Bool {
        guard backend.allowReceiptRemoval() else { return false }
        let scan = receiptPathScan
        guard scan.isComplete else { return false }
        var removed = true
        for url in scan.urls {
            if unlink(url.path) != 0, errno != ENOENT { removed = false }
        }
        guard removed, flushReceiptDirectory() else { return false }
        return !hasAnyReceipt
    }

    private func flushReceiptDirectory() -> Bool {
        let fd = Darwin.open(PersistentGuardPaths.directory.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        let synced = fsync(fd) == 0
        let closed = close(fd) == 0
        return synced && closed
    }

    private func finishCrashAnalysisIfNeeded() {
        guard analyzeCrashAfterCleanup, let diedAt = parentExitedAt else { return }
        GlobeGuard.handleCrash(
            parentPID: parentPID, livedSince: parentIdentity.startedAt, diedAt: diedAt
        )
    }
}
