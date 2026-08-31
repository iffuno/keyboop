import Foundation
import Darwin

/// Result of the one pre-helper migration pass. Runtime globe ownership never uses this path: it is
/// only for retiring the old GUI-created receipt which macOS may make unreadable to a child process.
enum GlobeLegacyMigrationPlan: Equatable {
    case none
    case repair(previous: Int)
    case blocked(String)
}

/// Системная настройка клавиши 🌐/Fn («При нажатии 🌐» в Настройках → Клавиатура).
///
/// Since resource-guard v3.1, every ordinary acquire/release mutation is helper-exclusive. The GUI
/// sends desired state only; the helper owns the cross-build flock, durable receipt and live
/// CFPreferences/TIS transaction. This is not cosmetic: a GUI-created receipt was observed in vivo
/// to be App-Data-protected from its Process()-spawned helper after the GUI died.
enum GlobeKey {
    private static let domain = "com.apple.HIToolbox" as CFString
    private static let key = "AppleFnUsageType" as CFString
    private static let user = kCFPreferencesCurrentUser
    private static let host = kCFPreferencesAnyHost

    enum Action: Int {
        case nothing = 0
        case inputSource = 1
        case emoji = 2
        case dictation = 3

        var conflicts: Bool { self != .nothing }
    }

    private static func rawValue() -> Int? {
        CFPreferencesSynchronize(domain, user, host)
        return CFPreferencesCopyValue(key, domain, user, host) as? Int
    }

    static var current: Action {
        guard let value = rawValue() else { return .inputSource }
        return Action(rawValue: value) ?? .inputSource
    }

    static var isExplicitlySet: Bool { rawValue() != nil }

    private static func applyLive(_ value: Int) {
        typealias Fn = @convention(c) (Int32) -> Void
        guard let carbon = dlopen(
            "/System/Library/Frameworks/Carbon.framework/Carbon", RTLD_NOW
        ), let symbol = dlsym(carbon, "TISUpdateFnUsageType") else {
            kbLog("globe: TISUpdateFnUsageType недоступен — live-применение не подтверждено")
            return
        }
        unsafeBitCast(symbol, to: Fn.self)(Int32(value))
    }

    // MARK: - Helper-owned v3 receipt

