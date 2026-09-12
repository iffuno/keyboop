import AppKit
import Carbon

extension NSPasteboard {
    /// ⚠️ ОБЯЗАННОСТЬ КАЖДОЙ НАШЕЙ ЗАПИСИ В БУФЕР: сразу после записи отметить её changeCount.
    /// Иначе история буфера (задача 228) запишет нашу служебную операцию как «скопированный текст»
    /// человека. Многошаговые операции (⌘C → чтение → восстановление) дополнительно заворачиваются
    /// в `PasteboardOwnership.beginOwnedWindow()` / `endOwnedWindow()`, см. `SelectionText`.
    func kbNoteOurs() { PasteboardOwnership.note(changeCount) }
}

/// Наблюдатель буфера обмена для единой истории (задача 228).
///
/// У `NSPasteboard` нет уведомлений об изменении, поэтому, как и все менеджеры буфера, опрашиваем
/// `changeCount` по таймеру: раз в полсекунды одно целое число из pboard-сервера, дешевле любого
/// нашего AX-чтения. Содержимое читается только когда счётчик сдвинулся, и только если запись
/// вообще возможна: под Secure Input текст не читается вовсе, не то что не сохраняется.
///
/// Изменение принимается не сразу, а на следующем тике, если счётчик не сдвинулся снова. Так
/// пропускаются промежуточные состояния (программа пишет в буфер в несколько шагов) и наши
/// собственные операции успевают отметиться в `PasteboardOwnership`.
///
/// Наблюдатель живёт только при включённом тумблере: выключенный по умолчанию захват не стоит
/// машине ни одного вызова.
final class ClipboardWatcher {
    static let shared = ClipboardWatcher()
    private var timer: Timer?
    private var lastSeen = 0
    private var pending: Int?
    private var lastSkipNote: (reason: ClipboardCapturePolicy.Reason, at: TimeInterval)?
    private let interval: TimeInterval = 0.5
    private init() {}

    var isRunning: Bool { timer != nil }

    /// Привести наблюдатель в соответствие с настройками. Зовётся на старте и из тумблеров
    /// «Хранить историю» и «Запоминать скопированный текст».
    func apply() {
        let s = AppSettings.shared
        if s.voiceHistoryEnabled && s.clipboardHistoryEnabled { start() } else { stop() }
    }

    private func start() {
        guard timer == nil else { return }
        // Не забираем то, что уже лежит в буфере: человек скопировал это до того, как включил
        // захват, и согласия на ту запись не давал.
        lastSeen = NSPasteboard.general.changeCount
        pending = nil
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        kbLog("буфер: история буфера включена")
    }

    private func stop() {
        guard let t = timer else { return }
        t.invalidate(); timer = nil; pending = nil
        kbLog("буфер: история буфера выключена")
    }

    private func tick() {
        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != lastSeen else { pending = nil; return }
        // Наша многошаговая операция ещё идёт: не смотрим, вернёмся после её конца.
        if PasteboardOwnership.inOwnedWindow { pending = nil; return }
        guard pending == count else { pending = count; return }
        pending = nil
        lastSeen = count

        let secure = IsSecureEventInputEnabled()
        let types = (pb.pasteboardItems ?? []).flatMap { $0.types.map(\.rawValue) }
        let text = secure ? nil : pb.string(forType: .string)
        let snap = ClipboardCapturePolicy.Snapshot(changeCount: count, types: types, text: text)
        let verdict = ClipboardCapturePolicy.verdict(snap,
                                                     ownChangeCounts: PasteboardOwnership.ownCounts(),
                                                     inOwnedWindow: false,
                                                     secureInput: secure,
                                                     lastStored: VoiceHistory.shared.lastClipboardText)
        switch verdict {
        case .store(let s):
            let app = NSWorkspace.shared.frontmostApplication?.localizedName
            VoiceHistory.shared.addClipboard(s, app: app)
            kbLog("буфер: записано \(s.count) симв.")   // только длина, не текст (принцип №2)
        case .skip(let reason):
            noteSkip(reason)
        }
    }

    /// Причины пропуска в лог, но без спама: `ours` и `duplicate` это норма, их не пишем; остальные
    /// не чаще раза в десять секунд на причину. Под залипшим Secure Input каждое копирование
    /// иначе давало бы строку.
    private func noteSkip(_ reason: ClipboardCapturePolicy.Reason) {
        guard reason != .ours, reason != .duplicate else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastSkipNote, last.reason == reason, now - last.at < 10 { return }
        lastSkipNote = (reason, now)
        kbLog("буфер: пропущено (\(reason.rawValue))")
    }
}
