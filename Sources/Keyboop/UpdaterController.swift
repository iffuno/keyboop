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
        // ⚠️ В dev-режиме отладки апдейтера (KEYBOOP_UPDATER=1) скачивание ЗАПРЕЩЕНО: пусть Sparkle
        // спрашивает фид и пишет в лог, но не приносит прод-DMG в dev-бандл (инцидент 23.07).
        let debugDev = (Bundle.main.bundleIdentifier ?? "").hasSuffix(".dev")
        controller?.updater.automaticallyDownloadsUpdates = automaticChecks && !debugDev
        kbLog("updater: started (check=\(automaticChecks) silent=\(AppSettings.shared.silentAutoUpdate)"
              + (debugDev ? ", DEV: скачивание запрещено" : "") + ")")

        // ПРОВЕРКА ПРИ ЗАПУСКЕ (просьба автора 30.07). Сам Sparkle этого не делает: он помнит время
        // прошлой проверки (SULastCheckTime переживает перезапуск) и досиживает ОСТАТОК интервала.
        // В логе это видно дословно — «launched» и сразу «следующая проверка через 119 мин», то есть
        // запуск проверку не вызвал. Для человека, который открыл Мак утром, разницы нет: интервал
        // давно истёк и проверка случится сама. А вот «вышел и зашёл» её не даёт, и релиз, вышедший
        // десять минут назад, ждёт лишние два часа без причины.
        //
        // Задержка в 25 секунд намеренная: старт и так занят прогревом модели распознавания и
        // установкой тапа, лезть туда же с сетью незачем. Пользователь этой секунды не замечает.
        guard automaticChecks else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            guard let u = self?.controller?.updater, u.automaticallyChecksForUpdates else { return }
            // Не дублируем Sparkle. Если интервал к моменту запуска уже истёк, он проверяет сам, и
            // тогда наша проверка была бы вторым запросом за полминуты (наблюдалось при отладке
            // 30.07: его проверка в 08:55:47, наша в 08:56:12). Спрашиваем у него самого, когда он
            // ходил в последний раз, вместо того чтобы вести свой счёт.
            if let last = u.lastUpdateCheckDate, Date().timeIntervalSince(last) < 300 {
                kbLog("updater: проверку при запуске пропускаю — Sparkle только что проверял сам")
                return
            }
            kbLog("updater: проверка при запуске")
            u.checkForUpdatesInBackground()
        }
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

    /// Как долго держим у себя право установить, если человек не нажал ни одной кнопки в плашке.
    /// По истечении — отпускаем и перезаводим цикл Sparkle, иначе плановые проверки не возобновятся
    /// (см. большой комментарий в делегате). Десять минут: плашка живёт на экране куда меньше.
    private let pendingTTL: TimeInterval = 600
    private var pendingSafety: DispatchWorkItem?

    /// Страховка от «плашку закрыли, а установку никто не позвал». Без неё возврат `true` из делегата
    /// убивает ВСЕ будущие проверки обновлений — тот самый механизм, из-за которого люди сидят на
    /// 0.2.69 до сих пор.
    private func armPendingSafety() {
        pendingSafety?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pendingInstall != nil else { return }
            self.pendingInstall = nil
            kbLog("updater: плашку \(self.pendingVersion) не тронули за \(Int(self.pendingTTL / 60)) мин — "
                  + "отпускаю установку и перезавожу расписание")
            self.controller?.updater.resetUpdateCycle()
        }
        pendingSafety = work
        DispatchQueue.main.asyncAfter(deadline: .now() + pendingTTL, execute: work)
    }

    /// Поставить отложенный апдейт сейчас (левая кнопка плашки, «Обновить»).
    ///
    /// Обработчик установки у нас на руках в ЛЮБОМ режиме (см. делегат), поэтому ставим и
    /// перезапускаемся сразу, без второго окна и без повторного вопроса. Ветка с `checkNow()` ниже
    /// остаётся только на случай, когда обработчика нет: например плашка провисела дольше pendingTTL
    /// и мы уже отпустили установку, а человек нажал кнопку на старой плашке.
    func installPendingNow() {
        pendingSafety?.cancel(); pendingSafety = nil
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
    /// Последний сбой проверки обновлений: текст для человека и когда случился. `nil` — всё в порядке.
    ///
    /// ⚠️ ЗАВЕДЕНО, ПОТОМУ ЧТО СБОЙ БЫЛ МОЛЧАЛИВЫМ (03.08.2026). Раньше эта функция только писала в
    /// лог, и человек не узнавал ничего: жмёт «Проверить обновления», а в ответ тишина. Ровно так
    /// выглядела жалоба («скачал с сайта, пару дней обновлялось, потом перестало, нажимаю проверить
    /// и ничего не происходит») и ровно это видно в отчёте с Intel-мака, где в логе висело
    /// «код 1005» — Sparkle отказывался обновлять приложение, запущенное не из «Программ».
    ///
    /// Причин, по которым проверка срывается, много и все они снаружи: нет сети, VPN режет домен,
    /// корпоративный фильтр, антивирус, запуск не из «Программ». Мы ни одну из них не исправим,
    /// но человек ОБЯЗАН узнать, что обновления не работают, иначе он месяцами сидит на старой
    /// версии и жалуется на давно починенное. Половина нашей почты именно такая.
    static private(set) var lastFailure: (text: String, at: Date)?

    /// Когда в последний раз проверка ЗАВЕРШИЛАСЬ УСПЕШНО (неважно, нашла обновление или нет).
    /// По ней считаем «давно не проверялось»: одиночный сбой это шум, две недели тишины это поломка.
    static var lastSuccessfulCheck: Date? {
        UpdaterController.shared.controller?.updater.lastUpdateCheckDate
    }

    /// Сколько дней тишины считаем поводом сказать вслух. Неделя: при интервале в два часа это
    /// восемьдесят с лишним неудачных попыток подряд, случайностью такое уже не объяснить.
    static let staleAfterDays = 7

    /// Проверки не проходят достаточно долго, чтобы об этом сказать.
    static var updatesLookBroken: Bool {
        // Сам выключил проверки — не наше дело напоминать.
        guard UpdaterController.shared.automaticChecks else { return false }
        guard let last = lastSuccessfulCheck else { return lastFailure != nil }
        return Date().timeIntervalSince(last) > Double(staleAfterDays) * 86400
    }

    @objc(updater:didAbortWithError:)
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let e = error as NSError
        guard e.code != Int(SUError.noUpdateError.rawValue) else { return }
        kbLog("updater: проверка сорвалась — \(e.localizedDescription) (код \(e.code))")
        Self.lastFailure = (e.localizedDescription, Date())
        DispatchQueue.main.async { NotificationCenter.default.post(name: .updaterStatusChanged, object: nil) }
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
            // ⚠️ ТЕПЕРЬ ДЕРЖИМ УСТАНОВКУ У СЕБЯ И В ОБЫЧНОМ РЕЖИМЕ (30.07, просьба автора).
            // Раньше здесь было `pendingInstall = nil; return false`, и кнопка «Обновить» в нашей
            // плашке не могла поставить апдейт сама — она отдавала человека штатному окну Sparkle,
            // где надо было нажать «обновить» ВТОРОЙ раз. автор прошёл этот путь вживую и попросил
            // убрать лишний шаг: одна кнопка, одно нажатие, приложение перезапускается.
            //
            // Но `true` здесь означает «я беру установку на себя», и Sparkle в ответ паркует не
            // только текущий цикл, но и ВСЕ БУДУЩИЕ проверки. Именно так люди застревали на 0.2.69
            // навсегда: плашку закрыли, обработчик никто не позвал, расписание умерло. Поэтому
            // держать обработчик можно ТОЛЬКО вместе со страховкой, которая ниже: не позвали за
            // pendingTTL — отпускаем установку и перезаводим цикл. Без неё не возвращать true.
            pendingInstall = immediateInstallHandler
            armPendingSafety()
            DispatchQueue.main.async { [weak self] in self?.onUpdateReady?(self?.pendingVersion ?? "") }
            return true
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