    private static var supportDirectory: URL {
#if RESOURCE_GUARD_TESTING
        if let path = ProcessInfo.processInfo.environment["KEYBOOP_RESOURCE_GUARD_TEST_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            return directory
        }
#endif
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Keyboop", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// New filename is deliberate. `globe-fn-receipt` may carry GUI App-Data provenance and is
    /// therefore migration input only; a helper must never overwrite it and assume the new bytes
    /// became readable after the GUI died.
    private static var receiptURL: URL {
        supportDirectory.appendingPathComponent("resource-guard-globe-receipt-v3.json")
    }

    private static var clearingReceiptURL: URL {
        supportDirectory.appendingPathComponent("resource-guard-globe-receipt-v3.clearing")
    }

    private static var legacyReceiptURLs: [URL] {
        [
            supportDirectory.appendingPathComponent("globe-fn-receipt"),
            supportDirectory.appendingPathComponent("globe-fn-receipt.clearing"),
        ]
    }

    private static var legacyRetirementURL: URL {
        supportDirectory.appendingPathComponent("resource-guard-globe-legacy-retired-v1.json")
    }

    private static var repairJournalURL: URL {
        supportDirectory.appendingPathComponent("resource-guard-globe-repair-v1.json")
    }

    private static var clearingRepairJournalURL: URL {
        supportDirectory.appendingPathComponent("resource-guard-globe-repair-v1.clearing")
    }

    private enum ReceiptPhase: String, Codable { case active }

    private struct Receipt: Codable {
        static let version = 3
        let version: Int
        let previous: Int
        let owner: ResourceGuardOwnershipIdentity
        let helper: ResourceGuardProcessIdentity
        let transaction: String
        let phase: ReceiptPhase

        var isSemanticallyValid: Bool {
            version == Self.version
                && validPrevious(previous)
                && owner.process.pid > 1
                && owner.process.startSeconds > 0
                && owner.process.startMicroseconds < 1_000_000
                && !owner.bootID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !owner.session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && helper.pid > 1
                && helper.startSeconds > 0
                && helper.startMicroseconds < 1_000_000
                && !transaction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && phase == .active
        }
    }

    private struct LegacyV2Receipt: Codable {
        let version: Int
        let previous: Int
        let owner: ResourceGuardOwnershipIdentity

        var isSemanticallyValid: Bool {
            version == 2
                && validPrevious(previous)
                && owner.process.pid > 1
                && owner.process.startSeconds > 0
                && owner.process.startMicroseconds < 1_000_000
                && !owner.bootID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !owner.session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private struct FileFingerprint: Codable, Equatable {
        let name: String
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let mode: UInt32
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        /// `rename(2)` deliberately changes the pathname and may update ctime, while the open file
        /// object remains the same. Tombstone completion therefore compares only stable object and
        /// content identity; pathname/ctime remain part of legacy retirement fingerprints, where a
        /// metadata change must invalidate the marker.
        func isSameObject(afterRename other: FileFingerprint) -> Bool {
            device == other.device
                && inode == other.inode
                && size == other.size
                && mode == other.mode
                && modifiedSeconds == other.modifiedSeconds
                && modifiedNanoseconds == other.modifiedNanoseconds
        }
    }

    private struct LegacyRetirementMarker: Codable {
        static let version = 1
        let version: Int
        let fingerprints: [FileFingerprint]
        let verifiedPrevious: Int
        let owner: ResourceGuardOwnershipIdentity
        let helper: ResourceGuardProcessIdentity
        let transaction: String
        let completedAt: TimeInterval

        var isSemanticallyValid: Bool {
            version == Self.version
                && fingerprints.count == 1
                && legacyReceiptURLs.map(\.lastPathComponent).contains(fingerprints[0].name)
                && fingerprints[0].size > 0 && fingerprints[0].size <= 16_384
                && (mode_t(fingerprints[0].mode) & S_IFMT) == S_IFREG
                && fingerprints[0].inode != 0
                && validPrevious(verifiedPrevious)
                && owner.process.pid > 1
                && owner.process.startSeconds > 0
                && owner.process.startMicroseconds < 1_000_000
                && !owner.bootID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !owner.session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && helper.pid > 1
                && helper.startSeconds > 0
                && helper.startMicroseconds < 1_000_000
                && !transaction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && completedAt.isFinite && completedAt > 0
        }
    }

    private struct RepairJournal: Codable {
        static let version = 1
        let version: Int
        let previous: Int
        let legacyFingerprint: FileFingerprint?
        let owner: ResourceGuardOwnershipIdentity
        let helper: ResourceGuardProcessIdentity
        let transaction: String
        let createdAt: TimeInterval

        var isSemanticallyValid: Bool {
            version == Self.version
                && validPrevious(previous)
                && owner.process.pid > 1
                && owner.process.startSeconds > 0
                && owner.process.startMicroseconds < 1_000_000
                && !owner.bootID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !owner.session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && helper.pid > 1
                && helper.startSeconds > 0
                && helper.startMicroseconds < 1_000_000
                && !transaction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && createdAt.isFinite && createdAt > 0
        }
    }

    private enum CanonicalState {
        case absent
        case receipt(Receipt, URL, FileFingerprint)
        case unsupported(String)
    }

    private enum LegacyValue {
        case v2(LegacyV2Receipt)
        case text(previous: Int, pid: pid_t?)
        case unsupported

        var previous: Int? {
            switch self {
            case let .v2(value): return value.previous
            case let .text(previous, _): return previous
            case .unsupported: return nil
            }
        }
    }

    private enum LegacySnapshot {
        case absent
        case retired(FileFingerprint)
        case readable(LegacyValue, FileFingerprint)
        case denied(FileFingerprint, Int32)
        case blocked(String)
    }

    private enum RepairJournalState {
        case absent
        case journal(RepairJournal, URL, FileFingerprint)
        case unsupported(String)
    }

    private enum CurrentReceiptAuthority: String {
        case ours
        case orphaned
        case liveOther
        case unknown
    }

    private enum POSIXResult<Success> {
        case success(Success)
        case failure(Int32)
    }

    private static let receiptHandleLock = NSLock()
    private static var heldReceiptFD: Int32 = -1
    private static var heldReceiptFingerprint: FileFingerprint?

    private static func validPrevious(_ value: Int) -> Bool {
        value == -2 || (Action(rawValue: value) != nil && value != Action.nothing.rawValue)
    }

    private static func currentReceiptAuthority(
        owner: ResourceGuardOwnershipIdentity
    ) -> CurrentReceiptAuthority {
        if PersistentResourceGuard.isHelperProcess,
           PersistentResourceGuard.helperMayRestoreGlobe(ownedBy: owner) {
            return .ours
        }
        let liveness = PersistentResourceGuard.exactOwnerLiveness(owner)
        if !PersistentResourceGuard.isHelperProcess,
           owner.process.pid == ProcessInfo.processInfo.processIdentifier,
           liveness == .alive {
            return .ours
        }
        switch liveness {
        case .alive: return .liveOther
        case .deadOrReused: return .orphaned
        case .unknown: return .unknown
        }
    }

    private static func fingerprint(_ url: URL) -> POSIXResult<FileFingerprint> {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return .failure(errno) }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
              info.st_size > 0, info.st_size <= 16_384 else {
            return .failure(EINVAL)
        }
        return .success(FileFingerprint(
            name: url.lastPathComponent,
            device: UInt64(bitPattern: Int64(info.st_dev)),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            mode: UInt32(info.st_mode),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changedSeconds: Int64(info.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(info.st_ctimespec.tv_nsec)
        ))
    }

    private static func readSnapshot(
        _ url: URL, expected: FileFingerprint? = nil
    ) -> POSIXResult<(Data, FileFingerprint)> {
        let before: FileFingerprint
        switch fingerprint(url) {
        case let .success(value): before = value
        case let .failure(error): return .failure(error)
        }
        if let expected, expected != before { return .failure(ESTALE) }
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return .failure(errno) }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0,
              UInt64(bitPattern: Int64(opened.st_dev)) == before.device,
              UInt64(opened.st_ino) == before.inode else { return .failure(ESTALE) }
        var data = Data(count: Int(before.size))
        var offset = 0
        let readOK = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return false }
            while offset < bytes.count {
                let count = Darwin.read(fd, base.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard readOK else { return .failure(errno == 0 ? EIO : errno) }
        guard case let .success(after) = fingerprint(url), after == before else {
            return .failure(ESTALE)
        }
        return .success((data, before))
    }

    private static func logIO(_ operation: String, _ url: URL, _ error: Int32) {
        kbLog("globe: \(operation) \(url.lastPathComponent) не выполнено: errno=\(error) "
            + String(cString: strerror(error)))
    }

    private static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return false }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
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

    /// Atomic helper-owned write without NSFileProtection/App-Data provenance. Receipt contents are
    /// not secret; crash availability is the safety property. Every rename is followed by dir fsync.
    private static func durableWrite(_ data: Data, to url: URL) -> Bool {
        guard PersistentResourceGuard.isHelperProcess else {
            kbLog("globe: отказал в записи receipt вне helper")
            return false
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString.lowercased()).tmp"
        )
        let fd = Darwin.open(
            temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600)
        )
        guard fd >= 0 else { logIO("create", temporary, errno); return false }
        var ok = fchmod(fd, mode_t(0o600)) == 0
        if ok { ok = writeAll(data, to: fd) }
        if ok { ok = fsync(fd) == 0 }
        let closeOK = close(fd) == 0
        ok = ok && closeOK
        guard ok else {
            let writeError = errno == 0 ? EIO : errno
            _ = unlink(temporary.path)
            logIO("write/fsync", temporary, writeError)
            return false
        }
        guard rename(temporary.path, url.path) == 0 else {
            let renameError = errno
            _ = unlink(temporary.path)
            logIO("rename", url, renameError)
            return false
        }
        guard flushReceiptDirectory() else {
            kbLog("globe: rename \(url.lastPathComponent) есть, но fsync каталога не доказан")
            return false
        }
        return true
    }

