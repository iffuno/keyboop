import AppKit
#if canImport(Translation)
import SwiftUI
import Translation

/// Перевод текста on-device через Apple Translation framework (macOS 15+).
/// Ноль сетевых запросов в рантайме после первичной загрузки языкового пака (её делает
/// СИСТЕМА по явному системному промпту — честный opt-in). Без модели и линковки.
/// API доступен только через SwiftUI `.translationTask`, поэтому держим скрытый NSHostingView.
@available(macOS 15.0, *)
@MainActor
final class TranslationEngine {
    static let shared = TranslationEngine()
    private var window: NSWindow?
    private let model = TranslateModel()

    /// Перевести строку. from/to — коды языков ("ru"/"en"). nil — если не вышло.
    /// ВСЕГДА молча, БЕЗ какого-либо видимого окна. Окно-хост существует только невидимым
    /// off-screen — нужно SwiftUI-lifecycle, чтобы срабатывал `.translationTask`. Если пакет
    /// не скачан — не дёргаем систему (промпт всё равно не показать без видимого окна, а оно
    /// виснет): возвращаем nil, пользователь качает пакет в Настройках → Перевод.
    func translate(_ text: String, from: String, to: String) async -> String? {
        guard await isInstalled(from: from, to: to) else {
            kbLog("translate: пакет \(from)→\(to) не установлен — нужны «Системные настройки» в Настройках → Перевод")
            return nil
        }
        ensureHost()
        return await withTimeout(8) { [model] in await model.translate(text: text, from: from, to: to) }
    }

    /// Установлен ли языковой пакет для пары (для UI настроек). true = .installed.
    func isInstalled(from: String, to: String) async -> Bool {
        let s = await LanguageAvailability().status(from: Locale.Language(identifier: from),
                                                    to: Locale.Language(identifier: to))
        switch s { case .installed: return true; default: return false }
    }

    private var downloadWindow: NSWindow?

    /// Явная докачка языковых пакетов ПО КНОПКЕ (кнопка в настройках / действие баннера).
    /// Ключевое: показываем МАЛЕНЬКОЕ ВИДИМОЕ окно на время докачки. Системный лист скачивания
    /// Apple («Download “Russian”?» + прогресс) привязывается к ВИДИМОМУ view приложения — на
    /// off-screen окне (наш translate-хост) он не может показаться и всё виснет. Отсюда и решение.
    /// Пары готовим последовательно (ru→en, затем en→ru), чтобы работали оба направления сразу.
    func presentDownload(pairs: [(from: String, to: String)], completion: @escaping (Bool) -> Void) {
        if downloadWindow != nil { return }                 // уже открыто — не плодим окна
        let dl = PackDownloader()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 160),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.title = L10n.t("tr.dlTitle")
        w.isReleasedWhenClosed = false
        w.center()
        w.contentView = NSHostingView(rootView: PackDownloadHost(model: dl, pairs: pairs))
        downloadWindow = w
        dl.onFinish = { [weak self, weak w] installed in
            w?.close()
            self?.downloadWindow = nil
            completion(installed)
        }
        NSApp.activate(ignoringOtherApps: true)             // агент из меню-бара — иначе окно не выйдет вперёд
        w.makeKeyAndOrderFront(nil)
    }

    /// Выполнить async-операцию с жёстким таймаутом: по истечении — отменяем модель
    /// (резолвим континуацию nil), чтобы вызывающий не завис.
    private func withTimeout(_ seconds: Double, _ op: @escaping () async -> String?) async -> String? {
        let watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { kbLog("translate: таймаут \(Int(seconds))с — отмена"); self?.model.cancel() }
        }
        let r = await op()
        watchdog.cancel()
        return r
    }

    private func ensureHost() {
        guard window == nil else { return }
        // Невидимое borderless-окно строго за экраном — НИКОГДА не показывается пользователю.
        // Нужно лишь чтобы жил SwiftUI-lifecycle и срабатывал `.translationTask` для уже
        // установленных пар. Никаких промптов/прогресса тут не показываем (это виснет).
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.alphaValue = 0; w.ignoresMouseEvents = true
        w.contentView = NSHostingView(rootView: TranslateHost(model: model))
        w.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        w.orderFrontRegardless()
        window = w
    }
}

@available(macOS 15.0, *)
@MainActor final class TranslateModel: ObservableObject {
    @Published var config: TranslationSession.Configuration?
    private var pending: CheckedContinuation<String?, Never>?
    private var text = ""
    private var lastFrom = ""
    private var lastTo = ""

