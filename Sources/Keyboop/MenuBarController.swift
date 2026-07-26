import AppKit

/// Иконка в статус-баре рядом с часами + меню.
final class MenuBarController: NSObject {
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
            button.title = ""
            button.imagePosition = .imageOnly
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
        let markS: CGFloat = 17                                   // знак почти во всю высоту строки меню (поля PNG срезаны → крупный, читаемый)
        let bw: CGFloat = 1.5, gap: CGFloat = 1.5, markGap: CGFloat = 3.5   // waveform ~15% у́же — освобождаем место знаку
        let barsW = CGFloat(waveBars) * bw + CGFloat(waveBars - 1) * gap
        let W = markS + markGap + barsW

        let img = NSImage(size: NSSize(width: ceil(W), height: H))
        img.lockFocus()
        // Фирменный знак — НАСТОЯЩИЙ логотип (Resources/menubar-mark.png, template); вектор — фолбэк.
        let markRect = NSRect(x: 0, y: (H - markS) / 2, width: markS, height: markS)
        if let mark = Self.markImage {
            mark.draw(in: markRect, from: .zero, operation: .sourceOver, fraction: 1)
        } else {
            KeyboopMark.draw(in: markRect, color: .black)
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

    private func buildMenu() {
        let menu = NSMenu()

        // Заголовок меню = ВЕРСИЯ, а не слоган (просьба автора 21.07: «раскладка под контролем» —
        // приятно, но бесполезно; версию хочется видеть сразу). Плюс два по-настоящему полезных
        // индикатора: «-dev» (чтобы никогда больше не диагностировать не ту сборку — инцидент 21.07)
        // и «авто выкл» — состояние, из-за которого человек решает, что программа сломалась.
        let ver = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
        let isDev = (Bundle.main.bundleIdentifier ?? "").hasSuffix(".dev")
        var headerTitle = "Keyboop \(ver)" + (isDev ? "-dev" : "")
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

        if needsPermission {
            let perm = NSMenuItem(title: L10n.t("menu.perm"), action: #selector(openPermissions), keyEquivalent: "")
            perm.target = self
            menu.addItem(perm)
            menu.addItem(.separator())
        }

        let auto = NSMenuItem(title: L10n.t("menu.auto"), action: #selector(toggleAuto), keyEquivalent: "")
        auto.target = self
        auto.state = settings.autoEnabled ? .on : .off
        menu.addItem(auto)

        let hot = NSMenuItem(title: String(format: L10n.t("menu.switchWord"), hotkeyDisplayString()),
                             action: nil, keyEquivalent: "")
        hot.isEnabled = false
        menu.addItem(hot)

        menu.addItem(.separator())

        // Быстрый доступ (в духе OpenSuperWhisper): язык распознавания + микрофон.
        menu.addItem(languageSubmenu())
        menu.addItem(microphoneSubmenu())

        let vh = NSMenuItem(title: L10n.t("menu.voiceHistory"), action: #selector(showVoiceHistory), keyEquivalent: "")
        vh.target = self
        menu.addItem(vh)

        // Проверить обновления — в ОДНОЙ группе с разделами выше (там иконок нет → пункт флешем влево),
        // а НЕ рядом с «Настройки»: у «Настройки» macOS 26 рисует системную шестерёнку, и в её группе
        // резервируется колонка под иконку → безиконочный сосед уезжал вправо (автор 16.06).
        let upd = NSMenuItem(title: L10n.t("menu.checkUpdates"), action: #selector(checkUpdatesItem), keyEquivalent: "")
        upd.target = self
        menu.addItem(upd)

        // Фидбэк — в один клик из места, где юзер живёт (та же безиконочная группа).
        let report = NSMenuItem(title: L10n.t("menu.report"), action: #selector(reportProblem), keyEquivalent: "")
        report.target = self
        menu.addItem(report)

        menu.addItem(.separator())

        // Настройки — отдельной группой между двумя разделителями: системная шестерёнка не задевает соседей.
        let prefs = NSMenuItem(title: L10n.t("menu.settings"), action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        menu.addItem(.separator())   // отделяем «Выйти», чтобы не нажать случайно

        let quit = NSMenuItem(title: L10n.t("menu.quit"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    /// Подменю «Язык распознавания» (Авто / Русский / English) — галочка на текущем.
    private func languageSubmenu() -> NSMenuItem {
        let item = NSMenuItem(title: L10n.t("voice.lang"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let langs: [(String, String)] = [("auto", L10n.t("voice.langAuto")), ("ru", "Русский"), ("en", "English")]
        for (code, label) in langs {
            let it = NSMenuItem(title: label, action: #selector(selectLang(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = code
            it.state = settings.voiceLanguage == code ? .on : .off
            sub.addItem(it)
        }
        item.submenu = sub
        return item
    }

    /// Подменю «Микрофон» — список устройств ввода, галочка на выбранном.
    private func microphoneSubmenu() -> NSMenuItem {
        let item = NSMenuItem(title: L10n.t("menu.mic"), action: nil, keyEquivalent: "")
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

    @objc private func selectLang(_ s: NSMenuItem) {
        if let code = s.representedObject as? String { settings.voiceLanguage = code; buildMenu() }
    }
    @objc private func selectMic(_ s: NSMenuItem) {
        if let uid = s.representedObject as? String { settings.voiceMicUID = uid; buildMenu() }
    }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func showVoiceHistory() { onShowVoiceHistory?() }
    @objc private func checkUpdatesItem() { onCheckUpdates?() }
    @objc private func reportProblem() { FeedbackWindowController.shared.show() }
    @objc private func openPermissions() { Permissions.openAccessibilitySettings() }
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
