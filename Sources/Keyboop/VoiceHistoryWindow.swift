import AppKit

/// Окно истории голосового набора (в духе Superwhisper/Wispr, в нашем стиле):
/// поиск, чистый список карточек (действия проявляются по наведению — как в Things/Mail,
/// чтобы иконки не наезжали на дату), крупная ОСНОВНАЯ кнопка записи (coral pill),
/// мелкие вторичные иконки (поверх окон / настройки / очистить).
final class VoiceHistoryWindowController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate {
    private var all: [VoiceHistory.Entry] = []
    private var filtered: [VoiceHistory.Entry] = []
    private let search = NSSearchField()
    private let listStack = NSStackView()
    private let scroll = NSScrollView()
    private let emptyView = NSStackView()
    private let recordBtn = PillButton()
    private let pinBtn = NSButton()
    private let translBtn = SecondaryClickButton()
    private var pinned = false
    private var translucent = false
    private var opacityPopover: NSPopover?
    private var refreshTimer: Timer?
    private var lastCount = -1
    private let df: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM, HH:mm"
        f.locale = Locale(identifier: L10n.current == .ru ? "ru_RU" : "en_US"); return f
    }()

    var onOpenVoiceSettings: (() -> Void)?

    convenience init() {
        // Узкое высокое окно (как у Superwhisper) — удобно держать сбоку.
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 820),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = L10n.t("hist.title")
        w.titlebarAppearsTransparent = true
        w.minSize = NSSize(width: 320, height: 380)   // нельзя свернуть в точку — элементы доступны
        w.center()
        self.init(window: w)
        w.delegate = self
        w.setFrameAutosaveName("KeyboopVoiceHistory2") // v2 — сбрасывает старый сохранённый размер на новый дефолт
        build()
    }

    func show() {
        // Опциональный пароль (HistoryGate): спрашиваем при ОТКРЫТИИ окна. Уже открытое окно
        // просто фронтим без повторного вопроса; закрыл — при следующем открытии спросим снова.
        if window?.isVisible != true, HistoryGate.enabled {
            HistoryGate.promptUnlock { [weak self] ok in
                guard ok else { return }
                self?.reallyShow()
            }
            return
        }
        reallyShow()
    }

    private func reallyShow() {
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // НЕ держим фокус в поле поиска: иначе диктовка сыплется в него. Курсор — нигде.
        window?.makeFirstResponder(nil)
        startRefresh()
        // Мгновенное обновление при новой записи (надёжнее поллинга): подписка на уведомление.
        NotificationCenter.default.removeObserver(self, name: .keyboopVoiceHistoryChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(historyChanged),
                                               name: .keyboopVoiceHistoryChanged, object: nil)
    }

    @objc private func historyChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.reload()
            self?.scrollToTop()   // новая запись сверху — показываем её сразу
        }
    }

    /// Промотать список к самому верху (doc-view flipped → верх = y 0).
    private func scrollToTop() {
        window?.contentView?.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func startRefresh() {
        refreshTimer?.invalidate()
        let t = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.updateRecordButton()
            self?.reloadIfChanged()
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    func windowWillClose(_ notification: Notification) {
        VoiceClipPlayerView.stopAll()   // окно ушло — голос из него звучать не должен
        refreshTimer?.invalidate()
        NotificationCenter.default.removeObserver(self, name: .keyboopVoiceHistoryChanged, object: nil)
    }

    // MARK: UI

    private func build() {
        guard let content = window?.contentView else { return }
        let dump = ProcessInfo.processInfo.environment["KEYBOOP_DUMP"] == "1"
        let bg: NSView
        if dump {                                   // непрозрачный ТЁМНЫЙ фон → cacheDisplay-снимок (окно тёмное)
            let s = NSView(); s.wantsLayer = true
            s.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor; bg = s
        } else {
            let eff = NSVisualEffectView(); eff.material = .underWindowBackground; eff.blendingMode = .behindWindow; bg = eff
        }
        bg.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bg)

        search.placeholderString = L10n.t("hist.search")
        search.translatesAutoresizingMaskIntoConstraints = false
        search.controlSize = .large
        search.delegate = self
        bg.addSubview(search)

        listStack.orientation = .vertical
        listStack.alignment = .width   // карточки одинаковой ширины на всю колонку (cross-axis sizing)
        listStack.spacing = 7
        listStack.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(listStack)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(scroll)

        // Пустое состояние: иконка + подпись по центру.
        let emptyIcon = NSImageView()
        emptyIcon.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
        emptyIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 26, weight: .regular)
        emptyIcon.contentTintColor = .quaternaryLabelColor
        let emptyLabel = NSTextField(labelWithString: L10n.t("hist.empty"))
        emptyLabel.font = .systemFont(ofSize: 12); emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyView.orientation = .vertical; emptyView.alignment = .centerX; emptyView.spacing = 10
        emptyView.addArrangedSubview(emptyIcon); emptyView.addArrangedSubview(emptyLabel)
        emptyView.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(emptyView)

        // ── Нижняя зона: вторичные иконки (мелкие, приглушённые) + ОСНОВНАЯ кнопка записи ──
        pinBtn.bezelStyle = .regularSquare; pinBtn.isBordered = false
        pinBtn.setButtonType(.toggle)
        pinBtn.image = NSImage(systemSymbolName: "pin", accessibilityDescription: L10n.t("hist.pin"))
        pinBtn.alternateImage = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: L10n.t("hist.pin"))
        pinBtn.imagePosition = .imageOnly
        pinBtn.contentTintColor = .secondaryLabelColor
        pinBtn.toolTip = L10n.t("hist.pin")
        pinBtn.target = self; pinBtn.action = #selector(togglePin)
        // Полупрозрачность окна — иконка СЛЕВА от пина (чтобы окно меньше мешалось, когда запинено).
        translBtn.bezelStyle = .regularSquare; translBtn.isBordered = false
        translBtn.setButtonType(.toggle)
        translBtn.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: L10n.t("hist.translucent"))
        translBtn.imagePosition = .imageOnly
        translBtn.contentTintColor = .secondaryLabelColor
        translBtn.toolTip = L10n.t("hist.translucent") + " · " + L10n.t("hist.opacityHint")
        translBtn.target = self; translBtn.action = #selector(toggleTranslucency)
        translBtn.onSecondaryClick = { [weak self] in self?.showOpacitySlider() }

        rateBtn.bezelStyle = .regularSquare; rateBtn.isBordered = false
        rateBtn.attributedTitle = rateTitle()
        rateBtn.toolTip = L10n.t("clip.rate")
        rateBtn.target = self; rateBtn.action = #selector(cycleRate)

        // «Поверх всех окон» — в ПРАВЫЙ ВЕРХНИЙ угол титлбара (напротив «светофора» слева).
        // Скорость воспроизведения — левее прозрачности: она про содержимое окна, а две правые
        // кнопки про само окно, и смешивать эти две группы не стоит.
        let pinHost = NSView(frame: NSRect(x: 0, y: 0, width: 104, height: 28))
        let titleBar = NSStackView(views: [rateBtn, translBtn, pinBtn])
        titleBar.orientation = .horizontal; titleBar.spacing = 8; titleBar.alignment = .centerY
        titleBar.translatesAutoresizingMaskIntoConstraints = false
        pinHost.addSubview(titleBar)
        NSLayoutConstraint.activate([
            titleBar.centerYAnchor.constraint(equalTo: pinHost.centerYAnchor),
            titleBar.trailingAnchor.constraint(equalTo: pinHost.trailingAnchor, constant: -10),
            pinBtn.widthAnchor.constraint(equalToConstant: 20),
            pinBtn.heightAnchor.constraint(equalToConstant: 20),
            translBtn.widthAnchor.constraint(equalToConstant: 20),
            translBtn.heightAnchor.constraint(equalToConstant: 20),
            rateBtn.widthAnchor.constraint(equalToConstant: 30),
            rateBtn.heightAnchor.constraint(equalToConstant: 20)
        ])
        let pinAcc = NSTitlebarAccessoryViewController()
        pinAcc.layoutAttribute = .trailing
        pinAcc.view = pinHost
        window?.addTitlebarAccessoryViewController(pinAcc)

        let setBtn = secondaryIcon("gearshape", L10n.t("hist.settings"), #selector(openSettings))
        let clearBtn = secondaryIcon("trash", L10n.t("voice.histClear"), #selector(clearAll))

        // ⚠️ НИЖНЯЯ ПОЛОСА ОДНА, А НЕ ДВЕ (автор 10.08). Раньше «Записать» занимала всю ширину, а
        // мелкие кнопки жались отдельной строкой над ней: две полосы съедали высоту у списка и
        // читались как два разных этажа управления. Теперь один ряд: слева кнопка записи в половину
        // ширины, справа настройки и очистка.
        recordBtn.target = self; recordBtn.action = #selector(toggleRecord)
        recordBtn.translatesAutoresizingMaskIntoConstraints = false
        updateRecordButton()

        // «Записать» стоит РОВНО ПО ЦЕНТРУ окна, а мелкие кнопки прижаты к правому краю. Через
        // NSStackView этого не добиться: он центрирует содержимое целиком, и главная кнопка уезжает
        // влево ровно на ширину соседей. Поэтому три отдельных якоря.
        let secondaryBar = NSStackView(views: [setBtn, clearBtn])
        secondaryBar.orientation = .horizontal; secondaryBar.spacing = 6; secondaryBar.alignment = .centerY
        secondaryBar.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(secondaryBar)
        bg.addSubview(recordBtn)

        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bg.topAnchor.constraint(equalTo: content.topAnchor),
            bg.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            search.topAnchor.constraint(equalTo: bg.safeAreaLayoutGuide.topAnchor, constant: 8),
            search.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 14),
            search.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -14),

            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: secondaryBar.topAnchor, constant: -10),

            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            listStack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 4),
            listStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 4),
            listStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -4),
            listStack.bottomAnchor.constraint(lessThanOrEqualTo: doc.bottomAnchor, constant: -4),

            emptyView.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyView.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 60),

            secondaryBar.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -14),
            secondaryBar.centerYAnchor.constraint(equalTo: recordBtn.centerYAnchor),

            recordBtn.centerXAnchor.constraint(equalTo: bg.centerXAnchor),
            recordBtn.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -14),
            // Половина ширины, но не уже 150 точек: на узком окне «Записать» иначе схлопнулась бы
            // до кружка с обрезанной подписью.
            recordBtn.widthAnchor.constraint(equalTo: bg.widthAnchor, multiplier: 0.5),
            recordBtn.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            recordBtn.heightAnchor.constraint(equalToConstant: 42)
        ])

        // Длинное удержание на фоне окна (~0.5 с) — тот же слайдер прозрачности, что по правому клику.
        let press = NSPressGestureRecognizer(target: self, action: #selector(longPressOpacity(_:)))
        press.minimumPressDuration = 0.5
        bg.addGestureRecognizer(press)
    }

    /// Мелкая вторичная иконка (приглушённая, без рамки) — поверх окон / настройки / очистить.
    /// Скорость воспроизведения — ОДНА НА ВСЕ ЗАПИСИ (решение автора 10.08). Стоит в заголовке окна
    /// слева от прозрачности, а не на карточке: человек выбирает, как ему слушать вообще, а не
    /// настраивает темп каждой заметке отдельно.
    private let rateBtn = NSButton()

    private func rateTitle() -> NSAttributedString {
        let r = AppSettings.shared.voiceClipRate
        // «1,5×» с запятой: это русский интерфейс, а не консоль.
        let text = r == rint(r) ? String(format: "%.0f×", r)
                                : String(format: "%.1f×", r).replacingOccurrences(of: ".", with: ",")
        return NSAttributedString(string: text, attributes: [
            .foregroundColor: r > 1.0 ? DS.coral : NSColor.secondaryLabelColor,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        ])
    }

    /// Следующая ступень по кругу. Играющая запись подхватывает темп на лету.
    @objc private func cycleRate() {
        let rates = VoiceClipPlayerView.rates
        let cur = AppSettings.shared.voiceClipRate
        let i = rates.firstIndex(where: { abs($0 - cur) < 0.01 }) ?? 0
        AppSettings.shared.voiceClipRate = rates[(i + 1) % rates.count]
        rateBtn.attributedTitle = rateTitle()
        VoiceClipPlayerView.applyRateToCurrent()
    }

    private func secondaryIcon(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: "", target: self, action: action)
        b.bezelStyle = .regularSquare; b.isBordered = false
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        b.imagePosition = .imageOnly
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = tip
        return b
    }

    // MARK: data

    private func reload() {
        all = VoiceHistory.shared.all().reversed()
        applyFilter()
    }
    private func reloadIfChanged() {
        let c = VoiceHistory.shared.all().count
        if c != lastCount { reload() }
    }
    private func applyFilter() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        filtered = q.isEmpty ? all : all.filter { $0.text.lowercased().contains(q) }
        lastCount = all.count
        rebuildCards()
    }
    private func rebuildCards() {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for e in filtered {
            let c = card(e)
            listStack.addArrangedSubview(c)
            // ЯВНО фиксируем ширину карточки = ширине списка (alignment=.width не растягивал
            // короткие записи → они выглядели как узкие «чат-пузыри» справа). Теперь все ровные.
            c.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        }
        emptyView.isHidden = !filtered.isEmpty
    }

    private func card(_ e: VoiceHistory.Entry) -> NSView {
        let tag = entryTag(e)
        let date = NSTextField(labelWithString: df.string(from: e.date))
        date.font = .systemFont(ofSize: 11, weight: .medium); date.textColor = .secondaryLabelColor
        date.setContentCompressionResistancePriority(.required, for: .horizontal)
        date.setContentHuggingPriority(.required, for: .horizontal)

        let copy = cardIcon("doc.on.doc", L10n.t("hist.copy"), #selector(copyEntry(_:)), tag)
        let del = cardIcon("trash", L10n.t("hist.del"), #selector(deleteEntry(_:)), tag)

        let text = WrappingLabel(string: e.text)
        text.font = .systemFont(ofSize: 13); text.textColor = .labelColor
        text.isSelectable = true                       // выделить и скопировать ЧАСТЬ текста
        text.maximumNumberOfLines = 0                  // перенос по словам, весь текст видно (не усекаем)
        text.lineBreakMode = .byWordWrapping

        // Аудио есть только если человек включил сохранение И файл ещё жив. Проверяем именно файл, а
        // не только поле записи: клип мог не пережить перевыпуск ключа, и плеер на пустоту предлагал
        // бы нажать кнопку, которая ничего не делает.
        guard let clip = e.audio, VoiceClips.exists(clip) else {
            return HoverCard(date: date, body: text, actions: [copy, del])
        }
        let body = NSStackView(views: [text, VoiceClipPlayerView(clipID: clip, wave: e.wave)])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 8
        body.translatesAutoresizingMaskIntoConstraints = false
        // Плеер тянем во всю ширину карточки: иначе NSStackView сжимает его по содержимому и дорожка
        // превращается в огрызок рядом с длинным текстом.
        body.arrangedSubviews.last?.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        return HoverCard(date: date, body: body, actions: [copy, del])
    }

    /// Иконка-действие на карточке (проявляется по наведению).
    private func cardIcon(_ symbol: String, _ tip: String, _ action: Selector, _ tag: Int) -> NSButton {
        let b = NSButton(title: "", target: self, action: action)
        b.bezelStyle = .regularSquare; b.isBordered = false
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        b.imagePosition = .imageOnly
        b.toolTip = tip; b.tag = tag
        b.contentTintColor = .secondaryLabelColor
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 22).isActive = true
        b.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return b
    }

    private func entryTag(_ e: VoiceHistory.Entry) -> Int {
        all.firstIndex { $0.date == e.date && $0.text == e.text } ?? -1
    }

    // MARK: actions

    func controlTextDidChange(_ obj: Notification) { applyFilter() }

    @objc private func copyEntry(_ s: NSButton) {
        guard s.tag >= 0, s.tag < all.count else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(all[s.tag].text, forType: .string)
        // короткий визуальный отклик: галочка на 1 c
        let prev = s.image
        s.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        s.contentTintColor = DS.coral
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak s] in
            s?.image = prev; s?.contentTintColor = .secondaryLabelColor
        }
    }
    @objc private func deleteEntry(_ s: NSButton) {
        guard s.tag >= 0, s.tag < all.count else { return }
        let e = all[s.tag]
        VoiceHistory.shared.remove(date: e.date, text: e.text)
        reload()
    }
    @objc private func toggleRecord() {
        VoiceController.shared.toggleRecording()
        updateRecordButton()
    }
    private func updateRecordButton() {
        let rec = VoiceController.shared.isRecording
        recordBtn.configure(symbol: rec ? "stop.fill" : "mic.fill",
                            title: L10n.t(rec ? "hist.recStop" : "hist.rec"),
                            color: rec ? NSColor.systemRed : DS.coral)
    }
    @objc private func togglePin() {
        pinned.toggle()
        window?.level = pinned ? .floating : .normal
        pinBtn.contentTintColor = pinned ? DS.coral : .secondaryLabelColor
    }
    @objc private func toggleTranslucency() {
        translucent.toggle()
        let saved = AppSettings.shared.voiceWinOpacity
        let lvl = saved > 0 ? saved : 0.8
        window?.alphaValue = translucent ? CGFloat(lvl) : 1.0
        translBtn.contentTintColor = translucent ? DS.coral : .secondaryLabelColor
    }

    /// Правый/⌃-клик по кнопке прозрачности → слайдер уровня (сохраняется).
    private func showOpacitySlider() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 210, height: 52))
        let cap = NSTextField(labelWithString: L10n.t("hist.translucent"))
        cap.font = .systemFont(ofSize: 11); cap.textColor = .secondaryLabelColor
        cap.frame = NSRect(x: 14, y: 30, width: 182, height: 14)
        let saved = AppSettings.shared.voiceWinOpacity
        let lvl = saved > 0 ? saved : 0.8
        let sld = NSSlider(value: lvl, minValue: 0.15, maxValue: 1.0, target: self, action: #selector(opacitySliderChanged(_:)))
        sld.frame = NSRect(x: 14, y: 10, width: 182, height: 18); sld.controlSize = .small
        host.addSubview(cap); host.addSubview(sld)
        let vc = NSViewController(); vc.view = host
        let pop = NSPopover(); pop.contentViewController = vc; pop.behavior = .transient
        opacityPopover = pop
        pop.show(relativeTo: translBtn.bounds, of: translBtn, preferredEdge: .maxY)
    }
    @objc private func longPressOpacity(_ gr: NSPressGestureRecognizer) {
        guard gr.state == .began else { return }
        showOpacitySlider()
    }
    @objc private func opacitySliderChanged(_ s: NSSlider) {
        translucent = true
        AppSettings.shared.voiceWinOpacity = s.doubleValue
        window?.alphaValue = CGFloat(s.doubleValue)
        translBtn.contentTintColor = DS.coral
    }
    @objc private func openSettings() { onOpenVoiceSettings?() }
    /// ⚠️ ОЧИСТКА СПРАШИВАЕТ ПОДТВЕРЖДЕНИЕ (автор 10.08). Кнопка стоит рядом с настройками, промах
    /// пальцем стоил бы человеку всей истории вместе с аудиозаписями, а отмены у этого действия нет.
    @objc private func clearAll() {
        let a = NSAlert()
        a.messageText = L10n.t("hist.clearConfirm")
        a.informativeText = L10n.t("hist.clearConfirmBody")
        a.alertStyle = .warning
        let del = a.addButton(withTitle: L10n.t("hist.clearConfirmYes"))
        del.hasDestructiveAction = true
        a.addButton(withTitle: L10n.t("hist.clearConfirmNo"))
        if let w = window {
            a.beginSheetModal(for: w) { [weak self] r in
                guard r == .alertFirstButtonReturn else { return }
                self?.reallyClearAll()
            }
        } else if a.runModal() == .alertFirstButtonReturn {
            reallyClearAll()
        }
    }

    private func reallyClearAll() {
        VoiceHistory.shared.clear()
        reload()
    }

    /// Dev: снимок окна истории (cacheDisplay по непрозрачному фону в DUMP-режиме).
    func dump(to path: String) {
        guard let v = window?.contentView else { return }
        v.layoutSubtreeIfNeeded()
        let b = v.bounds
        guard b.width > 1, let rep = v.bitmapImageRepForCachingDisplay(in: b) else { return }
        v.cacheDisplay(in: b, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
    /// Dev: подставить демо-записи и ПОКАЗАТЬ окно живьём (для снимка снаружи, см. KEYBOOP_HISTLIVE).
    func fillWithSamples() {
        dumpWithSamples(to: "/tmp/kb_history_live.png")
    }

    /// Dev: подставить демо-записи (НЕ трогая реальную историю) + показать действия + снять.
    func dumpWithSamples(to path: String) {
        window?.appearance = NSAppearance(named: .darkAqua)   // окно тёмное — рендерим как видит юзер
        // Демо-клип для плеера. Настройку трогаем только на время создания и возвращаем: правило про
        // чужие настройки действует и в dev-хуках, а `voiceSaveAudio` живёт в UserDefaults dev-сборки
        // (ru.keyboop.app.dev), то есть до боевых настроек всё равно не дотягивается.
        let savePrev = AppSettings.shared.voiceSaveAudio
        AppSettings.shared.voiceSaveAudio = true
        // ⚠️ Демо-сигнал должен быть РЕЧЕПОДОБНЫМ, а не ровным тоном. Первый вариант был чистой
        // синусоидой, и волна на снимке получилась одинаковой гребёнкой: картинка выглядела
        // сломанной, хотя код был верен. Снимок, который врёт про внешний вид, хуже отсутствующего.
        let demoLen = 16_000 * 7
        var demo = [Float](repeating: 0, count: demoLen)
        for i in 0..<demoLen {
            let t = Float(i) / 16_000
            // Слоги примерно по трети секунды и паузы между фразами: огибающая получается живой.
            let syllable = 0.55 + 0.45 * sinf(2 * .pi * 3.1 * t)
            let phrase: Float = (t.truncatingRemainder(dividingBy: 2.4) > 1.9) ? 0.05 : 1.0
            let voice = sinf(2 * .pi * 190 * t) + 0.4 * sinf(2 * .pi * 780 * t) + 0.2 * sinf(2 * .pi * 2400 * t)
            demo[i] = 0.22 * syllable * phrase * voice
        }
        let demoClip = VoiceClips.save(samples: demo)
        AppSettings.shared.voiceSaveAudio = savePrev
        let now = Date()
        all = [
            .init(date: now.addingTimeInterval(-50),   text: "Можно проверить, как работает голосовой ввод прямо в этом окне.", audio: demoClip?.id, wave: demoClip?.wave),
            .init(date: now.addingTimeInterval(-240),  text: "Так, ну, смотрим."),
            .init(date: now.addingTimeInterval(-900),  text: "Вот прямо сейчас пользуюсь этим голосовым вводом — и знаки препинания расставляются сами, без интернета."),
            .init(date: now.addingTimeInterval(-3600), text: "It's time to test and ship it to the market."),
            .init(date: now.addingTimeInterval(-7200), text: "Короткая заметка на память.")
        ]
        filtered = all; lastCount = all.count
        defer { demoClip.map { VoiceClips.delete($0.id) } }   // демо-файл не переживает снимок
        rebuildCards()
        window?.contentView?.layoutSubtreeIfNeeded()
        listStack.arrangedSubviews.compactMap { $0 as? HoverCard }.forEach { $0.revealForDump() }
        window?.contentView?.layoutSubtreeIfNeeded()
        dump(to: path)
    }
}

// MARK: - SecondaryClickButton: левый клик = action, правый / ⌃-клик = onSecondaryClick

/// Кнопка с дополнительным жестом: правый клик или ⌃-клик открывает слайдер/меню.
final class SecondaryClickButton: NSButton {
    var onSecondaryClick: (() -> Void)?
    override func rightMouseDown(with event: NSEvent) { onSecondaryClick?() }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { onSecondaryClick?(); return }
        super.mouseDown(with: event)
    }
}