    private static func flushReceiptDirectory() -> Bool {
        let fd = Darwin.open(supportDirectory.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { logIO("open-dir", supportDirectory, errno); return false }
        let synced = fsync(fd) == 0
        let syncError = errno
        let closed = close(fd) == 0
        if !synced { logIO("fsync-dir", supportDirectory, syncError) }
        return synced && closed
    }

    private static func closeHeldReceipt() {
        receiptHandleLock.lock()
        if heldReceiptFD >= 0 { close(heldReceiptFD) }
        heldReceiptFD = -1
        heldReceiptFingerprint = nil
        receiptHandleLock.unlock()
    }

    private static func holdReceipt(_ url: URL, fingerprint expected: FileFingerprint) -> Bool {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { logIO("hold-open", url, errno); return false }
        var info = stat()
        guard fstat(fd, &info) == 0,
              UInt64(bitPattern: Int64(info.st_dev)) == expected.device,
              UInt64(info.st_ino) == expected.inode else {
            let holdError = errno == 0 ? ESTALE : errno
            close(fd)
            logIO("hold-identity", url, holdError)
            return false
        }
        receiptHandleLock.lock()
        if heldReceiptFD >= 0 { close(heldReceiptFD) }
        heldReceiptFD = fd
        heldReceiptFingerprint = expected
        receiptHandleLock.unlock()
        return true
    }

    private static func canonicalState() -> CanonicalState {
        var present: [URL] = []
        for url in [receiptURL, clearingReceiptURL] {
            var info = stat()
            if lstat(url.path, &info) == 0 { present.append(url) }
            else if errno != ENOENT {
                logIO("lstat", url, errno)
                return .unsupported("lstat")
            }
        }
        guard !present.isEmpty else { closeHeldReceipt(); return .absent }
        guard present.count == 1 else {
            kbLog("globe: одновременно существуют active и clearing v3 receipt — блокирую")
            return .unsupported("mixed canonical receipts")
        }
        let url = present[0]
        switch readSnapshot(url) {
        case let .failure(error):
            logIO("read", url, error)
            return .unsupported("read errno=\(error)")
        case let .success((data, fileFingerprint)):
            guard let receipt = decodeCurrentReceipt(data) else {
                kbLog("globe: v3 receipt имеет неизвестный/повреждённый формат — блокирую")
                return .unsupported("schema")
            }
            guard holdReceipt(url, fingerprint: fileFingerprint) else {
                return .unsupported("identity")
            }
            return .receipt(receipt, url, fileFingerprint)
        }
    }

    private static func decodeCurrentReceipt(_ data: Data) -> Receipt? {
        guard let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.isSemanticallyValid else { return nil }
        return receipt
    }

    private static func canonicalPathPresence() -> POSIXResult<Bool> {
        var count = 0
        for url in [receiptURL, clearingReceiptURL] {
            var info = stat()
            if lstat(url.path, &info) == 0 { count += 1 }
            else if errno != ENOENT { return .failure(errno) }
        }
        guard count <= 1 else { return .failure(EINVAL) }
        return .success(count == 1)
    }

    private static func repairJournalPathPresence() -> POSIXResult<Bool> {
        var count = 0
        for url in [repairJournalURL, clearingRepairJournalURL] {
            var info = stat()
            if lstat(url.path, &info) == 0 { count += 1 }
            else if errno != ENOENT { return .failure(errno) }
        }
        guard count <= 1 else { return .failure(EINVAL) }
        return .success(count == 1)
    }

    private static func repairJournalState() -> RepairJournalState {
        var present: [URL] = []
        for url in [repairJournalURL, clearingRepairJournalURL] {
            var info = stat()
            if lstat(url.path, &info) == 0 { present.append(url) }
            else if errno != ENOENT {
                logIO("repair-journal-lstat", url, errno)
                return .unsupported("lstat")
            }
        }
        guard !present.isEmpty else { return .absent }
        guard present.count == 1 else {
            kbLog("globe: active+clearing repair journal одновременно — блокирую")
            return .unsupported("mixed repair journals")
        }
        let url = present[0]
        switch readSnapshot(url) {
        case let .failure(error):
            logIO("repair-journal-read", url, error)
            return .unsupported("read errno=\(error)")
        case let .success((data, fileFingerprint)):
            guard let journal = try? JSONDecoder().decode(RepairJournal.self, from: data),
                  journal.isSemanticallyValid else {
                return .unsupported("schema")
            }
            return .journal(journal, url, fileFingerprint)
        }
    }

    private static func writeRepairJournal(
        previous: Int, legacyFingerprint: FileFingerprint?
    ) -> Bool {
        guard PersistentResourceGuard.isHelperProcess,
              validPrevious(previous),
              let owner = PersistentResourceGuard.globeReceiptOwner(),
              let helper = PersistentResourceGuard.globeHelperIdentity(),
              let data = try? JSONEncoder().encode(RepairJournal(
                version: RepairJournal.version,
                previous: previous,
                legacyFingerprint: legacyFingerprint,
                owner: owner,
                helper: helper,
                transaction: UUID().uuidString.lowercased(),
                createdAt: Date().timeIntervalSince1970
              )) else { return false }
        guard case .absent = repairJournalState() else { return false }
        return durableWrite(data, to: repairJournalURL)
    }

    private static func clearRepairJournal(
        source: URL, fingerprint expected: FileFingerprint
    ) -> Bool {
        if source == repairJournalURL {
            guard rename(repairJournalURL.path, clearingRepairJournalURL.path) == 0 else {
                logIO("repair-journal→clearing", repairJournalURL, errno)
                return false
            }
            guard flushReceiptDirectory() else { return false }
        }
        guard case let .success(now) = fingerprint(clearingRepairJournalURL),
              now.isSameObject(afterRename: expected) else {
            kbLog("globe: repair journal identity сменилась — блокирую unlink")
            return false
        }
        guard unlink(clearingRepairJournalURL.path) == 0 || errno == ENOENT else {
            logIO("repair-journal-unlink", clearingRepairJournalURL, errno)
            return false
        }
        return flushReceiptDirectory()
    }

    private static func recoverRepairJournal() -> Bool {
        guard PersistentResourceGuard.isHelperProcess else { return false }
        switch repairJournalState() {
        case .absent:
            return true
        case .unsupported:
            return false
        case let .journal(journal, source, fileFingerprint):
            // Journal and canonical receipt are mutually exclusive transaction authorities. A
            // crash-safe explicit repair clears canonical first and only then writes its journal;
            // seeing both (including unreadable/future canonical bytes) is therefore corruption or
            // an incomplete foreign transaction. Never mutate CFPreferences until both canonical
            // paths have been scanned and proved absent.
            guard case .absent = canonicalState() else {
                kbLog("globe repair: journal + canonical authority одновременно — блокирую")
                return false
            }
            switch currentReceiptAuthority(owner: journal.owner) {
            case .liveOther, .unknown: return false
            case .ours, .orphaned: break
            }
            let live = rawValue()
            switch ResourceGuardGlobeRepairPolicy.resolve(
                live: live, target: journal.previous
            ) {
            case .applyTarget:
                guard applyPrevious(journal.previous) else { return false }
            case .alreadyMatches:
                break
            case let .preserveUserOverride(actual):
                // A non-zero user choice made after the journal wins. It is safe to retire the old
                // inode, but record/verify the actual choice rather than overwriting it.
                kbLog(
                    "globe repair: системная роль уже изменена пользователем на \(actual); "
                    + "сохраняю этот выбор и завершаю one-shot repair"
                )
                if let legacy = journal.legacyFingerprint,
                   !retireLegacy(fingerprint: legacy, verifiedPrevious: actual) { return false }
                return clearRepairJournal(source: source, fingerprint: fileFingerprint)
            case .blocked:
                return false
            }
            guard systemMatches(previous: journal.previous) else { return false }
            if let legacy = journal.legacyFingerprint {
                switch legacySnapshot() {
                case .absent:
                    break
                case let .retired(current):
                    guard current == legacy,
                          retireLegacy(
                            fingerprint: legacy, verifiedPrevious: journal.previous
                          ) else { return false }
                case let .readable(_, current), let .denied(current, _):
                    guard current == legacy,
                          retireLegacy(
                            fingerprint: legacy, verifiedPrevious: journal.previous
                          ) else { return false }
                case .blocked:
                    return false
                }
            }
            return clearRepairJournal(source: source, fingerprint: fileFingerprint)
        }
    }

    @discardableResult
    private static func writeReceipt(_ previous: Int) -> Bool {
        guard PersistentResourceGuard.isHelperProcess,
              validPrevious(previous),
              let owner = PersistentResourceGuard.globeReceiptOwner(),
              let helper = PersistentResourceGuard.globeHelperIdentity(),
              let data = try? JSONEncoder().encode(Receipt(
                version: Receipt.version,
                previous: previous,
                owner: owner,
                helper: helper,
                transaction: UUID().uuidString.lowercased(),
                phase: .active
              )) else {
            kbLog("globe: не сформировал helper-owned v3 receipt")
            return false
        }
        guard durableWrite(data, to: receiptURL) else { return false }
        guard case .receipt = canonicalState() else { return false }
        return true
    }

    private static func clearCanonicalReceipt() -> Bool {
        switch canonicalState() {
        case .absent: return flushReceiptDirectory()
        case .unsupported: return false
        case let .receipt(_, source, fileFingerprint):
            receiptHandleLock.lock()
            let heldMatches = heldReceiptFD >= 0 && heldReceiptFingerprint == fileFingerprint
            if heldMatches {
                var heldInfo = stat()
                if fstat(heldReceiptFD, &heldInfo) != 0
                    || UInt64(bitPattern: Int64(heldInfo.st_dev)) != fileFingerprint.device
                    || UInt64(heldInfo.st_ino) != fileFingerprint.inode {
                    receiptHandleLock.unlock()
                    kbLog("globe: открытый receipt сменил identity — блокирую unlink")
                    return false
                }
            }
            receiptHandleLock.unlock()
            guard heldMatches else { return false }

            if source == receiptURL {
                guard rename(receiptURL.path, clearingReceiptURL.path) == 0 else {
                    logIO("receipt→clearing", receiptURL, errno)
                    return false
                }
                guard flushReceiptDirectory() else { return false }
            }
            guard case let .success(now) = fingerprint(clearingReceiptURL),
                  now.isSameObject(afterRename: fileFingerprint) else {
                kbLog("globe: clearing receipt identity не совпала — блокирую unlink")
                return false
            }
            guard unlink(clearingReceiptURL.path) == 0 || errno == ENOENT else {
                logIO("unlink", clearingReceiptURL, errno)
                return false
            }
            guard flushReceiptDirectory() else { return false }
            closeHeldReceipt()
            return true
        }
    }

    // MARK: - Legacy GUI receipt migration

    private static func decodeLegacy(_ data: Data) -> LegacyValue {
        if let value = try? JSONDecoder().decode(LegacyV2Receipt.self, from: data),
           value.isSemanticallyValid {
            return .v2(value)
        }
        if (try? JSONSerialization.jsonObject(with: data)) != nil { return .unsupported }
        guard let text = String(data: data, encoding: .utf8) else { return .unsupported }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count == 1 || lines.count == 2,
              let first = lines.first,
              let previous = Int(first.trimmingCharacters(in: .whitespacesAndNewlines)),
              validPrevious(previous) else { return .unsupported }
        if lines.count == 1 { return .text(previous: previous, pid: nil) }
        guard let pid = pid_t(lines[1].trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1 else { return .unsupported }
        return .text(previous: previous, pid: pid)
    }

    private static func markerMatches(_ fingerprint: FileFingerprint) -> Bool {
        guard case let .success((data, _)) = readSnapshot(legacyRetirementURL),
              let marker = try? JSONDecoder().decode(LegacyRetirementMarker.self, from: data),
              marker.isSemanticallyValid,
              marker.fingerprints == [fingerprint] else { return false }
        let authority = currentReceiptAuthority(owner: marker.owner)
        // `retireLegacy` can write this marker only after an exact restore proof. From that point the
        // immutable App-Data inode remains retired even if the person later selects another valid
        // system action; only fingerprint/authority changes can reactivate it.
        return ResourceGuardLegacyRetirementPolicy.accepts(
            exactFingerprint: marker.fingerprints == [fingerprint],
            ownerIsOurs: authority == .ours,
            ownerLiveness: authority == .orphaned ? .deadOrReused
                : (authority == .liveOther ? .alive : .unknown)
        )
    }

    private static func legacySnapshot() -> LegacySnapshot {
        var present: [(URL, FileFingerprint)] = []
        for url in legacyReceiptURLs {
            switch fingerprint(url) {
            case let .success(value): present.append((url, value))
            case let .failure(error) where error == ENOENT: continue
            case let .failure(error):
                logIO("legacy-lstat", url, error)
                return .blocked("legacy lstat errno=\(error)")
            }
        }
        guard !present.isEmpty else { return .absent }
        guard present.count == 1 else {
            kbLog("globe: несколько legacy receipt одновременно — блокирую миграцию")
            return .blocked("mixed legacy receipts")
        }
        let (url, fileFingerprint) = present[0]
        if markerMatches(fileFingerprint) {
            return .retired(fileFingerprint)
        }
        switch readSnapshot(url, expected: fileFingerprint) {
        case let .success((data, _)):
            let value = decodeLegacy(data)
            guard case .unsupported = value else { return .readable(value, fileFingerprint) }
            kbLog("globe: legacy receipt читается, но формат неизвестен — не retire")
            return .blocked("unsupported legacy contents")
        case let .failure(error) where error == EPERM || error == EACCES:
            kbLog("globe: legacy receipt защищён App Data (errno=\(error)); нужен GLOBEFIX")
            return .denied(fileFingerprint, error)
        case let .failure(error):
            logIO("legacy-read", url, error)
            return .blocked("legacy read errno=\(error)")
        }
    }

    private static func writeRetirementMarker(
        fingerprint: FileFingerprint, verifiedPrevious: Int
    ) -> Bool {
        guard PersistentResourceGuard.isHelperProcess,
              validPrevious(verifiedPrevious),
              let owner = PersistentResourceGuard.globeReceiptOwner(),
              let helper = PersistentResourceGuard.globeHelperIdentity(),
              let data = try? JSONEncoder().encode(LegacyRetirementMarker(
                version: LegacyRetirementMarker.version,
                fingerprints: [fingerprint],
                verifiedPrevious: verifiedPrevious,
                owner: owner,
                helper: helper,
                transaction: UUID().uuidString.lowercased(),
                completedAt: Date().timeIntervalSince1970
              )) else { return false }
        return durableWrite(data, to: legacyRetirementURL)
    }

    private static func removeRetirementMarkerIfLegacyGone() -> Bool {
        var anyLegacy = false
        for url in legacyReceiptURLs {
            switch fingerprint(url) {
            case .success: anyLegacy = true
            case let .failure(error) where error == ENOENT: continue
            case let .failure(error):
                logIO("legacy-post-unlink-lstat", url, error)
                return false
            }
        }
        guard !anyLegacy else { return true }
        if unlink(legacyRetirementURL.path) != 0, errno != ENOENT {
            logIO("unlink-marker", legacyRetirementURL, errno)
            return false
        }
        return flushReceiptDirectory()
    }

    private static func retireLegacy(
        fingerprint expected: FileFingerprint, verifiedPrevious: Int
    ) -> Bool {
        let currentFingerprint: FileFingerprint?
        if case let .success(value) = fingerprint(
            supportDirectory.appendingPathComponent(expected.name)
        ) { currentFingerprint = value } else { currentFingerprint = nil }
        guard PersistentResourceGuard.isHelperProcess,
              validPrevious(verifiedPrevious),
              ResourceGuardLegacyRetirementPolicy.mayWriteMarker(
                exactFingerprint: currentFingerprint == expected,
                restoreVerified: systemMatches(previous: verifiedPrevious)
              ) else {
            kbLog("globe: legacy fingerprint/system proof изменился до retire — блокирую")
            return false
        }
        guard writeRetirementMarker(
            fingerprint: expected, verifiedPrevious: verifiedPrevious
        ) else { return false }
        let url = supportDirectory.appendingPathComponent(expected.name)
        guard case let .success(beforeUnlink) = fingerprint(url), beforeUnlink == expected else {
            kbLog("globe: legacy inode сменился после marker — не удаляю")
            return false
        }
        if unlink(url.path) == 0 {
            guard flushReceiptDirectory() else { return false }
            return removeRetirementMarkerIfLegacyGone()
        }
        let unlinkError = errno
        if unlinkError == EPERM || unlinkError == EACCES {
            // This is the observed Data Vault path. The helper-owned, fsynced exact-inode marker is
            // now the durable retirement record; changed inode/size/mtime/ctime stops matching.
            kbLog("globe: legacy receipt App Data не удаляется; exact fingerprint marker активен")
            return markerMatches(expected)
        }
        logIO("legacy-unlink", url, unlinkError)
        return false
    }

    /// Called by the GUI only after it owns the cross-build singleton and the globe flock, and
    /// before spawning v3. Ordinary runtime never mutates CFPreferences in the GUI.
    static func prepareLegacyMigration(explicitRepair: Bool) -> GlobeLegacyMigrationPlan {
        guard !PersistentResourceGuard.isHelperProcess else {
            return .blocked("helper cannot run GUI preflight")
        }
        let canonicalExists: Bool
        switch canonicalState() {
        case .absent:
            canonicalExists = false
        case .receipt:
            canonicalExists = true
        case let .unsupported(reason):
            return .blocked("unsupported canonical receipt: \(reason)")
        }
        let repairJournalExists: Bool
        switch repairJournalPathPresence() {
        case let .success(value): repairJournalExists = value
        case let .failure(error): return .blocked("repair journal lstat errno=\(error)")
        }
        if canonicalExists || repairJournalExists {
            return explicitRepair ? .repair(previous: -2) : .none
        }
        switch legacySnapshot() {
        case .absent, .retired:
            if explicitRepair {
                // The hook explicitly means “restore the macOS default”. Bundle defaults are a UI
                // cache and may belong to another build/generation; they are never repair authority.
                return .repair(previous: -2)
            }
            return .none
        case let .blocked(reason): return .blocked(reason)
        case let .denied(_, error):
            guard explicitRepair, !canonicalExists,
                  rawValue() == Action.nothing.rawValue else {
                return .blocked("legacy App Data errno=\(error)")
            }
            return .repair(previous: -2)
        case let .readable(value, _):
            guard !canonicalExists else { return .blocked("mixed canonical+legacy") }
            let previous: Int
            switch value {
            case let .v2(receipt):
                switch currentReceiptAuthority(owner: receipt.owner) {
                case .ours, .orphaned: previous = receipt.previous
                case .liveOther: return .blocked("legacy exact owner alive")
                case .unknown: return .blocked("legacy owner liveness unknown")
                }
            case let .text(value, pid):
                if let pid, pid != ProcessInfo.processInfo.processIdentifier,
                   kill(pid, 0) == 0 || errno == EPERM {
                    return .blocked("legacy PID alive")
                }
                previous = value
            case .unsupported:
                return .blocked("unsupported legacy")
            }
            // Safe-direction migration: receipt remains until the helper has written its own exact
            // retirement marker. A crash before restore leaves receipt+0; after restore it leaves a
            // harmless duplicate restore which the next preflight verifies again.
            if rawValue() == Action.nothing.rawValue {
                guard applyPrevious(previous), systemMatches(previous: previous) else {
                    return .blocked("legacy restore not verified")
                }
                return .repair(previous: previous)
            }
            let live = rawValue()
            let verified = live ?? -2
            guard validPrevious(verified) else {
                return .blocked("live globe value unsupported")
            }
            return .repair(previous: verified)
        }
    }

    /// Pre-READY helper command. It accepts a protected legacy inode only after the authenticated
    /// singleton parent explicitly requested repair; readable malformed bytes remain blocked in the
    /// GUI preflight and are never converted into authority.
    static func repairLegacyFromPersistentHelper(previous: Int) -> Bool {
        guard PersistentResourceGuard.isHelperProcess, validPrevious(previous) else { return false }
        switch repairJournalState() {
        case .absent: break
        case .journal:
            guard recoverRepairJournal() else { return false }
            if systemMatches(previous: previous) { return true }
        case .unsupported:
            return false
        }
        switch canonicalState() {
        case .absent:
            break
        case let .unsupported(reason):
            kbLog("globe: GLOBEFIX blocked by unsupported canonical receipt (\(reason))")
            return false
        case .receipt:
            // Explicit repair first completes the existing helper-owned transaction under this same
            // flock (restore→verify→clear), then journals the requested system-default repair. It
            // never overwrites or ignores a malformed/future canonical receipt.
            guard release() else { return false }
        }
        let snapshot = legacySnapshot()
        let legacyFingerprint: FileFingerprint?
        switch snapshot {
        case .absent:
            legacyFingerprint = nil
        case let .retired(fileFingerprint):
            legacyFingerprint = fileFingerprint
        case let .readable(value, fileFingerprint):
            // If the system is still `.nothing`, exact readable authority must agree with the
            // requested target. When it is already restored, the live user choice is authority.
            if rawValue() == Action.nothing.rawValue, value.previous != previous { return false }
            legacyFingerprint = fileFingerprint
        case let .denied(fileFingerprint, error):
            guard error == EPERM || error == EACCES else { return false }
            legacyFingerprint = fileFingerprint
        case let .blocked(reason):
            kbLog("globe: legacy repair blocked: \(reason)")
            return false
        }
        // Journal is durable before the first CFPreferences mutation. A helper SIGKILL at any later
        // boundary is resumed receipt-first by the replacement helper before READY.
        guard writeRepairJournal(
            previous: previous, legacyFingerprint: legacyFingerprint
        ) else { return false }
        return recoverRepairJournal()
    }

    // MARK: - Helper transaction

    static var hasGuardReceipt: Bool {
        switch repairJournalState() {
        case .journal, .unsupported: return true
        case .absent: break
        }
        switch canonicalState() {
        case .receipt, .unsupported: return true
        case .absent: break
        }
        switch legacySnapshot() {
        case .absent, .retired: return false
        case .readable, .denied, .blocked: return true
        }
    }

    static func adoptReceiptForPersistentHelper() -> PersistentGlobeReceiptAdoption {
        guard PersistentResourceGuard.isHelperProcess else { return .blocked }
        switch repairJournalState() {
        case .absent: break
        case .unsupported: return .blocked
        case let .journal(journal, _, _):
            guard case .absent = canonicalState() else {
                kbLog("globe: journal + canonical authority одновременно — READY заблокирован")
                return .blocked
            }
            switch currentReceiptAuthority(owner: journal.owner) {
            case .ours, .orphaned: return .recovering
            case .liveOther: return .ownedElsewhere
            case .unknown: return .blocked
            }
        }
        switch canonicalState() {
        case .absent:
            switch legacySnapshot() {
            case .absent, .retired: return .none
            case .denied:
                // This inode belongs to the old GUI provenance. Holding the global flock blocks
                // ordinary startup while the exact parent is alive, but the helper has no authority
                // to mutate or retain it after that parent exits. A later explicit GLOBEFIX owns the
                // journaled repair transaction.
                return .protectedLegacy
            case .readable, .blocked:
                // Legacy provenance is resolved by the authenticated pre-READY migration command.
                return .blocked
            }
        case .unsupported:
            return .blocked
        case let .receipt(receipt, source, _):
            switch currentReceiptAuthority(owner: receipt.owner) {
            case .ours:
                // A clearing receipt means restore was already proved and durable removal had
                // started. Resume that cleanup; never treat the tombstone as a live acquisition.
                return source == clearingReceiptURL ? .recovering : .adopted
            case .liveOther: return .ownedElsewhere
            case .unknown: return .blocked
            case .orphaned:
                // Rewriting an orphaned clearing tombstone into the active path would create an
                // active+clearing pair and permanently block recovery. Keep the original inode and
                // finish its restore/clear transaction under the newly acquired global flock.
                if source == clearingReceiptURL { return .recovering }
                return writeReceipt(receipt.previous) ? .adopted : .blocked
            }
        }
    }

    /// Full acquire: helper reads the live previous value, writes+fsyncs receipt, then applies and
    /// verifies `.nothing`. GUI-provided caches never enter this transaction.
    static func armFromPersistentHelper() -> PersistentGlobeArmResult {
        guard PersistentResourceGuard.isHelperProcess else { return .blocked }
        switch adoptReceiptForPersistentHelper() {
        case .ownedElsewhere: return .ownedElsewhere
        case .blocked, .recovering, .protectedLegacy: return .blocked
        case .adopted:
            // A person may change the system role while Keyboop is running. Their non-zero choice
            // wins: remove our receipt without overwriting it and relinquish the lease.
            if current != .nothing {
                let now = rawValue() ?? -2
                guard validPrevious(now), refreshLegacyMarkerIfNeeded(verifiedPrevious: now),
                      clearCanonicalReceipt() else { return .blocked }
                return .noMutation
            }
            return .active
        case .none:
            break
        }
        let live = rawValue()
        if live == Action.nothing.rawValue {
            // No receipt means Keyboop did not create this state. Do not invent ownership.
            return .noMutation
        }
        let previous = live ?? -2
        guard validPrevious(previous), writeReceipt(previous) else { return .blocked }
        guard takeSystemRole() else {
            kbLog("globe: take не подтверждён; receipt+flock сохранены для restore retry")
            return .blocked
        }
        return .active
    }

    private static func refreshLegacyMarkerIfNeeded(verifiedPrevious: Int) -> Bool {
        switch legacySnapshot() {
        case .absent: return true
        case let .retired(fileFingerprint):
            return retireLegacy(
                fingerprint: fileFingerprint, verifiedPrevious: verifiedPrevious
            )
        case let .readable(_, fileFingerprint), let .denied(fileFingerprint, _):
            return retireLegacy(
                fingerprint: fileFingerprint, verifiedPrevious: verifiedPrevious
            )
        case let .blocked(reason):
            kbLog("globe: не обновил legacy marker перед clear: \(reason)")
            return false
        }
    }

    @discardableResult
    static func release() -> Bool {
        if !PersistentResourceGuard.isHelperProcess {
            kbLog("globe: отказал в release вне persistent helper")
            return false
        }
        switch repairJournalState() {
        case .absent: break
        case .journal:
            guard recoverRepairJournal() else { return false }
        case .unsupported:
            return false
        }
        switch canonicalState() {
        case .absent:
            return !hasGuardReceipt
        case .unsupported:
            return false
        case let .receipt(receipt, _, _):
            switch currentReceiptAuthority(owner: receipt.owner) {
            case .liveOther, .unknown: return false
            case .ours, .orphaned: break
            }
            if current == .nothing {
                guard applyPrevious(receipt.previous),
                      systemMatches(previous: receipt.previous) else {
                    kbLog("globe: restore не подтверждён; v3 receipt+flock сохранены")
                    return false
                }
            }
            let now = rawValue() ?? -2
            guard validPrevious(now),
                  refreshLegacyMarkerIfNeeded(verifiedPrevious: now),
                  clearCanonicalReceipt() else { return false }
            AppSettings.shared.globePrevFnUsage = -1
            kbLog("globe: helper вернул системную роль и долговечно снял v3 receipt")
            return true
        }
    }

    private static func takeSystemRole() -> Bool {
        guard PersistentResourceGuard.isHelperProcess else { return false }
        CFPreferencesSetValue(key, Action.nothing.rawValue as CFNumber, domain, user, host)
        CFPreferencesSynchronize(domain, user, host)
        applyLive(Action.nothing.rawValue)
        let ok = rawValue() == Action.nothing.rawValue
        kbLog("globe: helper take+verify — \(ok ? "ok" : "failed")")
        return ok
    }

    private static func applyPrevious(_ previous: Int) -> Bool {
        guard validPrevious(previous) else { return false }
        if previous == -2 {
            CFPreferencesSetValue(key, nil, domain, user, host)
            CFPreferencesSynchronize(domain, user, host)
            applyLive(Action.inputSource.rawValue)
        } else {
            CFPreferencesSetValue(key, previous as CFNumber, domain, user, host)
            CFPreferencesSynchronize(domain, user, host)
            applyLive(previous)
        }
        return systemMatches(previous: previous)
    }

    private static func systemMatches(previous: Int) -> Bool {
        previous == -2 ? rawValue() == nil : rawValue() == previous
    }

    static func releaseLegacyV1(
        watchedParent: ResourceGuardProcessIdentity, bootID: String
    ) -> Bool {
        guard case let .readable(value, fileFingerprint) = legacySnapshot(),
              let previous = value.previous else { return false }
        switch value {
        case let .v2(receipt):
            guard receipt.owner.process == watchedParent,
                  receipt.owner.bootID == bootID else { return false }
        case let .text(_, pid):
            guard pid == nil || pid == watchedParent.pid else { return false }
        case .unsupported:
            return false
        }
        if current == .nothing, !applyPrevious(previous) { return false }
        guard current != .nothing else { return false }
        // v1 cannot write the v3 marker because it does not own the persistent globe flock. It may
        // only remove the exact inode it read; any failure leaves it for the v3 migration path.
        let url = supportDirectory.appendingPathComponent(fileFingerprint.name)
        guard case let .success(now) = fingerprint(url), now == fileFingerprint else { return false }
        if unlink(url.path) != 0, errno != ENOENT { return false }
        return flushReceiptDirectory()
    }

    // MARK: - GUI command-only facade

    static var wanted: Bool {
        let settings = AppSettings.shared
        let instant = settings.instantSwitchEnabled && settings.instantSwitchMode == "globe"
        let manual = settings.hotkeyMode == "modkey" && settings.hotkeyKeyCode == 63
        return instant || manual
    }

    static var looksOrphaned: Bool { current == .nothing && !wanted }

    static func restoreSystemAction() {
        if !PersistentResourceGuard.repairGlobeSystem(previous: -2) {
            kbLog("globe: явный restore ещё не подтверждён helper; он продолжает retry")
        }
    }

    static func reconcile() {
        if wanted {
            guard GlobeGuard.ensure() else {
                kbLog("globe: helper не завершил arm — системную роль не считаю захваченной")
                return
            }
        } else if !GlobeGuard.stop() {
            kbLog("globe: helper ещё не завершил restore — receipt+flock сохранены")
        }
    }

#if RESOURCE_GUARD_TESTING
    static func testReceiptDataClassification(_ data: Data) -> String {
        if let current = try? JSONDecoder().decode(Receipt.self, from: data),
           current.isSemanticallyValid { return "current" }
        switch decodeLegacy(data) {
        case .v2, .text: return "legacy"
        case .unsupported: return "unsupported"
        }
    }

    static func testCurrentReceiptAuthority(_ data: Data) -> String {
        if let current = try? JSONDecoder().decode(Receipt.self, from: data),
           current.isSemanticallyValid {
            return currentReceiptAuthority(owner: current.owner).rawValue
        }
        if let legacy = try? JSONDecoder().decode(LegacyV2Receipt.self, from: data),
           legacy.isSemanticallyValid {
            return currentReceiptAuthority(owner: legacy.owner).rawValue
        }
        return "unsupported"
    }

    static func testExplicitCanonicalRepairDisposition(_ data: Data) -> String {
        decodeCurrentReceipt(data) == nil ? "blocked" : "cleanupThenRepair"
    }

    /// File-transaction hooks use the production parser, lstat/open identity checks, rename,
    /// directory fsync and unlink. They never read or write CFPreferences.
    static func testClearCanonicalReceiptFiles() -> Bool {
        clearCanonicalReceipt()
    }

    static func testClearRepairJournalFiles() -> Bool {
        switch repairJournalState() {
        case let .journal(_, source, fileFingerprint):
            return clearRepairJournal(source: source, fingerprint: fileFingerprint)
        case .absent:
            return true
        case .unsupported:
            return false
        }
    }

    static func testPersistentAdoptionDisposition() -> String {
        switch adoptReceiptForPersistentHelper() {
        case .none: return "none"
        case .adopted: return "adopted"
        case .recovering: return "recovering"
        case .protectedLegacy: return "protectedLegacy"
        case .ownedElsewhere: return "ownedElsewhere"
        case .blocked: return "blocked"
        }
    }
#endif
}
