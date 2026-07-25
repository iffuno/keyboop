import AppKit
import Sparkle

/// Автообновления через Sparkle.
///
/// Поведение (security review 15.06 + выбор автора): проверка и фоновое скачивание ВКЛ по умолчанию,
/// но УСТАНОВКА по умолчанию — с согласия пользователя. Sparkle качает апдейт тихо и зовёт делегат
/// `willInstallUpdateOnQuit`; мы его перехватываем (return true, держим install-блок) и вместо тихой
/// подмены показываем СВОЁ уведомление «Обновить сейчас / Обновлять автоматически».
///   • «Обновить сейчас» → ставим эту версию.
///   • «Обновлять автоматически» → `silentAutoUpdate=true`; дальше ставим ТИХО в простое (когда юзер
///     отошёл), не мешая. Так пользователь сам выбирает тихий режим — молча у всех мы не ставим.
///
/// Приватность: профайлинг выключен, `feedParametersForUpdater` НЕ реализован → ровно один GET за
/// appcast + GET за DMG, без профиля/идентификатора. Подлинность — EdDSA + Developer ID.
final class UpdaterController: NSObject, SPUUpdaterDelegate {
    static let shared = UpdaterController()

    private var controller: SPUStandardUpdaterController?
    private var pendingInstall: (() -> Void)?       // immediateInstallHandler от Sparkle, ждёт решения
    private(set) var pendingVersion = ""
    private let idleThreshold: TimeInterval = 300    // 5 минут простоя для тихой установки

    /// Колбэк в AppDelegate: показать наше уведомление, что версия `$0` готова к установке.
    var onUpdateReady: ((String) -> Void)?

    func start() {
        guard controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        controller?.updater.automaticallyDownloadsUpdates = automaticChecks   // качаем заранее, если проверки вкл
        kbLog("updater: started (check=\(automaticChecks) silent=\(AppSettings.shared.silentAutoUpdate))")
    }

    /// Мастер-тумблер «Проверять обновления» (Sparkle хранит стейт в UserDefaults сам).
    var automaticChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? true }
        set {
            controller?.updater.automaticallyChecksForUpdates = newValue
            controller?.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    /// Проверить вручную («Проверить сейчас» / меню). Sparkle сам показывает окно «Проверяю…» → результат
    /// («Установлена последняя версия» либо предложение обновиться). НО мы — LSUIElement-агент без иконки
    /// в доке: без явной активации это окно НЕ выходит вперёд, и юзеру кажется, что «ничего не произошло»
    /// (фидбэк 16.06). Поэтому активируем приложение прямо перед проверкой.
    func checkNow() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    /// Поставить отложенный апдейт сейчас (кнопка «Обновить сейчас»). Тихая подмена + relaunch.
    func installPendingNow() {
        guard let block = pendingInstall else { return }
        pendingInstall = nil
        IdleMonitor.shared.stop()
        kbLog("updater: ставлю \(pendingVersion) по запросу пользователя")
        block()
    }

    /// Включить тихий режим и поставить текущий (кнопка «Обновлять автоматически»).
    func enableSilentAndInstall() {
        AppSettings.shared.silentAutoUpdate = true
        kbLog("updater: пользователь выбрал тихие автообновления")
        installPendingNow()
    }

    // MARK: SPUUpdaterDelegate

    /// Sparkle скачал апдейт и готов ставить. Перехватываем: либо тихо в простое (если юзер выбрал
    /// «авто»), либо спрашиваем нашим уведомлением.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        pendingInstall = immediateInstallHandler
        pendingVersion = item.displayVersionString
        kbLog("updater: \(pendingVersion) скачан, готов к установке (silent=\(AppSettings.shared.silentAutoUpdate))")
        if AppSettings.shared.silentAutoUpdate {
            // Юзер выбрал «авто» → ставим тихо, когда отошёл (5 мин без ввода, не идёт диктовка/окно).
            IdleMonitor.shared.waitForIdle(threshold: idleThreshold) { [weak self] in self?.installWhenClear() }
        } else {
            DispatchQueue.main.async { [weak self] in self?.onUpdateReady?(self?.pendingVersion ?? "") }
        }
        return true   // установку контролируем мы (Sparkle сам не ставит, кроме как при выходе из app)
    }

    /// Тихая установка только когда реально никто не мешает.
    private func installWhenClear() {
        guard pendingInstall != nil else { return }
        if VoiceController.shared.isRecording { return }
        if NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeKey }) { return }
        installPendingNow()
    }
}