    func translate(text: String, from: String, to: String) async -> String? {
        if pending != nil { pending?.resume(returning: nil); pending = nil }  // не залипаем на прошлом
        return await withCheckedContinuation { cont in
            self.text = text
            self.pending = cont
            // КЛЮЧЕВОЕ: та же пара языков → Configuration «равна» прежней, и .translationTask
            // НЕ перезапустится. Поэтому при повторе той же пары дёргаем invalidate() (штатный
            // способ перезапустить сессию); при смене направления — создаём новую конфигурацию.
            if config != nil, from == lastFrom, to == lastTo {
                config?.invalidate()
            } else {
                lastFrom = from; lastTo = to
                config = TranslationSession.Configuration(
                    source: Locale.Language(identifier: from),
                    target: Locale.Language(identifier: to))
            }
        }
    }

    /// Прервать висящую операцию (таймаут / закрытие окна / отмена) — резолвим континуацию nil.
    func cancel() {
        if let cont = pending { pending = nil; cont.resume(returning: nil) }
    }

    func run(_ session: TranslationSession) async {
        guard let cont = pending else { kbLog("translate: run без pending"); return }
        pending = nil
        do {
            // prepareTranslation триггерит системную докачку языкового пакета (честный opt-in),
            // если пара ещё не установлена. На уже установленной — мгновенно.
            try await session.prepareTranslation()
            let r = try await session.translate(text)
            kbLog("translate: run → \(r.targetText.count) симв.")   // переведённый текст в лог не пишем
            cont.resume(returning: r.targetText)
        } catch {
            kbLog("translate: ошибка \(error)")
            cont.resume(returning: nil)
        }
    }
}

@available(macOS 15.0, *)
private struct TranslateHost: View {
    @ObservedObject var model: TranslateModel
    var body: some View {
        // Невидимая точка — окно никогда не показывается; нужен только живой translationTask.
        Color.clear
            .translationTask(model.config) { session in
                await model.run(session)
            }
    }
}

// MARK: - Докачка языкового пакета (видимое окно, чтобы системный лист скачивания смог показаться)

@available(macOS 15.0, *)
@MainActor final class PackDownloader: ObservableObject {
    @Published var config: TranslationSession.Configuration?
    private var queue: [(from: String, to: String)] = []
    private var idx = 0
    private var anyFailed = false
    var onFinish: ((Bool) -> Void)?

    func start(_ pairs: [(from: String, to: String)]) {
        guard queue.isEmpty else { return }                 // старт один раз (onAppear может дёрнуться повторно)
        queue = pairs; idx = 0; anyFailed = false
        advance()
    }
    private func advance() {
        guard idx < queue.count else { onFinish?(!anyFailed); onFinish = nil; return }
        let p = queue[idx]
        // Смена config → .translationTask перезапускается с новой парой (пары различны, перезапуск гарантирован).
        config = TranslationSession.Configuration(source: Locale.Language(identifier: p.from),
                                                  target: Locale.Language(identifier: p.to))
    }
    func step(_ session: TranslationSession) async {
        let cur = idx < queue.count ? queue[idx] : (from: "?", to: "?")
        do {
            // prepareTranslation триггерит системный лист докачки (если пары нет) — честный opt-in.
            try await session.prepareTranslation()
            kbLog("pack: подготовлен \(cur.from)→\(cur.to)")
        } catch {
            anyFailed = true
            kbLog("pack: не докачан \(cur.from)→\(cur.to) — \(error)")
        }
        idx += 1
        advance()
    }
}

@available(macOS 15.0, *)
private struct PackDownloadHost: View {
    @ObservedObject var model: PackDownloader
    let pairs: [(from: String, to: String)]
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(L10n.t("tr.dlBody"))
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
        // config выставляется в start() (из onAppear) — гарантируем, что view уже смонтирован.
        .translationTask(model.config) { session in
            await model.step(session)
        }
        .onAppear { model.start(pairs) }
    }
}
#endif

/// Определение направления RU↔EN по содержимому (кириллица → ru→en, иначе en→ru).
enum TranslateDirection {
    static func of(_ text: String) -> (from: String, to: String) {
        let hasCyr = text.unicodeScalars.contains { $0.value >= 0x0400 && $0.value <= 0x04FF }
        return hasCyr ? ("ru", "en") : ("en", "ru")
    }
}
