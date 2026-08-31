import Darwin

/// Compatibility trap for an internal, never-released v2 argument vector. New builds only spawn
/// the persistent v3 helper. Keeping this tiny parser prevents an old invocation from reaching
/// AppKit without retaining a second callable guard lifecycle in the production target.
enum ResourceGuard {
    static func runIfRequested(parentPID: pid_t) -> Bool {
        _ = parentPID
        return CommandLine.arguments.contains("--resource-guard-v2")
    }
}

extension GlobeGuard {
    static func acquireSlap() -> Bool { PersistentResourceGuard.acquireSlap() }
    static func confirmSlapGrowth() -> Bool { PersistentResourceGuard.confirmSlapGrowth() }

    @discardableResult
    static func releaseSlap() -> Bool { PersistentResourceGuard.releaseSlap() }

    static func finishNormally() { PersistentResourceGuard.finishNormally() }
}