// MARK: - PillButton: основная coral-кнопка (запись) с hover/press

/// Крупная заполненная «pill»-кнопка (главное действие). Layer-backed, coral-фон,
/// белый символ+текст, лёгкое осветление при наведении и затемнение при нажатии.
final class PillButton: NSButton {
    private var base: NSColor = DS.coral
    private var hovering = false
    private var pressing = false

    override init(frame: NSRect) { super.init(frame: frame); common() }
    required init?(coder: NSCoder) { super.init(coder: coder); common() }
    private func common() {
        isBordered = false
        wantsLayer = true
        bezelStyle = .regularSquare
        // ⚠️ РАДИУС СЧИТАЕМ ОТ ВЫСОТЫ (автор 10.08: «искругли, чтобы была овальная»). Фиксированные
        // 11 точек на кнопке высотой 42 давали скруглённый прямоугольник, а не таблетку. Живой
        // расчёт в layout() держит форму при любой высоте.
        layer?.cornerCurve = .continuous
        imagePosition = .imageLeading
        imageHugsTitle = true
        font = .systemFont(ofSize: 13.5, weight: .semibold)
        contentTintColor = .white
        focusRingType = .none
    }

    func configure(symbol: String, title: String, color: NSColor) {
        base = color
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        attributedTitle = NSAttributedString(string: "  " + title, attributes: [
            .foregroundColor: NSColor.white, .font: font as Any
        ])
        contentTintColor = .white
        refresh()
    }
    private func refresh() {
        let c: NSColor
        if pressing { c = base.blended(withFraction: 0.18, of: .black) ?? base }
        else if hovering { c = base.blended(withFraction: 0.12, of: .white) ?? base }
        else { c = base }
        layer?.backgroundColor = c.cgColor
        // мягкая тень-подсветка основного действия
        layer?.shadowColor = base.cgColor
        layer?.shadowOpacity = hovering ? 0.45 : 0.30
        layer?.shadowRadius = hovering ? 10 : 7
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }
    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2   // настоящая таблетка при любой высоте
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with e: NSEvent) { hovering = false; pressing = false; refresh() }
    override func mouseDown(with e: NSEvent) {
        pressing = true; refresh()
        super.mouseDown(with: e)
        pressing = false; refresh()
    }
}

