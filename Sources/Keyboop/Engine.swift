import Foundation
import AppKit
import CoreGraphics
import Carbon

/// Центральный движок: связывает event tap, буфер, раскладку и замену текста.
final class Engine: EventTapHandler {
    let layout = LayoutManager()
    private let buffer = KeystrokeBuffer()
    private let eventTap = EventTap()
    private let settings = AppSettings.shared

    /// Пока true — игнорируем входящие события (это наша же синтетика).
    /// didSet штампует время подъёма — все 8 мест `muted = true` получают сторожа бесплатно.
    private var muted = false {
        didSet { if muted { mutedAt = ProcessInfo.processInfo.systemUptime; inFlightRealKeys = 0 } }
    }
    /// Реальные печатные клавиши, вклинившиеся В ПОЛЁТ нашей синтетики (аудит, Fence B).
    /// Клавиша легла на экран ВНУТРИ зоны замены (между backspace'ами и ретайпом), а в модели —
    /// после неё: буфер после такого полёта недостоверен («gприветhello»). Отменить нельзя,
    /// но можно НЕ распространять: буфер чистим, следующая конверсия начинает с чистого листа.
    private var inFlightRealKeys = 0

    /// Единая точка завершения полёта синтетики (все completion'ы конверсий).
    private func endSyntheticFlight() {
        if inFlightRealKeys > 0 {
            kbLog("⚠️ в полёт синтетики вклинились реальные клавиши (\(inFlightRealKeys)) — буфер очищен (страховка)")
            liveFixLast = ""
            buffer.clear()
            inFlightRealKeys = 0
        }
        muted = false
        drainPendingManual()
    }
    /// Когда muted подняли — для сторожа застревания (репорт 24.07: «конверсия перестаёт работать,
    /// пока что-то её не оживит»). Если completion синтетики по любой причине не пришёл, muted
    /// остался бы true НАВСЕГДА, и все авто-конверсии молча гибли бы на первом guard. Сторож в
    /// mutedStuckCheck() снимает флаг через 3с и честно пишет об этом в лог.
    private var mutedAt: TimeInterval = 0

    /// true = muted и это НЕ застревание; false = путь свободен (в т.ч. после самопочинки).
    private func mutedStuckCheck() -> Bool {
        guard muted else { return false }
        let held = ProcessInfo.processInfo.systemUptime - mutedAt
        if held > 1.2 {   // реальная конверсия < 200мс; 1.2с — всё ещё огромный запас (аудит R5: 3с давали 3с мёртвой зоны)
            muted = false
            kbLog("⚠️ muted застрял \(String(format: "%.1f", held))с — самопочинка (completion синтетики не пришёл); авто снова живо")
            return false
        }
        return true
    }

    /// Молчаливые ветки обязаны говорить (правило диагностики), но не заспамливать лог на
    /// каждое нажатие: одна и та же причина пишется не чаще раза в 2с.
    private var silentLogLast: [String: TimeInterval] = [:]
    private func silentLog(_ key: String, _ message: String) {
        let now = ProcessInfo.processInfo.systemUptime
        if let t = silentLogLast[key], now - t < 2.0 { return }
        silentLogLast[key] = now
        kbLog(message)
    }

    /// Таймер-поллер Secure Input (см. start(): на keyDown переход не поймать — событий нет).
    private var secureInputTimer: Timer?
    /// Когда Secure Input включился (для «держит уже N секунд» в логе снятия).
    private var secureInputSince: TimeInterval = 0

    /// Логируем ПЕРЕХОДЫ Secure Input (не каждое нажатие). На включении — ищем держателя:
    /// pid лежит в ioreg (kCGSSessionSecureInputPID); сам поиск — subprocess, поэтому строго
    /// асинхронно и не с горячего пути.
    private var secureInputWasOn = false
    private func noteSecureInput(_ on: Bool) {
        guard on != secureInputWasOn else { return }
        secureInputWasOn = on
        AppHealth.secureInputOn = on
        // ⚠️ Меню надо ПЕРЕРИСОВАТЬ прямо здесь (ревью 28.07). buildMenu() зовётся из onLayoutMaybeChanged,
        // то есть по факту УДАЧНОЙ конверсии, а при Secure Input конверсий нет по определению —
        // строка «что мешает» в своём главном случае просто не появлялась бы.
        DispatchQueue.main.async { MenuBarController.shared?.refresh() }
        if !on {
            AppHealth.secureInputHolder = nil
            let held = Int(ProcessInfo.processInfo.systemUptime - secureInputSince)
            kbLog("secure input СНЯТ (держали ~\(held)с) — Keyboop снова видит клавиатуру")
            return
        }
        secureInputSince = ProcessInfo.processInfo.systemUptime
        kbLog("secure input ВКЛЮЧЁН — macOS прячет клавиатуру от Keyboop (конверсия молчит СИСТЕМНО, это не поле настроек); ищу держателя…")
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
            p.arguments = ["-l", "-w0"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard let out = String(data: data, encoding: .utf8),
                  let r = out.range(of: #""kCGSSessionSecureInputPID"=(\d+)"#, options: .regularExpression),
                  let pid = Int32(out[r].components(separatedBy: "=").last ?? "") else {
                kbLog("secure input: держатель не найден в ioreg (уже отпустил?)")
                return
            }
            // NSRunningApplication знает только GUI-приложения; демоны (loginwindow и пр.) — по pid.
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "не-GUI процесс"
            // Пишем с main: читают отсюда меню и диагностика, оба на главном потоке (ревью 28.07 —
            // раньше запись шла с фоновой очереди ioreg, а чтение с main, без синхронизации).
            DispatchQueue.main.async {
                guard AppHealth.secureInputOn else { return }   // за время ioreg (~0.7с) могли уже снять
                AppHealth.secureInputHolder = name
                MenuBarController.shared?.refresh()             // имя нашлось — обновляем строку в меню
            }
            kbLog("secure input: держатель — \(name) (pid \(pid))")
        }
    }

    /// Предохранитель от «быстрого циклического переключения раскладки» (резонанса). Спрашиваем
    /// перед КАЖДОЙ авто-конверсией; при детекте осцилляции замораживает авто на пару секунд.
    private let antiResonance = AntiResonanceGuard()

    /// Диагностика 23.07 («слово конвертируется дважды», баг-репорт): держим ПОСЛЕДНИЙ результат
    /// конверсии в памяти; если новая конверсия стартует ОТ него (word == прошлый produced) или
    /// повторяет его результат — пишем факт в лог (пути/длины/интервал, БЕЗ контента). Первое —
    /// сигнатура loop-back'а нашей же синтетики в буфер, второе — двойная обработка одного слова.
    private var lastConvDiag: (produced: String, at: TimeInterval, path: String)?
    private func noteConvRepeat(word: String, produced: String, path: String) {
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastConvDiag = (produced, at: now, path: path) }
        guard let l = lastConvDiag, now - l.at < 3.0 else { return }
        if word == l.produced {
            kbLog("⚠️ конверсия ОТ нашего же вывода: \(l.path)→\(path), len \(word.count), через \(Int((now - l.at) * 1000))мс")
        } else if produced == l.produced {
            kbLog("⚠️ повтор того же результата: \(l.path)→\(path), len \(produced.count), через \(Int((now - l.at) * 1000))мс")
        }
    }

    /// Ручной хоткей, нажатый ПОКА летит синтетика (muted): не теряем его молча, а откладываем
    /// и выполняем, когда синтетика отыграла (muted снят). Иначе «отмена иногда ничего не делает»
    /// (баг H4, синтетический тест 2026-06-19): нажатие попадало в muted-окно и просто терялось.
    private var pendingManual = false

    /// «Дренаж» после постинга синтетики, перед снятием muted. Синтетика отыгрывает на serial-очереди
    /// и проходит через session-tap за единицы мс; этого хватает, чтобы хвостовые синтетические события
    /// успели пройти. Раньше было 0.18–0.25с — это мёртвое окно, где РЕАЛЬНЫЕ нажатия пользователя
    /// (быстрый набор следующего слова) тоже глотались (handleKeyDown под muted → return) → буфер
    /// рассинхронивался с экраном → следующее слово «иногда не переключалось» (баг 15.06, автор).
    private let muteDrain: TimeInterval = 0.08

    /// Валидатор «целевое слово есть в RU-словаре» — для smartConvert (концевые б/ю/ж: «yj;»→«нож»
    /// конвертим целиком, а не срезаем как пунктуацию). Передаём в Keymap, чтобы он не тянул LayoutData.
    private static let ruWordValidator: (String) -> Bool = { LayoutData.shared.wordsRu.contains($0) }

    /// Время последнего РЕАЛЬНОГО печатного нажатия — для пауза-гейта live-fix (24.07).
    private var lastRealKeyAt: TimeInterval = 0

    /// Класс алфавита строки для диагностики (БЕЗ контента): LAT/CYR/MIX/—.
    private static func scriptClass(_ s: String) -> String {
        let cyr = s.hasCyrillic, lat = s.hasLatinLetter
        if cyr && lat { return "MIX" }
        if cyr { return "CYR" }
        if lat { return "LAT" }
        return "—"
    }

    /// Отложенная очистка буфера после context-события (клик мышью / активация приложения, в т.ч.
    /// Spotlight по Cmd+Space). Эти события приходят с АСИНХРОННЫХ мониторов на main ПОЗЖЕ, чем
    /// обрабатывается первое нажатие → немедленный buffer.clear() съедал ПЕРВЫЙ символ (фидбэк юзеров:
    /// «adguard»→«фdguard», «hello»→«рhello»). Теперь чистим ЛЕНИВО — синхронно перед следующим
    /// нажатием (clear, затем append), без гонки. (16.06.2026.)
    private var pendingContextClear = false

