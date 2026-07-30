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
    private var lastDeferReason: String?             // чтобы не писать одну и ту же причину отказа в лог

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

    /// Поставить отложенный апдейт сейчас (кнопка «Обновить сейчас»).
    ///
    /// Тихий режим: у нас на руках `immediateInstallHandler` — подменяем и перезапускаем сами.
    /// Обычный режим: handler'а нет и быть не может (мы вернули `false`, см. делегат), поэтому
    /// отдаём человека штатному окну Sparkle. Апдейт уже скачан, так что это один клик, а не
    /// повторная загрузка.
    func installPendingNow() {
        IdleMonitor.shared.stop()
        guard let block = pendingInstall else {
            kbLog("updater: показываю штатное окно установки \(pendingVersion)")
            checkNow()
            return
        }
        pendingInstall = nil
        kbLog("updater: ставлю \(pendingVersion) по запросу пользователя")
        block()
    }

    /// Включить тихий режим и поставить текущий (кнопка «Обновлять автоматически»).
    func enableSilentAndInstall() {
        AppSettings.shared.silentAutoUpdate = true
        kbLog("updater: пользователь выбрал тихие автообновления")
        installPendingNow()
    }

    /// Тумблер «бета-версии» переключили — перезаводим цикл, иначе смена канала доедет только к
    /// следующей плановой проверке (а у агента в строке меню она может быть через сутки).
    func noteChannelChanged() {
        kbLog("updater: канал = \(AppSettings.shared.betaChannel ? "beta" : "стабильный")")
        controller?.updater.resetUpdateCycle()
    }

    // MARK: SPUUpdaterDelegate

    /// В какие каналы нам разрешено смотреть.
    ///
    /// Механика Sparkle (`SPUUpdaterDelegate.h:90-113`): элемент appcast без `<sparkle:channel>`
    /// лежит в канале по умолчанию и виден ВСЕМ, а помеченный `beta` — только тем, у кого «beta»
    /// есть в этом наборе. Канал по умолчанию входит в разрешённые ВСЕГДА, поэтому бета-участник
    /// продолжает получать и обычные релизы: он видит строго больше, а не другое.
    ///
    /// Зачем это вообще: приложение стоит перехватчиком клавиатуры у всех сразу, и 0.2.70 появился
    /// ровно потому, что глотание клавиш убивало пробел во всей системе. Обкатка на добровольцах
    /// ловит такой класс на десятках людей вместо тысяч.
    /// ⚠️ Селектор пришпилен явно. Методы `SPUUpdaterDelegate` необязательные, и Sparkle зовёт их
    /// через ObjC-протокол: если бы Swift переименовал метод хоть на букву иначе, компилятор бы
    /// промолчал, а канал просто никогда не спрашивался. То есть тумблер «бета» стоял бы в
    /// настройках и не делал ничего — молчаливый отказ, а их мы в этом проекте ловим весь день.
    @objc(allowedChannelsForUpdater:)
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        AppSettings.shared.betaChannel ? ["beta"] : []
    }

    // MARK: Видимость проверки в логе
    //
    // ⚠️ До 29.07 в логе было ровно две строки на всю жизнь апдейтера: «started» при запуске и
    // «скачан» уже перед установкой. Между ними — ничего. Поэтому жалоба «у меня не обновляется»
    // была принципиально неразбираемой: мы не знали даже, ходило ли приложение за фидом. Разбор
    // 29.07 пришлось вести по системному логу macOS (CFNetwork + os_log Sparkle), которого у
    // пользователя в отчёте нет и быть не может. Ниже — весь путь проверки, по строке на событие,
    // словами. Ни версии текста, ни адресов, ни идентификаторов — только наши же номера версий.

    @objc(updater:didFinishLoadingAppcast:)
    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        let top = appcast.items.first?.displayVersionString ?? "?"
        kbLog("updater: фид получен, записей \(appcast.items.count), верхняя \(top)")
    }

    @objc(updater:didFindValidUpdate:)
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        kbLog("updater: найден апдейт \(item.displayVersionString)\(item.isCriticalUpdate ? " (критический)" : "")")
    }

    @objc(updaterDidNotFindUpdate:error:)
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        let e = error as NSError
        // Sparkle кладёт сюда ПРИЧИНУ отказа. Без неё «апдейта нет» неотличимо от «мы его отбраковали».
        let why: String
        switch e.userInfo[SPUNoUpdateFoundReasonKey] as? Int {
        case Int(SPUNoUpdateFoundReason.onLatestVersion.rawValue):          why = "у нас уже свежая"
        case Int(SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue): why = "у нас новее, чем в фиде"
        case Int(SPUNoUpdateFoundReason.systemIsTooOld.rawValue):           why = "версия требует более новой macOS"
        case Int(SPUNoUpdateFoundReason.systemIsTooNew.rawValue):           why = "версия помечена как несовместимая с этой macOS"
        case Int(SPUNoUpdateFoundReason.hardwareDoesNotSupportARM64.rawValue): why = "версия только для Apple Silicon"
        default:                                                             why = "причина не указана"
        }
        let latest = (e.userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem)?.displayVersionString
        kbLog("updater: апдейта нет — \(why)\(latest.map { ", свежайшая в фиде \($0)" } ?? "")")
    }

    @objc(updater:willDownloadUpdate:withRequest:)
    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        kbLog("updater: качаю \(item.displayVersionString)")
    }

    @objc(updater:failedToDownloadUpdate:error:)
    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        kbLog("updater: не скачалось \(item.displayVersionString) — \(error.localizedDescription)")
    }

    @objc(updater:willScheduleUpdateCheckAfterDelay:)
    func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        kbLog("updater: следующая проверка через \(Int(delay / 60)) мин")
    }

    /// Любой обрыв цикла проверки. `noUpdateError` — это не обрыв, а нормальный ответ «нечего ставить»,
    /// его уже написал `updaterDidNotFindUpdate`, второй раз не дублируем.
    @objc(updater:didAbortWithError:)
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let e = error as NSError
        guard e.code != Int(SUError.noUpdateError.rawValue) else { return }
        kbLog("updater: проверка сорвалась — \(e.localizedDescription) (код \(e.code))")
    }

    /// Sparkle скачал апдейт и готов ставить. Перехватываем: либо тихо в простое (если юзер выбрал
    /// «авто»), либо спрашиваем нашим уведомлением.
    ///
    /// ⚠️ ВОЗВРАЩАЕМОЕ ЗНАЧЕНИЕ ЗДЕСЬ РЕШАЕТ СУДЬБУ ВСЕХ БУДУЩИХ ПРОВЕРОК (найдено ревью 28.07,
    /// подтверждено хедером `SPUUpdaterDelegate.h:424-431`). Раньше мы возвращали `true` ВСЕГДА,
    /// а по документации это значит «я беру установку на себя», и Sparkle в ответ
    /// «stalls the current update cycle and prevents future update cycles from running».
    /// То есть у человека с настройками ПО УМОЛЧАНИЮ (тихая установка выключена) всё выглядело так:
    /// скачался один апдейт, показалась плашка, он её закрыл — и плановые проверки прекратились
    /// НАВСЕГДА. Приложение живёт в строке меню неделями, так что молча застревало на той версии.
    /// Комментарий «переспросит на следующей проверке» в AppDelegate обещал ровно то, чего уже не
    /// могло случиться.
    ///
    /// Теперь по документации: `true` только когда мы действительно держим установку у себя
    /// (тихий режим). В обычном режиме `false` — плашку показываем свою, но расписание остаётся за
    /// Sparkle: он и переспросит сам, и критические апдейты покажет сразу.
    /// `immediateInstallHandler` при `false` использовать НЕЛЬЗЯ (хедер, строка 437), поэтому в этой
    /// ветке мы его даже не сохраняем — кнопка «Обновить сейчас» идёт через обычную проверку.
    /// ⚠️ Селектор пришпилен, как и у `allowedChannels`, и по той же причине: метод необязательный,
    /// зовётся через ObjC. Разъедься имя на букву — компилятор смолчит, Sparkle поставит апдейт
    /// молча при выходе, а наше уведомление «Обновить сейчас» не покажется никогда. Симптом при этом
    /// ровно тот, с которым к нам приходят: «оно не обновляется само».
    @objc(updater:willInstallUpdateOnQuit:immediateInstallationBlock:)
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        pendingVersion = item.displayVersionString
        let silent = AppSettings.shared.silentAutoUpdate
        kbLog("updater: \(pendingVersion) скачан, готов к установке (silent=\(silent))")
        guard silent else {
            pendingInstall = nil
            DispatchQueue.main.async { [weak self] in self?.onUpdateReady?(self?.pendingVersion ?? "") }
            return false
        }
        // Юзер выбрал «авто» → ставим тихо, когда отошёл (5 мин без ввода, не идёт диктовка/окно).
        pendingInstall = immediateInstallHandler
        IdleMonitor.shared.waitForIdle(threshold: idleThreshold) { [weak self] in self?.installWhenClear() }
        return true
    }

    /// Тихая установка только когда реально никто не мешает.
    ///
    /// ⚠️ Отказ ПЕРЕВЗВОДИТ ожидание простоя (28.07). Раньше отказ был тупиком: ждали простоя один
    /// раз, при занятости молча выходили — и апдейт висел до перезапуска приложения. Плюс ни строки
    /// в лог, из-за чего этот путь и был невидим при разборе.
    private func installWhenClear() {
        guard pendingInstall != nil else { return }
        // ⚠️ Тумблер могли ВЫКЛЮЧИТЬ уже после того, как мы взвели ожидание (найдено ревью 28.07:
        // человек включил тихий режим, дочитал подпись, передумал — а мы через 5 минут молча
        // подменяли бинарь и перезапускались вопреки явному «нет»). Правило проекта: установка
        // только с согласия пользователя.
        guard AppSettings.shared.silentAutoUpdate else {
            IdleMonitor.shared.stop()
            return
        }
        // Причины отказа. Модель качается без возобновления (до 1.6 ГБ), а перезапуск её убьёт;
        // запись хоткея держит движок отключённым, перезапуск посреди неё — гарантированная путаница.
        let reason: String?
        if VoiceController.shared.isRecording { reason = "идёт диктовка" }
        else if ModelDownloader.shared.downloadingName != nil { reason = "качается модель" }
        else if HotkeyRecording.active { reason = "идёт запись комбинации" }
        else if NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeKey }) { reason = "открыто окно" }
        else { reason = nil }
        guard let reason else { installPendingNow(); return }
        // ⚠️ Логируем только СМЕНУ причины. Ожидание перевзводится каждые ~20с, и строка на каждый
        // отказ забивала бы лог целиком: за сутки это сотни килобайт, а в багрепорт уходит хвост
        // из 300 строк — то есть шум вытеснил бы всё полезное (найдено ревью 28.07).
        if reason != lastDeferReason {
            lastDeferReason = reason
            kbLog("updater: тихая установка отложена (\(reason)) — жду простоя снова")
        }
        IdleMonitor.shared.waitForIdle(threshold: idleThreshold) { [weak self] in self?.installWhenClear() }
    }

    /// Тумблер тихих обновлений выключили — гасим ожидание простоя.
    func cancelSilentWait() {
        IdleMonitor.shared.stop()
        lastDeferReason = nil
    }

    /// Тумблер «обновлять тихо» включили, когда апдейт УЖЕ скачан и ждёт.
    /// Без этого он продолжал бы ждать нашего уведомления, которого в тихом режиме не будет.
    ///
    /// Если handler'а на руках нет, значит на этот апдейт мы уже ответили Sparkle «ставь сам»
    /// (обычный режим). Взять его обратно нельзя, поэтому просто перезаводим цикл: Sparkle
    /// переспросит, и следующий апдейт придёт уже в тихом режиме.
    func noteSilentModeEnabled() {
        guard pendingInstall != nil else {
            controller?.updater.resetUpdateCycle()
            return
        }
        kbLog("updater: включили тихий режим при готовом апдейте — жду простоя")
        IdleMonitor.shared.waitForIdle(threshold: idleThreshold) { [weak self] in self?.installWhenClear() }
    }
}
