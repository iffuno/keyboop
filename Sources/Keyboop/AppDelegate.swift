import AppKit
import AVFoundation
import Carbon   // AppleEvent-константы (kAEOpenApplication / keyAELaunchedAsLogInItem) для детекта ручного запуска

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var engine: Engine!
    private var menuBar: MenuBarController!
    private var settingsWC: SettingsWindowController?
    private var historyWC: VoiceHistoryWindowController?
    private var welcomeWC: WelcomeWindowController?
    private var retryTimer: Timer?
    private var engineRunning = false
    /// Уже написали в лог, что ждём Accessibility (иначе строка повторялась бы дважды в секунду).
    private var loggedWaitingForAX = false
    private var alertShown = false
    private var moveAlertShown = false    // алерт «перенеси в /Applications» (translocation) — показан
    private var relaunchOffered = false   // предложили перезапуск (TCC-залипание) — один раз
    private var retryTicks = 0            // тики ретрая без успешного старта (для relaunch-эскалации)
    private var axObserver: NSObjectProtocol?   // подписка на com.apple.accessibility.api (держать ссылку)

    // MARK: - Сторож живости движка (31.07.2026)
    //
    // ⚠️ ПОЧЕМУ ЭТО ВООБЩЕ НУЖНО. `engineRunning` — защёлка в ОДНУ сторону: ставится в true на
    // успешном старте и до сегодняшнего дня не сбрасывалась никогда. Сразу после первого успеха мы
    // гасим и ретрай-таймер, и подписку на TCC. То есть всё, что умеет поднимать движок, выключается
    // навсегда — при том, что тап вполне может умереть ПОЗЖЕ: отозвали и вернули Accessibility,
    // умер mach-порт, система выключила тап, а событие `.tapDisabled*` до нас не доехало.
    // Итог: приложение молча мертво до ручного перезапуска, и человек видит ровно то же, что при
    // любой другой поломке — тишину. Это и есть класс жалоб «перестало работать, помогает только
    // выход». Живой пробник `AppHealth.isEngineLive` у нас есть с 28.07, но его никто не спрашивал,
    // кроме строки меню, то есть диагноз был, а лечения не было.
    //
    // Своим таймером, а не тиком строки меню: жизненный цикл движка не дело контроллера меню, и
    // 2 секунды против 0.5 — это ещё и вчетверо меньше лишних опросов.
    private var watchdogTimer: Timer?
    private var revivals = 0                        // подряд идущие попытки (для back-off)
    private var revivalsTotal = 0                   // за сессию, НЕ обнуляется никогда
    private var healthyTicks = 0                    // подряд идущих тиков, где движок жив
    private var lastRevivalAt: TimeInterval = 0     // systemUptime последней попытки (для back-off)
    private var revivalCeilingLogged = false        // о достижении потолка пишем один раз
    /// Потолок подряд идущих попыток — для обычной разовой смерти.
    private let maxRevivals = 5
    /// ⚠️ ЖЁСТКИЙ ПОТОЛОК ЗА СЕССИЮ (добавлен 31.07 после аудита). Утренняя версия имела только
    /// `revivals`, и он обнулялся при КАЖДОМ «жив». А мигание «мёртв на одном тике, жив на
    /// следующем» — это ровно то, как выглядит шторм отключений снаружи. В таком режиме потолок был
    /// недостижим, back-off после сброса стартовал заново с двух секунд, и сторож вечно звал
    /// tapCreate на main каждые пару секунд, то есть заново взводил ловушку, пока система пыталась
    /// от неё избавиться. Сторож, задуманный как лекарство, усиливал бы аварию.
    private let maxRevivalsPerSession = 12
    /// Сколько тиков подряд надо прожить здоровым, чтобы считать аварию законченной и обнулить
    /// back-off. Один удачный тик ничего не доказывает — при шторме он чередуется с неудачным.
    private let healthyTicksToReset = 15            // 15 × 2с = 30 секунд устойчивого здоровья

    private var updatedFrom: String?      // версия, с которой обновились (nil если первый запуск/та же)
    private var currentVersion = ""
    // true пока WelcomeWindow ведёт пользователя через разрешения (первый запуск).
    // showPermissionAlertOnce() НЕ вмешивается в этот сценарий — иначе 3+ диалога подряд:
    // нативный AX prompt + наш NSAlert + микрофон + кнопка Allow в Welcome = хаос.
    private var welcomePending = false
    private var singleInstanceFD: Int32 = -1   // держим fd открытым → flock жив до выхода процесса
    // РУЧНОЙ ли это запуск (двойной клик в Finder / Spotlight / Dock), а НЕ старт из автозагрузки при
    // логине. Ловим в applicationWillFinishLaunching, где `currentAppleEvent` ещё достоверен.
    private var launchedManually = false

    /// Кросс-процессный сигнал «открой Настройки»: вторая копия (двойной клик по уже запущенному
    /// Keyboop, если Launch Services всё же породил процесс) шлёт его работающему экземпляру и выходит.
    static let openSettingsNotification = Notification.Name("ru.keyboop.app.openSettings")

    /// РУЧНОЙ запуск ⇔ система прислала Apple-event `kAEOpenApplication` БЕЗ маркера login-item.
    /// Запуск из автозагрузки (`SMAppService.mainApp`, launchd) либо не шлёт Apple-event вовсе
    /// (`currentAppleEvent == nil`), либо помечает его `keyAELaunchedAsLogInItem`. Дефолт безопасный:
    /// нет события → НЕ ручной → на логине настройки НЕ всплывают (главное требование). Проверять надо
    /// РАНО (willFinishLaunching) — позже `currentAppleEvent` уже не тот. Источник: hisaac.net + Apple AE.
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication else { launchedManually = false; return }
        let isLoginItem = event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        launchedManually = !isLoginItem
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SINGLE-INSTANCE: две копии Keyboop = два CGEventTap'а = каждое нажатие чинится ДВАЖДЫ
        // (дубли префиксов, латинские огрызки — прецедент 19.06.2026: dev `ru.keyboop.app.dev` рядом с
        // прод `ru.keyboop.app`). Замок КРОСС-БАНДЛОВЫЙ (flock по фикс-пути), иначе разные bundle id
        // расходятся. Если занят другим Keyboop — мы вторая копия: тихо уходим ДО установки тапа.
        guard acquireSingleInstanceLock() else {
            // Уже запущена другая копия Keyboop. НЕ показываем модальный «уже запущено» (лишний клик —
            // жалоба пользователя) и не дублируем ввод: просто просим РАБОТАЮЩИЙ экземпляр открыть
            // Настройки (человек запустил Keyboop именно чтобы туда попасть) и тихо выходим.
            kbLog("single-instance: Keyboop уже запущен — прошу его открыть Настройки и выхожу")
            DistributedNotificationCenter.default().postNotificationName(
                Self.openSettingsNotification, object: nil, userInfo: nil, deliverImmediately: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { NSApp.terminate(nil) }
            return
        }
        _ = AppHealth.launchedAt   // ленивый static let: «потрогать» на старте, иначе аптайм в первом
                                   // багрепорте всегда «0с» и разбор уходит в ложную ветку
        installMainMenu()   // меню Edit (Cmd+V/C/X/A/Z) — иначе в текстовых полях не работает вставка
        syncProcessLanguage()   // Sparkle и системные диалоги — на языке приложения (репорт 24.07)
        CapsRemap.reconcile()   // Caps-ремап не переживает перезагрузку (переприменить) и не должен
                                // переживать выключенный тумблер (снять после падения без restore)
        GlobeKey.reconcile()    // роль 🌐: забрать при включённом режиме / вернуть после падения
        installTerminationSignalHandlers()   // SIGTERM/SIGINT: вернуть системе 🌐 и Caps (см. ниже)
        engine = Engine()
        menuBar = MenuBarController(layout: engine.layout)
        menuBar.onOpenSettings = { [weak self] in self?.openSettings() }
        menuBar.onShowVoiceHistory = { [weak self] in self?.openVoiceHistory() }
        menuBar.onQuickDictate = { [weak self] in self?.engine.toggleVoiceFromMenu() }
        // Меню показывает паузу, значит обязано перерисоваться, когда она началась или кончилась.
        Pause.onChange = { [weak self] in self?.menuBar.refreshAfterPauseChange() }
        menuBar.onCheckUpdates = { UpdaterController.shared.checkNow() }
        menuBar.onQuit = { NSApp.terminate(nil) }
        menuBar.onToggleAuto = { _ in }
        // Через main: колбэк зовётся СИНХРОННО из обработчика события (Enter-pre конверсия), а
        // menuBar.refresh() трогает NSStatusItem.button (NSView) — AppKit не для колбэка тапа.
        // Соседние колбэки ниже уже так делают; этот был единственным без хопа.
        engine.onLayoutMaybeChanged = { [weak self] in
            DispatchQueue.main.async { self?.menuBar.refresh() }
        }
        // Вторая копия (двойной клик по уже запущенному Keyboop) просит нас открыть Настройки.
        DistributedNotificationCenter.default().addObserver(
            forName: Self.openSettingsNotification, object: nil, queue: .main
        ) { [weak self] _ in
            NSApp.activate(ignoringOtherApps: true)
            self?.openSettings()
        }
        // Обучение на отмене: нативное уведомление macOS (баннер вверху справа, у часов — «от значка»)
        // + обновляем список «Выученные» в открытых настройках.
        UndoLearner.shared.onLearned = { [weak self] word in
            self?.notifyLearned(word)
            DispatchQueue.main.async { self?.settingsWC?.reload() }
        }
        // Откат авто-конверсии → баннер-вопрос «добавить в исключения?» (решает пользователь).
        UndoLearner.shared.onSuggestLearn = { [weak self] word in
            DispatchQueue.main.async { self?.suggestLearnBanner(word) }
        }
        VoiceController.shared.onStateChange = { [weak self] s in
            DispatchQueue.main.async { self?.menuBar.setVoiceState(s) }
        }
        // ВАЖНО (20.07): promptModelDownload делает alert.runModal(), а зовётся этот колбэк изнутри
        // `Task { @MainActor }` (VoiceController.begin). Вложенный модальный рунлуп ВНУТРИ Swift-job
        // диспатчит обычные AppKit-события, пока в TLS главного потока живёт ExecutorTrackingInfo —
        // ровно то состояние, при котором на macOS 26 сизинг SwiftUI-бэкед контролов ловит PAC-trap
        // (разбор краша 0.2.57). Выходим из job'а до показа алерта.
        VoiceController.shared.onNeedModel = { [weak self] in
            DispatchQueue.main.async { self?.promptModelDownload() }
        }
        VoiceController.shared.preload()   // прогрев модели в фоне → первое нажатие диктовки без задержки
        VoiceHistory.migrateKeyIfNeeded()  // ключ истории: старый .histkey → Keychain (security-аудит M1, 01.07)

        // Dev-помощник: запуск с --settings[=snippets] сразу открывает Настройки (на нужном разделе).
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--settings") }) {
            let sec: SettingsSection? = arg.contains("snippets") ? .snippets
                                      : arg.contains("ambiguous") ? .ambiguous
                                      : arg.contains("voice") ? .voice : nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.openSettings(section: sec) }
        }

        // Версия прошлого запуска → текущая. Если это ОБНОВЛЕНИЕ и доступ off → вероятно протухший
        // grant после смены подписи (показываем спец-подсказку «убери и добавь заново», см.
        // showPermissionAlertOnce). Для Developer-ID→Developer-ID доступ не слетает → ветка не сработает.
        let curVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let prevVer = AppSettings.shared.lastRunVersion
        AppSettings.shared.lastRunVersion = curVer
        updatedFrom = (!prevVer.isEmpty && prevVer != curVer) ? prevVer : nil
        currentVersion = curVer

        // Штамп сборки в логе — чтобы при разборе репортов было ВИДНО, какую именно сборку гоняли
        // (прецедент 21.07: анализировали баг по логу процесса, стартовавшего раньше пересборки).
        let stamp = Bundle.main.infoDictionary?["KeyboopBuildStamp"] as? String ?? "?"
        let isDev = (Bundle.main.bundleIdentifier ?? "").hasSuffix(".dev")
        kbLog("launched; v\(curVer)\(isDev ? "-dev" : "") [build \(stamp)] (prev \(prevVer.isEmpty ? "—" : prevVer)); manual=\(launchedManually) AX=\(Permissions.isTrusted()) InputMon=\(Permissions.inputMonitoringGranted())")

        // Самый первый запуск: включаем автозапуск при входе в систему (дефолт-вкл).
        if !AppSettings.shared.didInitialSetup {
            AppSettings.shared.didInitialSetup = true
            AppSettings.shared.launchAtLogin = true
            // Дефолт диктовки для НОВЫХ пользователей — «переключение» (нажал-старт / нажал-стоп),
            // выставляем ЯВНО только на первом запуске. Существующих юзеров не трогаем: read-дефолт
            // voiceHoldMode остаётся "hold", так что у тех, кто его не менял, поведение не меняется.
            AppSettings.shared.voiceHoldMode = "toggle"
            kbLog("first run: launchAtLogin=\(AppSettings.shared.launchAtLogin), voice=toggle")
        }

        // ⚠️ МИГРАЦИЯ 29.07: снимаем мгновенное переключение с Shift, если оно там уже стоит.
        // Запрет в рекордере (UIControls) закрывает только НОВЫЕ привязки, а у тех, кто повесил
        // раньше, настройка лежит в defaults и продолжает работать. Shift нажимается перед каждой
        // заглавной буквой, а весь жест держится на улике «между нажатием и отпусканием не было
        // обычной клавиши» — улике, которую macOS от нас скрывает при залипшем Secure Input
        // (репорт #46: язык переключался после первой же заглавной, человек в итоге выключил
        // автопереключение целиком, лишь бы печатать).
        // Выключаем саму функцию, а не подменяем клавишу молча: подмена — это тихое изменение
        // поведения, а выключение человек увидит в настройках и выберет сам.
        if AppSettings.shared.instantSwitchMode == "modkey",
           AppSettings.shared.instantSwitchKeyCode == 56 || AppSettings.shared.instantSwitchKeyCode == 60 {
            let kc = AppSettings.shared.instantSwitchKeyCode
            AppSettings.shared.instantSwitchEnabled = false
            kbLog("миграция: мгновенное переключение было на Shift (keyCode \(kc)) — выключено, оно ложно срабатывало после заглавных букв")
        }

        // Первый запуск: окно-приветствие (онбординг) — один раз.
        if !AppSettings.shared.didShowWelcome
            && ProcessInfo.processInfo.environment["KEYBOOP_DUMP"] != "1"
            && ProcessInfo.processInfo.environment["KEYBOOP_WINSHOT"] != "1"
            && ProcessInfo.processInfo.environment["KEYBOOP_WELCOMESHOT"] != "1" {
            AppSettings.shared.didShowWelcome = true
            welcomePending = true   // WelcomeWindow берёт управление разрешениями на себя
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.showWelcome() }
        }

        // Открываем Настройки при запуске + иконку в Доке (значок у часов легко потерять в тесной
        // строке меню), но ТОЛЬКО если запуск РУЧНОЙ (человек сам открыл Keyboop из Finder/Spotlight/
        // Dock). Старт из автозагрузки при логине (главное требование автора 05.07) — тихо садимся в
        // строку меню, окно НЕ показываем. Различаем по Apple-event запуска (launchedManually,
        // см. applicationWillFinishLaunching): ручной = kAEOpenApplication без login-item-маркера;
        // логин = нет события / есть маркер. Это надёжнее прежнего прокси `launchAtLogin` (тот скрывал
        // настройки на РУЧНОМ запуске, если автозапуск включён — а именно там юзер, потерявший значок,
        // и открывает приложение). Повторный «запуск» уже работающего Keyboop всё равно откроет
        // Настройки через applicationShouldHandleReopen / single-instance-сигнал. Закрытие окна → снова
        // чистый агент (windowWillClose → .accessory). Не лезем поверх онбординга, авто-обновления
        // (Sparkle перезапускает сам), скриншот-режимов и dev-флага --settings.
        let screenshotMode = ["KEYBOOP_DUMP", "KEYBOOP_WINSHOT", "KEYBOOP_WELCOMESHOT"]
            .contains { ProcessInfo.processInfo.environment[$0] == "1" }
        let settingsArg = CommandLine.arguments.contains { $0.hasPrefix("--settings") }
        if launchedManually, !welcomePending, updatedFrom == nil, !screenshotMode, !settingsArg {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.openSettings()
            }
        }

        // Новый пользователь: заранее (один раз) просим доступ к микрофону, чтобы диктовка
        // сразу работала, а не «молчала». Раньше доступ спрашивался лениво — только при
        // первом нажатии хоткея И при установленной модели, поэтому промпт часто не появлялся.
        // НО НЕ во время онбординга (welcomePending): системный TCC-диалог микрофона всплывал бы
        // поверх welcome-анимации (юзер не видел логотип/онбординг). На первом запуске микрофоном
        // руководит сам WelcomeWindow (кнопка «разрешить») — там промпт уместен по шагу.
        if AppSettings.shared.voiceEnabled, !welcomePending,
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
        startEngineWatchdog()
        // Предохранитель снял перехват (или вернул) — строка меню должна сказать об этом сразу,
        // не дожидаясь своего тика: человек в этот момент как раз недоумевает, почему не печатается.
        AppHealth.onTapSuspended = { [weak self] in
            DispatchQueue.main.async { self?.menuBar.refresh() }
        }

        // Автообновления (Sparkle): по умолчанию спрашиваем НАШИМ баннером (две кнопки, AppBanner —
        // без системных уведомлений), тихо — только если юзер выбрал «авто». Под dev-рендер-хуками
        // не стартуем (без сетевых проверок).
        UpdaterController.shared.onUpdateReady = { [weak self] v in self?.notifyUpdateReady(v) }
        let env = ProcessInfo.processInfo.environment
        if (Bundle.main.bundleIdentifier ?? "").hasSuffix(".dev"), env["KEYBOOP_UPDATER"] != "1" {
            // Dev-сборка НЕ проверяет прод-апкаст: Sparkle иначе может «обновить» dev-бандл
            // прод-DMG — подмена под ногами + диалог с паролем посреди работы (23.07.2026).
            // Прод-поведение Sparkle тестируем на прод-бандле из /Applications.
            //
            // KEYBOOP_UPDATER=1 снимает запрет для ОТЛАДКИ самого апдейтера: дважды за 30.07 правки в
            // расписании проверок нельзя было увидеть иначе как выкатив релиз. Дыру 23.07 это не
            // возвращает: в этом режиме UpdaterController принудительно гасит скачивание, то есть
            // Sparkle может только спросить фид и записать в лог, но не принести и не подменить файл.
            kbLog("updater: dev-сборка — автопроверка обновлений выключена")
        } else if env["KEYBOOP_DUMP"] != "1", env["KEYBOOP_WINSHOT"] != "1",
           env["KEYBOOP_LIVEDIAG"] != "1", env["KEYBOOP_HISTDUMP"] != "1" {
            UpdaterController.shared.start()
        }

        // Конфликт с Punto Switcher — проверяем чуть позже старта (и не во время онбординга).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.checkPuntoConflictOnce() }

        // Dev-хук: одеть ПРИЛОЖЕНИЕ в светлое, не трогая окна (KEYBOOP_APP_AQUA=1).
        //
        // Нужен, чтобы воспроизвести режим «как в системе» на светлой теме, не переключая тему у
        // человека на его машине. В этом режиме окно намеренно НЕ задаёт себе appearance и наследует
        // его сверху — а именно этот путь и ломается по отзывам, тогда как явно выбранная светлая
        // тема работает. Ставя оформление приложению, мы воспроизводим ровно наследование.
        if ProcessInfo.processInfo.environment["KEYBOOP_APP_AQUA"] == "1" {
            NSApp.appearance = NSAppearance(named: .aqua)
            kbLog("dev: приложению выдано светлое оформление (проверка режима «как в системе»)")
        }
        // Тот же хук со значением 2 — смена оформления НА ЛЕТУ, через 3 с после старта. Нужен, чтобы
        // проверить второй сценарий из отзывов: человек переключает тему макОС при ОТКРЫТОМ окне.
        // Окну по-прежнему ничего не задано, меняется оформление приложения — значит идёт ровно тот же
        // путь уведомления (viewDidChangeEffectiveAppearance), что и при системном переключении.
        if ProcessInfo.processInfo.environment["KEYBOOP_APP_AQUA"] == "2" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                NSApp.appearance = NSAppearance(named: dark ? .aqua : .darkAqua)
                kbLog("dev: оформление приложения переключено на лету → \(dark ? "светлое" : "тёмное")")
            }
        }

        // Dev-хук: открыть окно настроек сразу (для скриншотов/отладки дизайна).
        //
        // ⚠️ ТОЛЬКО ОТКРЫТЬ. Раньше этот хук следом гнал `dump()` по всем девяти разделам, а `dump()`
        // первой строкой прибивает окно к `.aqua` (канон снимков, см. SettingsWindow). Получалось, что
        // инструмент, которым проверяют внешний вид живого окна, сам его перекрашивал: в тёмной системе
        // окно выходило светлым, и это выглядело как баг темы. Я трижды «чинил» из-за этого тему, хотя
        // ломалась проверка (04.08.2026). Прогон разделов в файлы — это KEYBOOP_DUMP, он ниже и он для
        // этого и заведён; здесь он был лишним.
        if ProcessInfo.processInfo.environment["KEYBOOP_OPEN_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.openSettings()
            }
        }
        // Dev-хук: показать окно записи комбинации (KEYBOOP_HKREC=1). Своего входа без мыши у него
        // нет, а офскрин-рендер на macOS 26 отдаёт пустой кадр (см. задачу 0d про KEYBOOP_WINSHOT),
        // поэтому единственный способ посмотреть на его вёрстку глазами это открыть его живьём.
        if ProcessInfo.processInfo.environment["KEYBOOP_HKREC"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                HotkeyRecorderPanel.shared.show(what: L10n.t("hkrec.what.switch"), over: nil,
                                                onCommit: {}, onCancel: {})
                // Образец комбинации: иначе окно пустое и капсулы клавиш, ради которых сюда и
                // смотрят, на снимок не попадают.
                HotkeyRecorderPanel.shared.render(parts: ["⌘", "⇧", "K"], complete: true)
            }
        }
        // Dev-хук: показать тост (KEYBOOP_TOAST=1). Тост живёт две секунды и появляется по
        // действию, которое руками к моменту снимка уже не повторить, поэтому без хука его
        // внешний вид проверялся «на память». автор 06.08 нашёл там чужой зелёный цвет.
        if ProcessInfo.processInfo.environment["KEYBOOP_TOAST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                VoiceIndicator.shared.showToast(L10n.t("menu.copyLastDone"))
            }
        }
        // Dev-хук: показать список выбора сниппета (KEYBOOP_SNIPPICK=1). Плашка не крадёт фокус и
        // управляется цифрами через перехватчик, поэтому руками её на снимок не поймать: любой клик
        // мимо ничего не закроет, а нажатие цифры вставит текст в чужое окно. Хук показывает её и
        // держит, пока смотрят.
        if ProcessInfo.processInfo.environment["KEYBOOP_SNIPPICK"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { _ = SnippetPicker.shared.show() }
        }
        // Dev-хук: открыть «Что нового» (KEYBOOP_WHATSNEW=1) — посмотреть список изменений глазами
        // до релиза, не кликая по «О программе».
        if ProcessInfo.processInfo.environment["KEYBOOP_WHATSNEW"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                guard let self = self else { return }
                self.openSettings()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.settingsWC?.openWhatsNewForDev() }
            }
        }
        // Dev-хук: показать плашку об обновлении с ЖИВЫМИ кнопками, не дожидаясь настоящего апдейта.
        // Появился 30.07 после срочного репорта «в плашке не нажимаются кнопки»: проверить починку
        // иначе можно было бы только выпустив ещё один релиз. Обработчики ничего не ставят, только
        // пишут в лог, так что кликать безопасно.
        if ProcessInfo.processInfo.environment["KEYBOOP_BANNER"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                AppBanner.shared.show(
                    title: String(format: L10n.t("upd.notifyTitle"), "0.0.0-проверка"),
                    body: L10n.t("upd.notifyBody"),
                    actions: [
                        .init(title: L10n.t("upd.now"), coral: false) { kbLog("БАННЕР-ТЕСТ: сработала левая кнопка «Обновить»") },
                        .init(title: L10n.t("upd.autoShort"), coral: true) { kbLog("БАННЕР-ТЕСТ: сработала правая кнопка «Обновлять автоматически»") }
                    ])
            }
        }
        // Dev-хук: снять блок ввода формы отзыва и выйти (диагностика «не видно текст», см.
        // FeedbackWindowController.dumpFieldForDev).
        if ProcessInfo.processInfo.environment["KEYBOOP_FBDUMP"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                FeedbackWindowController.shared.show()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    FeedbackWindowController.shared.dumpFieldForDev(to: "/tmp/kb_feedback.png")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
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
                // ⚠️ ВЕРНУТЬ ЯЗЫК КАК БЫЛ (30.07). Хук снимает два образца и для этого переключает
                // язык приложения. Раньше он оставлял его английским, и автор обнаружил свой Keyboop
                // на английском после моей же диагностики. Инструмент не должен менять настройки
                // человека — тем более незаметно.
                let wasLanguage = AppSettings.shared.language
                defer { AppSettings.shared.language = wasLanguage }
                AppSettings.shared.language = "ru"
                AppBanner.shared.renderSample(to: "/tmp/kb_banner_ru.png")
                AppSettings.shared.language = "en"
                AppBanner.shared.renderSample(to: "/tmp/kb_banner_en.png")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
            }
        }
    }

    /// Сторож живости: раз в 2 секунды сверяет «мы думаем, что работаем» с «движок реально жив».
    /// Расхождение = тап умер после успешного старта, и без этого сторожа лечилось только
    /// перезапуском приложения (см. блок комментариев у полей выше).
    private func startEngineWatchdog() {
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkEngineAlive()
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    private func checkEngineAlive() {
        // Ещё не стартовали ни разу — это забота retryTimer, не наша.
        guard engineRunning else { return }
        // Живой пробник (состояние тапа, НЕ TCC — см. AppHealth.blockingProblem про то, почему
        // спрашивать AXIsProcessTrusted первым нельзя).
        // Мы сами сняли перехват предохранителем — это не поломка, воскрешать нечего.
        guard !AppHealth.tapSuspended else { return }

        guard !AppHealth.engineRunning else {
            // ⚠️ Обнуляем back-off только после УСТОЙЧИВОГО здоровья, а не по одному удачному тику:
            // при шторме «мёртв/жив» чередуются, и сброс по первому же «жив» превращал потолок в
            // фикцию, а back-off — в постоянные две секунды (аудит 31.07).
            healthyTicks += 1
            if revivals > 0, healthyTicks >= healthyTicksToReset {
                kbLog("сторож: движок устойчиво жив \(healthyTicks) тиков — сбрасываю back-off (попыток было \(revivals), всего за сессию \(revivalsTotal))")
                revivals = 0
                lastRevivalAt = 0          // иначе после сброса первая же проверка проходит мгновенно
                revivalCeilingLogged = false
            }
            return
        }
        healthyTicks = 0

        guard revivalsTotal < maxRevivalsPerSession else {
            if !revivalCeilingLogged {
                revivalCeilingLogged = true
                kbLog("сторож: \(revivalsTotal) воскрешений за сессию — прекращаю совсем. Дальше только перезапуск приложения")
                menuBar.needsPermission = true
                menuBar.refresh()
            }
            return
        }

        guard revivals < maxRevivals else {
            if !revivalCeilingLogged {
                revivalCeilingLogged = true
                kbLog("сторож: движок мёртв, \(maxRevivals) попыток подряд не помогли — прекращаю. Скорее всего отозван доступ к Accessibility либо залип TCC; лечится перезапуском приложения")
                menuBar.needsPermission = true
                menuBar.refresh()
            }
            return
        }

        // Back-off: 2, 4, 8, 16, 32 секунды. Без него при отозванном доступе мы бы пытались
        // поднять тап дважды в секунду до конца сессии.
        let now = ProcessInfo.processInfo.systemUptime
        let wait = TimeInterval(2 << revivals)
        guard now - lastRevivalAt >= wait else { return }
        lastRevivalAt = now
        revivals += 1
        revivalsTotal += 1

        kbLog("сторож: движок мёртв, а мы считали его запущенным — поднимаю заново (попытка \(revivals) из \(maxRevivals), за сессию \(revivalsTotal) из \(maxRevivalsPerSession))")
        // Снимаем защёлку, иначе tryStart() выйдет по собственному гарду на первой же строке.
        engineRunning = false
        tryStart()
    }

    private func tryStart() {
        guard !engineRunning else { return }

        // ПЕРВЫЙ ЗАПУСК: пока открыт онбординг — НЕ дёргаем tapCreate вслепую. Он сам поднимает
        // системный TCC-промпт «Keyboop хочет управлять этим компьютером», причём МГНОВЕННО (мы
        // зовём tryStart сразу в didFinishLaunching, а окно онбординга показывается через 0.8с) —
        // и наше окно всплывало ПОВЕРХ системного запроса, перекрывая его (баг-репорт).
        // Ретрай-таймер 0.5с делал то же самое по кругу.
        // Теперь во время онбординга стартуем ТОЛЬКО если доступ уже реально выдан (переустановка,
        // апдейт) — тогда промпта не будет вовсе. Если доступа нет, ждём: кнопка «Разрешить» в самом
        // онбординге вызовет промпт в нужный момент, когда человек к нему готов и анимация отыграла.
        if welcomePending && !Permissions.isTrusted() {
            menuBar.needsPermission = true
            menuBar.refresh()
            // ⚠️ Пишем в лог ОДИН раз (репорт #34, 28.07: весь лог человека — три строки, потому что
            // этот возврат случался ~840 раз за семь минут и не оставлял следа). Сам гард правильный,
            // он не перекрывает системный промпт; лечим именно немоту, а не логику.
            if !loggedWaitingForAX {
                loggedWaitingForAX = true
                kbLog("жду доступ к Accessibility — движок НЕ запущен; конверсия и диктовка работать не будут, пока не разрешат")
            }
            return
        }

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
            welcomePending = false
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
        // Во время первого запуска WelcomeWindow сам ведёт пользователя через AX-разрешение
        // (кнопка Allow → requestTrust + openSettings). Вмешиваться не нужно — иначе пользователь
        // получает: нативный AX prompt + наш NSAlert + кнопку в Welcome + микрофон = 4 диалога.
        guard !alertShown, !welcomePending else { return }
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
                alert.messageText = L10n.t("alert.regrant.title")
                alert.informativeText = String(format: L10n.t("alert.regrant.body"), from, self.currentVersion)
            } else {
                alert.messageText = L10n.t("alert.ax.title")
                alert.informativeText = L10n.t("alert.ax.body")
            }
            alert.addButton(withTitle: L10n.t("alert.ax.open"))
            alert.addButton(withTitle: L10n.t("alert.later"))
            if alert.runModal() == .alertFirstButtonReturn {
                Permissions.openAccessibilitySettings()
            }
        }
    }

    /// Конфликт с Punto Switcher: он, как и Keyboop, переключает раскладку — вместе дерутся. Если он
    /// запущен, предлагаем закрыть его (мы МОЖЕМ — terminate) и ведём в «Объекты входа», чтобы убрать
    /// автозапуск (его за другое приложение программно не отключить). Показываем один раз за сессию,
    /// НЕ во время онбординга (чтобы не сыпать диалогами поверх welcome).
    private var puntoAlertShown = false
    private func runningPunto() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            let bid = ($0.bundleIdentifier ?? "").lowercased()
            let name = ($0.localizedName ?? "").lowercased()
            return bid.contains("punto") || name.contains("punto")
        }
    }
    private func checkPuntoConflictOnce() {
        guard !puntoAlertShown, !welcomePending, let punto = runningPunto() else { return }
        let env = ProcessInfo.processInfo.environment
        if env["KEYBOOP_DUMP"] == "1" || env["KEYBOOP_OPEN_SETTINGS"] == "1" { return }
        puntoAlertShown = true
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = L10n.t("alert.punto.title")
            a.informativeText = L10n.t("alert.punto.body")
            a.addButton(withTitle: L10n.t("alert.punto.quit"))
            a.addButton(withTitle: L10n.t("alert.punto.login"))
            a.addButton(withTitle: L10n.t("alert.later"))
            switch a.runModal() {
            case .alertFirstButtonReturn: punto.terminate()
            case .alertSecondButtonReturn: Permissions.openLoginItemsSettings()
            default: break
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
            a.messageText = L10n.t("alert.move.title")
            a.informativeText = L10n.t("alert.move.body")
            a.addButton(withTitle: L10n.t("alert.move.reveal"))
            a.addButton(withTitle: L10n.t("alert.later"))
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
            a.messageText = L10n.t("alert.relaunch.title")
            a.informativeText = L10n.t("alert.relaunch.body")
            a.addButton(withTitle: L10n.t("alert.relaunch.ok"))
            a.addButton(withTitle: L10n.t("alert.relaunch.no"))
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
        AppBanner.shared.show(title: "Keyboop", body: String(format: L10n.t("learn.toast"), word), autoDismiss: 5)
    }

    /// Откат авто-конверсии → баннер вверху справа с вопросом. «Добавить» → слово в исключения;
    /// «Не надо» → по этому слову больше не спрашиваем. Висит до решения (без авто-скрытия).
    private func suggestLearnBanner(_ word: String) {
        AppBanner.shared.show(
            title: String(format: L10n.t("learn.askTitle"), word),
            body: L10n.t("learn.askBody"),
            actions: [
                .init(title: L10n.t("learn.add"), coral: true) { [weak self] in
                    UndoLearner.shared.confirmLearn(word)
                    DispatchQueue.main.async { self?.settingsWC?.reload() }
                },
                .init(title: L10n.t("learn.no"), coral: false) {
                    UndoLearner.shared.declineLearn(word)
                }
            ]
        )
    }

    /// Готов апдейт → НАШ баннер вверху справа с двумя кнопками (без системных уведомлений и их
    /// запроса разрешений — по просьбе автора). Ждёт решения; «Обновить» ставит, «Авто» включает тихий
    /// режим. Закрыл/проигнорировал — переспросит на следующей проверке (или поставится при выходе).
    private func notifyUpdateReady(_ version: String) {
        AppBanner.shared.show(
            title: String(format: L10n.t("upd.notifyTitle"), version),
            body: L10n.t("upd.notifyBody"),
            // ПОРЯДОК И ЦВЕТ — РЕШЕНИЕ ИВАНА 30.07. Слева серая «Обновить», справа коралловая
            // «Обновлять автоматически». Обе ставят апдейт СРАЗУ, без второго окна; правая вдобавок
            // включает тихие автообновления. Коралл на правой намеренно: это подсказка, куда нажать,
            // чтобы больше не видеть эту плашку никогда. Раньше акцент стоял на «обновить один раз»,
            // то есть мы сами уводили людей от автообновлений и потом удивлялись застрявшим версиям.
            actions: [
                .init(title: L10n.t("upd.now"), coral: false) { UpdaterController.shared.installPendingNow() },
                .init(title: L10n.t("upd.autoShort"), coral: true) { UpdaterController.shared.enableSilentAndInstall() }
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
            welcomeWC?.onClose = { [weak self] in
                // Welcome закрыт — разрешаем showPermissionAlertOnce() работать нормально,
                // если AX всё ещё не выдан (пользователь пропустил онбординг).
                self?.welcomePending = false
            }
        }
        welcomeWC?.show()
    }

    /// Минимальное главное меню. У LSUIElement-агента его нет по умолчанию, из-за чего стандартные
    /// сочетания (Cmd+V/C/X/A/Z) НЕ доходят до текстовых полей — без пункта Paste в меню key-equivalent
    /// не срабатывает. App-меню даёт Cmd+Q / Cmd+W; Edit-меню — нативный буфер обмена в наших полях.
    /// Кросс-бандловый single-instance замок (flock по фикс-пути в Application Support). true — МЫ его
    /// взяли (единственная копия); false — уже держит другой Keyboop (ЛЮБОГО билда: dev и прод тоже).
    /// fd держим открытым весь процесс → замок жив до выхода (и авто-снимается при крэше — ядро закроет fd).
    /// Короткий ретрай: при Sparkle-перезапуске новая копия может стартовать на миг раньше, чем старая
    /// отпустит замок — даём ~2с освободиться, иначе ложно решим «уже запущен».
    private func acquireSingleInstanceLock() -> Bool {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keyboop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("singleton.lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true }   // не смогли создать замок — НЕ блокируем запуск (fail-open)
        for attempt in 0..<10 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { singleInstanceFD = fd; return true }
            if attempt < 9 { usleep(200_000) }   // 200мс × 10 ≈ 2с на отпускание старой копией (Sparkle relaunch)
        }
        close(fd)
        return false
    }

    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: L10n.t("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let closeItem = NSMenuItem(title: L10n.t("menu.close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(closeItem)

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: L10n.t("menu.edit"))
        editItem.submenu = edit
        edit.addItem(withTitle: L10n.t("menu.undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: L10n.t("menu.redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(withTitle: L10n.t("menu.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L10n.t("menu.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L10n.t("menu.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L10n.t("menu.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = main
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

    /// Перед exit() освобождаем модель Whisper (whisper_free): Swift не зовёт deinit при выходе
    /// процесса, Metal-буферы «утекали» за exit, и статический деструктор ggml бил ассерт → SIGABRT
    /// при квите (краш-репорт 20.07, llama.cpp #19137 «not a bug — free your context before exit»).
    /// Первый слой защиты — GGML_METAL_NO_RESIDENCY=1 в main.swift; этот — второй, канонический.
    /// Держим источники сигналов живыми (иначе GCD их снимет сразу после выхода из функции).
    private var signalSources: [DispatchSourceSignal] = []

    /// ВОЗВРАТ СИСТЕМНЫХ НАСТРОЕК ПРИ УБИЙСТВЕ ПРОЦЕССА (28.07).
    ///
    /// `applicationWillTerminate` выполняется при штатном выходе, но НЕ при SIGTERM: дефолтное
    /// действие сигнала убивает процесс, минуя AppKit. А `pkill`, «Завершить» в Мониторинге системы
    /// и перезагрузка с зависшим приложением шлют именно SIGTERM. Мы при этом держим ДВЕ системные
    /// настройки: роль клавиши 🌐 (AppleFnUsageType) и ремап Caps через hidutil. Обе переживают
    /// смерть процесса, поэтому «нас убили» означало «у человека сломана клавиша, и он даже не
    /// свяжет это с нами» — причём навсегда, в том числе после удаления Keyboop.
    ///
    /// `DispatchSourceSignal` вместо `signal(2)`-обработчика намеренно: обработчик сигнала обязан
    /// быть async-signal-safe, а CFPreferences и запуск hidutil таковыми не являются. Источник же
    /// выполняет блок на обычной очереди, вне контекста сигнала. `signal(sig, SIG_IGN)` обязателен —
    /// без него дефолтное действие убьёт процесс раньше, чем очередь проснётся.
    private func installTerminationSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                kbLog("получен сигнал \(sig) — возвращаю системе 🌐 и Caps, выхожу")
                CapsRemap.removeIfOurs()
                GlobeKey.release()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        VoiceController.shared.unloadForTermination()
        // Caps-ремап и забранная 🌐 без нас жить не должны: выходим — возвращаем всё системе.
        // (Синхронно: терминация не ждёт GCD; hidutil отрабатывает за ~50мс.)
        CapsRemap.removeIfOurs()
        GlobeKey.release()
    }

    /// Sparkle и прочие системные диалоги — на языке ПРИЛОЖЕНИЯ, а не только системы.
    /// У нас нет .lproj-папок (своя L10n) → без этого процесс запускается английским, и строки
    /// Sparkle.framework резолвятся в en, хотя ru.lproj в нём есть (баг-репорт:
    /// «You're up to date» в русском интерфейсе). CFBundleAllowMixedLocalizations в Info.plist
    /// разрешает фреймворкам локализоваться независимо; здесь досинхронизируем ЯВНЫЙ выбор языка
    /// в настройках (вступает в силу со следующего запуска — Sparkle-диалоги не горят).
    private func syncProcessLanguage() {
        let d = UserDefaults.standard
        switch AppSettings.shared.language {
        case "ru", "en":
            if d.stringArray(forKey: "AppleLanguages")?.first != AppSettings.shared.language {
                d.set([AppSettings.shared.language], forKey: "AppleLanguages")
            }
        default:
            d.removeObject(forKey: "AppleLanguages")   // «авто» — язык системы
        }
    }
}