// MARK: - HoverCard: карточка записи; действия проявляются по наведению (как в Things/Mail)

/// Карточка истории: дата слева, действия (копировать/удалить) справа — скрыты, пока курсор
/// не наведён (поэтому НИКОГДА не наезжают на дату). Тело — выделяемый переносимый текст.
final class HoverCard: NSView {
    private let actions: NSStackView

    init(date: NSTextField, body: NSView, actions buttons: [NSButton]) {
        self.actions = NSStackView(views: buttons)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false

        self.actions.orientation = .horizontal
        self.actions.spacing = 2
        self.actions.alphaValue = 0           // скрыты до наведения
        self.actions.translatesAutoresizingMaskIntoConstraints = false

        date.translatesAutoresizingMaskIntoConstraints = false
        let spacer = NSView(); spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let header = NSStackView(views: [date, spacer, self.actions])
        header.orientation = .horizontal; header.spacing = 4; header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false

        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header); addSubview(body)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            body.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 3),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11)
        ])
    }
    required init?(coder: NSCoder) { fatalError("no xib") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { hover(true) }
    override func mouseExited(with e: NSEvent) { hover(false) }
    func revealForDump() { actions.alphaValue = 1 }   // dev: показать действия для скриншота
    private func hover(_ on: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.allowsImplicitAnimation = true
            actions.animator().alphaValue = on ? 1 : 0
            layer?.backgroundColor = NSColor.white.withAlphaComponent(on ? 0.09 : 0.05).cgColor
        }
    }
}
