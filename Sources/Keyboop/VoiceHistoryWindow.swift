import AppKit
import Darwin
import UniformTypeIdentifiers

/// Окно истории голосового набора (в духе Superwhisper/Wispr, в нашем стиле):
/// поиск, чистый список карточек (действия проявляются по наведению — как в Things/Mail,
/// чтобы иконки не наезжали на дату), крупная ОСНОВНАЯ кнопка записи (coral pill),
/// мелкие вторичные иконки (поверх окон / настройки / очистить).
final class VoiceHistoryWindowController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate {
    /// Окно истории, которое сейчас показано: клик по значку в Dock возвращает именно его.
    static weak var frontmost: VoiceHistoryWindowController?
    private var all: [VoiceHistory.Entry] = []
    private var filtered: [VoiceHistory.Entry] = []
    private let search = NSSearchField()
    private let listStack = NSStackView()
    private let scroll = NSScrollView()
    private let emptyView = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "")
    // Импорт аудиофайла (задача 229): строка прогресса под поиском и раскрытие длинных записей.
    private let progressBox = NSView()
    private let progressLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let progressCancel = NSButton(title: "", target: nil, action: nil)
    private var progressHeight: NSLayoutConstraint?
    private var expanded = Set<Date>()
    /// Сколько карточек ленты нарисовано. Лента рисуется порциями: с 24.09.2026 история держит до
    /// 3000 диктовок (срок хранения 7 и 30 дней), а карточки здесь настоящие вьюхи со своим
    /// текстом, плеером и кнопками. ЗАМЕР 24.09 (M1 Max, `KEYBOOP_HISTDUMP_PAD=400`): карточка
    /// стоит около 4 мс, вся лента из 408 записей собиралась 2,3 с, порция из 150 — 0,6 с, из 50 —
    /// 0,2 с. Пересборка идёт на каждое открытие, новую запись и запрос в поиске, поэтому 50.
    /// Для сравнения: прежние потолки пускали до 170 карточек, то есть те же 0,6 с у тех, кто
    /// копил буфер, так что порция это заодно и ускорение для них.
    static let pageSize = 50
    private var shownLimit = pageSize
    /// Поиск пересобирает ленту не на каждую букву, а после короткой паузы в наборе.
    private var searchDebounce: DispatchWorkItem?
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
    private let exportDF: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX"); return f
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
        shownLimit = Self.pageSize
        reload()
        // Пока окно открыто, в Dock стоит значок с подписью (автор 04.09): иначе окно, ушедшее под
        // чужое, не найти без повторного вызова через меню.
        Self.frontmost = self
        DockPresence.acquire(.history)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // НЕ держим фокус в поле поиска: иначе диктовка сыплется в него. Курсор — нигде.
        window?.makeFirstResponder(nil)
        startRefresh()
        // Окно закрыли и открыли посреди импорта: строка прогресса возвращается сама.
        if AudioImporter.shared.isRunning, let p = AudioImporter.shared.lastProgress { showProgress(p) }
        // Мгновенное обновление при новой записи (надёжнее поллинга): подписка на уведомление.
        NotificationCenter.default.removeObserver(self, name: .keyboopVoiceHistoryChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(historyChanged),
                                               name: .keyboopVoiceHistoryChanged, object: nil)
    }

    @objc private func historyChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Новая запись сверху: порцию сбрасываем и мотаем к ней. Удаление карточки и тихая
            // чистка по сроку приходят ТЕМ ЖЕ уведомлением, и там человек читает ленту где-то в
            // середине: сбросить её к первым 50 значило бы выбросить его из места (ревью 24.09).
            let newest = VoiceHistory.shared.all().last?.date
            let isNew = newest != nil && newest != self.all.first?.date
            if isNew { self.shownLimit = Self.pageSize }
            self.reload()
            if isNew { self.scrollToTop() }
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
        if Self.frontmost === self { Self.frontmost = nil }
        DockPresence.release(.history)
        refreshTimer?.invalidate()
        NotificationCenter.default.removeObserver(self, name: .keyboopVoiceHistoryChanged, object: nil)
    }

    // MARK: UI

    private func build() {
        guard let content = window?.contentView else { return }
        let dump = ProcessInfo.processInfo.environment["KEYBOOP_DUMP"] == "1"
        let bg: NSView
        let drop: AudioDropHost
        if dump {                                   // непрозрачный ТЁМНЫЙ фон → cacheDisplay-снимок (окно тёмное)
            let s = AudioDropPlainView(); s.wantsLayer = true
            s.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor; bg = s; drop = s
        } else {
            let eff = AudioDropEffectView(); eff.material = .underWindowBackground; eff.blendingMode = .behindWindow
            bg = eff; drop = eff
        }
        // Аудиофайл можно перетащить в любое место окна (автор 04.09): контейнер под всеми
        // элементами зарегистрирован на файлы, а AppKit ищет получателя вверх по иерархии от того,
        // над чем отпустили, поэтому карточки и поиск не мешают.
        drop.onDrop = { [weak self] url in self?.beginImport(url: url) }
        bg.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bg)

        search.placeholderString = L10n.t("hist.search")
        search.translatesAutoresizingMaskIntoConstraints = false
        search.controlSize = .large
        search.delegate = self
        bg.addSubview(search)

        // Строка прогресса импорта (задача 229): видна только пока файл расшифровывается.
        progressBox.translatesAutoresizingMaskIntoConstraints = false
        progressBox.isHidden = true
        progressLabel.font = .systemFont(ofSize: 11); progressLabel.textColor = .secondaryLabelColor
        progressLabel.lineBreakMode = .byTruncatingMiddle
        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        progressBar.style = .bar; progressBar.isIndeterminate = false
        progressBar.minValue = 0; progressBar.maxValue = 1
        progressBar.controlSize = .small
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressCancel.title = L10n.t("hist.importCancel")
        progressCancel.bezelStyle = .rounded; progressCancel.controlSize = .small
        progressCancel.target = self; progressCancel.action = #selector(cancelImport)
        progressCancel.translatesAutoresizingMaskIntoConstraints = false
        progressBox.addSubview(progressLabel); progressBox.addSubview(progressCancel); progressBox.addSubview(progressBar)
        bg.addSubview(progressBox)
        let ph = progressBox.heightAnchor.constraint(equalToConstant: 0)
        ph.isActive = true; progressHeight = ph
        NSLayoutConstraint.activate([
            progressLabel.topAnchor.constraint(equalTo: progressBox.topAnchor, constant: 6),
            progressLabel.leadingAnchor.constraint(equalTo: progressBox.leadingAnchor, constant: 4),
            progressLabel.trailingAnchor.constraint(lessThanOrEqualTo: progressCancel.leadingAnchor, constant: -8),
            progressCancel.centerYAnchor.constraint(equalTo: progressLabel.centerYAnchor),
            progressCancel.trailingAnchor.constraint(equalTo: progressBox.trailingAnchor),
            progressBar.topAnchor.constraint(equalTo: progressLabel.bottomAnchor, constant: 5),
            progressBar.leadingAnchor.constraint(equalTo: progressBox.leadingAnchor, constant: 4),
            progressBar.trailingAnchor.constraint(equalTo: progressBox.trailingAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(importProgressed(_:)),
                                               name: .keyboopAudioImportProgress, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(importDidFinish(_:)),
                                               name: .keyboopAudioImportFinished, object: nil)

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
        emptyLabel.stringValue = emptyText()
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
        // Импорт аудиофайла (задача 229) стоит рядом с настройками и очисткой: автор 04.09 —
        // «вот там же можно добавить кнопку».
        let importBtn = secondaryIcon("waveform.badge.plus", L10n.t("hist.import"), #selector(importAudio))

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
        let secondaryBar = NSStackView(views: [importBtn, setBtn, clearBtn])
        // Между иконками воздух (автор 04.09: «чуть-чуть разнести»): три иконки впритык читались
        // как одна кнопка.
        secondaryBar.orientation = .horizontal; secondaryBar.spacing = 16; secondaryBar.alignment = .centerY
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

            progressBox.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 4),
            progressBox.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 14),
            progressBox.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: progressBox.bottomAnchor, constant: 8),
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
        emptyLabel.stringValue = emptyText()
        applyFilter()
    }
    /// Подсказка пустого окна зависит от того, что в него вообще может попасть.
    private func emptyText() -> String {
        AppSettings.shared.clipboardHistoryEnabled ? L10n.t("hist.emptyClip") : L10n.t("hist.empty")
    }
    private func reloadIfChanged() {
        let c = VoiceHistory.shared.all().count
        if c != lastCount { reload() }
    }
    private func applyFilter() {
        // Поиск идёт по обоим типам записей сразу (задача 228): человеку не нужно помнить,
        // продиктовал он это или скопировал. Имя программы у записи буфера тоже ищется.
        let q = search.stringValue
        filtered = all.filter { HistoryPolicy.matches($0, query: q) }
        lastCount = all.count
        rebuildCards()
    }
    private func rebuildCards() {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // ЯВНО фиксируем ширину карточки = ширине списка (alignment=.width не растягивал
        // короткие записи → они выглядели как узкие «чат-пузыри» справа). Теперь все ровные.
        filtered.prefix(shownLimit).forEach(appendCard)
        if filtered.count > shownLimit { listStack.addArrangedSubview(moreButton()) }
        emptyView.isHidden = !filtered.isEmpty
    }
    private func appendCard(_ e: VoiceHistory.Entry) {
        let c = card(e)
        listStack.addArrangedSubview(c)
        c.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
    }

    /// «Показать ещё» в конце ленты. Поиск идёт по ВСЕЙ истории, порция ограничивает только
    /// то, что нарисовано, поэтому найденная старая запись всегда доступна этой кнопкой.
    private func moreButton() -> NSView {
        let next = min(Self.pageSize, filtered.count - shownLimit)
        let title = String(format: L10n.t("hist.more"), Self.grouped(next), Self.grouped(filtered.count))
        let b = NSButton(title: title, target: self, action: #selector(showMore))
        b.isBordered = false; b.bezelStyle = .inline
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: DS.coral, .font: NSFont.systemFont(ofSize: 12, weight: .medium)])
        return b
    }
    /// Следующая порция ДОПИСЫВАЕТСЯ к нарисованным, а не пересобирает всю ленту: иначе каждое
    /// нажатие стоило бы дороже предыдущего.
    @objc private func showMore() {
        if let last = listStack.arrangedSubviews.last, !(last is HoverCard) { last.removeFromSuperview() }
        let from = shownLimit
        shownLimit += Self.pageSize
        filtered[min(from, filtered.count)..<min(shownLimit, filtered.count)].forEach(appendCard)
        if filtered.count > shownLimit { listStack.addArrangedSubview(moreButton()) }
    }

    private func card(_ e: VoiceHistory.Entry) -> NSView {
        let tag = entryTag(e)
        let date = NSTextField(labelWithString: df.string(from: e.date))
        date.font = .systemFont(ofSize: 11, weight: .medium); date.textColor = .secondaryLabelColor
        date.setContentCompressionResistancePriority(.required, for: .horizontal)
        date.setContentHuggingPriority(.required, for: .horizontal)
        let kind = kindBadge(e)

        let copy = cardIcon("doc.on.doc", L10n.t("hist.copy"), #selector(copyEntry(_:)), tag)
        let del = cardIcon("trash", L10n.t("hist.del"), #selector(deleteEntry(_:)), tag)

        let text = WrappingLabel(string: e.text)
        text.font = .systemFont(ofSize: 13); text.textColor = .labelColor
        text.isSelectable = true                       // выделить и скопировать ЧАСТЬ текста
        text.lineBreakMode = .byWordWrapping
        // Длинные записи (расшифровка часового созвона, задача 229) показываем свёрнутыми до десяти
        // строк с кнопкой «Показать целиком»: иначе одна запись превращает ленту в простыню.
        let long = e.text.count > Self.collapseThreshold
        let isExpanded = expanded.contains(e.date)
        if long && !isExpanded {
            text.maximumNumberOfLines = Self.collapsedLines
            text.cell?.truncatesLastVisibleLine = true
        } else {
            text.maximumNumberOfLines = 0              // весь текст видно (не усекаем)
        }
        var bodyViews: [NSView] = [text]
        if long { bodyViews.append(expandButton(tag: tag, expanded: isExpanded, count: e.text.count)) }
        // Порядок действий по решению автора 04.09: скопировать → (сохранить текст) → сохранить
        // аудио → удалить. Копирование первое как самое частое, удаление последнее как необратимое.
        var actions: [NSButton] = [copy]
        if e.isImported {
            actions.append(cardIcon("doc.plaintext", L10n.t("hist.saveText"), #selector(saveText(_:)), tag))
        }
        // Аудио есть только если человек включил сохранение И файл ещё жив. Проверяем именно файл, а
        // не только поле записи: клип мог не пережить перевыпуск ключа, и плеер на пустоту предлагал
        // бы нажать кнопку, которая ничего не делает.
        if let clip = e.audio, VoiceClips.exists(clip) {
            actions.append(cardIcon("square.and.arrow.down", L10n.t("hist.saveAudio"), #selector(saveAudio(_:)), tag))
            bodyViews.append(VoiceClipPlayerView(clipID: clip, wave: e.wave))
        }
        actions.append(del)
        guard bodyViews.count > 1 else { return HoverCard(date: date, kind: kind, body: text, actions: actions) }
        let body = NSStackView(views: bodyViews)
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 8
        body.translatesAutoresizingMaskIntoConstraints = false
        // Текст и плеер тянем во всю ширину карточки: иначе NSStackView сжимает плеер по содержимому
        // и дорожка превращается в огрызок рядом с длинным текстом.
        text.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        if let player = bodyViews.last as? VoiceClipPlayerView {
            player.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
        return HoverCard(date: date, kind: kind, body: body, actions: actions)
    }

    /// Порог свёрнутого показа: короткие диктовки видны целиком, часовой созвон складывается.
    static let collapseThreshold = 700
    static let collapsedLines = 10

    private func expandButton(tag: Int, expanded: Bool, count: Int) -> NSButton {
        let title = expanded ? L10n.t("hist.collapse")
                             : String(format: L10n.t("hist.expand"), Self.grouped(count))
        let b = NSButton(title: title, target: self, action: #selector(toggleExpand(_:)))
        b.isBordered = false; b.bezelStyle = .inline; b.tag = tag
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: DS.coral, .font: NSFont.systemFont(ofSize: 11, weight: .medium)])
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }
    @objc private func toggleExpand(_ s: NSButton) {
        guard s.tag >= 0, s.tag < all.count else { return }
        let e = all[s.tag]
        if expanded.contains(e.date) { expanded.remove(e.date) } else { expanded.insert(e.date) }
        // Перерисовываем ОДНУ карточку на её месте, а не всю ленту: после нескольких «Показать
        // ещё» на экране сотни карточек по ~4 мс, и раскрытие стоило бы секунды (ревью 24.09).
        // Позиция в стеке совпадает с позицией в `filtered`: кнопка «ещё» всегда последняя.
        guard let i = filtered.firstIndex(where: { $0.date == e.date && $0.text == e.text }),
              i < listStack.arrangedSubviews.count, listStack.arrangedSubviews[i] is HoverCard
        else { rebuildCards(); return }
        let old = listStack.arrangedSubviews[i]
        listStack.removeArrangedSubview(old)
        old.removeFromSuperview()
        let c = card(e)
        listStack.insertArrangedSubview(c, at: i)
        c.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
    }
    private static func grouped(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = " "
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
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

    /// Подпись типа записи: значок и слово, а не цвет (цвет никогда не носитель смысла). У записи
    /// буфера ещё и программа, из которой скопировали: по ней же работает поиск.
    private func kindBadge(_ e: VoiceHistory.Entry) -> NSView {
        let title: String
        let symbol: String
        switch e.resolvedKind {
        case .clipboard:
            title = e.app.map { String(format: L10n.t("hist.kind.clipboardFrom"), $0) } ?? L10n.t("hist.kind.clipboard")
            symbol = "doc.on.clipboard"
        case .imported:
            title = String(format: L10n.t("hist.kind.file"), e.app ?? "")
            symbol = "waveform"
        case .call:
            title = String(format: L10n.t("hist.kind.call"), e.app ?? "")
            symbol = "phone"
        case .dictation:
            title = L10n.t("hist.kind.dictation")
            symbol = "mic"
        }
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
        // Тот же цвет, что у даты: первый рендер с `tertiaryLabelColor` дал подпись, которую на
        // тёмной карточке не прочитать (снимок 04.09). Иерархия держится весом, а не бледностью.
        icon.contentTintColor = .secondaryLabelColor
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .regular); label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal; row.spacing = 3; row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func entryTag(_ e: VoiceHistory.Entry) -> Int {
        all.firstIndex { $0.date == e.date && $0.text == e.text } ?? -1
    }

    // MARK: actions

    func controlTextDidChange(_ obj: Notification) {
        searchDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.shownLimit = Self.pageSize   // новый запрос начинается с первой порции
            self.applyFilter()
        }
        searchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    @objc private func copyEntry(_ s: NSButton) {
        guard s.tag >= 0, s.tag < all.count else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(all[s.tag].text, forType: .string)
        NSPasteboard.general.kbNoteOurs()   // иначе история буфера запишет нашу же копию
        // короткий визуальный отклик: галочка на 1 c
        let prev = s.image
        s.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        s.contentTintColor = DS.coral
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak s] in
            s?.image = prev; s?.contentTintColor = .secondaryLabelColor
        }
    }
    @objc private func saveAudio(_ s: NSButton) {
        guard s.tag >= 0, s.tag < all.count,
              let clip = all[s.tag].audio
        else { return }
        // Клип мог исчезнуть между отрисовкой карточки и кликом (например, из-за retention).
        // Если кнопка уже была на экране, не делаем вид, что клика не было.
        guard VoiceClips.exists(clip) else {
            VoiceIndicator.shared.showToast(L10n.t("hist.saveAudioFailed"))
            return
        }

        // Расшифровываем ТОЛЬКО после того, как человек выбрал место. До этого момента открытых
        // байтов нет даже в памяти; после записи никакого временного файла за нами не остаётся.
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Audio]
        panel.canCreateDirectories = true
        panel.isMovable = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "Keyboop-\(exportDF.string(from: all[s.tag].date)).m4a"

        // Это отдельная системная панель, а не sheet окна истории. Sheet нельзя двигать, и у
        // истории, припаркованной у края экрана, широкая панель неизбежно вылезала за границу.
        // `begin` остаётся асинхронным, но позицию и перемещение целиком отдаёт macOS.
        s.isEnabled = false
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak s] response in
            guard response == .OK, let destination = panel.url else {
                s?.isEnabled = true
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak s] in
                guard let data = VoiceClips.data(for: clip) else {
                    DispatchQueue.main.async {
                        s?.isEnabled = true
                        VoiceIndicator.shared.showToast(L10n.t("hist.saveAudioFailed"))
                    }
                    return
                }
                do {
                    // Временный inode сразу рождается 0600 в ВЫБРАННОЙ папке и затем атомарно
                    // переименовывается. Поэтому даже на миг между write и chmod открытого 0644
                    // файла не бывает; дополнительной plaintext-копии в системном temp тоже нет.
                    try Self.writeExportSecurely(data, to: destination)
                    let sizeKB = data.count / 1024
                    DispatchQueue.main.async { [weak s] in
                        s?.isEnabled = true
                        kbLog("аудио диктовки: экспортировано \(sizeKB) КБ")
                        let folderURL = destination.deletingLastPathComponent()
                        let folderName = FileManager.default.displayName(atPath: folderURL.path)
                        let message = String(format: L10n.t("hist.saveAudioDoneFolder"), folderName)
                        VoiceIndicator.shared.showToast(message, onClick: {
                            // Путь нигде не логируем. Finder получает URL только по явному клику
                            // и выделяет именно экспортированный файл, а не просто открывает папку.
                            NSWorkspace.shared.activateFileViewerSelecting([destination])
                        })
                        let previous = s?.image
                        s?.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
                        s?.contentTintColor = DS.coral
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak s] in
                            s?.image = previous; s?.contentTintColor = .secondaryLabelColor
                        }
                    }
                } catch {
                    let nsError = error as NSError
                    let failure = "\(nsError.domain):\(nsError.code)"
                    DispatchQueue.main.async { [weak s] in
                        s?.isEnabled = true
                        // NSError.userInfo намеренно не пишем: там может быть имя/путь, выбранный человеком.
                        kbLog("аудио диктовки: экспорт не удался (\(failure))")
                        VoiceIndicator.shared.showToast(L10n.t("hist.saveAudioFailed"))
                    }
                }
            }
        }
    }

    /// Атомарная запись без окна с широкими правами: `mkstemp` создаёт соседний файл сразу 0600,
    /// а POSIX rename переносит этот же inode на выбранное имя. Любая ошибка оставляет destination
    /// нетронутым и удаляет только наш скрытый временный файл.
    private static func writeExportSecurely(_ data: Data, to destination: URL) throws {
        let folder = destination.deletingLastPathComponent()
        var template = Array(folder.appendingPathComponent(".keyboop-export.XXXXXX").path.utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let temporaryPath = String(cString: template)
        var descriptorOpen = true
        var moved = false
        defer {
            if descriptorOpen { Darwin.close(fd) }
            if !moved { temporaryPath.withCString { _ = Darwin.unlink($0) } }
        }

        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                guard count > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
                offset += count
            }
        }
        guard Darwin.fsync(fd) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard Darwin.close(fd) == 0 else {
            descriptorOpen = false
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        descriptorOpen = false

        let renamed = temporaryPath.withCString { source in
            destination.path.withCString { target in Darwin.rename(source, target) }
        }
        guard renamed == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        moved = true
    }
    @objc private func deleteEntry(_ s: NSButton) {
        guard s.tag >= 0, s.tag < all.count else { return }
        let e = all[s.tag]
        // Ленту пересобирает `historyChanged` по уведомлению от `remove`. Свой `reload()` здесь
        // собирал бы все нарисованные карточки второй раз подряд, а их теперь может быть сотни.
        VoiceHistory.shared.remove(date: e.date, text: e.text)
    }
    // MARK: импорт аудиофайла (задача 229)

    /// Общие проверки перед импортом: есть куда класть, никто уже не импортирует, есть модель.
    private func canImport() -> Bool {
        guard AppSettings.shared.voiceHistoryEnabled else {
            VoiceIndicator.shared.showToast(L10n.t("hist.importNoHistory")); return false
        }
        guard !AudioImporter.shared.isRunning else {
            VoiceIndicator.shared.showToast(L10n.t("hist.importBusy")); return false
        }
        guard VoiceController.shared.hasUsableModel else { VoiceController.shared.onNeedModel?(); return false }
        return true
    }
    /// Один вход для кнопки и для перетаскивания.
    private func beginImport(url: URL) {
        guard canImport() else { return }
        if AudioImporter.shared.start(url: url) {
            progressCancel.isEnabled = true
            showProgress(AudioImporter.Progress(fileName: url.lastPathComponent, processed: 0, total: 0, remaining: nil))
        }
    }
    @objc private func importAudio() {
        guard canImport() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = L10n.t("hist.importTitle")
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.beginImport(url: url)
        }
    }
    @objc private func cancelImport() {
        AudioImporter.shared.cancel()
        progressCancel.isEnabled = false
    }
    @objc private func importProgressed(_ n: Notification) {
        guard let p = n.object as? AudioImporter.Progress else { return }
        showProgress(p)
    }
    @objc private func importDidFinish(_ n: Notification) {
        showProgress(nil)
        progressCancel.isEnabled = true
        guard let o = n.object as? AudioImporter.Outcome else { return }
        let key: String
        var changed = false
        switch o {
        case .done:         key = "hist.importDone"; changed = true
        case .partial:      key = "hist.importPartial"; changed = true
        case .cancelled:    key = "hist.importCancelled"
        case .empty:        key = "hist.importEmpty"
        case .unreadable:   key = "hist.importFailed"
        case .engineFailed: key = "hist.importEngineFailed"
        }
        VoiceIndicator.shared.showToast(L10n.t(key))
        if changed { reload(); scrollToTop() }
    }
    private func showProgress(_ p: AudioImporter.Progress?) {
        guard let p else {
            progressBox.isHidden = true; progressHeight?.constant = 0
            window?.contentView?.layoutSubtreeIfNeeded(); return
        }
        progressBox.isHidden = false; progressHeight?.constant = 46
        var line = String(format: L10n.t("hist.importProgress"), p.fileName,
                          ImportProgressFormat.clock(p.processed), ImportProgressFormat.clock(p.total))
        if let r = p.remaining { line += " · " + String(format: L10n.t("hist.importEta"), ImportProgressFormat.clock(r)) }
        progressLabel.stringValue = line
        progressBar.doubleValue = p.total > 0 ? min(1, p.processed / p.total) : 0
        window?.contentView?.layoutSubtreeIfNeeded()
    }
    /// Экспорт текста записи в .txt: расшифровка созвона обычно нужна как документ (задача 229).
    @objc private func saveText(_ s: NSButton) {
        guard s.tag >= 0, s.tag < all.count else { return }
        let e = all[s.tag]
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.isMovable = true
        panel.isExtensionHidden = false
        let base = (e.app.map { ($0 as NSString).deletingPathExtension } ?? "Keyboop").replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = "\(base)-\(exportDF.string(from: e.date)).txt"
        s.isEnabled = false
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak s] response in
            guard response == .OK, let destination = panel.url else { s?.isEnabled = true; return }
            do {
                try Self.writeExportSecurely(Data(e.text.utf8), to: destination)
                s?.isEnabled = true
                kbLog("история: текст экспортирован, \(e.text.count) симв.")
                let folderName = FileManager.default.displayName(atPath: destination.deletingLastPathComponent().path)
                VoiceIndicator.shared.showToast(String(format: L10n.t("hist.saveTextDoneFolder"), folderName), onClick: {
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                })
            } catch {
                s?.isEnabled = true
                let nsError = error as NSError
                kbLog("история: экспорт текста не удался (\(nsError.domain):\(nsError.code))")
                VoiceIndicator.shared.showToast(L10n.t("hist.saveTextFailed"))
            }
        }
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
            .init(date: now.addingTimeInterval(-400),  text: "https://keyboop.com/changelog/", kind: .clipboard, app: "Safari"),
            .init(date: now.addingTimeInterval(-900),  text: "Вот прямо сейчас пользуюсь этим голосовым вводом — и знаки препинания расставляются сами, без интернета."),
            .init(date: now.addingTimeInterval(-1500), text: "Встречаемся в четверг в 15:00, ссылку на созвон пришлю утром.", kind: .clipboard, app: "Telegram"),
            .init(date: now.addingTimeInterval(-2000), text: Self.sampleTranscript, kind: .imported, app: "созвон-по-релизу.m4a"),
            .init(date: now.addingTimeInterval(-3600), text: "It's time to test and ship it to the market."),
            .init(date: now.addingTimeInterval(-7200), text: "Короткая заметка на память.")
        ]
        // Длинная лента (срок хранения 7 и 30 дней, 24.09.2026): KEYBOOP_HISTDUMP_PAD=N дописывает
        // N выдуманных диктовок, меряет сборку всей ленты против одной порции и снимает НИЗ ленты,
        // где стоит кнопка «Показать ещё». Настоящую историю не трогает, как и всё выше.
        let pad = Int(ProcessInfo.processInfo.environment["KEYBOOP_HISTDUMP_PAD"] ?? "") ?? 0
        for i in 0..<pad {
            all.append(.init(date: now.addingTimeInterval(-7200 - Double(i + 1) * 900),
                             text: "Выдуманная диктовка номер \(i + 1) для проверки длинной ленты."))
        }
        filtered = all; lastCount = all.count
        defer { demoClip.map { VoiceClips.delete($0.id) } }   // демо-файл не переживает снимок
        if pad > 0 {
            func timed(_ limit: Int) -> Int {
                shownLimit = limit
                let t0 = ProcessInfo.processInfo.systemUptime
                rebuildCards(); window?.contentView?.layoutSubtreeIfNeeded()
                return Int((ProcessInfo.processInfo.systemUptime - t0) * 1000)
            }
            let full = timed(Int.max)
            let series = [150, 150, 50, 50, 25, 25, Self.pageSize, Self.pageSize].map { "\($0):\(timed($0))" }
            let more = listStack.arrangedSubviews.last.map { !($0 is HoverCard) } ?? false
            kbLog("histdump: лента \(filtered.count) записей · вся за \(full) мс · порции (карточек:мс) \(series.joined(separator: " ")) · кнопка «ещё»=\(more)")
        }
        // Строка прогресса импорта на снимке: иначе её единственный способ увидеть — ждать файл.
        showProgress(AudioImporter.Progress(fileName: "созвон-по-релизу.m4a", processed: 1503, total: 4920, remaining: 380))
        // ⚗️ Три кандидата разом, чтобы сравнивать глазами рядом, а не по памяти (14.09.2026).
        for b in DockPresence.Badge.allCases {
            DockPresence.writeHistoryIconPNG(to: "/tmp/kb_dock_\(b.rawValue).png", badge: b)
        }
        rebuildCards()
        window?.contentView?.layoutSubtreeIfNeeded()
        listStack.arrangedSubviews.compactMap { $0 as? HoverCard }.forEach { $0.revealForDump() }
        window?.contentView?.layoutSubtreeIfNeeded()
        if pad > 0, let doc = scroll.documentView {       // к концу ленты: там кнопка «ещё»
            doc.scroll(NSPoint(x: 0, y: max(0, doc.bounds.height - scroll.contentView.bounds.height)))
        }
        dump(to: path)
    }
}

