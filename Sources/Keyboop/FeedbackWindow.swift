import AppKit
import AVFoundation

/// Окно «Написать разработчику»: текст + опциональный контакт + диагностика с превью.
/// Принцип ask+show+send: диагностику можно ПОСМОТРЕТЬ до отправки, галочку — снять.
/// Отправка на keyboop.com/api/feedback (автору мгновенно прилетает алерт в Telegram);
/// без сети — честный фолбэк на почту. Родилось из боли: репорты приходили пересказом
/// («всплывашка зависла») без версии и лога — каждый баг начинался с пинг-понга.
final class FeedbackWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    static let shared = FeedbackWindowController()

    private let textScroll = NSScrollView()
    private let textView = NSTextView()
    private let placeholder = NSTextField(labelWithString: "")
    private let contact = NSTextField()
    private let diagCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let sendBtn = NSButton()
    private let mailBtn = NSButton()

    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 0),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = L10n.t("fb.title")
        self.init(window: w)
        w.delegate = self
        build()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
    }

    private func build() {
        guard let w = window else { return }

        textView.font = .systemFont(ofSize: 13)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.delegate = self
        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.borderType = .bezelBorder
        textScroll.translatesAutoresizingMaskIntoConstraints = false
        textScroll.heightAnchor.constraint(equalToConstant: 150).isActive = true

        placeholder.stringValue = L10n.t("fb.placeholder")
        placeholder.textColor = .placeholderTextColor
        placeholder.font = .systemFont(ofSize: 13)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        textView.addSubview(placeholder)
        placeholder.topAnchor.constraint(equalTo: textView.topAnchor, constant: 8).isActive = true
        placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 11).isActive = true

        contact.placeholderString = L10n.t("fb.contact")
        contact.font = .systemFont(ofSize: 13)
        // Подпись под полем: объясняет, ЗАЧЕМ оставлять контакт. Без неё поле выглядит как
        // необязательная формальность, и люди его пропускают — а ответить потом некуда.
        let contactWhy = NSTextField(wrappingLabelWithString: L10n.t("fb.contactWhy"))
        contactWhy.font = .systemFont(ofSize: 11)
        contactWhy.textColor = .tertiaryLabelColor

        diagCheck.title = L10n.t("fb.diag")
        diagCheck.state = .on
        diagCheck.font = .systemFont(ofSize: 12)
        let diagShow = NSButton(title: L10n.t("fb.diagShow"), target: self, action: #selector(showDiag))
        diagShow.bezelStyle = .inline
        diagShow.controlSize = .small
        diagShow.font = .systemFont(ofSize: 11)
        let diagRow = NSStackView(views: [diagCheck, diagShow])
        diagRow.orientation = .horizontal
        diagRow.spacing = 8
        diagRow.alignment = .firstBaseline

        let intro = NSTextField(wrappingLabelWithString: L10n.t("about.fbBody"))
        intro.font = .systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor

        let hint = NSTextField(wrappingLabelWithString: L10n.t("fb.hint"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor

        sendBtn.title = L10n.t("fb.send")
        sendBtn.bezelStyle = .rounded
        sendBtn.keyEquivalent = "\r"
        sendBtn.target = self
        sendBtn.action = #selector(send)
        mailBtn.title = L10n.t("fb.mail")
        mailBtn.bezelStyle = .rounded
        mailBtn.target = self
        mailBtn.action = #selector(sendMail)
        mailBtn.isHidden = true
        let btnRow = NSStackView(views: [status, NSView(), mailBtn, sendBtn])
        btnRow.orientation = .horizontal
        btnRow.spacing = 10

        // AppKit-канон: вертикальный stack с alignment .leading + width-pin для wrapping-строк.
        let stack = NSStackView(views: [intro, textScroll, contact, contactWhy, diagRow, hint, btnRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 480),
        ])
        for v in [intro, textScroll, contact, contactWhy, diagRow, hint, btnRow] {
            (v as NSView).widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        w.contentView = content
        w.setContentSize(content.fittingSize)
    }

    func textDidChange(_ notification: Notification) {
        placeholder.isHidden = !textView.string.isEmpty
    }

    // MARK: - Диагностика

    /// Снимок окружения для багрепорта. Принцип №2 соблюдён по построению: лог и так без
    /// текста ввода/речи (только счётчики и статусы), настройки — булевы флаги и имена движков.
    static func buildDiagnostics() -> String {
        let b = Bundle.main
        let ver = (b.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        let stamp = (b.infoDictionary?["KeyboopBuildStamp"] as? String) ?? "?"
        var model = "?"
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        if size > 0 {
            var buf = [CChar](repeating: 0, count: size)
            sysctlbyname("hw.model", &buf, &size, nil, 0)
            model = String(cString: buf)
        }
        let s = AppSettings.shared
        let micName: String = {
            guard !s.voiceMicUID.isEmpty else { return "системный по умолчанию" }
            return AVCaptureDevice(uniqueID: s.voiceMicUID)?.localizedName ?? "(закреплён, но недоступен)"
        }()
        #if arch(arm64) && !KEYBOOP_NO_PARAKEET
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        var out = """
        Keyboop \(ver) [\(stamp)] · интерфейс \(L10n.current == .ru ? "ru" : "en")
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · \(model) · \(arch)
        движок: \(s.voiceEngine) · parakeet установлен=\(ParakeetEngine.modelInstalled) · whisper-модель=\(s.voiceModel)
        микрофон: \(micName)
        авто-переключение=\(s.autoEnabled) · live-fix=\(s.liveFixEnabled) · триггеры: space=\(s.triggerSpace) enter=\(s.triggerEnter) tab=\(s.triggerTab)

        --- лог, последние 60 строк (без текста ввода и речи) ---
        """
        if let log = try? String(contentsOfFile: kbLogPath, encoding: .utf8) {
            out += "\n" + log.split(separator: "\n").suffix(60).joined(separator: "\n")
        } else {
            out += "\n(лог пуст или недоступен)"
        }
        return out
    }

    @objc private func showDiag() {
        let a = NSAlert()
        a.messageText = L10n.t("fb.diagTitle")
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 320))
        tv.string = Self.buildDiagnostics()
        tv.isEditable = false
        tv.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        let sc = NSScrollView(frame: tv.frame)
        sc.documentView = tv
        sc.hasVerticalScroller = true
        sc.borderType = .bezelBorder
        a.accessoryView = sc
        a.addButton(withTitle: "OK")
        if let w = window { a.beginSheetModal(for: w) } else { a.runModal() }
    }

    // MARK: - Отправка

    @objc private func send() {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3 else { status.stringValue = L10n.t("fb.tooShort"); return }
        sendBtn.isEnabled = false
        status.textColor = .secondaryLabelColor
        status.stringValue = L10n.t("fb.sending")
        let ver = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        var body: [String: Any] = ["text": text, "version": ver, "kind": "feedback"]
        let c = contact.stringValue.trimmingCharacters(in: .whitespaces)
        if !c.isEmpty { body["contact"] = c }
        if diagCheck.state == .on { body["diag"] = Self.buildDiagnostics() }

        var req = URLRequest(url: URL(string: "https://keyboop.com/api/feedback")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { [weak self] _, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { self?.sendFinished(ok) }
        }.resume()
    }

    private func sendFinished(_ ok: Bool) {
        sendBtn.isEnabled = true
        if ok {
            status.textColor = .systemGreen
            status.stringValue = L10n.t("fb.sent")
            kbLog("feedback: отправлен (длина только — принцип №2)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
                self?.textView.string = ""
                self?.placeholder.isHidden = false
                self?.status.stringValue = ""
                self?.mailBtn.isHidden = true
                self?.window?.close()
            }
        } else {
            status.textColor = .systemOrange
            status.stringValue = L10n.t("fb.fail")
            mailBtn.isHidden = false
            kbLog("feedback: сеть не ответила — предложен фолбэк почтой")
        }
    }

    @objc private func sendMail() { Permissions.openFeedbackMail() }
}