    /// Мягкий отложенный сброс контекста (активация чужого приложения — каретка не двигалась):
    /// перед следующим нажатием забываем завершённое слово/группу, НО сохраняем currentWord.
    /// Полный clear (pendingContextClear) «сиротил» набираемое окончание → «ть»→«nm» (баг 29.06).
    private var pendingSoftReset = false

    /// Колбэк для UI — обновить индикатор после переключения.
    var onLayoutMaybeChanged: (() -> Void)?

    private var didSetup = false

    func start() -> Bool {
        if !didSetup {
            eventTap.handler = self
            // Смена активного приложения → контекст слова больше не достоверен.
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                // Активация ДРУГОГО приложения (уведомление/баннер/мигание фокуса) — каретка НЕ
                // двигалась. НЕ полный clear (он «сиротил» набираемое слово → «ть»→«nm», баг 29.06):
                // мягкий сброс перед следующим нажатием — забываем завершённый контекст, но НЕ
                // currentWord. Spotlight (Cmd+Space) и так чистит буфер как cmd-шорткат в handleKeyDown;
                // клик мышью идёт отдельным путём (handleContextReset → полный clear, каретка сдвинута).
                self?.pendingSoftReset = true
                self?.refreshFrontmostAppCache()   // inline-путь читает кеш (в колбэке NSWorkspace нельзя)
            }
            // Поллер Secure Input. Детект на keyDown НЕ работает для залипшего держателя: пока
            // Secure Input включён, macOS СИСТЕМНО прячет клавиатурные события от всех тапов —
            // проба 24.07: tap видит 0 нажатий даже при фоновом держателе (та же причина, по
            // которой Alfred/TextExpander показывают своё «secure input включён»). Значит, во
            // время залипания handleKeyDown не зовётся вовсе, и переход можно поймать только
            // опросом. Проверка — один mach-вызов раз в 2.5с, копейки.
            secureInputTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.noteSecureInput(IsSecureEventInputEnabled())
                // Фоновая сверка раскладки: в простое (2.5с+ после селектов) чтение TIS устоялось.
                if self.layout.reconcileWithReality() {
                    kbLog("раскладка: фоновая сверка приняла реальность (мнение расходилось)")
                }
            }
            refreshFrontmostAppCache()
            TextReplacer.warmUpInline()   // холодный первый burst стоил 23мс (замер 25.07) → греем заранее
            // Точная таблица символов из реальной раскладки (кавычки, Shift-ряд и т.д.).
            DynamicKeymap.rebuild()
            KeyboardLayoutCache.refreshOnMain()
            // ДВЕ нотификации, а не одна: Enabled…Changed = изменился СПИСОК раскладок,
            // Selected…Changed = переключили активную. Раньше слушали только первую — при обычном
            // переключении раскладки кэш не обновлялся бы (для DynamicKeymap это было терпимо,
            // для KeyboardLayoutCache означало бы неверные символы). TIS — только с main.
            let tisNotes: [CFString] = [kTISNotifyEnabledKeyboardInputSourcesChanged,
                                        kTISNotifySelectedKeyboardInputSourceChanged]
            for n in tisNotes {
                DistributedNotificationCenter.default().addObserver(
                    forName: NSNotification.Name(n as String), object: nil, queue: .main
                ) { [weak self] _ in
                    // Аудит C1 (24.07): уведомление прилетает и на НАШИ переключения — чуть позже
                    // по ранлупу, и его стейл-чтение «текущего» перезатирало только что
                    // детерминированно установленные кэш и мнение. В grace-окне своего select'а
                    // правда уже установлена из выбранного объекта — молчим; внешние смены
                    // (без недавнего своего select) обрабатываем как раньше.
                    guard self?.layout.withinOwnSelectGrace != true else { return }
                    DynamicKeymap.rebuild()
                    KeyboardLayoutCache.refreshOnMain()
                    self?.layout.noteExternalLayoutChange()   // память о раскладке — свежим чтением
                }
            }
            // Голосовая вставка завершилась → чистим буфер, чтобы надиктованное не попало в группу (G3).
            NotificationCenter.default.addObserver(
                forName: .keyboopVoiceInserted, object: nil, queue: .main
            ) { [weak self] _ in self?.liveFixLast = ""; self?.buffer.clear() }
            // Прогреть языковые данные в фоне, чтобы первый авто-свап не лагал.
            Warm.prime()
            // Предзаполнить список исключений дефолтами для установленных программ (видеоредакторы/
            // терминалы/IDE) — чтобы юзер сразу ВИДЕЛ их в Настройках и не ловил проблемы из коробки.
            seedDefaultExceptions()
            didSetup = true
        }
        return eventTap.start()
    }

    /// Скан установленных программ → предзаполнить список исключений дефолт-режимами. Только
    /// УСТАНОВЛЕННЫЕ (без мусорных строк), один раз каждую (seededApps), ручной выбор юзера не трогаем,
    /// удалённую не возвращаем. Async — не блокируем старт.
    private func seedDefaultExceptions() {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            // ВАЖНО: Adobe/Blackmagic кладут .app ВНУТРЬ папки (/Applications/Adobe Premiere Pro 2026/…app,
            // /Applications/DaVinci Resolve/…app) — поэтому сканируем верхний уровень И один уровень вглубь
            // папок (но НЕ внутрь самих .app). Иначе Premiere/DaVinci не находились (баг 17.06).
            let bases = ["/Applications", NSHomeDirectory() + "/Applications", "/System/Applications"]
            var pairs: [(bid: String, mode: String)] = []
            func consider(_ appPath: String) {
                guard let info = NSDictionary(contentsOfFile: appPath + "/Contents/Info.plist"),
                      let bid = info["CFBundleIdentifier"] as? String else { return }
                let mode = Engine.builtinAppMode(bid)
                if !mode.isEmpty { pairs.append((bid: bid, mode: mode)) }
            }
            for base in bases {
                guard let items = try? fm.contentsOfDirectory(atPath: base) else { continue }
                for item in items {
                    let path = base + "/" + item
                    if item.hasSuffix(".app") {
                        consider(path)                                   // .app прямо в /Applications
                    } else if let sub = try? fm.contentsOfDirectory(atPath: path) {
                        for s in sub where s.hasSuffix(".app") { consider(path + "/" + s) }   // .app внутри папки
                    }
                }
            }
            guard !pairs.isEmpty else { return }
            DispatchQueue.main.async {
                if ExceptionStore.shared.seedDefaultApps(pairs) {
                    kbLog("seed: предзаполнены исключения для установленных программ (кандидатов \(pairs.count))")
                }
            }
        }
    }

    // MARK: - EventTapHandler

    func handleContextReset() {
        // Клик/навигация двигает курсор — групповая история недействительна даже под muted (G10):
        // нашу синтетику мы шлём только с клавиатуры, mouse-down — всегда намерение пользователя.
        buffer.invalidateGroupHistory()
        if muted { pendingContextClear = true; return }   // клик двигал каретку: очистка не теряется, а ждёт следующего нажатия (аудит-гэп)
        // НЕ чистим буфер ЗДЕСЬ (этот колбэк прилетает с async-монитора ПОЗЖЕ первого нажатия и съедал
        // бы первый символ) — помечаем на ленивую очистку перед следующим нажатием (см. handleKeyDown).
        pendingContextClear = true
    }

    // Голосовой ввод (hold-to-talk) — делегируем оркестратору.
    func handleVoiceBegin() { VoiceController.shared.begin() }
    func handleVoiceEnd() { VoiceController.shared.end() }

    /// Возвращает true, если клавишу надо ПРОГЛОТИТЬ (граница слова раскрыла сниппет — см. expandSnippet).
    @discardableResult
    func handleKeyDown(keyCode: Int64, characters: String, flags: CGEventFlags,
                       post: ((CGEvent) -> Void)? = nil) -> Bool {
        // ВАЖНО: больше НЕ гейтим реальный ввод по muted — наша синтетика отсеивается тегом в EventTap
        // (kbSyntheticMarker), а реальные нажатия должны копиться в буфер ВСЕГДА, даже пока летит наша
        // конверсия (иначе буфер рассинхронивался с экраном при быстром наборе — корень №2 аудита).
        // muted сохранён только как guard от пере-входа в конверсию (maybeLiveFix/convertFromBuffer).
        // Поле пароля (Secure Input) — НЕ копим ввод (приватность).
        // ВАЖНО (репорт 24.07 «конверсия перестаёт работать, потом сама оживает»): Secure Input —
        // ГЛОБАЛЬНЫЙ флаг. Его держит не только честное поле пароля под курсором: браузер с формой
        // логина в фоновой вкладке, менеджер паролей, залипший loginwindow — и пока держат, Keyboop
        // «мёртв» ВО ВСЕХ приложениях. Раньше это происходило без единой строки в логе (гейт добавлен
        // в 0.2.60) — теперь логируем ПЕРЕХОДЫ и находим держателя (pid из ioreg, асинхронно).
        if IsSecureEventInputEnabled() {
            noteSecureInput(true)
            liveFixLast = ""; buffer.clear(); pendingContextClear = false; return false
        }
        noteSecureInput(false)

        // Ленивая очистка после context-события (клик/Spotlight — каретка сдвинулась): делаем СИНХРОННО
        // здесь, прямо перед обработкой нажатия → первый символ записывается в уже чистый буфер (без гонки).
        if pendingContextClear {
            liveFixLast = ""                  // курсор сместился (клик) — якорь self-heal сброшен
            buffer.clear()
            UndoLearner.shared.resetContext()
            antiResonance.resetHistory()      // новый контекст — история конверсий неактуальна (заморозка по таймеру сама истечёт)
            pendingContextClear = false
            pendingSoftReset = false          // полный clear перекрывает мягкий
        } else if pendingSoftReset {
            // Активация чужого приложения (каретка НЕ двигалась): мягкий сброс — забываем завершённый
            // контекст, но СОХРАНЯЕМ набираемое слово (иначе сиротили бы окончание → «ть»→«nm», 29.06).
            buffer.softContextReset()
            antiResonance.resetHistory()
            pendingSoftReset = false
        }

        let optOrCmd = flags.contains(.maskAlternate) || flags.contains(.maskCommand)
        let cmdOrCtrl = flags.contains(.maskCommand) || flags.contains(.maskControl)

        // liveFixLast валиден ТОЛЬКО в пределах текущего набираемого слова (якорь для self-heal).
        // Любая не-печатная клавиша (граница/backspace/навигация/шорткат) завершает/рвёт слово →
        // сбрасываем якорь в соответствующих case'ах ниже, иначе self-heal мог бы сработать по
        // устаревшему префиксу на новом слове или удалить не те символы (ревью 2026-06-19).
        // Печать символа якорь сохраняет (chain прогрессивной конверсии).
        switch keyCode {
        case 51: // Backspace
            liveFixLast = ""                          // правка слова — якорь self-heal недействителен
            // ⌥⌫ / ⌘⌫ стирают слово или строку целиком — мы не знаем сколько, сбрасываем контекст.
            if optOrCmd {
                buffer.clear()
                wordEdited = false                   // слово/строка стёрты целиком — следующее слово свежее
                UndoLearner.shared.resetContext()    // ⌥⌫/⌘⌫ стёрли слово/строку — контекст потерян
            } else {
                buffer.backspace()
                wordEdited = true                    // юзер правит слово внутри → live-fix молчит до границы
                UndoLearner.shared.observe(current: buffer.currentWord)   // U2: следим за стиранием нашего вывода
            }
        case 49, 48, 36: // Space, Tab, Return — граница слова
            liveFixLast = ""                          // слово завершено — якорь self-heal сброшен
            wordEdited = false                        // новое слово начинается свежим — live-fix снова активен
            let ws = keyCode == 48 ? "\t" : (keyCode == 36 ? "\n" : " ")
            // СНИППЕТ: проверяем ТЕКУЩЕЕ слово ДО boundary (currentWord = триггер, как на экране).
            // Совпало → ГЛОТАЕМ клавишу-границу и раскрываем сами. Не пускаем пробел в приложение →
            // не приходится потом удалять только что нажатый пробел → нет гонки «Backspace прилетел
            // раньше, чем приложение зафиксировало пробел/триггер» (баг автозамены: триггер не
            // удалялся + мусор в конце + «длинный пробел»). Раскладка не влияет — матч канонический,
            // а длину триггера берём по экрану (буфер == экран).
            // Разворот сниппета — только по выбранным в настройках клавишам (пробел/Enter/Tab).
            // Все галочки сняты → автозамена выключена (snippetsDisabled), сниппеты не трогаем.
            let snipKeyOK = (keyCode == 49 && settings.snippetExpandSpace)
                         || (keyCode == 36 && settings.snippetExpandEnter)
                         || (keyCode == 48 && settings.snippetExpandTab)
            if snipKeyOK, !muted, !buffer.currentWord.isEmpty,
               let expansion = SnippetStore.shared.expansion(forTyped: buffer.currentWord) {
                expandSnippet(trigger: buffer.currentWord, expansion: expansion, whitespace: ws)
                return true   // граница проглочена — в приложение не уходит
            }
            // Enter: чинить надо ДО того, как клавиша уйдёт в приложение — чаты отправляют по Enter
            // мгновенно, и boundary-конверсия (async ниже) опаздывала в пустое поле (репорт 11.07,
            // см. convertBeforeReturn). Пробел/Tab не отправляют — им async-путь ниже подходит.
            if keyCode == 36, convertBeforeReturn(flags: flags) {
                return true   // Enter проглочен — уйдёт синтетикой строго после замены
            }
            buffer.boundary(ws)
            // Авто-раскладка срабатывает только по разрешённым клавишам-триггерам.
            var autoTrigger = (keyCode == 49 && settings.triggerSpace)
                           || (keyCode == 36 && settings.triggerEnter)
                           || (keyCode == 48 && settings.triggerTab)
            // Режим разработчика: в IDE/терминалах авто не трогаем (но ⌥⇧ вручную — работает).
            if settings.developerMode && Engine.frontmostIsDevApp() {
                autoTrigger = false
                silentLog("devapp", "авто молчит: dev-режим в IDE/терминале")
            }
            // Программа-исключение: "off" — совсем не трогаем; "soft" — мягко (см. convertFromBuffer).
            let appMode = Engine.frontmostAppMode()
            if appMode == "off" {
                autoTrigger = false
                silentLog("appoff", "авто молчит: приложение в исключениях (режим «выкл»)")
            }
            let tBoundary = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                guard let self = self else { return }
                // Замер: планировали +30мс; всё сверх — очередь main-потока (репорт «стало дольше»).
                let lag = Int((ProcessInfo.processInfo.systemUptime - tBoundary) * 1000)
                if lag > 45 { kbLog("boundary: конверсия стартовала +\(lag)мс от границы (main-поток был занят)") }
                // СВЕРКА С РЕАЛЬНОСТЬЮ на границе слова — момент, когда чтение TIS достоверно
                // (только что было нажатие; kawa PR#21). Мнение разошлось с системой → буфер этого
                // слова декодирован ЧУЖОЙ раскладкой, любое решение по нему опасно: слово честно
                // пропускаем, со следующего декод уже верный. Ловит случай 24.07: уведомление о
                // ручной смене раскладки прочитало стейл → мнение и кэш самосогласованно врали
                // целую строку («cyjdf drk.xbk…» при русском буфере).
                if self.layout.reconcileWithReality() {
                    kbLog("раскладка: мнение разошлось с системой — принял реальность; слово пропущено (декод был чужой раскладкой)")
                    self.liveFixLast = ""
                    self.buffer.clear()
                    return
                }
                guard autoTrigger, self.settings.autoEnabled else { return }
                // Fence A (аудит): юзер уже печатает следующее слово — не стреляем синтетикой в
                // разгар набора (реальная клавиша между нашими backspace'ами = «gприветhello»).
                // ОДНА отсрочка 40мс; печатает и дальше — стреляем всё равно (completedOnly-цель
                // корректна, а Fence B подстрахует от вклинивания).
                if ProcessInfo.processInfo.systemUptime - self.lastRealKeyAt < 0.025 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                        guard let self else { return }
                        self.convertFromBuffer(manual: false, soft: appMode == "soft")
                    }
                    return
                }
                self.convertFromBuffer(manual: false, soft: appMode == "soft")
            }
        case 123, 124, 125, 126: // стрелки
            liveFixLast = ""                  // курсор сместился — якорь self-heal недействителен
            wordEdited = false                // курсор сместился — это уже другое слово/место
            buffer.invalidateGroupHistory()   // стрелка двигает курсор → группа печатала бы вслепую (G2)
            // Опция: стрелка отменяет авто-переключение текущего слова.
            if settings.arrowsCancel { buffer.clear(); UndoLearner.shared.resetContext() }
        case 53, 117, 115, 116, 119, 121:
            // Esc, Fwd-Delete, Home/End/PageUp/PageDown → навигация, всегда сбрасываем контекст
            liveFixLast = ""
            wordEdited = false
            buffer.clear()
            UndoLearner.shared.resetContext()
        default:
            if cmdOrCtrl { liveFixLast = ""; wordEdited = false; buffer.clear(); return false } // это шорткат, не текст
            if let scalar = characters.unicodeScalars.first, isPrintable(scalar) {
                lastRealKeyAt = ProcessInfo.processInfo.systemUptime
                // INLINE-ПОЧИНКА (25.07): пробуем заменить слово ПРЯМО ЗДЕСЬ, внутри колбэка тапа —
                // пока мы не вернули управление, ни одна клавиша пользователя не пройдёт, поэтому
                // вклиниться в нашу замену физически нечему (разбор: memory keyboop-inline-replace-in-callback).
                // Символ ЭТОЙ клавиши на экране ещё НЕ отрисован — он входит в замену, а клавишу глотаем.
                if let post, tryInlineLiveFix(pendingChar: characters, pendingKeyCode: keyCode,
                                              flags: flags, post: post) { return true }
                if muted { inFlightRealKeys += 1 }   // клавиша легла внутрь зоны замены (Fence B)
                buffer.append(characters)
                UndoLearner.shared.observe(current: buffer.currentWord)   // U2: перенабор оригинала = откат
                // «На лету» → «на паузе» (репорт 24.07: «привет» перепечатался сам в себя со звуком,
                // «црфе» осталась). Немедленный live-fix ПОД быстрый набор — генератор рассинхрона:
                // синтетика замены (backspace-ы + перепечатка) летит через ту же очередь событий, и
                // реальная клавиша, вклинившаяся между ними, ложится на экране ВНУТРИ зоны замены, а
                // в буфере — после неё → буфер ≠ экран → детектор судит не то, что видно. Теперь
                // live-fix стреляет через 150мс ТИШИНЫ: пальцы замерли — синтетике никто не мешает.
                // На границе слова (пробел/Enter) конверсия как была — без задержки.
                if settings.liveFixEnabled && settings.autoEnabled {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.maybeLiveFix() }
                }
            }
        }
        return false   // по умолчанию клавишу НЕ глотаем (проглатываем только границу-раскрытие сниппета)
    }

    private var liveFixLast = ""

    /// Юзер стёр букву ВНУТРИ текущего слова и допечатывает (правка опечатки). Пока правит — НЕ
    /// конвертим на лету: иначе спорное live-fix-решение переключит раскладку посреди слова, и хвост
    /// уйдёт в чужую раскладку («пройдём» + «ся»→«cz», баг-репорт). Финальная
    /// конверсия всё равно отработает на границе слова (boundary-auto), но уже без мид-слов-сюрприза.
    /// Сбрасывается на границе слова / навигации / шорткате — следующее слово снова live-fix'ится.
    private var wordEdited = false

    /// Выполнить отложенный ручной хоткей (если был нажат под muted). Зовётся из completion'ов
    /// конверсии сразу после снятия muted — нажатие пользователя не теряется, а отрабатывает по
    /// уже синхронизированному буферу/экрану.
    private func drainPendingManual() {
        guard pendingManual, !muted else { return }
        pendingManual = false
        convertFromBuffer(manual: true)
    }

    /// Хвостовой run латинских букв (для self-heal смешанного слова «кир-префикс + лат-хвост»).
    private static func trailingLatinRun(_ w: String) -> String {
        var run: [Character] = []
        for c in w.reversed() {
            if ("a"..."z").contains(c) || ("A"..."Z").contains(c) { run.append(c) } else { break }
        }
        return String(run.reversed())
    }

    /// Мид-слово конверсия: переключаем раскладку ДО ретайпа (анти-гонка), печатаем Unicode-ом.
    /// Кеш «текущее приложение» — в колбэке НЕЛЬЗЯ дёргать NSWorkspace (медленно, риск таймаута тапа).
    /// Обновляется на смене активного приложения (наблюдатель уже есть в start()).
    private var frontAppMode = ""
    private var frontAppIsDev = false
    func refreshFrontmostAppCache() {
        let app = NSWorkspace.shared.frontmostApplication
        let bid = app?.bundleIdentifier ?? ""
        frontAppMode = ExceptionStore.shared.appMode(bid)
        frontAppIsDev = Engine.devApps.contains(bid) || bid.hasPrefix("com.jetbrains")
        frontAppIsChromium = Engine.chromiumFamily.contains(bid)
            || bid.hasPrefix("com.microsoft.edgemac") || bid.hasPrefix("org.chromium")
            || bid.hasPrefix("com.electron") || bid.hasPrefix("com.tinyspeck")
        // ⚠️ НЕ удлинять паузу перед первым Backspace для Chromium/Electron (пробовали 25.07: 9→40мс).
        // Симптом «остаётся первая буква» — это НЕ поздний backspace, а ГОНКА: пока летит асинхронная
        // пачка (пауза + бэкспейсы + Unicode), пользователь успевает нажать следующую клавишу, и она
        // вклинивается в середину замены (в логе: «в полёт синтетики вклинились реальные клавиши»).
        // Длинная пауза только РАСШИРЯЕТ это окно: 24мс → 54мс, и промахов стало больше.
        // Настоящее лечение — глотать реальные клавиши на время полёта и доигрывать их после (задача
        // #19), а до тех пор держим окно минимальным.
    }
    private var frontAppIsChromium = false

    /// Electron-приложений становится больше, чем мы успеваем вписывать bundle id (Claude, Cursor,
    /// ChatGPT…), поэтому определяем по ФАКТУ: лежит ли внутри бандла Electron Framework. Результат
    /// кэшируем по bundle id — обращение к файловой системе происходит один раз на приложение и
    /// только на смене активного (в колбэке тапа такое звать нельзя).
    private static var electronCache: [String: Bool] = [:]
    static func isElectronApp(_ app: NSRunningApplication?) -> Bool {
        guard let bid = app?.bundleIdentifier else { return false }
        if let cached = electronCache[bid] { return cached }
        guard let url = app?.bundleURL else { return false }
        let fw = url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        let found = FileManager.default.fileExists(atPath: fw.path)
        electronCache[bid] = found
        return found
    }

    /// Chromium/Electron: Unicode-события игнорируют (см. F6 и открытый репорт по Workflowy).
    static let chromiumFamily: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "com.brave.Browser", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
        "com.tinyspeck.slackmacgap", "notion.id", "md.obsidian", "com.figma.Desktop",
        "com.workflowy.desktop", "com.spotify.client", "com.hnc.Discord",
        "com.todoesk.superhuman", "com.linear", "org.whispersystems.signal-desktop",
        "com.vivaldi.Vivaldi", "company.thebrowser.Browser", "com.operasoftware.Opera",
        "ru.yandex.desktop.yandex-browser", "com.yandex.desktop.yandex-browser"
    ]

    /// INLINE-ПОЧИНКА СЛОВА ВНУТРИ КОЛБЭКА ТАПА. Возвращает true, если замена отправлена и
    /// клавишу надо ПРОГЛОТИТЬ (её символ уже входит в напечатанное).
    ///
    /// Почему это решает то, что не решали пауза-гейты: наш tap активный, WindowServer ждёт возврата
    /// из колбэка, а `tapPostEvent` кладёт события ВПЕРЁД возвращаемого. Значит между нашими
    /// backspace-ами и печатью физически не может оказаться реальная клавиша — рваных слов
    /// («yнормаmyj») больше нет по построению, а не по вероятности.
    ///
    /// ЖЁСТКО: тут нельзя AX / TIS / NSSound / NSWorkspace / локи / usleep — только чистая логика.
    /// Всё «тяжёлое» уходит в асинхронный хвост на main.
    /// F3: keyCode проглоченной inline-клавишей — её keyUp тоже надо проглотить (непарный keyup ломает
    /// Chromium/Qt/игры). Одноразовая метка со сроком годности.
    private(set) var inlineSwallowedKeyCode: Int64 = -1
    private var inlineSwallowedAt: TimeInterval = 0
    /// Забрать метку, если это тот самый keyUp и он пришёл вовремя (иначе метка просто истечёт).
    func consumeInlineSwallowedKeyUp(_ keyCode: Int64) -> Bool {
        guard inlineSwallowedKeyCode == keyCode,
              ProcessInfo.processInfo.systemUptime - inlineSwallowedAt < 2.0 else { return false }
        inlineSwallowedKeyCode = -1
        return true
    }

    /// F5: одно срабатывание системного таймаута тапа — и inline выключается до перезапуска.
    /// Лучше потерять фичу, чем поймать «ввод не проходит нигде» (инцидент 21.07).
    private(set) var inlineHealthy = true
    func disableInlineAfterTapTimeout() {
        guard inlineHealthy else { return }
        inlineHealthy = false
        kbLog("inline-fix ОТКЛЮЧЁН на эту сессию: система вырубала тап (страховка F5)")
    }

    private func tryInlineLiveFix(pendingChar: String, pendingKeyCode: Int64, flags: CGEventFlags, post: (CGEvent) -> Void) -> Bool {
        guard settings.inlineLiveFix, inlineHealthy, settings.liveFixEnabled, settings.autoEnabled else { return false }
        guard Warm.isReady, !muted, !wordEdited else { return false }   // F7: асинхронная синтетика в полёте → молчим
        guard !frontAppIsDev || !settings.developerMode else { return false }
        guard frontAppMode.isEmpty else { return false }          // приложение в исключениях (off/soft)
        // F6 (ревью 25.07): Chromium/Electron игнорируют Unicode-события и печатают носитель как «a»,
        // а backspace'ы при этом доходят → слово удалено, вставки нет. Наш открытый репорт (Workflowy,
        // 24.07) — ровно про это. Пока вставка в Chromium не решена, inline там ЗАПРЕЩЁН: у этих
        // приложений остаётся прежний асинхронный путь по границе слова.
        guard !frontAppIsChromium else { return false }
        // F2 (ревью 25.07): если пользователь ФИЗИЧЕСКИ держит модификатор, наши backspace'ы поедут
        // с ним: ⇧⌫ выделяет назад, ⌥⌫ стирает слово целиком — молчаливая потеря текста. Заглавные
        // буквы набирают с зажатым ⇧, так что случай штатный. Флаги события не «обнулить»: приложение
        // читает ГЛОБАЛЬНОЕ состояние модификаторов. Единственный безопасный ход — не стрелять.
        let heldMods: CGEventFlags = [.maskShift, .maskAlternate, .maskCommand, .maskControl]
        guard flags.intersection(heldMods).isEmpty else { return false }
        // F5: secure input проверяем ЗДЕСЬ по кэшу поллера, а не в TextReplacer (сам вызов до ~44мс).
        guard !secureInputWasOn else { return false }
        // Слово на экране = буфер; символ этой клавиши ещё не отрисован — добавляем его сами.
        let onScreen = buffer.currentWord
        let candidate = onScreen + pendingChar
        guard candidate.count >= 4, candidate.count <= 16 else { return false }   // cap: держим колбэк коротким
        guard candidate != liveFixLast else { return false }
        guard !candidate.hasCyrillic || !candidate.hasLatinLetter else { return false }  // смешанное — не наш случай
        guard case .convert(let toCyr) = LayoutDetector.liveDecide(word: candidate) else { return false }
        let converted = Keymap.smartConvert(candidate, toCyrillic: toCyr, isValidTarget: Self.ruWordValidator)
        guard converted != candidate else { return false }
        guard antiResonance.allow(word: candidate, produced: converted) else {
            liveFixLast = ""; buffer.clear(); return false
        }
        if UndoLearner.shared.shouldSuppress(current: candidate)
            || UndoLearner.shared.isSessionProtected(candidate) { return false }
        // Печатаем: удалить то, что НА ЭКРАНЕ (onScreen), впечатать converted (он включает символ клавиши).
        guard TextReplacer.replaceInline(deleteCount: onScreen.count, with: converted, post: post) else { return false }
        inlineSwallowedKeyCode = pendingKeyCode   // F3: его keyUp тоже проглотим (иначе непарный keyup)
        inlineSwallowedAt = ProcessInfo.processInfo.systemUptime
        // Модель — синхронно (следующая клавиша обязана видеть верный буфер).
        buffer.append(pendingChar)
        buffer.applyConversion(converted: converted)
        liveFixLast = converted
        // Хвост: всё, что нельзя в колбэке.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layout.selectLayout(cyrillic: toCyr)
            UndoLearner.shared.noteConversion(original: candidate, converted: converted)
            self.settings.rescuedCount += 1
            self.onLayoutMaybeChanged?()
            self.playSound()
            kbLog("inline-fix: \(candidate.count)→\(converted.count) симв. \(Self.scriptClass(candidate))→\(Self.scriptClass(converted))")
        }
        return true
    }

    private func maybeLiveFix() {
        guard Warm.isReady else { silentLog("warm", "авто молчит: языковые данные ещё греются"); return }
        guard !mutedStuckCheck() else { return }   // muted честный → синтетика в полёте; застрявший снимает сторож
        guard !wordEdited else { return }   // юзер правит опечатку внутри слова → не дёргаем раскладку до границы
        // Пауза-гейт (см. место планирования в handleKeyDown): если после планирования пришла новая
        // клавиша — молчим; её собственный отложенный вызов проверит тишину заново. Стреляет только
        // ПОСЛЕДНИЙ вызов серии — через 150мс после того, как пальцы остановились.
        guard ProcessInfo.processInfo.systemUptime - lastRealKeyAt >= 0.14 else { return }
        let word = buffer.currentWord
        guard word.count >= 4, word != liveFixLast else { return }
        if settings.developerMode && Engine.frontmostIsDevApp() { return }
        // Программа-исключение (встроенная или пользовательская): off/soft → НЕ чиним на лету
        // (видеоредакторы/терминалы/код — синтетика мид-слова там особенно нежелательна).
        if !Engine.frontmostAppMode().isEmpty { return }
        // Обучение на отмене: не трогаем слово, которое юзер прямо сейчас восстанавливает, и то,
        // что он уже восстановил в этом контексте (анти-«драка»).
        if UndoLearner.shared.shouldSuppress(current: word) || UndoLearner.shared.isSessionProtected(word) { return }
        // SELF-HEAL: слово стало смешанным (кир-префикс + сырой лат-хвост) — артефакт частичной
        // конверсии (live-fix починил начало, пока дописывали хвост на медленной печати). liveDecide
        // такое слово игнорирует (sourceCyr == sourceLat → .keep), и без лечения оно «застревает».
        // Чиним ТОЛЬКО хвост, удаляя ровно столько символов, сколько сырых на экране → слово сходится
        // к одному скрипту. Одиночное смешанное слово — практически всегда наш артефакт. (2026-06-19.)
        if word.hasCyrillic, word.hasLatinLetter {
            let tail = Self.trailingLatinRun(word)
            let prefix = String(word.dropLast(tail.count))
            guard tail.count >= 1, !prefix.hasLatinLetter else { return }   // чистый split кир|лат
            // Лечим ТОЛЬКО наш собственный артефакт: кир-префикс должен быть ровно тем, что мы
            // только что сконвертировали. Иначе не трогаем (намеренно смешанный текст не портим).
            guard prefix == liveFixLast else { return }
            let convTail = Keymap.convert(tail, toCyrillic: true)
            guard convTail != tail, !(convTail.hasCyrillic && convTail.hasLatinLetter) else { return }
            // Предохранитель от резонанса: если это место уже мелькало туда-сюда — стоп, чистим буфер.
            guard antiResonance.allow(word: word, produced: prefix + convTail) else {
                liveFixLast = ""; buffer.clear(); return
            }
            muted = true
            layout.selectLayout(cyrillic: true)
            TextReplacer.replace(deleteCount: tail.count, with: convTail) { [weak self] in
                guard let self else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + self.muteDrain) { self.endSyntheticFlight() }
            }
            buffer.applyConversion(converted: prefix + convTail)
            liveFixLast = prefix + convTail
            onLayoutMaybeChanged?()
            playSound()
            kbLog("live-heal: хвост \(tail.count) симв.")   // контент не логируем (приватность)
            return
        }
        guard case .convert(let toCyr) = LayoutDetector.liveDecide(word: word) else { return }
        let converted = Keymap.smartConvert(word, toCyrillic: toCyr, isValidTarget: Self.ruWordValidator)
        guard converted != word else { return }
        // Предохранитель от резонанса: осцилляция этого места → стоп, разрываем цикл (чистим буфер).
        guard antiResonance.allow(word: word, produced: converted) else {
            liveFixLast = ""; buffer.clear(); return
        }
        // Фантомный предохранитель (24.07): экран уже показывает converted → буфер отстал от жизни
        // (стейл-переводы), замена дала бы только звук и мигание. Выравниваем модель и молчим.
        // Только в окне после нашего переключения (см. boundary-путь): вне его AX-IPC на main —
        // лишний риск таймаута тапа, а фантом невозможен. nil (AX недоступен) → обычный путь.
        if layout.withinOwnSelectGrace, AXScreenCheck.caretEndsWith(converted) == true {
            kbLog("фантом предотвращён (live-fix): на экране уже итог (AX), len \(converted.count)")
            buffer.applyConversion(converted: converted)
            liveFixLast = converted
            return
        }
        muted = true
        layout.selectLayout(cyrillic: toCyr)            // раскладка — раньше ретайпа
        // Снятие muted — в completion (после async-постинга синтетики на serial-очереди), а не по
        // фикс-таймеру: иначе размьютит до того, как backspace+ретайп отыграют → re-entrancy.
        TextReplacer.replace(deleteCount: word.count, with: converted) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + self.muteDrain) { self.endSyntheticFlight() }
        }
        buffer.applyConversion(converted: converted)
        UndoLearner.shared.noteConversion(original: word, converted: converted)   // кандидат на откат
        settings.rescuedCount += 1                       // мид-слово тоже считаем
        onLayoutMaybeChanged?()
        playSound()                                     // звук конвертации (как в обычном переключении)
        liveFixLast = converted
        kbLog("live-fix: \(word.count)→\(converted.count) симв. \(Self.scriptClass(word))→\(Self.scriptClass(converted))")   // контент в лог не пишем (приватность)
        noteConvRepeat(word: word, produced: converted, path: "live")
    }

    func handleSwitchHotkey() {
        DispatchQueue.main.async { [weak self] in
            self?.convertFromBuffer(manual: true)
        }
    }

    /// 🌐/Fn/⇪: ТОЛЬКО смена языка, набранное не трогаем (в отличие от хоткея конвертации).
    /// Ровно поведение системной клавиши, но без её задержки — мы срабатываем по факту
    /// чистого отпускания, а macOS ждёт, не начало ли это комбинации.
    ///
    /// Направление считаем от ПАМЯТИ (currentIsCyrillicOpinion), а не от сырого TIS-чтения:
    /// баг стейл-кэша давал «→ EN» ×6 подряд — каждое нажатие читало устаревший RU и «переключало»
    /// туда же (баг-репорт, разбор в LayoutManager.opinionCyr).
    func handleLayoutSwitchOnly() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let curCyr = self.layout.currentIsCyrillicOpinion()
            let toCyr = !curCyr
            guard self.layout.selectLayout(cyrillic: toCyr) else {
                kbLog("globe: НЕ переключил — среди включённых раскладок нет \(toCyr ? "RU" : "EN")")
                return
            }
            // Слово оборвано сменой языка: дальше пойдут символы другого алфавита, и старый
            // префикс в буфере сделал бы из них «смешанное» слово. Начинаем с чистого листа.
            self.liveFixLast = ""
            self.buffer.clear()
            self.onLayoutMaybeChanged?()
            // Звук НЕ играем (просьба автора 24.07): это замена системной смены языка, а она
            // молчит. Индикатор в строке меню и так показывает текущий язык.
            kbLog("globe: язык переключён \(curCyr ? "RU" : "EN") → \(toCyr ? "RU" : "EN")")
            // (300мс-диагностику стейл-чтения убрали: механизм подтверждён и уже обслуживается
            //  opinionCyr + reconcileWithReality; лишний TIS-read на main под globe-шторм не нужен.)
        }
    }

    func handleTranslateHotkey() {
        kbLog("translate: хоткей нажат")
        DispatchQueue.main.async { [weak self] in self?.translateSelection() }
    }

    /// Перевод выделенного текста (Apple Translation, macOS 15+). Буфер НЕ трогаем (принцип №1):
    /// читаем выделение через AX, пишем обратно через AX/печать. Направление — по содержимому.
    private func translateSelection() {
        guard !muted else { return }
        if IsSecureEventInputEnabled() { NSSound.beep(); return }   // поле пароля — не читаем выделение (L1, 01.07)
        liveFixLast = ""                               // ручной хоткей перевода рвёт слово — якорь self-heal сброшен
        guard #available(macOS 15.0, *) else { kbLog("translate: нужна macOS 15"); NSSound.beep(); return }
        #if canImport(Translation)
        muted = true                                  // глушим синтетический Cmd+C от readViaClipboard
        let sel = SelectionText.read()
        muted = false
        guard let (text, writeBack) = sel else { kbLog("translate: выделение не прочитано"); NSSound.beep(); return }
        let dir = TranslateDirection.of(text)
        kbLog("translate: \(text.count) симв. \(dir.from)→\(dir.to)…")
        Task { @MainActor in
            // Языковой пакет не установлен → ЧЕСТНО говорим баннером (не молчим и не играем «успех»-звук
            // зря — иначе «звук был, а перевода нет»). Именно этот кейс у большинства новых пользователей.
            guard await TranslationEngine.shared.isInstalled(from: dir.from, to: dir.to) else {
                kbLog("translate: языковой пакет \(dir.from)→\(dir.to) не установлен")
                // Не молчим и не конвертируем раскладку (иначе «привет как дела»→«ghbdtn rfr ltkf»):
                // баннер с кнопкой «Скачать» ставит пакет прямо из приложения, оба направления сразу.
                AppBanner.shared.show(
                    title: L10n.t("tr.needPackTitle"),
                    body: L10n.t("tr.needPackBody"),
                    actions: [.init(title: L10n.t("tr.download"), coral: true) {
                        TranslationEngine.shared.presentDownload(pairs: [("ru", "en"), ("en", "ru")]) { _ in }
                    }])
                return
            }
            guard let t = await TranslationEngine.shared.translate(text, from: dir.from, to: dir.to),
                  t != text else { kbLog("translate: пусто/без изменений"); return }
            self.playTranslateSound()                 // звук — ТОЛЬКО когда реально перевели
            self.muted = true
            if !(writeBack?(t) ?? false) {
                TextReplacer.insert(t) { [weak self] in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.muted = false; self?.drainPendingManual() }
                }
            } else {   // запись через AX (синтетику не постим) — снимаем muted по таймеру как раньше
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.muted = false; self?.drainPendingManual() }
            }
            self.buffer.clear()
        }
        #endif
    }

    // MARK: - Конвертация

    /// Конвертация ВЫДЕЛЕННОГО текста (нативные приложения, через AX). true — если выделение
    /// было и сконвертировано. Направление — по содержимому. Буфер обмена НЕ трогаем (принцип №1).
    private func convertSelection() -> Bool {
        // Secure Input (поле пароля): НЕ читаем выделение — ни через AX, ни синтетическим Cmd+C, иначе
        // можно вытащить пароль. Клавиатурный путь уже гейтится в handleKeyDown; закрываем и путь
        // выделения (security-аудит L1, 01.07).
        if IsSecureEventInputEnabled() { return false }
        muted = true                                  // глушим синтетический Cmd+C от readViaClipboard
        let sel = SelectionText.read()
        guard let (text, writeBack) = sel else {
            muted = false
            kbLog("convert-selection: выделение не прочитано — падаю на последнее слово")
            return false
        }
        // Защита от «Cmd+C при пустом выделении копирует целую строку/абзац» (редакторы, терминалы,
        // VS Code): многострочный текст — почти наверняка авто-копия, а не намеренное выделение для
        // смены раскладки. И для clipboard-fallback (writeBack==nil, не можем проверить) — кап по длине.
        let isClipboard = (writeBack == nil)
        if text.contains("\n") || text.contains("\r") || (isClipboard && text.count > 80) {
            muted = false
            kbLog("convert-selection: отклонено (\(text.count) симв., многострочн=\(text.contains("\n")), clipboard=\(isClipboard)) — вероятно авто-копия строки, падаю на слово")
            return false
        }
        let toCyrillic: Bool
        if text.hasCyrillic { toCyrillic = false }
        else if text.hasLatinLetter { toCyrillic = true }
        else { muted = false; return false }          // нет букв — нечего переключать
        let converted = Keymap.convert(text, toCyrillic: toCyrillic)
        guard converted != text else { muted = false; return false }
        let usedSynth = !(writeBack?(converted) ?? false)
        if usedSynth {
            TextReplacer.insert(converted) { [weak self] in   // печатаем поверх выделения (Unicode)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.muted = false; self?.drainPendingManual() }
            }
        }
        // выделение могло быть из нескольких слов — считаем по словам
        settings.rescuedCount += max(1, text.split(separator: " ").count)
        layout.selectLayout(cyrillic: toCyrillic)
        onLayoutMaybeChanged?()
        buffer.clear()
        playSound()                                   // звук конвертации — подтверждение действия
        kbLog("convert-selection: \(text.count) симв. → \(toCyrillic ? "RU" : "EN")")
        if !usedSynth {   // запись через AX — снимаем muted по таймеру
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.muted = false; self?.drainPendingManual() }
        }
        return true
    }

    /// Групповая конвертация нескольких слов сессии набора одним хоткеем (эксперимент, groupConvert).
    /// КЛЮЧЕВОЕ (ключевая идея H): конвертируем ПОСЛОВНО только те слова, что LayoutDetector
    /// помечает как .convert — валидные слова в группе НЕ трогаем («hello ghbdtn» → «hello привет»).
    /// Печатаем Unicode напрямую (Backspace + set), буфер обмена НЕ трогаем (принцип №1).
    private func convertGroup() -> Bool {
        guard let g = buffer.groupForConversion() else { return false }
        var out = ""
        var anyConverted = false
        var convertedN = 0            // сколько слов реально починили (для счётчика спасённых)
        var lastToCyrillic = false
        var prevWord: String? = nil   // бежит по группе: предыдущее слово-РЕЗУЛЬТАТ (для контекста)
        for (word, tail) in g.words {
            switch LayoutDetector.decide(word: word, exceptions: ExceptionStore.shared, prev: prevWord) {
            case .convert(let toCyr):
                // smartConvert бережёт концевую пунктуацию, длина символов сохраняется (1:1) →
                // out.count == deleteCount, удаление Backspace'ами совпадает с напечатанным.
                let conv = Keymap.smartConvert(word, toCyrillic: toCyr, isValidTarget: Self.ruWordValidator)
                out += conv + tail
                anyConverted = true
                convertedN += 1
                lastToCyrillic = toCyr
                prevWord = conv
            case .keep:
                out += word + tail                     // валидное слово — оставляем как набрано
                prevWord = word
            }
        }
        // Все слова валидны (нечего конвертировать): группа «съедает» хоткей как no-op и возвращает
        // true — НЕ падаем на single-word логику, иначе она force-конвертнула бы валидное последнее
        // слово в кашу (G5: «hello world» → beep + «world»→«цщкдв»). Без beep — текст корректен.
        guard anyConverted else { return true }
        // Инвариант длины: smartConvert/keep строго 1:1 по символам → out.count == deleteCount.
        // Если вдруг разошлось (будущие не-1:1 преобразования) — НЕ печатаем вслепую (защита от порчи).
        guard out.count == g.deleteCount else {
            kbLog("convert-group: длина out(\(out.count)) ≠ deleteCount(\(g.deleteCount)) — отказ")
            return true
        }

        muted = true
        kbLog("convert-group(хоткей): \(g.words.count) слов, \(g.deleteCount) симв.")   // без контента
        // Синтетика — async на serial-очереди (не морозим main с активным tap'ом). Снятие muted — в
        // completion: оно сработает РОВНО после постинга, поэтому length-scaling задержки больше не нужен
        // (раньше масштабировали под время синхронного постинга на main, G4) — хватает дренаж-константы.
        TextReplacer.replace(deleteCount: g.deleteCount, with: out) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + self.muteDrain) { self.endSyntheticFlight() }
        }
        settings.rescuedCount += convertedN            // вся группа разом — по числу починенных слов
        buffer.clear()                                 // состояние слов изменилось — начинаем сессию заново
        layout.selectLayout(cyrillic: lastToCyrillic)  // раскладку — по последнему сконвертированному
        onLayoutMaybeChanged?()
        playSound()
        return true
    }

    private func convertFromBuffer(manual: Bool, soft: Bool = false) {
        // Ручной хоткей в muted-окно НЕ теряем: откладываем до снятия muted (drainPendingManual).
        // Авто (manual=false) повторять не нужно — оно само придёт со следующим словом/границей.
        guard !mutedStuckCheck() else {
            if manual { pendingManual = true } else { silentLog("muted", "авто молчит: синтетика в полёте (muted)") }
            return
        }
        // Ручной хоткей (вкл. group/selection с buffer.clear()) рвёт текущее слово → якорь self-heal
        // недействителен. Авто (manual=false) НЕ трогаем — оно не должно стирать якорь набираемого
        // следующего слова (ревью 2026-06-19, закрытие residual-гэпа #2).
        if manual { liveFixLast = "" }
        // ПОРЯДОК ВАЖЕН (фикс бага #39): если буфер НЕ пуст (только что печатали) — чиним именно
        // набранное слово, выделение НЕ трогаем. Иначе Cmd+C в редакторах/терминалах при ПУСТОМ
        // выделении копирует ЦЕЛУЮ СТРОКУ → раньше конвертило 150 символов вместо последнего слова.
        // Выделение пробуем только когда буфер пуст (клик/мышь чистят буфер = намеренное выделение).
        if manual, buffer.wordForConversion() == nil, convertSelection() { return }
        // Экспериментально: групповая конвертация нескольких слов сессии (если включено и слов ≥2).
        // ТОЛЬКО при ВЫКЛЮЧЕННОМ авто-переключении: при авто sessionWords рассинхронятся с экраном
        // (авто чинит каждое слово на лету, не обновляя sessionWords) → группа испортила бы текст.
        // При авто группа к тому же бессмысленна. UI делает тумблер серым при авто — это страхует логику.
        // Падает на одно-словную логику ниже, если группы нет (groupForConversion вернул nil).
        if manual, settings.groupConvert, !settings.autoEnabled, convertGroup() { return }
        // Авто (boundary) целится строго в ЗАВЕРШЁННОЕ слово (аудит C2): за +30мс задержки юзер
        // мог начать следующее — раньше конверсия перечитывала буфер, попадала в огрызок «x» и
        // молча no-op'ала, а завершённое слово сиротело («иногда не переключается» у быстрых рук).
        guard let item = buffer.wordForConversion(completedOnly: !manual) else {
            if !manual { silentLog("emptybuf", "авто молчит: на границе слова буфер пуст") }
            // Нечего конвертировать (буфер пуст), но нажат хоткей — просто переключаем язык RU↔EN.
            if manual {
                let toCyr = !layout.currentIsCyrillic()
                layout.selectLayout(cyrillic: toCyr)
                onLayoutMaybeChanged?()
                playSound()
            }
            return
        }
        let word = item.word

        var autoProp: (text: String, toCyrillic: Bool, rescue: Bool)?
        let toCyrillic: Bool
        if manual {
            // Явный хоткей — направление по содержимому; если в слове только символы/
            // цифры/кавычки (букв нет) — по текущей системной раскладке.
            if word.hasCyrillic {
                toCyrillic = false
            } else if word.hasLatinLetter {
                toCyrillic = true
            } else {
                toCyrillic = !layout.currentIsCyrillic()
            }
        } else {
            // ЕДИНАЯ точка авто-решения (session-protect + mixed-rescue + детектор + soft-фильтр +
            // smartConvert) — общая с enter-pre путём (convertBeforeReturn): логика не расходится.
            guard let prop = autoConversionProposal(word: word, soft: soft, completed: true) else { return }
            autoProp = prop
            toCyrillic = prop.toCyrillic
        }

        // Ручной хоткей переключает ВСЁ (буквы + знаки + кавычки); авто — готовый текст из proposal
        // (smartConvert бережёт концевую пунктуацию: "ghbdtn." → "привет.", а не "приветю").
        let converted = autoProp?.text ?? Keymap.convert(word, toCyrillic: toCyrillic)
        guard converted != word else {
            if manual { NSSound.beep() }
            return
        }
        // Авто-конверсия (boundary) проходит через анти-резонансный предохранитель; ручной хоткей — нет
        // (юзер решает сам, резонировать не может). Осцилляция → стоп, чистим буфер, разрываем цикл.
        if !manual, !antiResonance.allow(word: word, produced: converted) {
            silentLog("resonance", "авто молчит: анти-резонанс заморозил конверсию (len \(word.count))")
            liveFixLast = ""; buffer.clear(); return
        }
        // ФАНТОМНЫЙ ПРЕДОХРАНИТЕЛЬ (24.07): экран уже показывает итог? Тогда буфер отстал от
        // жизни (стейл-переводы) — заменять нечего, только звук и мигание. Молча выравниваем
        // модель по экрану. AX молчит (Electron/веб) → nil → обычный путь.
        // ТОЛЬКО в окне после НАШЕГО переключения раскладки: стейл-фантом возможен лишь там, а AX-чтение
        // синхронно на main (до ~150мс IPC) — гонять его на КАЖДУЮ конверсию congestило main и роняло
        // тап по таймауту у занятых приложений (репорт #8, 0.2.66). Вне окна буфер достоверен, страж не нужен.
        if !manual, layout.withinOwnSelectGrace, AXScreenCheck.caretEndsWith(converted + item.tail) == true {
            kbLog("фантом предотвращён: на экране уже итог (AX), len \(converted.count) — буфер выровнен")
            buffer.applyConversion(converted: converted)
            return
        }

        muted = true
        kbLog("\(autoProp?.rescue == true ? "mixed-rescue" : "convert-word")\(manual ? "(хоткей)" : "(авто)"): \(item.deleteCount) симв. \(Self.scriptClass(word)) → \(toCyrillic ? "RU" : "EN")")   // без контента
        noteConvRepeat(word: word, produced: converted, path: manual ? "хоткей" : "boundary")
        // Снятие muted — в completion (после async-постинга), а не фикс-таймером (см. live-fix выше).
        TextReplacer.replace(deleteCount: item.deleteCount, with: converted + item.tail) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + self.muteDrain) { self.endSyntheticFlight() }
        }
        if manual { buffer.applyConversion(converted: converted) }
        else { buffer.applyCompletedConversion(converted: converted) }   // огрызок следующего слова не трогаем (C2)
        // Обучение на отмене: авто-конверсия → кандидат на откат; ручной ре-флип, отменяющий нашу
        // недавнюю авто-конверсию (U1), — засчитываем как откат.
        if manual {
            UndoLearner.shared.noteManualConvert(from: word, to: converted)
            // Любая ручная конверсия → защищаем РЕЗУЛЬТАТ от немедленной повторной авто-конверсии:
            // юзер сам выбрал раскладку слова, следующий пробел не должен флипнуть его обратно «не туда»
            // (просьба автора 2026-06-22). Сбрасывается на смене контекста (клик/навигация).
            UndoLearner.shared.protect(converted)
        } else if autoProp?.rescue != true {
            // mixed-rescue не учим на отмене (артефакт нашего же флипа, не выбор юзера) — как и раньше.
            UndoLearner.shared.noteConversion(original: word, converted: converted)
        }
        settings.rescuedCount += 1                      // зверёк расколдовал ещё одно слово
        layout.selectLayout(cyrillic: toCyrillic)
        onLayoutMaybeChanged?()
        playSound()
        // muted снимается в completion TextReplacer выше (после постинга синтетики).
    }

    /// ЧИСТОЕ авто-решение для слова (без побочных эффектов): текст замены + направление + признак
    /// mixed-rescue, либо nil («не трогаем»). ЕДИНАЯ точка для boundary-авто (convertFromBuffer)
    /// и enter-pre (convertBeforeReturn) — два пути обязаны решать ОДИНАКОВО, иначе дрейф.
    private func autoConversionProposal(word: String, soft: Bool, completed: Bool = false)
        -> (text: String, toCyrillic: Bool, rescue: Bool)?
    {
        guard Warm.isReady else { return nil }   // см. Warm: до готовности молчим, а не блокируем колбэк
        // Обучение на отмене: слово, которое юзер только что восстановил в этом контексте, —
        // не конвертируем повторно (анти-«драка»), даже если порог обучения ещё не достигнут.
        if UndoLearner.shared.isSessionProtected(word) {
            kbLog("авто молчит: слово под session-защитой UndoLearner (len \(word.count))")   // диагностика 23.07
            return nil
        }
        // СПАСЕНИЕ СМЕШАННОГО СЛОВА (кир+лат): артефакт нашего мид-слов-флипа + правки опечатки
        // («привtn», «приdет», «ghbdет»). decide() их всегда .keep → «переключилось только окончание».
        // Чиним по словарю (ровно одна сторона даёт валидное слово), весь токен 1:1 → длина == deleteCount.
        // Намеренный билингв (API-ключ, C++код, helloмир) не валиден ни в одну сторону → не трогаем.
        if case .convert(let toCyr) = LayoutDetector.mixedRescue(word: word) {
            return (Keymap.convert(word, toCyrillic: toCyr), toCyr, true)
        }
        // Двусторонний детектор (словарь + триграммы + force-swap + исключения) + контекст фразы:
        // предыдущее слово разрешает короткие коллизии (yt↔не) и классификаторы (vitamin d). O(1).
        // Для завершённого слова (boundary) «предыдущее» — это dropLast: само слово уже лежит
        // последним в sessionWords, и forCurrent:true вернуло бы его самого как контекст (C2).
        let prevW = buffer.contextWord(forCurrent: !completed && !buffer.currentWord.isEmpty)
        switch LayoutDetector.decide(word: word, exceptions: ExceptionStore.shared, prev: prevW) {
        case .keep:
            silentLog("keep", "авто молчит: детектор keep (len \(word.count), \(Self.scriptClass(word)), раскладка(мнение)=\(layout.currentIsCyrillicOpinion() ? "RU" : "EN"))")
            return nil
        case .convert(let c):
            // Мягкий фильтр: не трогаем одиночные/короткие/повторяющиеся буквы — только
            // очевидные слова (анти-Punto: C/V/B + пробел не должны конвертиться).
            // Включается (а) для программ-исключений в режиме «Мягкий», (б) ГЛОБАЛЬНО при
            // режиме разработчика: переменные c/d/i и команды живут не только в IDE —
            // в Slack, заметках, доках (просьба автора 2026-06-09). Обычным людям без
            // dev-режима одиночные предлоги (d→в, c→с) чинятся как прежде.
            if soft || settings.developerMode {
                let core = Keymap.core(of: word).lowercased()
                if core.count <= 2 || Set(core).count == 1 {
                    silentLog("soft", "авто молчит: мягкий фильтр (короткое/однобуквенное, len \(word.count))")
                    return nil
                }
            }
            let converted = Keymap.smartConvert(word, toCyrillic: c, isValidTarget: Self.ruWordValidator)
            if converted == word {
                kbLog("авто молчит: конверсия совпала с исходным (len \(word.count))")   // диагностика 23.07
                return nil
            }
            return (converted, c, false)
        }
    }

    /// Enter-гонка «send on Enter» (репорт Жени 11.07, скрин: «nbgf» отправлен, «типа» осталось в
    /// строке ввода): чат отправляет сообщение по Enter МГНОВЕННО, а boundary-конверсия приходила
    /// через 30мс в уже ПУСТОЕ поле — сообщение улетало неисправленным, и исправленное слово
    /// печаталось в опустевшую строку. Фикс: голый Enter ГЛОТАЕМ (тап активный — прецедент
    /// сниппетов), чиним слово, пока оно ЕЩЁ на экране, и отпускаем синтетический Return строго
    /// ПОСЛЕ замены (thenReturn в том же synth-задании) → приложение отправляет уже починенный
    /// текст. В редакторах то же: починка, затем перенос. Задержка Enter ≈ длина слова × 2.7мс +
    /// 10мс — незаметно. Аварийный откат без релиза: defaults write ru.keyboop.app enterPreConvert -bool NO.
    /// Возвращает true, если Enter проглочен (уйдёт синтетикой).
    private func convertBeforeReturn(flags: CGEventFlags) -> Bool {
        guard Warm.isReady else { return false }   // см. Warm
        guard settings.enterPreConvert, settings.autoEnabled, settings.triggerEnter, !muted else { return false }
        // Только «голый» Enter: ⇧/⌘/⌥/⌃+Enter несут свою семантику (newline/alt-send) — не задерживаем,
        // а синтетический Return всё равно ушёл бы без модификаторов (postKey шлёт flags=[]).
        guard flags.intersection([.maskShift, .maskCommand, .maskAlternate, .maskControl]).isEmpty else { return false }
        let word = buffer.currentWord
        guard !word.isEmpty else { return false }   // слово уже завершено пробелом → обычный путь
        // Сверка с реальностью (аудит-гэп): enter-pre работает синхронно и не проходил через
        // boundary-сверку. Мнение разошлось → декод слова недостоверен → Enter без конверсии
        // (честно отправить как есть лучше, чем сконвертировать по чужой раскладке).
        if layout.reconcileWithReality() {
            kbLog("enter-pre: раскладка разошлась с мнением — Enter пропущен без конверсии")
            liveFixLast = ""; buffer.clear()
            return false
        }
        if settings.developerMode && Engine.frontmostIsDevApp() { return false }
        let appMode = Engine.frontmostAppMode()
        if appMode == "off" { return false }
        guard let prop = autoConversionProposal(word: word, soft: appMode == "soft") else { return false }
        // AX-предохранителя здесь НЕТ намеренно (финал аудита 24.07, R1): enter-pre работает
        // СИНХРОННО внутри колбэка тапа, а AX-чтение — до 2×50мс IPC к занятому приложению =
        // риск kCGEventTapDisabledByTimeout на самом горячем пути «Enter-отправить». Boundary и
        // live-fix предохранители живут в async-блоках — им можно. Enter-pre защищён сверкой
        // раскладки выше + анти-резонансом ниже; его фантомный риск низкий (слово не завершено,
        // модель им ещё владеет).
        guard antiResonance.allow(word: word, produced: prop.text) else {
            liveFixLast = ""; buffer.clear(); return false   // резонанс — разрываем цикл, Enter пропускаем
        }
        muted = true
        kbLog("\(prop.rescue ? "mixed-rescue" : "convert-word")(enter-pre): \(word.count) симв. → \(prop.toCyrillic ? "RU" : "EN")")   // без контента
        noteConvRepeat(word: word, produced: prop.text, path: "enter")
        TextReplacer.replace(deleteCount: word.count, with: prop.text, thenReturn: true) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + self.muteDrain) { self.endSyntheticFlight() }
        }
        buffer.applyConversion(converted: prop.text)   // экран после замены = converted
        buffer.boundary("\n")                          // граница в модели: Enter уйдёт нашей синтетикой
        if !prop.rescue { UndoLearner.shared.noteConversion(original: word, converted: prop.text) }
        settings.rescuedCount += 1
        layout.selectLayout(cyrillic: prop.toCyrillic)
        onLayoutMaybeChanged?()
        playSound()
        return true
    }

    /// Режем управляющие символы из раскрытия сниппета (кроме \n и \t).
    private static func sanitizeSnippet(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || $0.value >= 0x20 }))
    }

    private var switchCue: NSSound?   // удерживаем синтез-звук, иначе оборвётся на середине
    /// Звук переключения: "keyboop" = НАШ синтез-«поп» (по умолчанию), "" = тишина,
    /// иначе системный звук по имени (кому привычнее Pop/Tink — остаётся выбор).
    private func playSound() {
        guard settings.soundEnabled, !settings.soundName.isEmpty else { return }
        let vol = Float(max(0, min(1, settings.soundVolume)))
        if settings.soundName == "keyboop" {
            switchCue?.stop()
            switchCue = NSSound(data: CueSynth.switchData)
            switchCue?.volume = vol
            switchCue?.play()
        } else {
            let s = NSSound(named: settings.soundName)
            s?.volume = vol
            s?.play()
        }
    }

    private var translateCue: NSSound?   // удерживаем синтез-звук, иначе оборвётся
    /// Звук перевода: "keyboop" = наш синтез-трезвучие, "" = тишина, иначе системный звук по имени.
    private func playTranslateSound() {
        guard settings.translateSoundEnabled else { return }
        let name = settings.translateSoundName
        guard !name.isEmpty else { return }
        let vol = Float(max(0, min(1, settings.translateSoundVolume)))
        if name == "keyboop" {
            translateCue?.stop()
            translateCue = NSSound(data: CueSynth.translateData)
            translateCue?.volume = vol
            translateCue?.play()
        } else {
            let s = NSSound(named: name); s?.volume = vol; s?.play()
        }
    }

    /// Приложения-разработчика: IDE и терминалы, где авто-переключение лишнее при кодинге.
    static let devApps: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.apple.dt.Xcode",
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.zed.Zed",
        "sh.cursor.Cursor", "com.exafunction.windsurf", "com.panic.Nova", "com.github.atom",
        "com.sublimetext.4", "com.sublimetext.3", "org.vim.MacVim", "io.alacritty",
        "net.kovidgoyal.kitty", "com.apple.Console",
        "com.mitchellh.ghostty", "co.zeit.hyper", "org.tabby", "com.github.wez.wezterm"
    ]
    static func frontmostIsDevApp() -> Bool {
        guard let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return devApps.contains(bid) || bid.hasPrefix("com.jetbrains")
    }

    /// ВСТРОЕННЫЕ дефолты-исключения (чтобы юзеру не приходилось искать настройку — частая жалоба).
    /// «off» — авто-переключение ВЫКЛ совсем: видеоредакторы (Space=play, а Backspace=УДАЛИТЬ КЛИП —
    /// наша синтетика может натворить дел) и терминалы (Space/команды критичны). «soft» — мягкий режим:
    /// код-редакторы (прозу/комментарии чиним, но одиночные буквы/команды/переменные не трогаем).
    /// Пользователь может переопределить в Настройках → Исключения (его выбор приоритетнее).
    static let defaultOffApps: Set<String> = [
        "com.apple.FinalCut", "com.apple.motionapp", "com.apple.Compressor",
        "com.apple.logic10", "com.apple.garageband10", "com.apple.iMovieApp",
        "com.ableton.live", "com.avid.ProTools", "net.maxon.cinema4d",
        "org.blenderfoundation.blender",
        // терминалы (id проверены на реальной машине; Warp = dev.warp.Warp-Stable, не com.warp.*)
        "com.apple.Terminal", "com.googlecode.iterm2", "com.apple.Console",
        "io.alacritty", "net.kovidgoyal.kitty", "com.mitchellh.ghostty",
        "co.zeit.hyper", "org.tabby", "com.github.wez.wezterm"
    ]
    static let defaultSoftApps: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.apple.dt.Xcode",
        "sh.cursor.Cursor", "com.exafunction.windsurf", "com.panic.Nova", "dev.zed.Zed",
        "com.sublimetext.4", "com.sublimetext.3", "org.vim.MacVim", "com.github.atom"
    ]
    /// Встроенный дефолт-режим для bundle id. Версионные/вариативные id — по префиксу
    /// (Adobe PremierePro.26 / AfterEffects.application; Warp dev.warp.Warp-Stable; DaVinci с суффиксами).
    static func builtinAppMode(_ bid: String) -> String {
        if defaultOffApps.contains(bid) { return "off" }
        // ПРЕФИКСЫ — для версионных/вариативных id (бета/триал/несколько установленных версий рядом).
        // Final Cut: у второй установленной версии id мог отличаться (FinalCutTrial / FinalCut-beta /
        // …Pro) → точный com.apple.FinalCut её не ловил, авто-сид пропускал (баг: «новая версия не
        // добавилась в исключения», 2026-06-25). Префикс ловит все варианты Final Cut. Logic/Motion с
        // версионным суффиксом (logic10→logic11, motionapp) — туда же, чтобы не повторять при апдейте.
        if bid.hasPrefix("com.apple.FinalCut") || bid.hasPrefix("com.apple.logic")
            || bid.hasPrefix("com.apple.motion") || bid.hasPrefix("com.apple.Compressor")
            || bid.hasPrefix("com.adobe.PremierePro") || bid.hasPrefix("com.adobe.AfterEffects")
            || bid.hasPrefix("com.adobe.Audition") || bid.hasPrefix("com.adobe.Premiere")
            || bid.hasPrefix("dev.warp.Warp")
            || bid.hasPrefix("com.blackmagic-design.DaVinciResolve") { return "off" }
        if defaultSoftApps.contains(bid) || bid.hasPrefix("com.jetbrains") { return "soft" }
        return ""
    }

    /// Режим-исключение текущего приложения: "off" | "soft" | "" (обычный). Единственный источник —
    /// СПИСОК исключений (appModes), который предзаполняется дефолтами для установленных программ при
    /// запуске (seedDefaultExceptions). Так дефолты ВИДНЫ и редактируемы; удалил из списка → авто
    /// включается (builtinAppMode тут НЕ подмешиваем, иначе удаление не сработало бы).
    static func frontmostAppMode() -> String {
        guard let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return "" }
        return ExceptionStore.shared.appMode(bid)
    }

    /// Автозамена сниппета с ПРОГЛОЧЕННОЙ границей. Клавишу-границу (пробел/таб/Enter) мы уже
    /// проглотили в handleKeyDown → в приложение она не ушла. Здесь: удаляем ТОЛЬКО триггер (он на
    /// экране давно, зафиксирован) и печатаем раскрытие + разделитель (разделитель — наш Unicode,
    /// а не удаление свежего пробела). Этим убираем гонку, из-за которой триггер не удалялся / в конце
    /// появлялся мусор / «длинный пробел». `firstKeySettle` крупнее обычного — страховка, что последний
    /// символ триггера успел закоммититься в поле (раньше эту паузу «съедал» ещё-несохранённый пробел).
    private func expandSnippet(trigger: String, expansion: String, whitespace ws: String) {
        muted = true
        let body = Self.sanitizeSnippet(expansion)
        // Не плодим «длинный»/двойной пробел: если раскрытие уже кончается таким же пробелом/табом,
        // что и проглоченный разделитель — не дублируем разделитель.
        let glue: String
        if let last = body.last, last == " " || last == "\t", String(last) == ws { glue = "" } else { glue = ws }
        TextReplacer.replace(deleteCount: trigger.count, with: body + glue, firstKeySettleMicros: 45_000) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + self.muteDrain) { self.endSyntheticFlight() }
        }
        buffer.commitSnippet(expansion: expansion, whitespace: ws)   // буфер: триггер→раскрытие, затем граница
        buffer.invalidateGroupHistory()   // сниппет изменил длину экрана не 1:1 → группа недействительна (G1)
        playSound()
        kbLog("snippet: \(trigger.count)→\(body.count) симв., граница проглочена")  // контент не логируем
    }

    private func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
        // отсекаем управляющие символы
        return scalar.value >= 0x20 && scalar.value != 0x7F
    }
}
