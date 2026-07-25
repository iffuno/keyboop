import AppKit

/// Окно-приветствие при первом запуске: кратко — что умеет, какие хоткеи, песочница
/// для тренировки. Тон — наш (сухо-тёпло, бупаем клавиши). Показывается один раз.
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    var onOpenSettings: (() -> Void)?
    var onClose: (() -> Void)?
    private var fullWidth: [NSView] = []   // элементы, чья ширина пинится к ширине стека
    private weak var voiceBtn: NSButton?
    private weak var introOverlay: NSView?
    private weak var introLogo: AnimatedLogoView?
    private var voiceDownloading = false
    private var permTimer: Timer?
    private weak var axStatus: NSTextField?
    private weak var axBtn: NSButton?
    private weak var micStatus: NSTextField?
    private weak var micBtn: NSButton?
    private weak var trPackStatus: NSTextField?   // статус языкового пакета перевода RU↔EN (async)

    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        // Высоту можно менять (контент в скролле), ширина фиксирована 480 (min.width == max.width).
        w.minSize = NSSize(width: 480, height: 430)
        w.maxSize = NSSize(width: 480, height: 1200)
        w.center()
        self.init(window: w)
        w.delegate = self
        build()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(nil)
        // Интро-заставку — наверх и видимой, затем проиграть «сборку» 1 раз (в конце сама уведётся).
        introOverlay?.isHidden = false
        introOverlay?.alphaValue = 1
        if let o = introOverlay { o.superview?.addSubview(o) }   // гарантированно поверх контента
        // Дать окну выложиться (playerLayer.frame ставится в layout), затем старт.
        DispatchQueue.main.async { [weak self] in self?.introLogo?.play() }
    }

    private func build() {
        guard let content = window?.contentView else { return }
        let bg = NSVisualEffectView()
        bg.material = .underWindowBackground; bg.blendingMode = .behindWindow
        bg.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bg)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Заголовок: маленькая стандартная иконка + «Привет. Я Keyboop.».
        // (Крупная анимация теперь — интро-заставка на всё окно, см. introOverlay ниже.)
        let icon = NSImageView(); icon.image = NSApp.applicationIconImage
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 50).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 50).isActive = true
        let hi = NSTextField(labelWithString: L10n.t("wel.hi"))
        hi.font = .systemFont(ofSize: 22, weight: .bold)
        let head = NSStackView(views: [icon, hi]); head.orientation = .horizontal; head.spacing = 14; head.alignment = .centerY
        stack.addArrangedSubview(head)

        addWrap(stack, L10n.t("wel.tagline"), size: 13.5, color: .secondaryLabelColor)
        addWrap(stack, L10n.t("wel.menubar"), size: 12, color: .tertiaryLabelColor)
        addGap(stack, 10)

        // ДОСТУПЫ — ставим ПЕРВЫМ: без Accessibility движок не стартует (тап активный → нужен доступ),
        // авто-переключение и хоткеи не работают. Прецедент: у тестера не было доступа → «не работает».
        addSection(stack, L10n.t("wel.permTitle"))
        addWrap(stack, L10n.t("wel.permBody"), size: 12.5, color: .secondaryLabelColor)
        let ax = addPermRow(stack, title: L10n.t("wel.permAxT"), sub: L10n.t("wel.permAxS"),
                            granted: Permissions.isTrusted(), action: #selector(grantAX))
        axStatus = ax.0; axBtn = ax.1
        let mic = addPermRow(stack, title: L10n.t("wel.permMicT"), sub: L10n.t("wel.permMicS"),
                             granted: AudioRecorder.authorized, action: #selector(grantMic))
        micStatus = mic.0; micBtn = mic.1
        startPermTimer()
        addGap(stack, 10)

        addSection(stack, L10n.t("wel.canTitle"))
        for k in ["wel.can1", "wel.can2", "wel.can3", "wel.can4"] { addBullet(stack, L10n.t(k)) }
        addGap(stack, 8)

        addSection(stack, L10n.t("wel.keysTitle"))
        addControlRow(stack, L10n.t("wel.key2short"), HotkeyControl())       // переключение раскладки
        addControlRow(stack, L10n.t("wel.key1short"), VoiceHotkeyControl())  // диктовка
        addWrap(stack, L10n.t("wel.keysNote"), size: 11.5, color: .tertiaryLabelColor)
        addGap(stack, 8)

        // Голос: предложить скачать модель прямо в онбординге.
        addSection(stack, L10n.t("wel.voiceTitle"))
        addWrap(stack, L10n.t("wel.voiceBody"), size: 12.5, color: .secondaryLabelColor)
        if ParakeetEngine.modelInstalled {
            let ok = NSTextField(labelWithString: L10n.t("wel.voiceReady"))
            ok.font = .systemFont(ofSize: 12, weight: .semibold); ok.textColor = DS.coral
            stack.addArrangedSubview(ok)
        } else {
            let b = NSButton(title: L10n.t("wel.voiceDownload"), target: self, action: #selector(downloadVoice))
            b.bezelStyle = .rounded
            b.bezelColor = DS.coral            // акцент: рекомендуемое действие в онбординге (заметный дефолт-движок)
            b.contentTintColor = .white
            voiceBtn = b
            stack.addArrangedSubview(b)
        }
        addWrap(stack, L10n.t("wel.histSafety"), size: 11.5, color: .tertiaryLabelColor)
        addGap(stack, 8)

        // Перевод выделенного: третья фича по хоткею. Translation framework — macOS 15+, поэтому всё
        // зависящее от движка (хоткей-контрол, карточка пакета, приглашение в песочницу) под #available.
        addSection(stack, L10n.t("wel.trTitle"))
        addWrap(stack, L10n.t("wel.trBody"), size: 12.5, color: .secondaryLabelColor)
        if #available(macOS 15.0, *) {
            addControlRow(stack, L10n.t("wel.trKeyShort"), TranslateHotkeyControl())
            addWrap(stack, L10n.t("wel.trPackNote"), size: 11.5, color: .tertiaryLabelColor)
            addTrPackRow(stack)                                   // статус пакета RU↔EN + переход в Системные настройки
            addWrap(stack, String(format: L10n.t("wel.trSandbox"), translateHotkeyDisplayString()),
                    size: 11.5, color: .tertiaryLabelColor)
        } else {
            addWrap(stack, L10n.t("wel.trNeedOS"), size: 12, color: .tertiaryLabelColor)
        }
        addGap(stack, 8)

        addSection(stack, L10n.t("wel.practiceTitle"))
        addWrap(stack, L10n.t("wel.practiceHint"), size: 12.5, color: .secondaryLabelColor)
        // В песочнице пробуется НЕ только автозамена раскладки — голос сюда же (просьба автора 21.07).
        // Показываем только когда голос реально доступен: иначе это приглашение в никуда.
        if AppSettings.shared.voiceEnabled, VoiceController.shared.hasUsableModel {
            addWrap(stack, String(format: L10n.t("wel.practiceVoice"), voiceHotkeyDisplayString()),
                    size: 11.5, color: .tertiaryLabelColor)
        }
        if #available(macOS 15.0, *) {
            addWrap(stack, String(format: L10n.t("wel.practiceTr"), translateHotkeyDisplayString()),
                    size: 11.5, color: .tertiaryLabelColor)
        }
        let field = NSTextField()
        field.placeholderString = "ghbdtn привет…"
        field.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        // Песочница на 2 строки — больше места набрать фразу (тест группы/переноса). Многострочный ввод с переносом.
        field.usesSingleLineMode = false
        field.cell?.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.maximumNumberOfLines = 2
        field.lineBreakMode = .byWordWrapping
        field.translatesAutoresizingMaskIntoConstraints = false
        field.heightAnchor.constraint(equalToConstant: 58).isActive = true
        stack.addArrangedSubview(field); fullWidth.append(field)
        addGap(stack, 12)

        // Кнопки — прижаты ВПРАВО, «Поехали» последняя и фирменно-коралловая: из длинного онбординга
        // должно быть сразу видно, где выход «всё понял, поехали» (просьба автора 21.07). Правый край —
        // привычное место главного действия в macOS-диалогах, взгляд идёт туда сам.
        let setBtn = NSButton(title: L10n.t("wel.settings"), target: self, action: #selector(openSettings))
        setBtn.bezelStyle = .rounded
        let goBtn = NSButton(title: L10n.t("wel.go"), target: self, action: #selector(goClose))
        goBtn.bezelStyle = .rounded; goBtn.keyEquivalent = "\r"   // Enter — тоже «Поехали»
        // Коралловый = наш AccentColor из ассетов; contentTintColor даёт читаемый белый текст поверх.
        if let coral = NSColor(named: "AccentColor") {
            goBtn.bezelColor = coral
            goBtn.contentTintColor = .white
        }
        // Растяжка слева съедает всё свободное место → обе кнопки уезжают к правому краю.
        let btnSpacer = NSView()
        btnSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        btnSpacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let btns = NSStackView(views: [btnSpacer, setBtn, goBtn])
        btns.orientation = .horizontal; btns.spacing = 10
        stack.addArrangedSubview(btns)
        fullWidth.append(btns)   // строка кнопок — во всю ширину колонки, иначе прижимать некуда
        addGap(stack, 8)
        // Вскользь, не отдельным шагом: приложение самообновляется.
        addWrap(stack, L10n.t("upd.onboard"), size: 12, color: .secondaryLabelColor)
        addGap(stack, 6)
        addWrap(stack, L10n.t("wel.foot"), size: 11, color: .tertiaryLabelColor)

        // Контент в скролле — онбординг с доступами+хоткеями длинный, на узких экранах не клипается.
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.automaticallyAdjustsContentInsets = false
        let clip = FlippedClip(); clip.drawsBackground = false
        scroll.contentView = clip
        let doc = NSView(); doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc
        doc.addSubview(stack)
        bg.addSubview(scroll)
        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bg.topAnchor.constraint(equalTo: content.topAnchor),
            bg.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bg.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
            doc.widthAnchor.constraint(equalTo: clip.widthAnchor),   // канон: docView ширина = clip-view (не scroll со скроллером)
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -30),
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -22)
        ])
        // Многострочные элементы и поле — ширина = ширине стека (иначе не переносятся).
        for v in fullWidth { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }

        // Интро-заставка ПОВЕРХ всего окна: тёмно-графитовый экран с крупной анимацией «сборки» K.
        // Играет один раз, затем плавно (0.5с, через прозрачность) уводится — проявляя приветствие.
        let intro = NSView(); intro.wantsLayer = true
        intro.layer?.backgroundColor = DS.graphite.cgColor
        intro.translatesAutoresizingMaskIntoConstraints = false
        let bigLogo = AnimatedLogoView(frame: .zero)
        bigLogo.translatesAutoresizingMaskIntoConstraints = false
        bigLogo.onFinished = { [weak self] in self?.dismissIntro() }
        intro.addSubview(bigLogo)
        content.addSubview(intro)   // последним → поверх контента
        NSLayoutConstraint.activate([
            intro.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            intro.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            intro.topAnchor.constraint(equalTo: content.topAnchor),
            intro.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bigLogo.centerXAnchor.constraint(equalTo: intro.centerXAnchor),
            bigLogo.centerYAnchor.constraint(equalTo: intro.centerYAnchor),
            bigLogo.widthAnchor.constraint(equalToConstant: 260),
            bigLogo.heightAnchor.constraint(equalToConstant: 260)
        ])
        introOverlay = intro
        introLogo = bigLogo
    }

    /// Плавно увести интро-заставку (0.5с через прозрачность) → проявляется окно приветствия.
    /// Оверлей не удаляем — прячем (isHidden), чтобы переоткрытие «Знакомства» снова показало интро.
    private func dismissIntro() {
        guard let intro = introOverlay, !intro.isHidden else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.5
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            intro.animator().alphaValue = 0
        }, completionHandler: {
            intro.isHidden = true
            intro.alphaValue = 1   // сброс для следующего показа
        })
    }

    @objc private func openSettings() { permTimer?.invalidate(); onOpenSettings?(); window?.close() }
    @objc private func goClose() { permTimer?.invalidate(); window?.close() }
    func windowWillClose(_ n: Notification) { permTimer?.invalidate(); onClose?() }

    // Фикс «окно уползает вправо при ресайзе высоты»: ширина фиксирована (min.width == max.width == 480),
    // и AppKit при изменении высоты иногда дрейфит origin.x мелкими шажками. Держим x неизменным на время
    // живого ресайза. setFrameOrigin меняет ТОЛЬКО позицию (не размер) → не рекурсит в windowDidResize.
    private var liveResizeX: CGFloat?
    func windowWillStartLiveResize(_ n: Notification) { liveResizeX = window?.frame.origin.x }
    func windowDidEndLiveResize(_ n: Notification) { liveResizeX = nil }
    func windowDidResize(_ n: Notification) {
        guard let w = window, let x = liveResizeX, abs(w.frame.origin.x - x) > 0.5 else { return }
        w.setFrameOrigin(NSPoint(x: x, y: w.frame.origin.y))
    }

    // MARK: доступы (онбординг)
    @objc private func grantAX() {
        _ = Permissions.requestTrust()          // системный промпт (добавит Keyboop в список)
        Permissions.openAccessibilitySettings() // и сразу открываем панель — включить тумблер
    }
    @objc private func grantMic() {
        Task { _ = await AudioRecorder.requestAccess(); await MainActor.run { self.refreshPerms() } }
    }
    private func startPermTimer() {
        permTimer?.invalidate()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.refreshPerms() }
        RunLoop.main.add(t, forMode: .common); permTimer = t
        refreshPerms()
    }
    private func refreshPerms() {
        let ax = Permissions.isTrusted()
        axStatus?.stringValue = ax ? "✓" : "—"
        axStatus?.textColor = ax ? DS.coral : .tertiaryLabelColor
        axBtn?.isHidden = ax
        let mic = AudioRecorder.authorized
        micStatus?.stringValue = mic ? "✓" : "—"
        micStatus?.textColor = mic ? DS.coral : .tertiaryLabelColor
        micBtn?.isHidden = mic
    }
    /// Строка доступа: заголовок+подпись слева, статус (✓/—) + кнопка «Разрешить» справа (кнопка
    /// прячется, когда доступ выдан — статус обновляется по таймеру, пока окно открыто).
    private func addPermRow(_ stack: NSStackView, title: String, sub: String, granted: Bool, action: Selector) -> (NSTextField, NSButton) {
        let t = NSTextField(labelWithString: title); t.font = .systemFont(ofSize: 13, weight: .semibold)
        let subL = WrappingLabel(string: sub); subL.font = .systemFont(ofSize: 11.5); subL.textColor = .tertiaryLabelColor
        let col = NSStackView(views: [t, subL]); col.orientation = .vertical; col.alignment = .leading; col.spacing = 1
        let status = NSTextField(labelWithString: granted ? "✓" : "—")
        status.font = .systemFont(ofSize: 15, weight: .bold)
        status.textColor = granted ? DS.coral : .tertiaryLabelColor
        status.setContentHuggingPriority(.required, for: .horizontal)
        let btn = NSButton(title: L10n.t("wel.allow"), target: self, action: action)
        btn.bezelStyle = .rounded; btn.controlSize = .regular
        btn.setContentHuggingPriority(.required, for: .horizontal); btn.isHidden = granted
        let spacer = NSView(); spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        col.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let row = NSStackView(views: [col, spacer, status, btn])
        row.orientation = .horizontal; row.spacing = 10; row.alignment = .centerY
        stack.addArrangedSubview(row); fullWidth.append(row)
        return (status, btn)
    }

    /// Карточка языкового пакета RU↔EN для онбординга: статус (async) + кнопка в системный менеджер
    /// языков (там реальная загрузка с прогрессом — своё окно докачки виснет, не делаем). Зеркало
    /// SettingsWindow.trPackCard в стиле онбординга.
    @available(macOS 15.0, *)
    private func addTrPackRow(_ stack: NSStackView) {
        let name = NSTextField(labelWithString: L10n.t("tr.packName"))
        name.font = .systemFont(ofSize: 13); name.textColor = .labelColor
        name.setContentCompressionResistancePriority(.required, for: .horizontal)
        let meta = NSTextField(labelWithString: L10n.t("tr.checking"))
        meta.font = .systemFont(ofSize: 11); meta.textColor = .secondaryLabelColor
        trPackStatus = meta
        let nameCol = NSStackView(views: [name, meta])
        nameCol.orientation = .vertical; nameCol.alignment = .leading; nameCol.spacing = 1
        nameCol.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let sys = NSButton(title: L10n.t("tr.openSys"), target: self, action: #selector(openLangSettings))
        sys.bezelStyle = .rounded; sys.controlSize = .regular
        sys.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = NSView(); spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let row = NSStackView(views: [nameCol, spacer, sys])
        row.orientation = .horizontal; row.spacing = 10; row.alignment = .centerY
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        stack.addArrangedSubview(row); fullWidth.append(row)
        refreshTrPackStatus()
    }

    /// Async-проверка наличия пакета RU↔EN (мирроr SettingsWindow.refreshTrPackStatus).
    private func refreshTrPackStatus() {
        guard #available(macOS 15.0, *) else { return }
        Task { [weak self] in
            let ok = await TranslationEngine.shared.isInstalled(from: "ru", to: "en")
            await MainActor.run {
                self?.trPackStatus?.stringValue = ok ? L10n.t("tr.installed") : L10n.t("tr.notInstalled")
                self?.trPackStatus?.textColor = ok ? DS.coral : .secondaryLabelColor
            }
        }
    }

    /// Системные настройки → «Язык и регион» (менеджер языков перевода с реальным прогрессом).
    @objc private func openLangSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Строка «подпись слева — контрол справа» (для хоткей-контролов в онбординге).
    private func addControlRow(_ s: NSStackView, _ label: String, _ control: NSView) {
        let l = NSTextField(labelWithString: label); l.font = .systemFont(ofSize: 13); l.textColor = .labelColor
        l.lineBreakMode = .byTruncatingTail
        l.setContentCompressionResistancePriority(.required, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = NSView(); spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let row = NSStackView(views: [l, spacer, control]); row.orientation = .horizontal; row.spacing = 14; row.alignment = .centerY
        // Вертикальное «дыхание» — иначе ряды с popup'ами слипаются (заметил автор на скрине онбординга).
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
        s.addArrangedSubview(row); fullWidth.append(row)
    }
    @objc private func downloadVoice() {
        guard !voiceDownloading else { return }
        voiceDownloading = true
        voiceBtn?.isEnabled = false; voiceBtn?.title = "0%"
        Task { [weak self] in
            let ok = await ParakeetEngine.shared.download(progress: { f in
                DispatchQueue.main.async { self?.voiceBtn?.title = "\(Int(f * 100))%" }
            })
            await MainActor.run {
                self?.voiceDownloading = false
                self?.voiceBtn?.isEnabled = true
                self?.voiceBtn?.title = ok ? L10n.t("wel.voiceReady") : L10n.t("wel.voiceDownload")
            }
        }
    }

    // MARK: helpers
    private func addGap(_ s: NSStackView, _ h: CGFloat) {
        let v = NSView(); v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        s.addArrangedSubview(v)
    }
    private func addWrap(_ s: NSStackView, _ text: String, size: CGFloat, color: NSColor) {
        let l = WrappingLabel(string: text)
        l.font = .systemFont(ofSize: size); l.textColor = color
        s.addArrangedSubview(l); fullWidth.append(l)
    }
    private func addSection(_ s: NSStackView, _ text: String) {
        // Коралловый «eyebrow» с кернингом — единый стиль с настройками (SettingsWindow.sectionTitle).
        let l = NSTextField(labelWithString: "")
        l.attributedStringValue = NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: DS.coral,
            .kern: 1.1
        ])
        l.isEditable = false; l.isBordered = false; l.drawsBackground = false
        s.addArrangedSubview(l)
    }
    private func addBullet(_ s: NSStackView, _ text: String) {
        let dot = NSTextField(labelWithString: "▸")
        dot.font = .systemFont(ofSize: 12, weight: .bold); dot.textColor = DS.coral
        dot.setContentHuggingPriority(.required, for: .horizontal)
        dot.setContentCompressionResistancePriority(.required, for: .horizontal)
        let txt = WrappingLabel(string: text)
        txt.font = .systemFont(ofSize: 13); txt.textColor = .labelColor
        let row = NSStackView(views: [dot, txt]); row.orientation = .horizontal; row.spacing = 8; row.alignment = .firstBaseline
        s.addArrangedSubview(row); fullWidth.append(row)
    }
    private func addKeyRow(_ s: NSStackView, _ key: String, _ desc: String) {
        let label = NSTextField(labelWithString: key)
        label.font = .monospacedSystemFont(ofSize: 12.5, weight: .semibold); label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        let chip = NSView(); chip.wantsLayer = true
        chip.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        chip.layer?.cornerRadius = 6
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(label)
        NSLayoutConstraint.activate([
            chip.widthAnchor.constraint(equalToConstant: 46),
            chip.heightAnchor.constraint(equalToConstant: 24),
            label.centerXAnchor.constraint(equalTo: chip.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: chip.centerYAnchor)
        ])
        chip.setContentHuggingPriority(.required, for: .horizontal)
        let txt = WrappingLabel(string: desc)
        txt.font = .systemFont(ofSize: 13); txt.textColor = .secondaryLabelColor
        let row = NSStackView(views: [chip, txt]); row.orientation = .horizontal; row.spacing = 10; row.alignment = .centerY
        s.addArrangedSubview(row); fullWidth.append(row)
    }
}

/// Flipped clip-view для NSScrollView: y растёт вниз → контент начинается сверху (а не снизу).
private final class FlippedClip: NSClipView { override var isFlipped: Bool { true } }
