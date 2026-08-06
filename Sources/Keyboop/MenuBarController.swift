import AppKit

/// Иконка в статус-баре рядом с часами + меню.
final class MenuBarController: NSObject, NSMenuDelegate {
    /// Единственный экземпляр (для уровня микрофона из VoiceController в живой waveform статус-бара).
    static weak var shared: MenuBarController?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let layout: LayoutManager
    private let settings = AppSettings.shared
    private var pollTimer: Timer?

    // Живой waveform в строке меню во время записи: «K» + столбики по громкости.
    private let waveBars = 5
    private var waveTargets: [CGFloat]
    private var waveShown: [CGFloat]
    private var wavePeak: Float = 0.03
    private var waveTimer: Timer?

    var onOpenSettings: (() -> Void)?
    var onShowVoiceHistory: (() -> Void)?
    /// Старт диктовки из быстрого действия (задача 21).
    var onQuickDictate: (() -> Void)?
    var onToggleAuto: ((Bool) -> Void)?
    var onCheckUpdates: (() -> Void)?
    var onQuit: (() -> Void)?
    var needsPermission = false
    private var voiceState: VoiceController.State = .idle

    /// Настоящий логотип Keyboop (белая фигура + альфа) для waveform в строке меню. Грузим один раз.
    private static let markImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "menubar-mark", withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        return img
    }()

    init(layout: LayoutManager) {
        self.layout = layout
        waveTargets = Array(repeating: 0.08, count: waveBars)
        waveShown = waveTargets
        super.init()
        Self.shared = self
        configureButton()
        buildMenu()
        startPolling()
        // Язык интерфейса сменили в настройках → пересобрать меню вживую (без перезапуска).
        NotificationCenter.default.addObserver(
            self, selector: #selector(languageChanged),
            name: .keyboopLanguageChanged, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func refresh() {
        updateTitle()
        buildMenu()
    }

    @objc private func languageChanged() { buildMenu() }

    private func configureButton() {
        applyIconStyle()
    }

    /// «Фирменный знак» для покоя строки меню: тот же логотип (template), что и в waveform.
    /// Масштабируем под высоту строки меню (~16pt), рендерим как template → системная тонировка.
    private static let brandStatusImage: NSImage? = {
        guard let src = markImage else { return nil }
        let h: CGFloat = 15, w = h * (src.size.width / max(src.size.height, 1))
        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        src.draw(in: NSRect(x: 0, y: 0, width: w, height: h),
                 from: .zero, operation: .sourceOver, fraction: 1)
        img.unlockFocus()
        img.isTemplate = true
        return img
    }()

    /// ФЛАГ ЯЗЫКА в строке меню — как когда-то в Punto Switcher (просьба пользователей 25.07).
    ///
    /// Берём СИСТЕМНЫЙ эмодзи-флаг. Пробовали рисовать плоские флаги вектором — американский вышел
    /// неубедительно: 13 полос и 50 звёзд на 16pt не помещаются, а упрощённый до 5 полос флаг — это
    /// уже не флаг США (решение автора 25.07: «неправильно отображать неправильно нарисованный флаг»).
    /// Системный глиф всегда корректен и совпадает с тем, что человек видит в остальной системе.
    ///
    /// Чтобы флаг не выглядел мелким, картинку обрезаем по ФАКТИЧЕСКИМ границам глифа
    /// (`usesDeviceMetrics`): у эмодзи высота строки заметно больше самого рисунка, и раньше почти
    /// треть картинки уходила в пустоту под и над флагом.
    ///
    /// `isTemplate` обязательно false: template схлопнул бы флаг в монохромный силуэт.
    private static var flagCache: [String: NSImage] = [:]

    /// Целевая высота флага. Строка меню — 24pt, системные значки ~16–18pt: выше делать нельзя,
    /// иначе macOS обрежет картинку.
    private static let flagTargetH: CGFloat = 20

    /// Язык раскладки → флаг. Код приходит из `LayoutManager.currentCodeLive()`, то есть это ЯЗЫК
    /// ВВОДА, а не страна пользователя. Флаг ≠ язык (на русском пишут не только в РФ, на английском —
    /// тем более), поэтому таблица покрывает распространённые раскладки, а остальное честно остаётся
    /// без флага: лучше обычный значок клавиатуры, чем «похожий» чужой флаг.
    private static let flagByLang: [String: String] = [
        "RU": "🇷🇺", "EN": "🇺🇸", "UK": "🇺🇦", "BE": "🇧🇾", "KK": "🇰🇿",
        "DE": "🇩🇪", "FR": "🇫🇷", "ES": "🇪🇸", "IT": "🇮🇹", "PT": "🇵🇹", "NL": "🇳🇱",
        "PL": "🇵🇱", "CS": "🇨🇿", "TR": "🇹🇷", "SV": "🇸🇪", "NB": "🇳🇴", "DA": "🇩🇰",
        "FI": "🇫🇮", "EL": "🇬🇷", "HE": "🇮🇱", "AR": "🇸🇦", "HY": "🇦🇲", "KA": "🇬🇪",
        "ZH": "🇨🇳", "JA": "🇯🇵", "KO": "🇰🇷", "HI": "🇮🇳", "TH": "🇹🇭", "VI": "🇻🇳"
    ]

    /// Флаг как NSImage под высоту строки меню. Кэш по языку: раскладку опрашиваем каждые полсекунды —
    /// пересоздавать картинку незачем.
    static func flagImage(lang: String) -> NSImage? {
        if let cached = flagCache[lang] { return cached }
        guard let emoji = flagByLang[lang] else { return nil }
        // Кегль подбираем так, чтобы РИСУНОК флага (а не строка с отбивками) вышел нужной высоты.
        // Эмодзи рисуется примерно на 0.78 кегля, поэтому берём с запасом и обрезаем по факту.
        let font = NSFont.systemFont(ofSize: flagTargetH / 0.78)
        let text = NSAttributedString(string: emoji, attributes: [.font: font])
        let box = text.boundingRect(with: NSSize(width: 200, height: 200),
                                    options: [.usesLineFragmentOrigin, .usesDeviceMetrics])
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = min(1, flagTargetH / box.height)          // не даём вылезти за высоту строки меню
        let size = NSSize(width: ceil(box.width * scale), height: ceil(box.height * scale))
        let img = NSImage(size: size)
        img.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        if scale < 1 {
            let t = NSAffineTransform()
            t.scale(by: scale)
            t.concat()
        }
        // Сдвигаем на минус-origin рамки глифа — так пустые поля сверху и снизу срезаются.
        text.draw(at: NSPoint(x: -box.minX, y: -box.minY))
        img.unlockFocus()
        img.isTemplate = false
        img.accessibilityDescription = lang
        flagCache[lang] = img
        return img
    }

    /// Язык, под который уже нарисован флаг. Меняем картинку ТОЛЬКО при реальной смене раскладки:
    /// иначе трогали бы NSStatusItem.button дважды в секунду на ровном месте.
    private var lastFlagLang = ""

    /// Флаг для языка, а если такого флага у нас нет — обычный значок клавиатуры.
    private func flagOrKeyboard(_ lang: String) -> NSImage? {
        Self.flagImage(lang: lang)
            ?? NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Keyboop")
    }

    /// Применить выбранный стиль значка (brand/letter/layout/keyboard/hidden). Зовётся из init,
    /// при смене настройки и при языке/раскладке. Во время диктовки не трогаем — иконку держит
    /// voice-индикатор (setVoiceState).
    func applyIconStyle() {
        let style = settings.menuBarStyle
        let showLang = settings.menuBarShowLanguage
        // Пункт исчезает из строки меню, только если НЕТ и значка, и языка.
        statusItem.isVisible = !(style == "hidden" && !showLang)
        guard statusItem.isVisible, voiceState == .idle, let button = statusItem.button else { return }
        switch style {
        case "brand":
            button.image = Self.brandStatusImage ?? NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Keyboop")
            button.imagePosition = .imageLeading
        case "flag":
            let lang = layout.currentCodeLive()
            button.image = flagOrKeyboard(lang)
            button.imagePosition = .imageLeading
            lastFlagLang = lang
        case "hidden":
            button.image = nil
            button.imagePosition = .noImage       // значка нет — остаётся только язык (см. updateTitle)
        default:   // "keyboard"
            button.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Keyboop")
            button.imagePosition = .imageLeading
        }
        updateTitle()
    }

    private func updateTitle() {
        if voiceState != .idle { return }   // во время диктовки иконку держит voice-индикатор
        guard let button = statusItem.button else { return }
        if needsPermission { button.title = " ⚠︎"; return }
        // Раскладку спрашиваем ОДИН раз на тик: и флагу, и подписи нужен один и тот же код.
        // currentCodeLive, а НЕ currentCode: в фоновом агенте чтение TIS не следует за внешними
        // переключениями раскладки (замер 25.07 — см. LayoutManager.currentCodeLive).
        let code = layout.currentCodeLive()
        // Флаг должен следовать за раскладкой, а единственный живой сигнал о её смене здесь —
        // опрос из startPolling. Картинку меняем только когда язык реально другой.
        if settings.menuBarStyle == "flag", code != lastFlagLang {
            lastFlagLang = code
            button.image = flagOrKeyboard(code)
        }
        guard settings.menuBarShowLanguage else { button.title = ""; return }   // язык скрыт
        // Без значка (hidden) язык без ведущего пробела; со значком — с отступом от него.
        button.title = settings.menuBarStyle == "hidden" ? code : " \(code)"
    }

    /// Индикатор диктовки в статус-баре: запись / распознавание / покой.
    func setVoiceState(_ s: VoiceController.State) {
        voiceState = s
        guard let button = statusItem.button else { return }
        switch s {
        case .idle:
            stopWave()
            applyIconStyle()                              // вернуть выбранный пользователем значок (не хардкод)
        case .recording:
            // Живой waveform «K + столбики по громкости» вместо «микрофон + точка».
            // В режиме «без значка» код языка на время записи НЕ прячем: он там единственное, что
            // человек согласился видеть, и его исчезновение читалось бы как ещё одна поломка.
            let bare = settings.menuBarStyle == "hidden"
            button.title = (bare && settings.menuBarShowLanguage) ? layout.currentCodeLive() : ""
            button.imagePosition = bare ? .imageLeading : .imageOnly
            button.image?.accessibilityDescription = L10n.t("a11y.recording")
            startWave()
        case .processing:
            stopWave()
            button.imagePosition = .imageLeading
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: L10n.t("voice.recognizing"))
            button.title = " …"
        }
    }

    /// Уровень микрофона (RMS) → правый край ленты столбиков. Зовётся из VoiceController-хука; вне
    /// записи молча игнорируем.
    func pushLevel(_ rms: Float) {
        DispatchQueue.main.async {
            guard self.voiceState == .recording else { return }
            self.wavePeak = Swift.max(rms, self.wavePeak * 0.92)           // следящий пик → авто-гейн
            let n = Swift.min(1, rms / Swift.max(self.wavePeak, 0.02))
            let v = CGFloat(0.10 + 0.90 * pow(n, 0.65))
            self.waveTargets.removeFirst(); self.waveTargets.append(v)
        }
    }

    private func startWave() {
        wavePeak = 0.03
        for i in 0..<waveBars { waveTargets[i] = 0.10; waveShown[i] = 0.10 }
        guard waveTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in self?.waveTick() }
        RunLoop.main.add(t, forMode: .common)
        waveTimer = t
        renderWave()
    }
    private func stopWave() {
        waveTimer?.invalidate(); waveTimer = nil
    }
    private func waveTick() {
        var changed = false
        for i in 0..<waveBars {
            let d = waveTargets[i] - waveShown[i]
            if abs(d) > 0.003 { waveShown[i] += d * 0.4; changed = true }
        }
        if changed { renderWave() }
    }

    /// Рисуем фирменный знак (клавиша-K по логотипу) + столбики-waveform в template-картинку →
    /// строка меню сама адаптирует под свет/тьму и подсветку при клике.
    private func renderWave() {
        guard let button = statusItem.button else { return }
        let H: CGFloat = 18
        // ⚠️ «Без значка» значит без значка И ВО ВРЕМЯ ДИКТОВКИ (репорт #43). Если человек выбрал
        // «без значка», но оставил язык рядом, статус-элемент остаётся видимым ради кода языка —
        // и мы рисовали туда waveform ВМЕСТЕ с фирменным знаком. То есть логотип возникал ровно
        // там, где его выключили, и только на время записи: со стороны это выглядит как «оно само
        // включилось обратно». Столбики оставляем: это индикатор состояния, а не бренд, и без них
        // человек не увидит, что запись идёт.
        let showMark = settings.menuBarStyle != "hidden"
        let markS: CGFloat = showMark ? 17 : 0                    // знак почти во всю высоту строки меню (поля PNG срезаны → крупный, читаемый)
        let bw: CGFloat = 1.5, gap: CGFloat = 1.5
        let markGap: CGFloat = showMark ? 3.5 : 0                 // waveform ~15% у́же — освобождаем место знаку
        let barsW = CGFloat(waveBars) * bw + CGFloat(waveBars - 1) * gap
        let W = markS + markGap + barsW

        let img = NSImage(size: NSSize(width: ceil(W), height: H))
        img.lockFocus()
        // Фирменный знак — НАСТОЯЩИЙ логотип (Resources/menubar-mark.png, template); вектор — фолбэк.
        if showMark {
            let markRect = NSRect(x: 0, y: (H - markS) / 2, width: markS, height: markS)
            if let mark = Self.markImage {
                mark.draw(in: markRect, from: .zero, operation: .sourceOver, fraction: 1)
            } else {
                KeyboopMark.draw(in: markRect, color: .black)
            }
        }
        NSColor.black.setFill()
        for i in 0..<waveBars {
            let bh = Swift.max(bw, waveShown[i] * (H - 4))
            let x = markS + markGap + CGFloat(i) * (bw + gap)
            let y = (H - bh) / 2
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: bw, height: bh), xRadius: bw / 2, yRadius: bw / 2).fill()
        }
        img.unlockFocus()
        img.isTemplate = true   // монохром + авто-адаптация к строке меню
        button.image = img
        button.imagePosition = .imageOnly
    }

    /// Иконка пункта меню: монохромный SF Symbol как template — систему тонирует она сама, и в тёмной
    /// теме, и на подсвеченном пункте. Размер берём от шрифта меню, а не константой: иначе на крупном
    /// системном шрифте иконки окажутся мелкими марками.
    ///
    /// Имена перечисляем ОТ САМОГО НОВОГО К ЗАПАСНОМУ, берём первое, которое система знает. Так на
    /// свежей macOS рисуются нынешние глифы (SF Symbols 6 приехал с macOS 15, 7 — с macOS 26), а на
    /// старых сам собой берётся дедовский эквивалент. Наш пол — macOS 13 на Intel (арм-срез собран под
    /// 14), поэтому жёстко требовать новые имена нельзя, а проверять версию системы руками незачем:
    /// `NSImage(systemSymbolName:)` про незнакомое имя честно возвращает nil.
    ///
    /// ⚠️ Последним в цепочке всегда должно стоять имя из SF Symbols 1.0, иначе на macOS 13 пункт
    /// останется без иконки. Это не падение, но дырка в ряду: AppKit резервирует колонку под иконку на
    /// всю группу, и сосед без картинки выглядит съехавшим (эффект от 16.06). Иконка есть у КАЖДОГО
    /// пункта в группе, либо ни у кого.
    ///
    /// `color` — только для состояний «не работает»: цветной значок видно боковым зрением, а ради него
    /// эти строки в меню и появились (разбор 34 репортов, 28.07).
    private func icon(_ names: String..., color: NSColor? = nil) -> NSImage? {
        guard let base = names.lazy
            .compactMap({ NSImage(systemSymbolName: $0, accessibilityDescription: nil) })
            .first else { return nil }
        // Конфигурации СКЛАДЫВАЕМ через applying(_:) — если применять их по очереди, вторая затирает
        // первую, и цветной значок молча выходит монохромным.
        var cfg = NSImage.SymbolConfiguration(pointSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular)
        if let color { cfg = cfg.applying(.init(paletteColors: [color])) }
        let img = base.withSymbolConfiguration(cfg) ?? base
        img.isTemplate = (color == nil)
        return img
    }

    /// Меню живёт ОДНИМ объектом и открывается нами вручную (`showMenu`), а не через
    /// `statusItem.menu`. Причина одна: пока меню назначено пункту, macOS открывает его на ЛЮБОЙ
    /// клик, и правый от левого не отличить. Быстрое действие (задача 21) требует их различать.
    /// Содержимое по-прежнему пересобирается в момент открытия, через `menuNeedsUpdate`.
    private let menu = NSMenu()

    private func buildMenu() {
        menu.delegate = self
        guard let button = statusItem.button else { return }
        statusItem.menu = nil
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusItemClicked() {
        // ⌃-клик система штатно считает правым, и человек с трекпадом часто именно им и пользуется.
        let e = NSApp.currentEvent
        let right = e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true
        if right { runQuickAction() } else { showMenu() }
    }

    /// ⚠️ ОТКРЫВАЕМ ЧЕРЕЗ `performClick`, А НЕ ЧЕРЕЗ `popUp` (автор 06.08, вернулись назад).
    ///
    /// Ради различения левого и правого клика меню перестали держать на `statusItem.menu`, и левый
    /// клик показывал его вручную через `popUp`. Выглядело это неправильно: у меню появлялась
    /// стрелка прокрутки сверху, а шапка с версией уезжала за край и «отскакивала» при наведении.
    /// `popUp` рисует меню как контекстное, в отрыве от пункта строки меню, и системную геометрию
    /// не воспроизводит.
    ///
    /// Возврат к штатному пути: назначаем меню на время клика и снимаем сразу после. Комментарий
    /// выше про «не подменять открывающееся меню» остаётся в силе и не нарушается: мы подменяем ДО
    /// открытия и снимаем ПОСЛЕ закрытия (performClick блокирующий), а не на лету.
    private func showMenu() {
        guard let button = statusItem.button else { return }
        statusItem.menu = menu          // содержимое соберёт menuNeedsUpdate, как и раньше
        button.performClick(nil)
        // ⚠️ Снимаем меню в `menuDidClose`, а НЕ строкой ниже. `performClick` блокирует, пока меню
        // открыто, но полагаться на это опасно: стоит ему на какой-нибудь версии вернуться сразу,
        // и меню закроется в тот же миг, то есть по левому клику не откроется вовсе. Событие
        // закрытия говорит правду в любом случае.
    }

    /// БЫСТРОЕ ДЕЙСТВИЕ ПО ПРАВОМУ КЛИКУ (задача 21, автор 05.08.2026).
    ///
    /// ⚠️ Здесь не может быть действий, печатающих в «текущее поле». Клик по значку делает активными
    /// НАС, и любая вставка ушла бы в Keyboop, а не туда, где стоит курсор. Поэтому в списке только
    /// то, чему чужой фокус не нужен: копирование, пауза, диктовка и окно истории.
    private func runQuickAction() {
        switch settings.quickAction {
        case "pause":
            if Pause.active { Pause.stop(); VoiceIndicator.shared.showToast(L10n.t("quick.resumed")) }
            else {
                Pause.start(minutes: settings.pauseMinutes)
                VoiceIndicator.shared.showToast(L10n.t("quick.paused"))
            }
        case "dictate":  onQuickDictate?()
        case "history":  onShowVoiceHistory?()
        case "settings": onOpenSettings?()
        default:         copyLastDictation()
        }
    }

    /// ⚠️ ПЕРЕСБОРКА В МОМЕНТ ОТКРЫТИЯ (30.07). Раньше меню собиралось только по событиям — смена
    /// раскладки, пара переключателей — и его содержимое было свежим лишь случайно. Пока все пункты
    /// были статичными, это сходило с рук. Как только появился пункт, зависящий от состояния истории
    /// диктовок, стало видно: после первой диктовки он бы не появился, а после истечения срока
    /// хранения не исчез бы, потому что между этими моментами никто меню не трогал.
    ///
    /// Перезаполняем ТОТ ЖЕ объект меню, который macOS сейчас открывает (`removeAllItems` + populate),
    /// а не подменяем `statusItem.menu` — подмена открывающегося меню на лету и есть способ получить
    /// пустое или мигающее меню.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        populate(menu)
    }

    /// Меню закрылось — отвязываем его от пункта, иначе правый клик снова начнёт открывать меню
    /// вместо быстрого действия (см. `showMenu`).
    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    private func populate(_ menu: NSMenu) {
        // Заголовок меню = ВЕРСИЯ, а не слоган (просьба автора 21.07: «раскладка под контролем» —
        // приятно, но бесполезно; версию хочется видеть сразу). Плюс два по-настоящему полезных
        // индикатора: «-dev» (чтобы никогда больше не диагностировать не ту сборку — инцидент 21.07)
        // и «авто выкл» — состояние, из-за которого человек решает, что программа сломалась.
        let ver = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
        let isDev = (Bundle.main.bundleIdentifier ?? "").hasSuffix(".dev")
        // Имя версии подставляет Changelog.versionWithName — тот же помощник, что у низа списка
        // настроек и у «О программе», чтобы формат не разъехался. В релизе шапка читается как
        // «Keyboop 0.3.2 · Pika», в dev как «Keyboop 0.3.2-dev · Pika».
        var headerTitle = "Keyboop " + Changelog.versionWithName(ver + (isDev ? "-dev" : ""))
        // В dev-сборке показываем ВРЕМЯ СБОРКИ прямо в шапке меню (просьба автора 24.07): за вечер
        // мы оба дважды путались, какую именно сборку тестируем. Дата не нужна — за день их много,
        // различает время. В релизе не показываем: пользователю штамп ни о чём не говорит.
        if isDev, let stamp = Bundle.main.infoDictionary?["KeyboopBuildStamp"] as? String {
            headerTitle += " · \(stamp.split(separator: " ").last.map(String.init) ?? stamp)"
        }
        if !settings.autoEnabled { headerTitle += " · " + L10n.t("menu.autoOff") }
        let header = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        // ПАУЗА — первой строкой и только когда она есть. Состояние, из-за которого человек решит,
        // что программа сломалась, обязано быть видно сразу, а не третьим пунктом снизу.
        if let until = Pause.until, Pause.active {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            let row = NSMenuItem(title: String(format: L10n.t("menu.pausedUntil"), f.string(from: until)),
                                 action: nil, keyEquivalent: "")
            row.isEnabled = false
            menu.addItem(row)
            let resume = NSMenuItem(title: L10n.t("menu.resumeNow"), action: #selector(resumePause), keyEquivalent: "")
            resume.target = self
            menu.addItem(resume)
            menu.addItem(.separator())
        }

        if needsPermission {
            // ⚠️ НАЗЫВАЕМ ТОТ ДОСТУП, КОТОРОГО НЕТ (репорт #71, 03.08.2026).
            //
            // Раньше пункт всегда назывался «Нужен доступ (Accessibility)…» и всегда вёл в раздел
            // Универсального доступа. У человека с Intel-мака Accessibility был ВЫДАН, а не хватало
            // Мониторинга ввода — он читал «нужен Accessibility», шёл туда, видел галочку на месте
            // и делал единственный логичный вывод: приложение врёт. Мы называли не ту дверь и вели
            // не в ту комнату.
            //
            // Порядок проверки не случаен: Мониторинг ввода спрашиваем ПЕРВЫМ, потому что
            // AXIsProcessTrusted() умеет залипать на false сразу после выдачи доступа (баг macOS 13+,
            // см. комментарий в AppDelegate), а IOHIDCheckAccess отвечает честно и сразу.
            let needIM = !Permissions.inputMonitoringGranted()
            let perm = NSMenuItem(title: L10n.t(needIM ? "menu.permInput" : "menu.permAX"),
                                  action: needIM ? #selector(openInputMonitoring) : #selector(openPermissions),
                                  keyEquivalent: "")
            perm.target = self
            perm.image = icon("exclamationmark.triangle.fill", color: .systemOrange)
            menu.addItem(perm)
            // Запущено не из «Программ» — вторая частая причина, по которой доступы «не держатся»:
            // грант привязан к пути, а путь у копии в «Загрузках» живёт до первого переноса.
            if !Permissions.isInApplications() {
                let where_ = NSMenuItem(title: L10n.t("menu.permMove"), action: nil, keyEquivalent: "")
                where_.isEnabled = false
                menu.addItem(where_)
            }
            menu.addItem(.separator())
        }

        // ⚠️ СОСТОЯНИЕ «НЕ МОГУ РАБОТАТЬ» — ПЕРВОЙ СТРОКОЙ (разбор 34 репортов, 28.07). Главный вывод
        // разбора: приложение молчит ровно в тех состояниях, где оно не работает, и человеку неоткуда
        // узнать причину. Самый частый случай — Secure Input: пока его держит другое приложение,
        // macOS СИСТЕМНО прячет клавиатуру от всех тапов, и мы мертвы не по своей вине. В логе одного
        // репортёра держатель даже назван по имени, а человек об этом так и не узнал и написал
        // «не работает» (причём написал в неверной раскладке — мы не сконвертировали, потому что были
        // слепы). Показываем прямо в меню, с именем держателя, если успели его найти.
        if let problem = AppHealth.blockingProblem {
            // Значок вместо прежнего «⚠︎ » в тексте: символ рисуется цветным и стоит в общей колонке
            // иконок, а не съедает начало строки, где важен сам текст проблемы.
            let warn = NSMenuItem(title: problem, action: nil, keyEquivalent: "")
            warn.isEnabled = false
            warn.image = icon("exclamationmark.triangle.fill", color: .systemOrange)
            menu.addItem(warn)
            menu.addItem(.separator())
        }

        // Галочка состояния и иконка живут в РАЗНЫХ колонках, поэтому на переключателе уживаются обе.
        let auto = NSMenuItem(title: L10n.t("menu.auto"), action: #selector(toggleAuto), keyEquivalent: "")
        auto.target = self
        auto.state = settings.autoEnabled ? .on : .off
        auto.image = icon("arrow.trianglehead.2.clockwise.rotate.90",   // SF 6, macOS 15
                          "arrow.triangle.2.circlepath",                // SF 1
                          "arrow.2.squarepath")
        menu.addItem(auto)

        // Строка-подсказка, а не действие, но иконка ей нужна: без неё она одна в группе съедет вправо.
        let hot = NSMenuItem(title: String(format: L10n.t("menu.switchWord"), hotkeyDisplayString()),
                             action: nil, keyEquivalent: "")
        hot.isEnabled = false
        hot.image = icon("keyboard")
        menu.addItem(hot)

        menu.addItem(.separator())

        // Быстрый доступ (в духе OpenSuperWhisper): микрофон.
        // ЯЗЫК РАСПОЗНАВАНИЯ УБРАН ОТСЮДА 30.07 (задача T40). Он меняется редко, дефолт «Авто» и так
        // стоит (AppSettings.voiceLanguage), а в настройках селектор уже есть — SettingsWindow
        // .voiceLangControl(). В меню он занимал строку и целое подменю ради того, что человек трогает
        // раз в жизни. Пункт микрофона остаётся: устройство меняется на ходу (наушники пришли/ушли).
        menu.addItem(microphoneSubmenu())

        // «Скопировать последнюю диктовку» — ПЕРЕД историей: чаще нужна именно последняя расшифровка,
        // а не окно со списком (в Handy это `copy last transcript`).
        // Пункта НЕТ, когда копировать нечего (решение автора 30.07). Своего хранилища у него не
        // существует: копировать можно только из истории диктовок. Поэтому он живёт ровно столько,
        // сколько живёт последняя запись — история выключена, ещё не диктовали или срок хранения уже
        // вышел, и пункт исчезает. Мёртвая строка, всегда отвечающая «нечего копировать», хуже, чем её
        // отсутствие. Проверка честна именно потому, что меню пересобирается при открытии (см.
        // menuNeedsUpdate выше); без этого пункт появлялся и пропадал бы с опозданием.
        // Порядок: сначала история, потом копирование (решение автора 30.07 — было наоборот).
        let vh = NSMenuItem(title: L10n.t("menu.voiceHistory"), action: #selector(showVoiceHistory), keyEquivalent: "")
        vh.target = self
        vh.image = icon("clock.arrow.trianglehead.counterclockwise.rotate.90",   // SF 6, macOS 15
                        "clock.arrow.circlepath")
        menu.addItem(vh)

        if VoiceHistory.shared.lastVisible() != nil {
            let copyLast = NSMenuItem(title: L10n.t("menu.copyLast"), action: #selector(copyLastDictation), keyEquivalent: "")
            copyLast.target = self
            copyLast.image = icon("document.on.document",   // SF 6, macOS 15 — переименование doc.* → document.*
                                  "doc.on.doc")
            menu.addItem(copyLast)
        }

        menu.addItem(.separator())

        // Настройки — отдельной группой между двумя разделителями: системная шестерёнка не задевает соседей.
        let prefs = NSMenuItem(title: L10n.t("menu.settings"), action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        // Шестерёнку ставим САМИ, хотя macOS 26 рисует её пункту настроек и без нас (наблюдение 16.06):
        // на более старых системах она не появляется, и пункт остался бы единственным без иконки.
        // Слот у пункта один, так что двух шестерёнок не будет — в худшем случае наша совпадёт с системной.
        prefs.image = icon("gearshape")
        menu.addItem(prefs)

        menu.addItem(.separator())

        // «Обслуживание»: сначала «Проверить обновления», потом «Сообщить о проблеме» (порядок автора,
        // 30.07). Смысл порядка: человек, у которого что-то не так, сперва видит, что есть новая версия,
        // и только потом идёт писать нам. Половина репортов приходит с уже починенного старого билда.
        //
        // ⚠️ Требование от 16.06 сохранено: «Проверить обновления» НЕ в одной группе с «Настройки».
        // У «Настройки» macOS 26 рисует системную шестерёнку, и в её группе резервируется колонка под
        // иконку → безиконочный сосед уезжал вправо. Здесь между ними разделитель, то есть это другая
        // группа, и оба пункта тут безиконочные — сдвинуть их нечему.
        let upd = NSMenuItem(title: L10n.t("menu.checkUpdates"), action: #selector(checkUpdatesItem), keyEquivalent: "")
        upd.target = self
        upd.image = icon("arrow.down.circle")
        menu.addItem(upd)

        let report = NSMenuItem(title: L10n.t("menu.report"), action: #selector(reportProblem), keyEquivalent: "")
        report.target = self
        report.image = icon("exclamationmark.bubble")
        menu.addItem(report)

        menu.addItem(.separator())   // «Выйти» снова один за разделителем, чтобы не нажать случайно

        let quit = NSMenuItem(title: L10n.t("menu.quit"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        quit.image = icon("power")
        menu.addItem(quit)
    }

    /// Подменю «Микрофон» — список устройств ввода, галочка на выбранном.
    private func microphoneSubmenu() -> NSMenuItem {
        let item = NSMenuItem(title: L10n.t("menu.mic"), action: nil, keyEquivalent: "")
        item.image = icon("microphone",   // SF 6, macOS 15 — переименование mic → microphone
                          "mic")
        let sub = NSMenu()
        let def = NSMenuItem(title: L10n.t("menu.micDefault"), action: #selector(selectMic(_:)), keyEquivalent: "")
        def.target = self; def.representedObject = ""
        def.state = settings.voiceMicUID.isEmpty ? .on : .off
        sub.addItem(def)
        let devs = AudioDevices.inputs()
        if !devs.isEmpty { sub.addItem(.separator()) }
        for d in devs {
            let it = NSMenuItem(title: d.name, action: #selector(selectMic(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = d.uid
            it.state = settings.voiceMicUID == d.uid ? .on : .off
            sub.addItem(it)
        }
        item.submenu = sub
        return item
    }

    private func startPolling() {
        // Лёгкий опрос текущей раскладки для индикатора.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateTitle()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    @objc private func toggleAuto() {
        let newValue = !settings.autoEnabled
        settings.autoEnabled = newValue
        onToggleAuto?(newValue)
        buildMenu()
    }

    @objc private func selectMic(_ s: NSMenuItem) {
        if let uid = s.representedObject as? String { settings.voiceMicUID = uid; buildMenu() }
    }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func showVoiceHistory() { onShowVoiceHistory?() }
    @objc private func checkUpdatesItem() { onCheckUpdates?() }

    /// «Скопировать последнюю диктовку» (задача T40).
    ///
    /// ⚠️ Единственное место во всём приложении, где мы СОЗНАТЕЛЬНО и НЕОБРАТИМО пишем в буфер обмена.
    /// Принцип №1 запрещает трогать буфер ради своих нужд (поэтому и замена текста идёт печатью
    /// Unicode, а чтение выделения через ⌘C восстанавливает буфер — SelectionText.swift). Здесь запись
    /// буфера и ЕСТЬ то, о чём человек попросил, поэтому ничего не восстанавливаем.
    @objc private func copyLastDictation() {
        // Пароль на историю (HistoryGate) действует и на этот пункт. Иначе последнюю расшифровку можно
        // было бы забрать из меню в один клик, минуя пароль, который человек поставил именно на её
        // чтение — то есть мы сами сделали бы дырку в своей же защите от любопытных глаз.
        guard HistoryGate.enabled else { Self.copyLastDictationNow(); return }
        HistoryGate.promptUnlock { ok in if ok { Self.copyLastDictationNow() } }
    }

    private static func copyLastDictationNow() {
        // Тот же источник, по которому пункт вообще решает показываться (VoiceHistory.lastVisible):
        // история включена и запись не просрочена. Тост здесь — страховка на редкий случай, когда срок
        // хранения истёк между открытием меню и кликом, а не штатный путь: обычно пункта просто нет.
        guard let text = VoiceHistory.shared.lastVisible()?.text, !text.isEmpty else {
            VoiceIndicator.shared.showToast(L10n.t("menu.copyLastEmpty"))
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        VoiceIndicator.shared.showToast(L10n.t("menu.copyLastDone"))
    }
    /// Пауза изменилась: меню пересобирается при открытии само, но значок и подсказка живут
    /// отдельно, и им нужен толчок.
    func refreshAfterPauseChange() { applyIconStyle() }

    @objc private func resumePause() { Pause.stop() }
    @objc private func reportProblem() { FeedbackWindowController.shared.show() }
    @objc private func openPermissions() { Permissions.openAccessibilitySettings() }
    @objc private func openInputMonitoring() {
        // Сначала системный запрос: если macOS ещё не спрашивала, она покажет свой диалог, и
        // человеку не придётся искать галочку руками. Уже отказал — открываем нужный раздел.
        Permissions.requestInputMonitoring()
        Permissions.openInputMonitoringSettings()
    }
    @objc private func quit() {
        let alert = NSAlert()
        alert.messageText = L10n.t("menu.quitConfirm")
        alert.informativeText = L10n.t("menu.quitBody")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.t("menu.stay"))   // дефолт (Enter) — безопасный выбор
        alert.addButton(withTitle: L10n.t("menu.quit"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn { onQuit?() }
    }
}
