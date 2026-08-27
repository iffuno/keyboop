import AppKit
import Sparkle

/// Sparkle's normal progress and error UI, with only the update decision replaced by our banner.
/// The decision is returned to Sparkle while it can still persist `.skip`; after downloading there
/// is no supported way to cancel installation-on-quit.
@MainActor
private final class KeyboopUpdateUserDriver: NSObject, SPUUserDriver {
    private let standard = SPUStandardUserDriver(hostBundle: .main, delegate: nil)
    weak var owner: UpdaterController?
    private var pendingChoice: ((SPUUserUpdateChoice) -> Void)?
    private var installApproved = false

    func show(_ request: SPUUpdatePermissionRequest) async -> SUUpdatePermissionResponse {
        await standard.show(request)
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        standard.showUserInitiatedUpdateCheck(cancellation: cancellation)
    }

    func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState) async -> SPUUserUpdateChoice {
        // Informational-only releases have a link instead of an install payload; keep Sparkle's UI.
        guard !item.isInformationOnlyUpdate else {
            return await standard.showUpdateFound(with: item, state: state)
        }

        // A manual check may have opened Sparkle's small checking window. It must go away before
        // our decision banner appears; later progress is intentionally quiet until relaunch.
        standard.dismissUpdateInstallation()
        return await withCheckedContinuation { continuation in
            // Defensive only: Sparkle should never ask twice in one session. Resolving the earlier
            // question avoids leaving an update cycle parked if that invariant ever changes.
            resolve(.dismiss)
            pendingChoice = { continuation.resume(returning: $0) }
            let version = item.displayVersionString
            AppBanner.shared.show(
                title: String(format: L10n.t("upd.availableTitle"), version),
                body: L10n.t("upd.availableBody"),
                actions: [
                    .init(title: L10n.t("upd.now"), coral: false) { [weak self] in
                        self?.resolve(.install)
                    },
                    .init(title: L10n.t("upd.autoShort"), coral: true) { [weak self] in
                        self?.owner?.enableSilentUpdates()
                        self?.resolve(.install)
                    }
                ],
                onClose: { [weak self] in self?.resolve(.skip) },
                onDismiss: { [weak self] in self?.resolve(.dismiss) }
            )
        }
    }

    /// Used when the automatic-update setting is enabled while an update question is visible.
    func approvePresentedUpdate() -> Bool {
        guard pendingChoice != nil else { return false }
        resolve(.install)
        AppBanner.shared.dismiss()
        return true
    }

    private func resolve(_ choice: SPUUserUpdateChoice) {
        guard let reply = pendingChoice else { return }
        pendingChoice = nil
        installApproved = (choice == .install)
        reply(choice)
    }

    func showUpdateReleaseNotes(with data: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error) async { await showResult(error) }
    func showUpdaterError(_ error: Error) async { await showResult(error) }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {}
    func showDownloadDidReceiveExpectedContentLength(_ length: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() {}
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReadyToInstallAndRelaunch() async -> SPUUserUpdateChoice {
        installApproved ? .install : await standard.showReadyToInstallAndRelaunch()
    }
    func showInstallingUpdate(withApplicationTerminated terminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {}
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool) async {}
    func dismissUpdateInstallation() {
        resolve(.dismiss)
        installApproved = false
        AppBanner.shared.dismiss()
        standard.dismissUpdateInstallation()
    }
    func showUpdateInFocus() { NSApp.activate(ignoringOtherApps: true) }

    private func showResult(_ error: Error) async {
        standard.dismissUpdateInstallation()
        let e = error as NSError
        let body = e.localizedRecoverySuggestion ?? e.localizedFailureReason ?? ""
        await withCheckedContinuation { continuation in
            var finished = false
            let finish = {
                guard !finished else { return }
                finished = true
                continuation.resume()
            }
            AppBanner.shared.show(title: e.localizedDescription, body: body, autoDismiss: 8,
                                  onClose: finish, onDismiss: finish)
        }
    }
}

/// Автообновления через Sparkle.
///
/// Поведение: проверка, предварительное скачивание и тихая установка — три отдельных уровня.
/// Без предварительного скачивания крестик возвращает Sparkle `.skip` до загрузки файла.
///   • «Обновить сейчас» → ставим эту версию.
///   • «Мгновенные обновления» → Sparkle скачивает заранее и поэтому установит файл при выходе.
///   • «Обновлять автоматически» → дальше ставим ТИХО в простое (когда юзер отошёл), не мешая.
///
/// Приватность: профайлинг выключен, `feedParametersForUpdater` НЕ реализован → ровно один GET за
/// appcast + GET за DMG, без профиля/идентификатора. Подлинность — EdDSA + Developer ID.
final class UpdaterController: NSObject, SPUUpdaterDelegate {
    static let shared = UpdaterController()