extension VoiceHistoryWindowController {
    /// Демо-расшифровка для снимка: длиннее порога сворачивания, с абзацами по паузам.
    static let sampleTranscript = """
        Давайте по порядку. Первое, что мы обсуждали на прошлой неделе, это выпуск беты и то, как \
        люди на неё реагируют. Отзывов пришло больше, чем обычно, и большинство про диктовку.

        По истории буфера обмена вопросов нет, всё работает, но тумблер надо перенести из голосового \
        набора, потому что буфер к голосу не имеет никакого отношения. Пусть живёт в общих настройках, \
        по крайней мере пока.

        Дальше импорт аудиофайла. Я записывал рабочий звонок на час двадцать, и надо сразу \
        предусмотреть, что туда будут грузить большие длинные файлы. Текст такого размера в истории \
        должен быть свёрнут, а экспорт в документ тоже придётся предусмотреть, потому что искать в \
        карточке час разговора никто не будет.

        И последнее: про Windows пока ничего не обещаем, спрос фиксируем, но версию не начинаем. \
        На этом всё, спасибо, до связи.
        """
}

// MARK: - Приём аудиофайла перетаскиванием (задача 229)

/// Контейнер окна истории принимает перетащенный аудио- или видеофайл в любом месте окна.
protocol AudioDropHost: AnyObject {
    var onDrop: ((URL) -> Void)? { get set }
}

