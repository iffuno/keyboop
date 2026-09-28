import Cocoa

/// КЛАВИАТУРНЫЙ ФОКУС У НАКЛАДНОЙ ПАНЕЛИ, А НЕ У ПЕРЕДНЕГО ПРИЛОЖЕНИЯ (задача 21, 28.09.2026).
///
/// Raycast, Alfred, Launchpad и похожие панели принимают ввод, не становясь передним приложением:
/// `NSWorkspace.frontmostApplication` остаётся программой под панелью. События на annotated идут
/// именно переднему приложению, поэтому при соседнем тапе (`RivalTapWatch`) замена уезжала в окно
/// под панелью. Лог 0.4.10: «selection: AX, 5 симв., com.raycast.macos (спереди
/// com.anthropic.claudefordesktop)», а соседом был сам Raycast (его активный тап на hid).
///
/// Spotlight закрывает `SpotlightWatch`, но заводить наблюдатель на каждую панель не нужно: сама
/// система через Accessibility знает, чей элемент в фокусе. Если его pid не совпадает с передним
/// приложением, annotated доставит текст не туда, и синтетику надо слать с hid, как до 0.4.8.
enum OverlayFocusWatch {

    /// Ответ живёт 250 мс: `synthPostTap` читается на каждое событие, а AX-запрос это синхронный
    /// IPC. За одну замену фокус никуда не уходит.
    private static var cached = false
    private static var checkedAt: TimeInterval = -1
    private static let ttl: TimeInterval = 0.25
    private static let lock = NSLock()

    /// Фокус ввода принадлежит не переднему приложению. Не удалось спросить — `false`, то есть
    /// прежнее поведение.
    static var focusIsElsewhere: Bool {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        if now - checkedAt < ttl { return cached }
        checkedAt = now
        cached = scan()
        return cached
    }

    private static func scan() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let owner = focusedElementPid() else { return report(nil) }
        guard owner != front else { return report(nil) }
        let bid = NSRunningApplication(processIdentifier: owner)?.bundleIdentifier ?? "pid \(owner)"
        return report(bid)
    }

    /// ⚠️ Таймаут 50 мс, как во всех наших AX-чтениях (см. `SecureInputPolicy.focusedFieldVerdict`).
    private static func focusedElementPid() -> pid_t? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.05)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedAny = focusedRef, CFGetTypeID(focusedAny) == AXUIElementGetTypeID() else { return nil }
        let el = unsafeDowncast(focusedAny as AnyObject, to: AXUIElement.self)
        var pid: pid_t = 0
        guard AXUIElementGetPid(el, &pid) == .success, pid > 0 else { return nil }
        return pid
    }

    /// В лог только смену вердикта, как у `RivalTapWatch`.
    private static var lastReported: String?? = .none
    private static func report(_ owner: String?) -> Bool {
        if lastReported != .some(owner) {
            lastReported = .some(owner)
            if let owner {
                kbLog("фокус у накладной панели \(owner), а не у переднего приложения — синтетика идёт с hid")
            }
        }
        return owner != nil
    }
}