    private var updater: SPUUpdater?
    private var userDriver: KeyboopUpdateUserDriver?
    private var pendingInstall: (() -> Void)?       // установка уже скачанного мгновенного обновления
    private(set) var pendingVersion = ""
    private let idleThreshold: TimeInterval = 300    // 5 минут простоя для тихой установки
    private var lastDeferReason: String?             // чтобы не писать одну и ту же причину отказа в лог

    func start() {
        guard updater == nil else { return }
        let driver = KeyboopUpdateUserDriver()
        driver.owner = self
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        userDriver = driver
        self.updater = updater
        do { try updater.start() }
        catch {
            kbLog("updater: не запустился — \(error.localizedDescription)")
            self.updater = nil; userDriver = nil
            return
        }
        // ⚠️ В dev-режиме отладки апдейтера (KEYBOOP_UPDATER=1) скачивание ЗАПРЕЩЕНО: пусть Sparkle
        // спрашивает фид и пишет в лог, но не приносит прод-DMG в dev-бандл (инцидент 23.07).
        let debugDev = (Bundle.main.bundleIdentifier ?? "").hasSuffix(".dev")
        updater.automaticallyDownloadsUpdates = automaticChecks && AppSettings.shared.instantUpdates && !debugDev
        kbLog("updater: started (check=\(automaticChecks) instant=\(AppSettings.shared.instantUpdates)"
              + " silent=\(AppSettings.shared.silentAutoUpdate)"
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
            guard let u = self?.updater, u.automaticallyChecksForUpdates else { return }
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
        get { updater?.automaticallyChecksForUpdates ?? true }
        set {
            updater?.automaticallyChecksForUpdates = newValue
            updater?.automaticallyDownloadsUpdates = newValue && AppSettings.shared.instantUpdates && !isDevBuild
        }
    }

    private var isDevBuild: Bool { (Bundle.main.bundleIdentifier ?? "").hasSuffix(".dev") }

    /// Проверить вручную («Проверить сейчас» / меню). Sparkle сам показывает окно «Проверяю…» → результат
    /// («Установлена последняя версия» либо предложение обновиться). НО мы — LSUIElement-агент без иконки
    /// в доке: без явной активации это окно НЕ выходит вперёд, и юзеру кажется, что «ничего не произошло»
    /// (фидбэк 16.06). Поэтому активируем приложение прямо перед проверкой.
    func checkNow() {
        NSApp.activate(ignoringOtherApps: true)
        if pendingInstall != nil, AppSettings.shared.silentAutoUpdate {
            kbLog("updater: проверка вручную при тихо загруженном \(pendingVersion) — ставлю сейчас")
            installPendingNow()
            return
        }
        updater?.checkForUpdates()
    }

    /// Install an update Sparkle downloaded through the explicitly enabled automatic path.
    private func installPendingNow() {
        IdleMonitor.shared.stop()
        guard let block = pendingInstall else { return }
        pendingInstall = nil
        kbLog("updater: ставлю \(pendingVersion) в тихом режиме")
        block()
    }

    /// The banner's right button opts into future automatic downloads before installing this one.
    func enableSilentUpdates() {
        AppSettings.shared.instantUpdates = true
        AppSettings.shared.silentAutoUpdate = true
        automaticChecks = true
        kbLog("updater: пользователь выбрал тихие автообновления")
    }

    /// The pre-download switch changes Sparkle's runtime behavior immediately. It cannot undo an
    /// update that Sparkle has already downloaded; that update remains scheduled for app quit.
    func noteInstantModeChanged() {
        updater?.automaticallyDownloadsUpdates = automaticChecks && AppSettings.shared.instantUpdates && !isDevBuild
        kbLog("updater: мгновенные обновления = \(AppSettings.shared.instantUpdates)")
        if pendingInstall == nil { updater?.resetUpdateCycle() }
    }

    /// Тумблер «бета-версии» переключили — перезаводим цикл, иначе смена канала доедет только к
    /// следующей плановой проверке (а у агента в строке меню она может быть через сутки).
    func noteChannelChanged() {
        kbLog("updater: канал = \(AppSettings.shared.betaChannel ? "beta" : "стабильный")")
        updater?.resetUpdateCycle()
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
        let latestItem = e.userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem
        let latest = latestItem?.displayVersionString
        kbLog("updater: апдейта нет — \(why)\(latest.map { ", свежайшая в фиде \($0)" } ?? "")")
        offerBetaIfNewerExists(latestItem)
    }

    /// «У ВАС ПОСЛЕДНЯЯ ВЕРСИЯ», КОГДА НОВЕЕ ЕСТЬ, НО ОНА БЕТА (задача 107).
    ///
    /// Это не баг, но выглядит багом, и в отзыве это видно построчно: человек честно нажимает
    /// «Проверить обновления», Sparkle честно отвечает «установлена последняя версия», а на сайте в
    /// это же время лежит версия новее. Он делает единственный доступный вывод: обновления сломаны.
    /// Правда же в том, что новее только бета, а бета-канал у него выключен, и об этом ему никто не
    /// сказал ни словом.
    ///
    /// Поэтому после ответа «нечего ставить» мы смотрим, что за версия лежит в фиде самой свежей.
    /// Если она НОВЕЕ нашей, значит существует сборка, которую мы сознательно не берём, и человеку
    /// про неё говорим сами, вместе с кнопкой включить бета-канал.
    ///
    /// ⚠️ ЧЕСТНО ПРО ГРАНИЦУ ЗНАНИЯ. Отдаёт ли Sparkle в `SPULatestAppcastItemFoundKey` сборку из
    /// ЧУЖОГО канала или уже отфильтрованную, из документации не следует, а проверить это можно
    /// только на живой бете новее нашей: сейчас такой в фиде нет. Код написан так, что оба ответа
    /// безопасны. Пришла версия новее — говорим о ней. Пришла отфильтрованная (не новее) — молчим,
    /// как молчали раньше, и ни одного ложного сообщения не появляется. Проверить на следующем же
    /// бета-релизе: `Tools/updateprobe` умеет притвориться клиентом любой версии.
    private func offerBetaIfNewerExists(_ latest: SUAppcastItem?) {
        guard !AppSettings.shared.betaChannel else { return }   // человек и так на бете, говорить не о чем
        guard let latest, let ver = latest.displayVersionString as String? else { return }
        let mine = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard ver.compare(mine, options: .numeric) == .orderedDescending else { return }
        kbLog("updater: в фиде есть \(ver), новее нашей \(mine), но бета-канал выключен — предлагаю включить")
        DispatchQueue.main.async {
            AppBanner.shared.show(
                title: L10n.t("upd.betaExistsTitle"),
                body: String(format: L10n.t("upd.betaExistsBody"), ver),
                actions: [.init(title: L10n.t("upd.betaExistsYes"), coral: true) {
                    AppSettings.shared.betaChannel = true
                    NotificationCenter.default.post(name: .updaterStatusChanged, object: nil)
                    UpdaterController.shared.checkNow()
                }])
        }
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
        UpdaterController.shared.updater?.lastUpdateCheckDate
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

    /// An update reaches this delegate only after the opt-in pre-download path has fetched it.
    /// Sparkle will install that file on quit. We retain the immediate block so the banner can
    /// install now, or the silent mode can wait for five minutes of real idle time.
    @objc(updater:willInstallUpdateOnQuit:immediateInstallationBlock:)
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        pendingVersion = item.displayVersionString
        let silent = AppSettings.shared.silentAutoUpdate
        kbLog("updater: \(pendingVersion) скачан, готов к установке (silent=\(silent))")
        pendingInstall = immediateInstallHandler
        if silent {
            kbLog("updater: жду 5 минут простоя, чтобы поставить \(pendingVersion) тихо")
            IdleMonitor.shared.waitForIdle(threshold: idleThreshold) { [weak self] in self?.installWhenClear() }
        } else {
            showReadyBanner()
        }
        return true
    }

    private func showReadyBanner() {
        AppBanner.shared.show(
            title: String(format: L10n.t("upd.notifyTitle"), pendingVersion),
            body: L10n.t("upd.notifyBody"),
            actions: [
                .init(title: L10n.t("upd.now"), coral: false) { [weak self] in self?.installPendingNow() },
                .init(title: L10n.t("upd.autoShort"), coral: true) { [weak self] in
                    self?.enableSilentUpdates()
                    self?.installPendingNow()
                }
            ],
            onClose: { [weak self] in self?.deferDownloadedUpdate() },
            onDismiss: { [weak self] in self?.deferDownloadedUpdate() }
        )
    }

    /// Closing or replacing the ready banner cannot cancel Sparkle's install-on-quit commitment.
    /// Release our immediate handler and resume the cycle; the setting explains this consequence.
    private func deferDownloadedUpdate() {
        guard pendingInstall != nil else { return }
        pendingInstall = nil
        kbLog("updater: готовое обновление отложено до выхода из Keyboop")
        updater?.resetUpdateCycle()
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
        updater?.automaticallyDownloadsUpdates = automaticChecks && AppSettings.shared.instantUpdates && !isDevBuild
        lastDeferReason = nil
        if pendingInstall != nil { showReadyBanner() }
    }

    /// Тумблер «обновлять тихо» включили при уже показанном или загруженном апдейте: видимый вопрос
    /// подтверждаем, а загруженную автоматическую установку снова ставим в ожидание простоя.
    func noteSilentModeEnabled() {
        automaticChecks = true
        if userDriver?.approvePresentedUpdate() == true {
            kbLog("updater: включили тихий режим при показанном апдейте — начинаю установку")
            return
        }
        guard pendingInstall != nil else {
            updater?.resetUpdateCycle()
            return
        }
        kbLog("updater: включили тихий режим при готовом апдейте — жду простоя")
        IdleMonitor.shared.waitForIdle(threshold: idleThreshold) { [weak self] in self?.installWhenClear() }
    }
}