enum AudioDrop {
    /// Единственный подходящий файл из перетаскивания, иначе nil: пачку файлов не берём, потому что
    /// импорт идёт по одному и очереди у него нет.
    static func url(from info: NSDraggingInfo) -> URL? {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard urls.count == 1, let u = urls.first,
              let type = UTType(filenameExtension: u.pathExtension) else { return nil }
        return (type.conforms(to: .audio) || type.conforms(to: .movie) || type.conforms(to: .audiovisualContent)) ? u : nil
    }
    /// Рамка на время перетаскивания: словом «можно бросать» здесь не скажешь, но рамка в цвете
    /// действия плюс курсор копирования читаются одинаково всеми.
    static func highlight(_ v: NSView, _ on: Bool) {
        v.wantsLayer = true
        v.layer?.borderColor = on ? DS.coral.cgColor : nil
        v.layer?.borderWidth = on ? 2 : 0
        v.layer?.cornerRadius = on ? 10 : 0
    }
}

final class AudioDropEffectView: NSVisualEffectView, AudioDropHost {
    var onDrop: ((URL) -> Void)?
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { super.init(coder: coder); registerForDraggedTypes([.fileURL]) }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard AudioDrop.url(from: sender) != nil else { return [] }
        AudioDrop.highlight(self, true); return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { AudioDrop.highlight(self, false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { AudioDrop.highlight(self, false) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        AudioDrop.highlight(self, false)
        guard let u = AudioDrop.url(from: sender) else { return false }
        onDrop?(u); return true
    }
}

final class AudioDropPlainView: NSView, AudioDropHost {
    var onDrop: ((URL) -> Void)?
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { super.init(coder: coder); registerForDraggedTypes([.fileURL]) }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard AudioDrop.url(from: sender) != nil else { return [] }
        AudioDrop.highlight(self, true); return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { AudioDrop.highlight(self, false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { AudioDrop.highlight(self, false) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        AudioDrop.highlight(self, false)
        guard let u = AudioDrop.url(from: sender) else { return false }
        onDrop?(u); return true
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

/// Карточка истории: дата слева, действия (сохранить аудио / копировать / удалить) справа — скрыты,
/// пока курсор не наведён (поэтому НИКОГДА не наезжают на дату). Тело — выделяемый переносимый текст.
final class HoverCard: NSView {
    private let actions: NSStackView

    init(date: NSTextField, kind: NSView? = nil, body: NSView, actions buttons: [NSButton]) {
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
        let header = NSStackView(views: [date] + (kind.map { [$0] } ?? []) + [spacer, self.actions])
        header.orientation = .horizontal; header.spacing = 6; header.alignment = .centerY
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
