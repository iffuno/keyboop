import AppKit

/// Иконка в статус-баре рядом с часами + меню.
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let layout: LayoutManager
    private let settings = AppSettings.shared
    private var pollTimer: Timer?

    var onOpenSettings: (() -> Void)?
    var onShowVoiceHistory: (() -> Void)?
    var onToggleAuto: ((Bool) -> Void)?
    var onCheckUpdates: (() -> Void)?
    var onQuit: (() -> Void)?
    var needsPermission = false
    private var voiceState: VoiceController.State = .idle

    init(layout: LayoutManager) {
        self.layout = layout
        super.init()
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
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Keyboop")
            button.imagePosition = .imageLeading
            updateTitle()
        }
    }

    private func updateTitle() {
        if voiceState != .idle { return }   // во время диктовки иконку держит voice-индикатор
        statusItem.button?.title = needsPermission ? " ⚠︎" : " \(layout.currentCode())"
    }

    /// Индикатор диктовки в статус-баре: запись / распознавание / покой.
    func setVoiceState(_ s: VoiceController.State) {
        voiceState = s
        guard let button = statusItem.button else { return }
        switch s {
        case .idle:
            button.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Keyboop")
            updateTitle()
        case .recording:
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Запись")
            button.title = " ●"
        case .processing:
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Распознаю")
            button.title = " …"
        }
    }

    private func buildMenu() {
        let menu = NSMenu()

        let header = NSMenuItem(title: L10n.t("menu.header"), action: nil, keyEquivalent: "")
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

        let hot = NSMenuItem(title: L10n.t("menu.switchWord"), action: nil, keyEquivalent: "")
        hot.isEnabled = false
        menu.addItem(hot)

        menu.addItem(.separator())

        // Быстрый доступ (в духе OpenSuperWhisper): язык распознавания + микрофон.
        menu.addItem(languageSubmenu())
        menu.addItem(microphoneSubmenu())

        let vh = NSMenuItem(title: L10n.t("menu.voiceHistory"), action: #selector(showVoiceHistory), keyEquivalent: "")
        vh.target = self
        menu.addItem(vh)

        menu.addItem(.separator())

        // Проверить обновления вручную (помимо фоновой проверки) — перед настройками.
        let upd = NSMenuItem(title: L10n.t("menu.checkUpdates"), action: #selector(checkUpdatesItem), keyEquivalent: "")
        upd.target = self
        menu.addItem(upd)

        // Настройки — предпоследним, Выйти — последним.
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
