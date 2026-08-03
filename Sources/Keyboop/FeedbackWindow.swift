import AppKit
import AVFoundation

/// Подпись-плейсхолдер, ПРОЗРАЧНАЯ для мыши.
///
/// Репорты #12 и #26 (25-27.07): «если фокус поля меняется, мышкой не получается сфокусировать его
/// обратно», «нельзя вернуть в поле с описанием проблемы, если переключился на ввод почты». Причина:
/// плейсхолдер — это NSTextField, лежащий ПОВЕРХ NSTextView в его левом верхнем углу, то есть ровно
/// там, куда человек целится мышью. Label не может стать первым откликающимся, но клик всё равно
/// съедает, и до текстового поля событие не доходит. hitTest = nil пропускает клики насквозь.
private final class ClickThroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Окно «Написать разработчику»: текст + опциональный контакт + диагностика с превью.
/// Принцип ask+show+send: диагностику можно ПОСМОТРЕТЬ до отправки, галочку — снять.
/// Отправка на keyboop.com/api/feedback (автору мгновенно прилетает алерт в Telegram);
/// без сети — честный фолбэк на почту. Родилось из боли: репорты приходили пересказом
/// («всплывашка зависла») без версии и лога — каждый баг начинался с пинг-понга.
final class FeedbackWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    static let shared = FeedbackWindowController()

    private let textScroll = NSScrollView()
    private let textView = NSTextView()
    private let placeholder = ClickThroughLabel(labelWithString: "")
    private let contact = NSTextField()
    private let diagCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let sendBtn = NSButton()
    private let tgBtn = NSButton()
    private let mailBtn = NSButton()
    /// Экран формы и экран «отправлено» — меняем целиком, а не подписью у кнопки (см. showDone).
    private var formContent: NSView?
    private let doneText = NSTextField(wrappingLabelWithString: "")
    /// Ушёл ли контакт в отправленном письме (не «лежит ли он в поле сейчас» — см. send()).
    private var sentWithContact = false

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
        showForm()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
        // ДИАГНОСТИКА ГЕОМЕТРИИ (30.07). Жалоба «не видно текст» живёт с 25.07 и пережила уже одну
        // «починку», потому что чинили вслепую. Если она вернётся, следующий отчёт должен принести
        // ответ с собой: размеры вью и его текстового контейнера в момент открытия окна. Нулевая или
        // крошечная высота здесь = диагноз, без переписки и догадок.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let f = self.textView.frame, c = self.textView.textContainer?.containerSize ?? .zero
            kbLog(String(format: "feedback: поле %.0f×%.0f, контейнер %.0f×%.0f, скролл %.0f×%.0f",
                         f.width, f.height, c.width, c.height,
                         self.textScroll.frame.width, self.textScroll.frame.height))
        }
    }

    private func build() {
        guard let w = window else { return }

        textView.font = .systemFont(ofSize: 13)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.delegate = self
        // ⚠️ ЧЕТЫРЕ репорта об одном (#12, #20, #25, #26, 25-27.07): «не видно текст, который
        // печатаешь». Задаём цвета ЯВНО, чтобы они не зависели от того, что унаследует поле.
        //
        // Осторожно с оттенком (проверено замером живого AppKit в ревью 28.07): у свежего NSTextView
        // textColor уже равен системному `.textColor` с alpha 1.0, а `.labelColor` — это alpha 0.847.
        // То есть попытка «сделать текст виднее» через .labelColor делает его на 15% БЛЕДНЕЕ. Берём
        // .textColor. Фон и drawsBackground не трогаем вовсе: дефолты и так ровно такие.
        //
        // ⚠️ И ГЛАВНОЕ: настоящая причина жалоб этим НЕ доказана. Строки ниже — страховка, а не
        // диагноз. Пока причина не найдена (кандидаты: залипший локальный монитор рекордера,
        // глотавший клавиши в наших окнах, и наш собственный тап, работающий по своим же окнам),
        // в changelog писать «починили невидимый текст» НЕЛЬЗЯ.
        textView.textColor = .textColor
        textView.insertionPointColor = .textColor

        // ⚠️ ПРОВЕРЕННАЯ И ОТВЕРГНУТАЯ ГИПОТЕЗА (28.07). Кандидатом на «не видно текст» была
        // недонастройка NSTextView внутри NSScrollView: здесь нет ни minSize/maxSize, ни
        // isVerticallyResizable, ни widthTracksTextView, а голый `NSTextView()` создаётся без
        // фрейма. Звучит как учебниковый случай «глифам негде разместиться».
        // Собран стенд с ЭТОЙ ЖЕ конструкцией (Auto Layout, скролл получает размер позже, ввод
        // посимвольно через insertText): и с канонной настройкой, и без неё результат идентичен —
        // контейнер 426 пунктов, все 300 глифов размещены, перенос на 6 строк. Назначение
        // documentView само доводит вью до ума. Не тратить время на этот путь повторно.
        // ⚠️ ГЕОМЕТРИЯ ПОЛЯ — КАНОНИЧЕСКАЯ НАСТРОЙКА NSTextView В NSScrollView (30.07).
        //
        // Ревью 28.07 эту гипотезу проверяло и отвергло: на стенде глифы размещались, и вывод был
        // «documentView сам доводит вью до ума». Возвращаюсь к ней из-за НОВОЙ улики от автора,
        // которой у того разбора не было: «перешёл в поле контакта и обратно вернуться уже нельзя».
        // Мышь — это hit-test, а hit-test — это ФРЕЙМ. В вырожденный по высоте вью попасть нельзя,
        // и это ровно то, что человек описывает. При открытии окна фокус ставится программно
        // (makeFirstResponder), там фрейм не нужен, поэтому первый вход работает, а возврат нет.
        //
        // Та же причина объясняет и первый симптом, четыре репорта подряд (#12, #20, #25, #26):
        // «каретка двигается, текста не видно». Размещённые глифы рисуются за границей видимой
        // области, а каретка видна, потому что её рисуют в начале координат. Цвета тут ни при чём,
        // их выставили явно ещё в июле, и не помогло — потому что лечили не то.
        textView.frame = NSRect(x: 0, y: 0, width: 468, height: 150)
        textView.minSize = NSSize(width: 0, height: 150)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 468, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

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
        // Второй канал: файл + бот. Не замена форме, а выбор — см. sendViaTelegram().
        tgBtn.title = L10n.t("fb.tg")
        tgBtn.bezelStyle = .rounded
        tgBtn.target = self
        tgBtn.action = #selector(sendViaTelegram)
        tgBtn.toolTip = L10n.t("fb.tgTip")
        let btnRow = NSStackView(views: [status, NSView(), mailBtn, tgBtn, sendBtn])
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
        formContent = content
        w.contentView = content
        w.setContentSize(content.fittingSize)
    }

    /// Экран «отправлено».
    ///
    /// ⚠️ ПЯТЬ репортов «непонятно, ушло или нет». Раньше подтверждением была зелёная строчка слева
    /// от кнопки, которая жила 1.1 секунды, после чего окно закрывалось само. Человек в этот момент
    /// смотрит на кнопку «Отправить», а не на мелкий текст сбоку; окно исчезает, следов не остаётся —
    /// и внешне это неотличимо от «нажал, всё пропало, наверное не отправилось». Отсюда и дубли
    /// репортов: люди присылали одно и то же по два-три раза.
    /// Поэтому подтверждение теперь ОТДЕЛЬНЫЙ экран, и закрывает его человек, а не таймер.
    /// Заодно честно говорим, что без контакта ответить некуда: это тот же довод, что и в подписи
    /// под полем, но здесь он приходит в момент, когда человек уже написал и ждёт ответа.
    private func makeDoneContent() -> NSView {
        let title = NSTextField(labelWithString: L10n.t("fb.doneTitle"))
        title.font = .systemFont(ofSize: 17, weight: .semibold)

        doneText.font = .systemFont(ofSize: 13)
        doneText.textColor = .secondaryLabelColor

        let close = NSButton(title: L10n.t("fb.doneClose"), target: self, action: #selector(closeDone))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\r"

        let btnRow = NSStackView(views: [NSView(), close])
        btnRow.orientation = .horizontal

        let stack = NSStackView(views: [title, doneText, btnRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 26, left: 20, bottom: 18, right: 20)
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
        for v in [doneText, btnRow] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        return content
    }

    private func showDone(hasContact: Bool) {
        guard let w = window else { return }
        doneText.stringValue = L10n.t(hasContact ? "fb.doneWithContact" : "fb.doneNoContact")
        let done = makeDoneContent()
        w.contentView = done
        w.setContentSize(done.fittingSize)
        w.makeFirstResponder(nil)
    }

    /// Вернуть форму в исходное состояние: окно одно на всё приложение, открывают его повторно.
    ///
    /// ⚠️ Чистим ТОЛЬКО когда возвращаемся с экрана «отправлено». Если форма уже на экране, значит в
    /// ней может лежать недописанный отзыв, и трогать его нельзя: у нас нет иконки в доке, поднять
    /// ушедшее за чужие окна окно можно ИСКЛЮЧИТЕЛЬНО пунктом меню и кнопкой в настройках, а оба
    /// зовут show(). То есть безусловная чистка означала бы: человек написал десять строк, полез в
    /// другую программу за версией системы, вернулся через меню — и текста нет, отменить нельзя
    /// (программная замена .string не пишется в undo). Найдено ревью 28.07.
    private func showForm() {
        guard let w = window, let form = formContent else { return }
        guard w.contentView !== form else { return }
        textView.string = ""
        placeholder.isHidden = false
        status.stringValue = ""
        // Контакт НЕ чистим: кто написал раз, часто пишет и второй, а перенабирать его каждый раз
        // — ровно тот мелкий труд, из-за которого поле и оставляют пустым.
        mailBtn.isHidden = true
        sendBtn.isEnabled = true
        w.contentView = form
        w.setContentSize(form.fittingSize)
    }

    @objc private func closeDone() { window?.close() }

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
        // ⚠️ ДОСТУПЫ И СОСТОЯНИЕ — В ШАПКЕ, А НЕ В ХВОСТЕ ЛОГА (разбор 28.07). Раньше AX/InputMon
        // писались только строкой `launched` при старте, а в багрепорт попадали последние 60 строк —
        // у человека, который пользуется приложением неделю, эта строка давно вымылась. То есть
        // ровно то, что объясняет половину репортов «не работает», мы систематически НЕ видели.
        let health = AppHealth.blockingProblem ?? "работает"
        // ⚠️ НАСТРОЙКИ ХОТКЕЕВ обязательны: без них весь класс «приложение блокирует пробел»
        // (репорты #13/#22/#30) по репорту принципиально неразрешим — мы не знаем, что человек
        // назначил. Это ЗНАЧЕНИЯ настроек, не пользовательский текст: принцип №2 не затронут.
        let hk = """
        хоткеи: конверсия=\(s.hotkeyMode)/\(s.hotkeyKeyCode)/\(s.hotkeyModifiers) · \
        диктовка=\(s.voiceHotkeyMode)/\(s.voiceHotkeyKeyCode)/\(s.voiceHotkeyModifiers) (hold=\(s.voiceHoldMode)) · \
        перевод=\(s.translateHotkeyKeyCode)/\(s.translateHotkeyModifiers) · \
        мгновенное=\(s.instantSwitchEnabled ? s.instantSwitchMode : "выкл")/\(s.instantSwitchKeyCode)/\(s.instantSwitchMods)
        """
        // Список ВКЛЮЧЁННЫХ раскладок: прямая улика для «переключает только в одну сторону»
        // (баг с поиском латиницы по языковому тегу). Только названия, ничего пользовательского.
        let layouts = LayoutManager.enabledLayoutNamesForDiagnostics().joined(separator: ", ")
        var out = """
        Keyboop \(ver) [\(stamp)] · интерфейс \(L10n.current == .ru ? "ru" : "en") · работает \(AppHealth.uptimeDescription)
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · \(model) · \(arch)
        состояние: \(health)
        доступы: Accessibility=\(Permissions.isTrusted()) · InputMonitoring=\(Permissions.inputMonitoringGranted()) · движок запущен=\(AppHealth.engineRunning) · secure input сейчас=\(AppHealth.secureInputOn)
        запущено из: \(Permissions.launchLocationForDiagnostics())
        раскладки: \(layouts.isEmpty ? "—" : layouts)
        движок: \(s.voiceEngine) · parakeet установлен=\(ParakeetEngine.modelInstalled) · whisper-модель=\(s.voiceModel)
        микрофон: \(micName)
        авто-переключение=\(s.autoEnabled) · live-fix=\(s.liveFixEnabled) · триггеры: space=\(s.triggerSpace) enter=\(s.triggerEnter) tab=\(s.triggerTab)
        \(hk)

        --- лог, последние 300 строк (без текста ввода и речи) ---
        """
        if let log = try? String(contentsOfFile: kbLogPath, encoding: .utf8) {
            out += "\n" + log.split(separator: "\n").suffix(300).joined(separator: "\n")
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
        // Запоминаем, УШЁЛ ли контакт, а не что лежит в поле сейчас: между отправкой и ответом до
        // 15 секунд, поле всё это время редактируемо. Дописал почту, пока крутилось «отправляю» —
        // и экран «Улетело» обещал бы ответ, которого не будет: в базу контакт не попал.
        sentWithContact = !c.isEmpty
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
            kbLog("feedback: отправлен (длина только — принцип №2)")
            showDone(hasContact: sentWithContact)
        } else {
            status.textColor = .systemOrange
            status.stringValue = L10n.t("fb.fail")
            mailBtn.isHidden = false
            kbLog("feedback: сеть не ответила — предложен фолбэк почтой")
        }
    }

    @objc private func sendMail() { Permissions.openFeedbackMail() }

    /// DEV-ХУК (`KEYBOOP_FBDUMP=1`): напечатать в поле образец и отрисовать сам блок ввода в PNG.
    ///
    /// Зачем понадобился инструмент. Жалоба «печатаю и не вижу текста» пришла ЧЕТЫРЕ раза
    /// (#12, #20, #25, #26) и живёт до сих пор — репорт #53 пришёл уже с 0.3.2, буквально «ФЫФЫВФЫВ»
    /// от человека, печатавшего вслепую. Её дважды чинили вслепую: сперва явными цветами, потом
    /// прозрачным для мыши плейсхолдером. Обе правки разумны, обе не помогли, потому что причину
    /// никто не ВИДЕЛ. Рендерим ровно то, на что смотрит пользователь.
    ///
    /// Снимаем `textScroll`, а не окно целиком: `cacheDisplay` по окну отдаёт белый лист
    /// (проверено на WINSHOT), а по вложенному вью работает — на этом же держится дамп настроек.
    func dumpFieldForDev(to path: String) {
        // ⚠️ ОБРАЗЕЦ БЕЗ \n — И ЭТО ГЛАВНОЕ (31.07). Прежний образец содержал явный перенос строки,
        // поэтому дамп показывал две аккуратные строки и «всё в порядке» даже тогда, когда настоящий
        // перенос по ширине сломан. Репорт #60 («уезжает вправо, переносится символов через 30»)
        // этой проверкой поймать было НЕЛЬЗЯ. Проверка, которая не воспроизводит дефект, хуже
        // отсутствия проверки: она даёт ложное спокойствие. Длинная строка без переносов — то
        // единственное, что здесь имеет смысл рисовать.
        let sample = "Проверка видимости и переноса: ЖЖЫ ghbdtn 123. "
            + String(repeating: "Длинная строка без единого переноса, которая обязана свернуться по ширине поля. ", count: 3)
        // ⚠️ ПЕЧАТАЕМ ПОСИМВОЛЬНО, а не присваиваем строку (31.07). Присваивание `textView.string = …`
        // проходит совсем другой путь, чем набор с клавиатуры: разом, при уже скрытом плейсхолдере,
        // без промежуточных layout-проходов. Именно поэтому дамп с присваиванием рисовал идеальный
        // перенос в тот самый день, когда пришёл репорт #60 о сломанном переносе при НАБОРЕ.
        textView.string = ""
        for ch in sample {
            textView.insertText(String(ch), replacementRange: textView.selectedRange())
            textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        }
        textScroll.layoutSubtreeIfNeeded()
        textView.layoutSubtreeIfNeeded()
        let b = textScroll.bounds
        kbLog(String(format: "FBDUMP: скролл %.0f×%.0f, поле %.0f×%.0f, текст %d симв.",
                     b.width, b.height, textView.frame.width, textView.frame.height,
                     textView.string.count))
        guard b.width > 1, b.height > 1, let rep = textScroll.bitmapImageRepForCachingDisplay(in: b) else {
            kbLog("FBDUMP: нечего рисовать"); return
        }
        textScroll.cacheDisplay(in: b, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            kbLog("FBDUMP: записан \(path)")
        }
    }

    /// Второй способ отправки: ФАЙЛОМ через @keyboop_bot (просьба автора 30.07). Форма остаётся,
    /// это выбор, а не замена.
    ///
    /// Зачем вообще: форма отправляет отчёт сама, и человеку приходится верить нам на слово, что
    /// именно ушло. Здесь всё наоборот — мы кладём файл, человек его открывает, читает и отправляет
    /// сам. Ничего не уходит без его действия, и видно ровно то, что уходит.
    ///
    /// ⚠️ Почему файлом, а не сообщением. Диагностика — это 300+ строк. В сообщение Telegram влезает
    /// 4096 символов, а в deep-link `t.me/bot?start=…` вообще 64. То есть «нажал и лог улетел» здесь
    /// технически невозможно ни в каком виде: лог передаётся только вложением.
    @objc private func sendViaTelegram() {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3 else { status.stringValue = L10n.t("fb.tooShort"); return }
        let ver = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        var parts = ["Keyboop \(ver)", "", text]
        let c = contact.stringValue.trimmingCharacters(in: .whitespaces)
        if !c.isEmpty { parts += ["", "Контакт: \(c)"] }
        if diagCheck.state == .on { parts += ["", "--- диагностика ---", Self.buildDiagnostics()] }

        // Имя файла со временем: человек отправляет несколько отчётов подряд, и одинаковые имена в
        // «Загрузках» превращаются в «Keyboop-отчёт 2», по которому потом не понять, какой из них какой.
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HHmm"
        let name = "Keyboop-\(ver)-\(fmt.string(from: Date())).txt"
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent(name)
        do {
            try parts.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            status.textColor = .systemOrange
            status.stringValue = L10n.t("fb.tgFileFail")
            kbLog("feedback: файл для Telegram не записался: \(error)")
            return
        }
        // ⚠️ СНАЧАЛА ОБЪЯСНЯЕМ, ПОТОМ ОТКРЫВАЕМ (замечание автора 30.07). Первая версия молча
        // распахивала Finder и чат: человек оставался с двумя чужими окнами и без понимания, что
        // от него хотят. Показываем ровно три шага и НАЗЫВАЕМ ИМЯ ФАЙЛА — в «Загрузках» у людей
        // сотни файлов, «тот, что мы только что положили» там не находится.
        let alert = NSAlert()
        alert.messageText = L10n.t("fb.tgHowTitle")
        alert.informativeText = String(format: L10n.t("fb.tgHowBody"), name)
        alert.addButton(withTitle: L10n.t("fb.tgHowGo"))
        alert.addButton(withTitle: L10n.t("fb.tgHowCancel"))
        guard alert.runModal() == .alertFirstButtonReturn else {
            // Отказался — файл всё равно оставляем: он уже сохранён и может пригодиться, а молча
            // удалять то, что человек, возможно, пошёл смотреть, невежливо.
            status.stringValue = L10n.t("fb.tgSaved")
            return
        }
        // Показать в Finder И открыть чат: без первого человек не найдёт файл, без второго не поймёт,
        // куда его нести. Порядок такой, чтобы поверх остался Telegram, а Finder ждал под ним.
        NSWorkspace.shared.activateFileViewerSelecting([url])
        // `?start=report` — метка для бота: по ней он встречает человека инструкцией про файл, а не
        // обычной подпиской на обновления (см. TG_REPORT_WELCOME на сервере).
        if let tg = URL(string: "https://t.me/keyboop_bot?start=report") { NSWorkspace.shared.open(tg) }
        status.textColor = .secondaryLabelColor
        status.stringValue = L10n.t("fb.tgReady")
        kbLog("feedback: отчёт сохранён файлом для отправки ботом (длина только — принцип №2)")
    }
}
