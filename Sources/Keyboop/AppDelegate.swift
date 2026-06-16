import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var engine: Engine!
    private var menuBar: MenuBarController!
    private var settingsWC: SettingsWindowController?
    private var historyWC: VoiceHistoryWindowController?
    private var welcomeWC: WelcomeWindowController?
    private var retryTimer: Timer?
    private var engineRunning = false
    private var alertShown = false
    private var moveAlertShown = false    // алерт «перенеси в /Applications» (translocation) — показан
    private var relaunchOffered = false   // предложили перезапуск (TCC-залипание) — один раз
    private var retryTicks = 0            // тики ретрая без успешного старта (для relaunch-эскалации)
    private var axObserver: NSObjectProtocol?   // подписка на com.apple.accessibility.api (держать ссылку)
    private var updatedFrom: String?      // версия, с которой обновились (nil если первый запуск/та же)
    private var currentVersion = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine = Engine()
        menuBar = MenuBarController(layout: engine.layout)
        menuBar.onOpenSettings = { [weak self] in self?.openSettings() }
        menuBar.onShowVoiceHistory = { [weak self] in self?.openVoiceHistory() }
        menuBar.onCheckUpdates = { UpdaterController.shared.checkNow() }
        menuBar.onQuit = { NSApp.terminate(nil) }
        menuBar.onToggleAuto = { _ in }
        engine.onLayoutMaybeChanged = { [weak self] in self?.menuBar.refresh() }
        // Обучение на отмене: нативное уведомление macOS (баннер вверху справа, у часов — «от значка»)
        // + обновляем список «Выученные» в открытых настройках.
        UndoLearner.shared.onLearned = { [weak self] word in
            self?.notifyLearned(word)
            DispatchQueue.main.async { self?.settingsWC?.reload() }
        }
        VoiceController.shared.onStateChange = { [weak self] s in
            DispatchQueue.main.async { self?.menuBar.setVoiceState(s) }
        }
        VoiceController.shared.onNeedModel = { [weak self] in self?.promptModelDownload() }
        VoiceController.shared.preload()   // прогрев модели в фоне → первое нажатие диктовки без задержки

        // Версия прошлого запуска → текущая. Если это ОБНОВЛЕНИЕ и доступ off → вероятно протухший
        // grant после смены подписи (показываем спец-подсказку «убери и добавь заново», см.
        // showPermissionAlertOnce). Для Developer-ID→Developer-ID доступ не слетает → ветка не сработает.
        let curVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let prevVer = AppSettings.shared.lastRunVersion
        AppSettings.shared.lastRunVersion = curVer
        updatedFrom = (!prevVer.isEmpty && prevVer != curVer) ? prevVer : nil
        currentVersion = curVer

        kbLog("launched; v\(curVer) (prev \(prevVer.isEmpty ? "—" : prevVer)); AX=\(Permissions.isTrusted()) InputMon=\(Permissions.inputMonitoringGranted())")

        // Самый первый запуск: включаем автозапуск при входе в систему (дефолт-вкл).
        if !AppSettings.shared.didInitialSetup {
            AppSettings.shared.didInitialSetup = true
            AppSettings.shared.launchAtLogin = true
            kbLog("first run: launchAtLogin=\(AppSettings.shared.launchAtLogin)")
        }

        // Первый запуск: окно-приветствие (онбординг) — один раз.
        if !AppSettings.shared.didShowWelcome
            && ProcessInfo.processInfo.environment["KEYBOOP_DUMP"] != "1"
            && ProcessInfo.processInfo.environment["KEYBOOP_WINSHOT"] != "1"
            && ProcessInfo.processInfo.environment["KEYBOOP_WELCOMESHOT"] != "1" {
            AppSettings.shared.didShowWelcome = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.showWelcome() }
        }

        // Новый пользователь: заранее (один раз) просим доступ к микрофону, чтобы диктовка
        // сразу работала, а не «молчала». Раньше доступ спрашивался лениво — только при
        // первом нажатии хоткея И при установленной модели, поэтому промпт часто не появлялся.
        if AppSettings.shared.voiceEnabled,
           AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                Task { _ = await AudioRecorder.requestAccess() }
            }
        }

        // НЕ просим доступ безусловно на каждом старте (это долбит системным диалогом).
        // Сначала тихо проверяем (AXIsProcessTrusted) — если доступ уже есть, ничего не
        // показываем. Если нет — tryStart() один раз аккуратно попросит. (см. showPermissionAlertOnce)

        // Устойчивый подхват доступа БЕЗ перезапуска приложения. Два механизма вместе (как AltTab):
        //  (1) подписка на com.apple.accessibility.api — мгновенная реакция на выдачу галки;
        //  (2) поллинг-бэкстоп 0.5 c — на случай, если уведомление не стрельнуло (его тайминг
        //      не охарактеризован). Сам старт пробуем через engine.start() (живой tapCreate), а НЕ
        //      через залипающий AXIsProcessTrusted() — см. tryStart().
        tryStart()
        axObserver = Permissions.observeAXChanges { [weak self] in self?.tryStart() }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            if self.engineRunning { t.invalidate(); return }
            self.tryStart()
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer

        // Автообновления (Sparkle): по умолчанию спрашиваем НАШИМ баннером (две кнопки, AppBanner —
        // без системных уведомлений), тихо — только если юзер выбрал «авто». Под dev-рендер-хуками
        // не стартуем (без сетевых проверок).
        UpdaterController.shared.onUpdateReady = { [weak self] v in self?.notifyUpdateReady(v) }
        let env = ProcessInfo.processInfo.environment
        if env["KEYBOOP_DUMP"] != "1", env["KEYBOOP_WINSHOT"] != "1",
           env["KEYBOOP_LIVEDIAG"] != "1", env["KEYBOOP_HISTDUMP"] != "1" {
            UpdaterController.shared.start()
        }

        // Dev-хук: открыть окно настроек сразу (для скриншотов/отладки дизайна).
        if ProcessInfo.processInfo.environment["KEYBOOP_OPEN_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                self.openSettings()
                let names = ["switching", "exceptions", "snippets", "translate", "voice", "general", "updates", "privacy", "about"]
                for (i, name) in names.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 * Double(i + 1)) {
                        self.settingsWC?.dump(section: i, to: "/tmp/kb_\(name).pdf")
                    }
                }
            }
        }
        // Dev-хук: отрендерить все разделы настроек в PNG и выйти.
        if ProcessInfo.processInfo.environment["KEYBOOP_DUMP"] == "1" {
            kbLog("DUMP: hook armed")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self = self else { return }
                kbLog("DUMP: opening settings")
                if self.settingsWC == nil { self.settingsWC = SettingsWindowController() }
                self.settingsWC?.show()
                let names = ["switching", "exceptions", "snippets", "translate", "voice", "general", "updates", "privacy", "about"]
                for (i, name) in names.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 * Double(i + 1)) {
                        kbLog("DUMP: section \(i) \(name)")
                        self.settingsWC?.dump(section: i, to: "/tmp/kb_\(name).pdf")
                        if i == names.count - 1 {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
                        }
                    }
                }
            }
        }
        // Dev-хук: снимок ВСЕГО окна настроек (sidebar+detail, тёмная тема) по секциям и выход.
        if ProcessInfo.processInfo.environment["KEYBOOP_WINSHOT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self = self else { return }
                if self.settingsWC == nil { self.settingsWC = SettingsWindowController() }
                self.settingsWC?.show()
                let secs: [(Int, String)] = [(0, "switching"), (3, "voice"), (4, "privacy"), (2, "snippets"), (6, "updates")]
                for (k, pair) in secs.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45 * Double(k + 1)) {
                        self.settingsWC?.dumpFullWindow(section: pair.0, to: "/tmp/kbwin_\(pair.1).png")
                        if k == secs.count - 1 {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
                        }
                    }
                }
            }
        }
        // Dev-хук: живая диагностика переноса подписей в ШИРОКОМ окне (без forced-layout) и выход.
        if ProcessInfo.processInfo.environment["KEYBOOP_LIVEDIAG"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self = self else { return }
                if self.settingsWC == nil { self.settingsWC = SettingsWindowController() }
                self.settingsWC?.show(section: .voice)   // самый длинный раздел — мерим высоту/скролл
                // ждём естественного settle окна (НЕ форсим layout), потом читаем кадры
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.settingsWC?.liveDiag(to: "/tmp/kb_live_privacy.txt")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
                }
            }
        }
        // Dev-хук: снимок окна истории голосового набора (демо-записи) и выход.
        if ProcessInfo.processInfo.environment["KEYBOOP_HISTDUMP"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self = self else { return }
                let wc = VoiceHistoryWindowController()
                self.historyWC = wc
                wc.show()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    wc.dumpWithSamples(to: "/tmp/kb_history.png")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
                }
            }
        }
        // Dev-хук: показать окно знакомства и записать его window-id (cacheDisplay не захватывает
        // AVPlayerLayer → реальный рендер снимаем из bash через screencapture -l<id>). Живём ~12с.
        if ProcessInfo.processInfo.environment["KEYBOOP_WELCOMESHOT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self = self else { return }
                self.showWelcome()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    if let win = self.welcomeWC?.window {
                        try? "\(win.windowNumber)".write(toFile: "/tmp/kb_welcome_winid.txt", atomically: true, encoding: .utf8)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 12.0) { NSApp.terminate(nil) }
            }
        }
        // Dev-хук: off-screen рендер образца баннера на ОБОИХ языках и выход (визуальная проверка).
        if ProcessInfo.processInfo.environment["KEYBOOP_BANNERSHOT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                AppSettings.shared.language = "ru"
                AppBanner.shared.renderSample(to: "/tmp/kb_banner_ru.png")
                AppSettings.shared.language = "en"
                AppBanner.shared.renderSample(to: "/tmp/kb_banner_en.png")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
            }
        }
    }

    private func tryStart() {
        guard !engineRunning else { return }

        // App Translocation: .app запущен из эфемерного рандомизированного пути (DMG/Downloads).
        // Грант Accessibility к нему не привяжется (путь исчезнет при перезапуске) — стартовать
        // бессмысленно. Просим переехать в /Applications, а не долбим Accessibility у нестабильного
        // экземпляра. Это одна из причин «заработало только после reboot» (см. Permissions.isTranslocated).
        if Permissions.isTranslocated() {
            menuBar.needsPermission = true
            menuBar.refresh()
            showMoveToApplicationsAlertOnce()
            return
        }

        // КЛЮЧЕВОЕ: НЕ гейтим на AXIsProcessTrusted() — он залипает на false в живом процессе после
        // выдачи доступа (macOS 13+ баг). Пробуем поднять tap напрямую: tapCreate внутри engine.start()
        // вернёт не-nil РОВНО когда Accessibility реально выдан СЕЙЧАС — это живой детектор без TCC-кэша.
        if engine.start() {
            engineRunning = true
            retryTicks = 0
            menuBar.needsPermission = false
            menuBar.refresh()
            kbLog("engine STARTED ok (AX=\(Permissions.isTrusted()) InputMon=\(Permissions.inputMonitoringGranted()))")
            retryTimer?.invalidate()
            if let obs = axObserver { DistributedNotificationCenter.default().removeObserver(obs); axObserver = nil }
            return
        }

        // tap не поднялся → Accessibility пока нет (или TCC ещё не пропускает живой процесс).
        menuBar.needsPermission = true
        menuBar.refresh()
        showPermissionAlertOnce()   // один раз, НЕ блокирует ретрай (async)

        // Эскалация: галка Accessibility уже стоит, но tap несколько секунд всё равно не встаёт —
        // это TCC-залипание живого процесса, ретраем его не пробить. Предлагаем перезапуск приложения
        // (НЕ перезагрузку компьютера) — единственный надёжный способ против залипания.
        retryTicks += 1
        if Permissions.isTrusted() && retryTicks >= 6 && !relaunchOffered {
            relaunchOffered = true
            offerRelaunch()
        }
    }

    private func showPermissionAlertOnce() {
        guard !alertShown else { return }
        // При dev-хуках (дамп/открытие настроек) не блокируем main runloop модальным алертом.
        let env = ProcessInfo.processInfo.environment
        if env["KEYBOOP_DUMP"] == "1" || env["KEYBOOP_OPEN_SETTINGS"] == "1" { return }
        alertShown = true
        // Системный prompt — на первом запуске, ДО показа нашего алерта и ВНЕ модального цикла.
        if updatedFrom == nil { Permissions.requestTrust() }
        // КРИТИЧНО: алерт показываем АСИНХРОННО. Блокирующий runModal() из retry-пути морозил бы
        // главный runloop → retry-таймер и подписка на доступ не работали бы, пока висит окно
        // (это и давало «доступ выдал, но заработало только после перезапуска»).
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            if let from = self.updatedFrom {
                // ОБНОВЛЕНИЕ + доступа нет → почти наверняка протухший grant после смены подписи
                // (доступ показан включённым, но не действует). Нужно ПЕРЕсоздать запись.
                alert.messageText = "После обновления переразреши Keyboop"
                alert.informativeText = """
                Похоже, ты обновил Keyboop (\(from) → \(self.currentVersion)). Из-за смены подписи доступ к \
                Accessibility мог «протухнуть»: в списке он показан включённым, но не действует.

                Почини один раз: System Settings → Privacy & Security → Accessibility → выдели Keyboop, \
                нажми «−» (убрать), затем добавь заново «+» (или перетащи Keyboop в список).

                Это разовое — дальнейшие обновления доступ сохранят.
                """
            } else {
                alert.messageText = "Keyboop нужен доступ к Accessibility"
                alert.informativeText = """
                Включи Keyboop в System Settings → Privacy & Security → Accessibility.
                Как включишь — переключение раскладки заработает сразу, перезапускать не нужно.
                """
            }
            alert.addButton(withTitle: "Открыть Accessibility")
            alert.addButton(withTitle: "Позже")
            if alert.runModal() == .alertFirstButtonReturn {
                Permissions.openAccessibilitySettings()
            }
        }
    }

    /// App Translocation: .app запущен из временного пути (DMG/Downloads). Просим перенести в
    /// /Applications — иначе грант Accessibility не переживёт перезапуск. Показываем один раз, async.
    private func showMoveToApplicationsAlertOnce() {
        guard !moveAlertShown else { return }
        let env = ProcessInfo.processInfo.environment
        if env["KEYBOOP_DUMP"] == "1" || env["KEYBOOP_OPEN_SETTINGS"] == "1" { return }
        moveAlertShown = true
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Перенеси Keyboop в «Программы»"
            a.informativeText = """
            Keyboop запущен из временной папки (образа .dmg или «Загрузок»), поэтому macOS не сохранит \
            за ним доступ к Accessibility, и переключение раскладки работать не будет.

            Перетащи Keyboop.app в «Программы» и запусти уже оттуда — тогда всё заработает и не слетит.
            """
            a.addButton(withTitle: "Показать в Finder")
            a.addButton(withTitle: "Позже")
            if a.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Bundle.main.bundlePath)])
            }
        }
    }

    /// TCC-залипание: галка Accessibility стоит, но живой процесс её не видит. Перезапуск приложения
    /// (НЕ компьютера) это чинит. Предлагаем один раз, async.
    private func offerRelaunch() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Перезапустить Keyboop?"
            a.informativeText = """
            Доступ к Accessibility выдан, но macOS не подхватил его для текущего сеанса \
            (известная особенность системы). Один перезапуск Keyboop это чинит — \
            перезагружать компьютер не нужно.
            """
            a.addButton(withTitle: "Перезапустить")
            a.addButton(withTitle: "Не сейчас")
            if a.runModal() == .alertFirstButtonReturn {
                let url = URL(fileURLWithPath: Bundle.main.bundlePath)
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.createsNewApplicationInstance = true
                NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                }
            }
        }
    }

    /// Повторный запуск уже работающего приложения (двойной клик по .app, пока оно
    /// крутится в фоне как агент) — macOS не плодит второй экземпляр, а зовёт это.
    /// Открываем настройки, чтобы клик не «проваливался в пустоту».
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    /// Нативное уведомление macOS при обучении на отмене — баннер вверху справа (у часов, «от значка»).
    /// Авторизацию спрашиваем ЛЕНИВО (только когда реально что-то выучили) — не долбим новичка лишним
    /// промптом. Локально, без сети (принцип №2). Если запрещено — тихо (слово и так в «Выученных»).
    /// «Выучил слово» — НАШ баннер (не системное уведомление), сам скрывается через 4с.
    private func notifyLearned(_ word: String) {
        AppBanner.shared.show(title: "Keyboop", body: String(format: L10n.t("learn.toast"), word), autoDismiss: 4)
    }

    /// Готов апдейт → НАШ баннер вверху справа с двумя кнопками (без системных уведомлений и их
    /// запроса разрешений — по просьбе Ивана). Ждёт решения; «Обновить» ставит, «Авто» включает тихий
    /// режим. Закрыл/проигнорировал — переспросит на следующей проверке (или поставится при выходе).
    private func notifyUpdateReady(_ version: String) {
        AppBanner.shared.show(
            title: String(format: L10n.t("upd.notifyTitle"), version),
            body: L10n.t("upd.notifyBody"),
            actions: [
                .init(title: L10n.t("upd.now"), coral: true) { UpdaterController.shared.installPendingNow() },
                .init(title: L10n.t("upd.autoShort"), coral: false) { UpdaterController.shared.enableSilentAndInstall() }
            ]
        )
    }

    private func promptModelDownload() {
        let alert = NSAlert()
        alert.messageText = L10n.t("voice.needModelTitle")
        alert.informativeText = L10n.t("voice.needModelBody")
        alert.addButton(withTitle: L10n.t("voice.needModelOpen"))
        alert.addButton(withTitle: L10n.t("voice.needModelLater"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { openSettings(section: .voice) }
    }

    private func showWelcome() {
        if welcomeWC == nil {
            welcomeWC = WelcomeWindowController()
            welcomeWC?.onOpenSettings = { [weak self] in self?.openSettings() }
        }
        welcomeWC?.show()
    }

    private func openSettings(section: SettingsSection? = nil) {
        if settingsWC == nil { settingsWC = SettingsWindowController() }
        settingsWC?.show(section: section)
    }
    private func openVoiceHistory() {
        if historyWC == nil {
            historyWC = VoiceHistoryWindowController()
            historyWC?.onOpenVoiceSettings = { [weak self] in self?.openSettings(section: .voice) }
        }
        historyWC?.show()
    }
}
