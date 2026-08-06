import AppKit
import CoreGraphics

/// Человекочитаемая запись текущего хоткея.
func hotkeyDisplayString() -> String {
    let s = AppSettings.shared
    if s.hotkeyMode == "doubletap" {
        let mods = CGEventFlags(rawValue: s.hotkeyModifiers)
        if mods.contains(.maskShift) { return "2× ⇧" }
        if mods.contains(.maskCommand) { return "2× ⌘" }
        if mods.contains(.maskAlternate) { return "2× ⌥" }
        return L10n.t("hk.dblMod")
    }
    if s.hotkeyMode == "modkey" {
        switch s.hotkeyKeyCode {
        case 61: return L10n.t("hk.rOpt")
        case 58: return L10n.t("hk.lOpt")
        case 54: return L10n.t("hk.rCmd")
        case 55: return L10n.t("hk.lCmd")
        case 60: return L10n.t("hk.rShift")
        case 62: return L10n.t("hk.rCtrl")
        default: return L10n.t("hk.key")
        }
    }
    let mods = CGEventFlags(rawValue: s.hotkeyModifiers)
    var out = ""
    if mods.contains(.maskControl) { out += "⌃" }
    if mods.contains(.maskAlternate) { out += "⌥" }
    if mods.contains(.maskShift) { out += "⇧" }
    if mods.contains(.maskCommand) { out += "⌘" }
    if s.hotkeyMode == "key", s.hotkeyKeyCode >= 0 {
        let ks = KeyLabels.symbol(forKeyCode: s.hotkeyKeyCode)   // подпись по keyCode (стабильно: `` ` `` ≠ ё)
        out += ks.isEmpty ? "·" : ks
    }
    return out.isEmpty ? "—" : out
}

/// Человекочитаемый хоткей ДИКТОВКИ (та же логика, что в пункте «Свой…» VoiceHotkeyControl).
/// Вынесено наружу, чтобы онбординг мог подставлять РЕАЛЬНО назначенные комбинации в текст,
/// а не абстрактное «нажми хоткей» — так пользователю проще их запомнить (просьба автора 21.07).
func voiceHotkeyDisplayString() -> String {
    let s = AppSettings.shared
    if s.voiceHotkeyMode == "modkey" {
        switch s.voiceHotkeyKeyCode {
        case 61: return L10n.t("hk.rOpt"); case 58: return L10n.t("hk.lOpt")
        case 54: return L10n.t("hk.rCmd"); case 55: return L10n.t("hk.lCmd")
        case 60: return L10n.t("hk.rShift"); case 56: return L10n.t("hk.lShift")
        case 62: return L10n.t("hk.rCtrl"); case 59: return L10n.t("hk.lCtrl")
        default: return L10n.t("hk.key")
        }
    }
    return modsPlusKey(CGEventFlags(rawValue: s.voiceHotkeyModifiers), s.voiceHotkeyKeyCode)
}

/// Человекочитаемый хоткей ПЕРЕВОДА (напр. «⌃⌥T»).
func translateHotkeyDisplayString() -> String {
    let s = AppSettings.shared
    return modsPlusKey(CGEventFlags(rawValue: s.translateHotkeyModifiers), s.translateHotkeyKeyCode)
}

/// «модификаторы + клавиша» → «⌃⌥T». Подпись клавиши берём по keyCode (стабильно: `` ` `` ≠ ё).
private func modsPlusKey(_ mods: CGEventFlags, _ keyCode: Int) -> String {
    var out = ""
    if mods.contains(.maskControl) { out += "⌃" }
    if mods.contains(.maskAlternate) { out += "⌥" }
    if mods.contains(.maskShift) { out += "⇧" }
    if mods.contains(.maskCommand) { out += "⌘" }
    let ks = KeyLabels.symbol(forKeyCode: keyCode)
    out += ks.isEmpty ? "·" : ks
    return out.isEmpty ? "—" : out
}

/// Хоткей: пресеты (combo + правые модификаторы) + «Свой…».
/// ЗАПИСЬ СВОЕЙ КОМБИНАЦИИ — общая механика для всех хоткей-контролов.
///
/// Баг, который это лечит (репорты пользователей 25.07: «нажимаю переназначить — не ловит»):
/// наш CGEventTap стоит на сессии ПЕРЕД приложениями и активно ГЛОТАЕТ уже назначенные хоткеи
/// (перевод/диктовка/мгновенное переключение). Пока идёт запись, пользователь жмёт как раз такие
/// комбинации — tap съедал нажатие и запускал СТАРОЕ действие, а локальный монитор окна настроек
/// не получал ничего. Поэтому на время записи tap перестаёт трогать наши хоткеи (см. EventTap).
/// Режим записи комбинации. Пока он включён, EventTap пропускает ВСЁ насквозь (EventTap.swift:161) —
/// то есть авто-переключение, исправление на лету и сниппеты не работают вовсе.
///
/// ⚠️ Почему здесь сторожа (28.07). Раньше флаг снимался только из `capture()`, то есть по факту
/// нажатия клавиши. Человек открывал «Назначить свою…», передумывал и закрывал окно — флаг оставался
/// поднятым до конца жизни процесса: движок молча мёртв, в логе ни строки, лечится только
/// перезапуском. Вторая половина хуже: локальный монитор контрола продолжал глотать клавиши в наших
/// окнах, и следующее нажатие могло назначить на хоткей что угодно, вплоть до пробела.
/// `reset()` для этого и был задуман, но его никто не вызывал — предохранитель без проводов.
///
/// Теперь запись гасится сама: по закрытию СВОЕГО окна, по потере фокуса приложением и по таймауту.
enum HotkeyRecording {
    /// Идёт запись комбинации (читает EventTap; всё на main-потоке, гонки нет).
    private(set) static var active = false

    /// Сколько ждём БЕЗДЕЙСТВИЯ, прежде чем считать, что человек передумал.
    ///
    /// ⚠️ Это таймер ПРОСТОЯ, а не общий лимит на запись (баг-репорт: «окошко исчезло само,
    /// я перебирал варианты и не успел»). Раньше он отсчитывал 15с от начала и не продлевался — то
    /// есть наказывал именно за то, ради чего окно и сделано: спокойно попробовать несколько
    /// сочетаний. Теперь любое нажатие продлевает его заново, а сам порог поднят: окно записи теперь
    /// ВИДНО, поэтому сторож нужен лишь как страховка от протечки, а не как средство сигнализации.
    private static let watchdogSeconds: TimeInterval = 90
    /// Абсолютный потолок сессии записи: продлеваемый таймер простоя можно продлевать бесконечно
    /// теми же клавишами, которые локальный монитор глотает в наших окнах. Этот не продлевается
    /// ничем (найдено ревью 28.07).
    private static let hardCapSeconds: TimeInterval = 180
    private static var hardCap: Timer?
    /// Насколько недавним должно быть нажатие, чтобы уход из приложения НЕ считался отказом.
    /// Нужен, потому что часть назначаемых сочетаний система забирает себе (⌘Space открывает
    /// Spotlight) и фокус уезжает сам собой — это не «человек ушёл», это он нажал то, что просили.
    private static let recentActivityWindow: TimeInterval = 3
    private static var lastActivity: TimeInterval = 0

    private static var stopper: (() -> Void)?
    private static var watchdog: Timer?
    private static var observers: [NSObjectProtocol] = []
    /// Поколение записи. Наблюдатели ставятся с `queue: .main`, то есть их блок уходит в очередь;
    /// `removeObserver` уже поставленную операцию не отменяет. Без этого счётчика отложенный колбэк
    /// от ПРОШЛОЙ записи мог погасить УЖЕ ДРУГУЮ, начатую мгновением позже.
    private static var session = 0

    /// Начать запись. `stop` — как вернуть КОНКРЕТНЫЙ контрол в обычный вид (снять локальный
    /// монитор, перерисовать список): сторожа зовут именно его, а не только гасят флаг.
    ///
    /// `window` — окно, в котором идёт запись. Наблюдатель закрытия вешается ИМЕННО на него.
    /// ⚠️ Почему не `object: nil` (найдено ревью 28.07): уведомление о закрытии прилетает от ЛЮБОГО
    /// окна процесса. У нас есть окна, которые закрываются сами: окно докачки языковых пакетов
    /// (TranslationEngine закрывает его из колбэка, когда загрузка кончилась) и окно отзыва
    /// (закрывается по таймеру через ~1.1с после отправки). Человек начал назначать хоткей, в этот
    /// момент докачалась модель — запись молча умирала, тап оживал, и следующее нажатие запускало
    /// СТАРЫЙ хоткей вместо записи. Это ровно тот баг 25.07, который сторожа и должны были лечить.
    static func begin(stop: @escaping () -> Void, in window: NSWindow?) {
        // Повторный вход: не выбрасываем прошлый stopper молча, а честно ЗАВЕРШАЕМ ту запись —
        // иначе её локальный монитор остаётся висеть и глотает клавиши во всех наших окнах
        // (в поле сниппетов, в поиске исключений, в форме отзыва — «не набирается ни символа»).
        forceStop("начата запись другой комбинации")
        session &+= 1
        let mySession = session
        active = true
        stopper = stop
        lastActivity = ProcessInfo.processInfo.systemUptime
        kbLog("хоткей: запись комбинации начата")
        armWatchdog(session: mySession)
        armHardCap(session: mySession)
        let nc = NotificationCenter.default
        if let window {
            observers.append(nc.addObserver(forName: NSWindow.willCloseNotification,
                                            object: window, queue: .main) { _ in
                forceStop("окно закрыто", session: mySession)
            })
        }
        observers.append(nc.addObserver(forName: NSApplication.didResignActiveNotification,
                                        object: nil, queue: .main) { _ in
            // Если человек только что нажимал — фокус увела САМА система (Spotlight на ⌘Space и
            // подобное), и обрывать запись из-за этого нельзя.
            let idle = ProcessInfo.processInfo.systemUptime - lastActivity
            if idle > recentActivityWindow {
                forceStop("ушли из приложения", session: mySession)
                return
            }
            // Нажатие было только что: возможно, фокус увела САМА система (⌘Space открыл Spotlight).
            // Но молча оставлять запись живой нельзя — иначе человек уйдёт работать в другую
            // программу, а движок будет отключён. Перепроверяем через recentActivityWindow.
            DispatchQueue.main.asyncAfter(deadline: .now() + recentActivityWindow) {
                guard !NSApp.isActive else { return }
                forceStop("ушли из приложения", session: mySession)
            }
        })
    }

    /// Была активность в записи: продлеваем сторожа. Зовут контролы из своих capture().
    static func noteActivity() {
        guard active else { return }
        lastActivity = ProcessInfo.processInfo.systemUptime
        armWatchdog(session: session)
    }

    private static func armWatchdog(session sess: Int) {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: watchdogSeconds, repeats: false) { _ in
            forceStop("ничего не нажимали \(Int(watchdogSeconds))с", session: sess)
        }
    }

    private static func armHardCap(session sess: Int) {
        hardCap?.invalidate()
        hardCap = Timer.scheduledTimer(withTimeInterval: hardCapSeconds, repeats: false) { _ in
            forceStop("запись идёт дольше \(Int(hardCapSeconds / 60)) мин", session: sess)
        }
    }

    /// Штатное завершение (клавиша нажата либо Esc).
    static func end() {
        guard active else { return }
        active = false
        disarm()
        kbLog("хоткей: запись комбинации завершена")
    }

    /// Аварийный сброс: окно закрыли / потеряли фокус / истёк таймаут / начали другую запись.
    /// `session` — чью именно запись гасим; отложенный колбэк от прошлой не трогает текущую.
    private static func forceStop(_ reason: String, session sess: Int? = nil) {
        guard active else { return }
        if let sess, sess != session { return }
        active = false
        let s = stopper
        disarm()
        kbLog("хоткей: запись прервана (\(reason)) — движок снова работает")
        s?()      // вернуть контрол в нормальный вид и снять его локальный монитор
    }

    private static func disarm() {
        watchdog?.invalidate(); watchdog = nil
        hardCap?.invalidate(); hardCap = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        stopper = nil
    }
}

/// Общее правило «хватает ли модификаторов». Живёт здесь, чтобы рекордеры и тап судили ОДИНАКОВО.
///
/// Почему это правило вообще есть (репорты #13/#22/#30, 27.07): назначенная по недосмотру «голая»
/// клавиша перехватывается у ВСЕЙ системы. В пределе человек назначает пробел и остаётся без
/// пробела во всех программах, пока не выйдет из Keyboop. Раньше запрет стоял только в контроле
/// перевода, остальные три принимали что угодно.
enum HotkeyKeys {
    /// ⚠️ Белый список F13…F20 УБРАН (ревью 28.07). Он был реализован наполовину: рекордеры голую
    /// F-клавишу принимали, но тап её перехватывал только для мгновенного переключения (у конверсии
    /// и перевода стоит `!isEmpty`), а подписи KeyLabels знают лишь F1–F12 — панель рисовала пустую
    /// капсулу и всё равно давала нажать «Назначить». Человек получал вечно мёртвый хоткей.
    /// Полдела хуже, чем ничего: правило теперь одно и без исключений.

    /// Допустима ли клавиша с таким набором модификаторов.
    static func modifiersSufficient(keyCode: Int, mods: CGEventFlags) -> Bool {
        let relevant: CGEventFlags = [.maskAlternate, .maskShift, .maskCommand, .maskControl]
        return !mods.intersection(relevant).isEmpty
    }
}

/// Комбинации, которые НЕЛЬЗЯ отдавать под наши хоткеи.
///
/// Репорт 25.07: пользователь при записи нажал ⌘C — и оно записалось. После этого КАЖДОЕ копирование
/// запускало перевод, а перевод сам делает ⌘C → бесконечный цикл с «ритмичным звуком», пока человек
/// не сменит хоткей в настройках. Петлю мы разорвали маркером синтетики, но назначать системные
/// сочетания всё равно нельзя — они нужны самому пользователю.
enum HotkeyGuard {
    /// keyCode → подпись, для чистого ⌘ (буквы, которые везде значат своё).
    private static let cmdCritical: [Int: String] = [
        8: "⌘C", 9: "⌘V", 7: "⌘X", 6: "⌘Z", 0: "⌘A", 1: "⌘S", 12: "⌘Q", 13: "⌘W",
        45: "⌘N", 31: "⌘O", 35: "⌘P", 3: "⌘F", 4: "⌘H", 46: "⌘M", 15: "⌘R", 2: "⌘D",
        48: "⌘Tab", 51: "⌘⌫"
    ]
    /// Объяснить человеку, почему не взяли (без этого «нажал — ничего» выглядит как поломка).
    /// Текст «эта комбинация занята системой» — показываем ПРЯМО в окне записи, не отдельным
    /// модальным окном (просьба автора 28.07: алерт перекрывал само окно и обрывал запись, вместо
    /// того чтобы дать спокойно нажать другое сочетание).
    static func busyMessage(_ what: String) -> String {
        String(format: L10n.t("hkrec.warn.busy"), what)
    }

    /// Текст «нужен хотя бы один модификатор».
    static func needsModifierMessage() -> String { L10n.t("hkrec.warn.bare") }

    /// ДВА РАЗНЫХ «ЗАНЯТО» (решение автора 06.08.2026), и разница принципиальная.
    ///
    /// `blocked` — то, что отбирать нельзя ни при каких обстоятельствах: ⌘C, ⌘V, ⌘Z и прочая
    /// мышечная память. Человек, назначивший туда нашу функцию, сломает себе не Keyboop, а вообще
    /// весь Mac, и связать это с нами не сможет.
    ///
    /// `warn` — системные функции macOS (Spotlight, Mission Control, переключение раскладки). Это
    /// его Mac и его выбор: он вправе отключить системное сочетание в настройках и занять его нами.
    /// Наше дело предупредить, а не запретить. Кнопка «Назначить» остаётся живой.
    enum Verdict {
        case ok
        case blocked(String)
        case warn(String)
    }

    static func verdict(keyCode: Int, mods: CGEventFlags) -> Verdict {
        if let hard = rejection(keyCode: keyCode, mods: mods) { return .blocked(hard) }
        if let who = SystemHotkeys.takenBy(keyCode: keyCode, mods: mods) { return .warn(who) }
        return .ok
    }

    /// Мягкое предупреждение: занято системой, но назначить можно.
    static func conflictMessage(_ what: String) -> String {
        String(format: L10n.t("hkrec.warn.system"), what)
    }

    /// nil — комбинация допустима; иначе текст, чем именно она занята. ТОЛЬКО жёсткие запреты.
    static func rejection(keyCode: Int, mods: CGEventFlags) -> String? {
        let onlyCmd = mods == .maskCommand
        if onlyCmd, let name = cmdCritical[keyCode] { return name }
        // Одиночный ⌘+любая буква — почти всегда занято приложением; просим добавить ⌥ или ⌃.
        if onlyCmd { return "⌘ + клавиша" }
        // ⚠️ Системные сочетания сюда НЕ входят: они мягкие и живут в `verdict` (автор 06.08).
        // Здесь только то, что не обсуждается.
        return nil
    }
}

final class HotkeyControl: NSView {
    private let settings = AppSettings.shared
    private let pop = NSPopUpButton(frame: .zero, pullsDown: false)
    private var monitor: Any?
    /// Что применить, если человек нажмёт «Назначить» в окне записи. Пока nil — назначать нечего.
    private var pendingApply: (() -> Void)?
    /// Кандидат набран и ЗАМОРОЖЕН на экране: отпускание клавиш его больше не меняет.
    private var frozen = false
    /// Показали отказ, а клавиши ещё ФИЗИЧЕСКИ зажаты — ждём, пока отпустят всё. См. capture().
    private var awaitingRelease = false
    /// Предыдущий набор модификаторов — чтобы отличить «отпускает старое» от «начал новое».
    private var lastMods: CGEventFlags = []

    /// Человек начал набирать заново: модификаторы пошли вверх с нуля.
    private func shouldRestart(_ mods: CGEventFlags) -> Bool { !mods.isEmpty && lastMods.isEmpty }

    /// Сбросить замороженного кандидата перед новым набором.
    private func restartIfFrozen() {
        guard frozen else { return }
        frozen = false
        pendingApply = nil
        resetPeaks()
    }

    /// Живое отображение, пока клавиши зажаты.
    private func live(_ parts: [String]) {
        HotkeyRecorderPanel.shared.render(parts: parts, complete: false)
    }

    /// Зафиксировать набранное: остаётся на экране, кнопка «Назначить» становится активной.
    private func freeze(_ parts: [String], warning: String? = nil) {
        frozen = true
        HotkeyRecorderPanel.shared.render(parts: parts, complete: true, warning: warning)
    }

    /// Отказ БЕЗ прерывания записи: показываем причину в самом окне, человек жмёт другое сочетание.
    private func warnInPanel(_ text: String, parts: [String]) {
        frozen = false
        pendingApply = nil
        resetPeaks()
        awaitingRelease = true
        HotkeyRecorderPanel.shared.warn(text, parts: parts)
    }
    private var peak: CGEventFlags = []
    private var peakKey: Int = -1   // keyCode ПЕРВОГО одиночного модификатора (для modkey, напр. левый Option)
    private func resetPeaks() { peak = []; peakKey = -1 }

    // (label, mode, keyCode, modifiers). Лейбл modkey-пресетов локализуется в presetLabel() на
    // момент сборки списка (combo/doubletap — символ+англ., как у Apple в RU не переводится).
    private static let presets: [(String, String, Int, UInt64)] = [
        ("⌥⇧  Option+Shift",      "combo",  -1, CGEventFlags([.maskAlternate, .maskShift]).rawValue),
        ("⌃⌥  Control+Option",    "combo",  -1, CGEventFlags([.maskControl, .maskAlternate]).rawValue),
        ("Right ⌥",  "modkey", 61, CGEventFlags.maskAlternate.rawValue),
        ("Left ⌥",   "modkey", 58, CGEventFlags.maskAlternate.rawValue),
        ("Right ⌘", "modkey", 54, CGEventFlags.maskCommand.rawValue),
        ("Left ⌃",   "modkey", 59, CGEventFlags.maskControl.rawValue),
        ("2× ⇧  (DoubleShift)",        "doubletap", 56, CGEventFlags.maskShift.rawValue),
        // 🌐/Fn как хоткей КОНВЕРСИИ (просьба автора 24.07 — «мало ли кому так удобно»). Событие
        // глотаем в EventTap, поэтому системное действие клавиши не сработает параллельно.
        ("🌐  Globe / Fn",             "modkey",    63, CGEventFlags.maskSecondaryFn.rawValue)
    ]
    /// Локализованный лейбл пресета (modkey → L10n; остальные — статический символ+англ.).
    private static func presetLabel(_ p: (String, String, Int, UInt64)) -> String {
        if p.1 == "modkey" {
            switch p.2 {
            case 61: return L10n.t("hk.rOpt"); case 58: return L10n.t("hk.lOpt")
            case 54: return L10n.t("hk.rCmd"); case 59: return L10n.t("hk.lCtrl")
            default: break
            }
        }
        return p.0
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 230, height: 26))
        pop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pop)
        NSLayoutConstraint.activate([
            pop.leadingAnchor.constraint(equalTo: leadingAnchor),
            pop.trailingAnchor.constraint(equalTo: trailingAnchor),
            pop.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 230)
        ])
        rebuild()
        pop.target = self
        pop.action = #selector(changed)
    }
    required init?(coder: NSCoder) { fatalError("no xib") }

    private func matchedPreset() -> Int? {
        Self.presets.firstIndex { (_, mode, kc, mods) in
            mode == settings.hotkeyMode && (mode == "combo" ? mods == settings.hotkeyModifiers : kc == settings.hotkeyKeyCode)
        }
    }

    private func rebuild() {
        pop.removeAllItems()
        pop.addItems(withTitles: Self.presets.map { Self.presetLabel($0) })
        let custom = matchedPreset() == nil
        // Своя комбинация — ОТДЕЛЬНЫМ пунктом (без «карандаша»: он читался как часть сочетания,
        // особенно рядом с ⌃ — баг-репорт). Строка «Назначить свою…» остаётся ВСЕГДА
        // последней, иначе после назначения своей комбинации непонятно, куда нажать, чтобы сменить.
        if custom { pop.addItem(withTitle: hotkeyDisplayString()) }
        pop.addItem(withTitle: L10n.t("hk.custom"))
        if let idx = matchedPreset() { pop.selectItem(at: idx) }
        else { pop.selectItem(at: Self.presets.count) }   // свой пункт стоит сразу за пресетами
    }

    @objc private func changed() {
        let i = pop.indexOfSelectedItem
        if i < Self.presets.count {
            let p = Self.presets[i]
            // Обратная проверка коллизии: та же комбинация уже назначена на МГНОВЕННУЮ смену языка
            // → два действия подрались бы за одно нажатие (требование автора 24.07).
            if settings.instantSwitchEnabled, p.1 == settings.instantSwitchMode,
               p.2 == settings.instantSwitchKeyCode {
                let a = NSAlert()
                a.messageText = L10n.t("is.busy.title")
                a.informativeText = String(format: L10n.t("is.busy.body"), L10n.t("is.busy.instant"))
                a.addButton(withTitle: "OK"); a.runModal()
                rebuild(); return
            }
            settings.hotkeyMode = p.1
            settings.hotkeyKeyCode = p.2
            settings.hotkeyModifiers = p.3
            settings.hotkeyKeyLabel = ""
            rebuild()
        } else if i == pop.numberOfItems - 1 {
            startRecording()          // последняя строка — «Назначить свою…» (есть ВСЕГДА)
        } else {
            rebuild()                 // выбрали свою уже назначенную комбинацию — менять нечего
        }
    }

    private func startRecording() {
        HotkeyRecording.begin(stop: { [weak self] in self?.stopRecording() }, in: self.window)   // tap не трогает наши хоткеи, пока пишем
        peak = []; peakKey = -1; pendingApply = nil
        frozen = false; lastMods = []; awaitingRelease = false   // прошлую запись могли завершить с зажатыми модификаторами
        pop.item(at: Self.presets.count)?.title = L10n.t("hk.press")
        pop.synchronizeTitleAndSelectedItem()
        HotkeyRecorderPanel.shared.show(what: L10n.t("hkrec.what.switch"), over: self.window,
                                        onCommit: { [weak self] in self?.commitPending() },
                                        onCancel: { [weak self] in self?.stopRecording() })
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] ev in
            self?.capture(ev)
            return nil
        }
    }
    /// Человек нажал «Назначить» — только теперь пишем настройки.
    private func commitPending() {
        let apply = pendingApply
        stopRecording()
        apply?()
        rebuild()
    }
    private func stopRecording() {
        HotkeyRecording.end()
        HotkeyRecorderPanel.shared.hide()
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        pendingApply = nil
        rebuild()
    }

    private func capture(_ ev: NSEvent) {
        HotkeyRecording.noteActivity()   // продлеваем сторожа: человек перебирает варианты, это не простой
        let mods = cg(ev.modifierFlags)
        if ev.type == .keyDown {
            if ev.keyCode == 53 { stopRecording(); return } // Esc
            restartIfFrozen()
            guard HotkeyKeys.modifiersSufficient(keyCode: Int(ev.keyCode), mods: mods) else {
                warnInPanel(HotkeyGuard.needsModifierMessage(),
                            parts: HotkeyRecorderPanel.parts(mods: mods, keyLabel: KeyLabels.symbol(forKeyCode: Int(ev.keyCode))))
                return
            }
            let verdict = HotkeyGuard.verdict(keyCode: Int(ev.keyCode), mods: mods)
            if case .blocked(let busy) = verdict {
                warnInPanel(HotkeyGuard.busyMessage(busy),
                            parts: HotkeyRecorderPanel.parts(mods: mods, keyLabel: KeyLabels.symbol(forKeyCode: Int(ev.keyCode))))
                return
            }
            let kc = Int(ev.keyCode), label = KeyLabels.symbol(forKeyCode: Int(ev.keyCode))
            pendingApply = { [weak self] in
                guard let s = self?.settings else { return }
                s.hotkeyMode = "key"; s.hotkeyKeyCode = kc
                s.hotkeyModifiers = mods.rawValue; s.hotkeyKeyLabel = label
            }
            // Мягкий конфликт показываем ВМЕСТЕ с кандидатом: кнопка «Назначить» остаётся живой,
            // человек решает сам (автор 06.08).
            if case .warn(let who) = verdict {
                freeze(HotkeyRecorderPanel.parts(mods: mods, keyLabel: label), warning: HotkeyGuard.conflictMessage(who))
            } else {
                freeze(HotkeyRecorderPanel.parts(mods: mods, keyLabel: label))
            }
        } else {
            // Пока на экране висит зафиксированный кандидат, ОТПУСКАНИЕ клавиш его не трогает —
            // иначе человек не успевал донести мышь до «Назначить». Сброс только на новом наборе
            // (см. shouldRestart): модификаторы пошли вверх с нуля.
            // ⚠️ Показали отказ, а клавиши всё ещё ФИЗИЧЕСКИ зажаты. Их отпускание по одной приходит
            // сюда обычным flagsChanged, и накопитель принимает его за НАЧАЛО нового набора: в
            // кандидат уходит keyCode ОТПУСКАЕМОЙ клавиши с маской от тех, что ещё внизу. Человек
            // видит на экране «⌃», а записывается левый ⌥ с маской control: сочетание, которое не
            // сработает никогда, но при этом глотает модификатор у всей системы. Ждём чистого нуля.
            // (Найдено ревью 28.07 на сценарии «зажал ⌃⌥, нажал T, получил отказ, отпустил по одной».)
            if awaitingRelease {
                lastMods = mods
                if mods.isEmpty { awaitingRelease = false; resetPeaks() }
                return
            }
            if frozen, !shouldRestart(mods) { lastMods = mods; return }
            restartIfFrozen()
            lastMods = mods
            if mods.isEmpty {
                // Отпустили все модификаторы → предлагаем накопленный пик (записываем по кнопке).
                if count(peak) >= 2 {
                    let p = peak
                    pendingApply = { [weak self] in
                        guard let s = self?.settings else { return }
                        s.hotkeyMode = "combo"          // ⌥⇧ и т.п.
                        s.hotkeyKeyCode = -1; s.hotkeyModifiers = p.rawValue; s.hotkeyKeyLabel = ""
                    }
                    freeze(HotkeyRecorderPanel.parts(mods: p))
                } else if count(peak) == 1, peakKey >= 0 {
                    // ОДИН модификатор (напр. левый Option) → modkey: тап по нему = переключение.
                    // Без этой ветки одиночный модификатор НЕ записывался → запись висела «бесконечно».
                    let p = peak, pk = peakKey
                    pendingApply = { [weak self] in
                        guard let s = self?.settings else { return }
                        s.hotkeyMode = "modkey"
                        s.hotkeyKeyCode = pk; s.hotkeyModifiers = p.rawValue; s.hotkeyKeyLabel = ""
                    }
                    freeze(HotkeyRecorderPanel.parts(mods: p))
                } else { peak = []; peakKey = -1 }
            } else {
                if peak.isEmpty, count(mods) == 1 { peakKey = Int(ev.keyCode) }  // ПЕРВЫЙ одиночный модификатор
                if count(mods) >= count(peak) { peak = mods }
                // Живое отображение: человек видит, что уже зажато.
                live(HotkeyRecorderPanel.parts(mods: mods))
            }
        }
    }

    private func cg(_ f: NSEvent.ModifierFlags) -> CGEventFlags {
        var m: CGEventFlags = []
        if f.contains(.option) { m.insert(.maskAlternate) }
        if f.contains(.shift) { m.insert(.maskShift) }
        if f.contains(.command) { m.insert(.maskCommand) }
        if f.contains(.control) { m.insert(.maskControl) }
        return m
    }
    private func count(_ m: CGEventFlags) -> Int {
        [.maskAlternate, .maskShift, .maskCommand, .maskControl].filter { m.contains($0) }.count
    }
}

/// Выпадающий список системных звуков + превью при выборе.
final class SoundPicker: NSPopUpButton {
    private let settings = AppSettings.shared

    private var cue: NSSound?   // держим превью, иначе оборвётся

    init() {
        super.init(frame: .zero, pullsDown: false)
        // Наш звук — ПЕРВЫМ после «без звука» и по умолчанию (25.07: все звуки в приложении свои,
        // системный Pop был единственным чужим). Системные оставляем — кому привычнее.
        addItem(withTitle: L10n.t("sound.none"))
        addItem(withTitle: L10n.t("sound.keyboop"))
        addItems(withTitles: Self.systemSounds())
        switch settings.soundName {
        case "":         selectItem(at: 0)
        case "keyboop":  selectItem(at: 1)
        default:         selectItem(withTitle: settings.soundName)
        }
        target = self
        action = #selector(changed)
    }
    required init?(coder: NSCoder) { fatalError("no xib") }

    @objc private func changed() {
        let vol = Float(max(0, min(1, settings.soundVolume)))
        switch indexOfSelectedItem {
        case 0:
            settings.soundName = ""
        case 1:
            settings.soundName = "keyboop"
            cue?.stop(); cue = Sounds.play(NSSound(data: CueSynth.switchData), volume: Double(vol))
        default:
            if let t = titleOfSelectedItem {
                settings.soundName = t
                Sounds.play(NSSound(named: t), volume: Double(vol))
            }
        }
    }
    static func systemSounds() -> [String] {
        let dir = "/System/Library/Sounds"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return files.filter { $0.hasSuffix(".aiff") }.map { ($0 as NSString).deletingPathExtension }.sorted()
    }
}

/// Выбор звука перевода: «Keyboop (наш)» + «Без звука» + системные. Хранится в translateSoundName
/// ("keyboop" / "" / имя системного). При выборе — короткое превью на текущей громкости.
final class TranslateSoundPicker: NSPopUpButton {
    private let settings = AppSettings.shared
    private var preview: NSSound?

    init() {
        super.init(frame: .zero, pullsDown: false)
        addItem(withTitle: L10n.t("sound.keyboopTr"))   // index 0 → "keyboop"
        addItem(withTitle: L10n.t("sound.none"))       // index 1 → ""
        addItems(withTitles: SoundPicker.systemSounds())
        switch settings.translateSoundName {
        case "keyboop": selectItem(at: 0)
        case "":        selectItem(at: 1)
        case let n:     selectItem(withTitle: n)
        }
        target = self
        action = #selector(changed)
    }
    required init?(coder: NSCoder) { fatalError("no xib") }

    @objc private func changed() {
        let vol = Float(max(0, min(1, settings.translateSoundVolume)))
        switch indexOfSelectedItem {
        case 0:
            settings.translateSoundName = "keyboop"
            preview = Sounds.play(NSSound(data: CueSynth.translateData), volume: Double(vol))
        case 1:
            settings.translateSoundName = ""
        default:
            if let t = titleOfSelectedItem {
                settings.translateSoundName = t
                Sounds.play(NSSound(named: t), volume: Double(vol))
            }
        }
    }
}

/// Хоткей диктовки: пресеты (правый ⌥ / правый ⌘ / ⌥`) + «Свой…» — запись своей
/// клавиши/модификатора (одиночный модификатор как hold-to-talk, или клавиша+модификаторы).
final class VoiceHotkeyControl: NSView {
    private let settings = AppSettings.shared
    private let pop = NSPopUpButton(frame: .zero, pullsDown: false)
    private var monitor: Any?
    /// Что применить, если человек нажмёт «Назначить» в окне записи. Пока nil — назначать нечего.
    private var pendingApply: (() -> Void)?
    /// Кандидат набран и ЗАМОРОЖЕН на экране: отпускание клавиш его больше не меняет.
    private var frozen = false
    /// Показали отказ, а клавиши ещё ФИЗИЧЕСКИ зажаты — ждём, пока отпустят всё. См. capture().
    private var awaitingRelease = false
    /// Предыдущий набор модификаторов — чтобы отличить «отпускает старое» от «начал новое».
    private var lastMods: CGEventFlags = []

    /// Человек начал набирать заново: модификаторы пошли вверх с нуля.
    private func shouldRestart(_ mods: CGEventFlags) -> Bool { !mods.isEmpty && lastMods.isEmpty }

    /// Сбросить замороженного кандидата перед новым набором.
    private func restartIfFrozen() {
        guard frozen else { return }
        frozen = false
        pendingApply = nil
        resetPeaks()
    }

    /// Живое отображение, пока клавиши зажаты.
    private func live(_ parts: [String]) {
        HotkeyRecorderPanel.shared.render(parts: parts, complete: false)
    }

    /// Зафиксировать набранное: остаётся на экране, кнопка «Назначить» становится активной.
    private func freeze(_ parts: [String], warning: String? = nil) {
        frozen = true
        HotkeyRecorderPanel.shared.render(parts: parts, complete: true, warning: warning)
    }

    /// Отказ БЕЗ прерывания записи: показываем причину в самом окне, человек жмёт другое сочетание.
    private func warnInPanel(_ text: String, parts: [String]) {
        frozen = false
        pendingApply = nil
        resetPeaks()
        awaitingRelease = true
        HotkeyRecorderPanel.shared.warn(text, parts: parts)
    }
    /// Накопитель, как у HotkeyControl. ДО 29.07 здесь лежала одна пара pendingModKey/pendingModFlag,
    /// и каждый следующий нажатый модификатор ЗАТИРАЛ предыдущий: зажал ⌥, добавил ⌘ — про ⌥ забыли,
    /// на отпускании предлагали ⌘ в одиночку. Пользователь видел ровно то, что описал в репорте #21:
    /// «просто выбирает одну клавишу, которая была», и повторил на 0.3.0 (репорты #44/#45).
    /// Копим пик и на полном отпускании решаем: ≥2 модификатора → combo, ровно один → modkey.
    private var peak: CGEventFlags = []
    private var peakKey: Int = -1   // keyCode ПЕРВОГО одиночного модификатора (для modkey)
    private func resetPeaks() { peak = []; peakKey = -1 }
    private func count(_ m: CGEventFlags) -> Int {
        [.maskAlternate, .maskShift, .maskCommand, .maskControl].filter { m.contains($0) }.count
    }

    /// Занята ли эта комбинация модификаторов другим нашим хоткеем, живущим в режиме "combo".
    /// Сравниваем только с такими же комбинациями: modkey и key — другие нажатия, они не конфликтуют.
    private func comboCollision(_ mods: CGEventFlags) -> String? {
        let s = settings
        if s.hotkeyMode == "combo", s.hotkeyModifiers == mods.rawValue { return L10n.t("is.busy.convert") }
        if s.instantSwitchMode == "combo", s.instantSwitchMods == mods.rawValue { return L10n.t("is.busy.instant") }
        return nil
    }

    // (label, mode, keyCode, modifiers)
    private static var presets: [(String, String, Int, UInt64)] {
        [
            (L10n.t("voice.hkRopt"),  "modkey", 61, CGEventFlags.maskAlternate.rawValue),
            (L10n.t("voice.hkRcmd"),  "modkey", 54, CGEventFlags.maskCommand.rawValue),
            (L10n.t("voice.hkTilde"), "key",    50, CGEventFlags.maskAlternate.rawValue)
        ]
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 230, height: 26))
        pop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pop)
        NSLayoutConstraint.activate([
            pop.leadingAnchor.constraint(equalTo: leadingAnchor),
            pop.trailingAnchor.constraint(equalTo: trailingAnchor),
            pop.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 230)
        ])
        rebuild()
        pop.target = self
        pop.action = #selector(changed)
    }
    required init?(coder: NSCoder) { fatalError("no xib") }

    private func matched() -> Int? {
        Self.presets.firstIndex { (_, mode, kc, _) in
            mode == settings.voiceHotkeyMode && kc == settings.voiceHotkeyKeyCode
        }
    }

    /// Человекочитаемое текущее назначение (для пункта «Свой…»).
    private func display() -> String {
        if settings.voiceHotkeyMode == "modkey" {
            switch settings.voiceHotkeyKeyCode {
            case 61: return L10n.t("hk.rOpt"); case 58: return L10n.t("hk.lOpt")
            case 54: return L10n.t("hk.rCmd"); case 55: return L10n.t("hk.lCmd")
            case 60: return L10n.t("hk.rShift"); case 56: return L10n.t("hk.lShift")
            case 62: return L10n.t("hk.rCtrl"); case 59: return L10n.t("hk.lCtrl")
            default: return L10n.t("hk.key")
            }
        }
        let mods = CGEventFlags(rawValue: settings.voiceHotkeyModifiers)
        var out = ""
        if mods.contains(.maskControl) { out += "⌃" }
        if mods.contains(.maskAlternate) { out += "⌥" }
        if mods.contains(.maskShift) { out += "⇧" }
        if mods.contains(.maskCommand) { out += "⌘" }
        let ks = KeyLabels.symbol(forKeyCode: settings.voiceHotkeyKeyCode)   // подпись по keyCode (`` ` `` ≠ ё)
        out += ks.isEmpty ? "·" : ks
        return out
    }

    private func rebuild() {
        pop.removeAllItems()
        pop.addItems(withTitles: Self.presets.map { $0.0 })
        let custom = matched() == nil
        // Своя комбинация — ОТДЕЛЬНЫМ пунктом (без «карандаша»: он читался как часть сочетания,
        // особенно рядом с ⌃ — баг-репорт). Строка «Назначить свою…» остаётся ВСЕГДА
        // последней, иначе после назначения своей комбинации непонятно, куда нажать, чтобы сменить.
        if custom { pop.addItem(withTitle: display()) }
        pop.addItem(withTitle: L10n.t("hk.custom"))
        if let idx = matched() { pop.selectItem(at: idx) }
        else { pop.selectItem(at: Self.presets.count) }   // свой пункт стоит сразу за пресетами
    }

    @objc private func changed() {
        let i = pop.indexOfSelectedItem
        if i < Self.presets.count {
            let p = Self.presets[i]
            settings.voiceHotkeyMode = p.1
            settings.voiceHotkeyKeyCode = p.2
            settings.voiceHotkeyModifiers = p.3
            settings.voiceHotkeyKeyLabel = ""
            rebuild()
        } else if i == pop.numberOfItems - 1 {
            startRecording()          // последняя строка — «Назначить свою…» (есть ВСЕГДА)
        } else {
            rebuild()                 // выбрали свою уже назначенную комбинацию — менять нечего
        }
    }

    private func startRecording() {
        HotkeyRecording.begin(stop: { [weak self] in self?.stopRecording() }, in: self.window)   // tap не трогает наши хоткеи, пока пишем
        resetPeaks(); pendingApply = nil
        frozen = false; lastMods = []; awaitingRelease = false   // прошлую запись могли завершить с зажатыми модификаторами
        pop.item(at: Self.presets.count)?.title = L10n.t("hk.press")
        pop.synchronizeTitleAndSelectedItem()
        HotkeyRecorderPanel.shared.show(what: L10n.t("hkrec.what.voice"), over: self.window,
                                        onCommit: { [weak self] in self?.commitPending() },
                                        onCancel: { [weak self] in self?.stopRecording() })
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] ev in
            self?.capture(ev); return nil
        }
    }
    private func commitPending() {
        let apply = pendingApply
        stopRecording()
        apply?()
        rebuild()
    }
    private func stopRecording() {
        HotkeyRecording.end()
        HotkeyRecorderPanel.shared.hide()
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        pendingApply = nil
        rebuild()
    }

    private func capture(_ ev: NSEvent) {
        HotkeyRecording.noteActivity()   // продлеваем сторожа: человек перебирает варианты, это не простой
        if ev.type == .keyDown {
            if ev.keyCode == 53 { stopRecording(); return }   // Esc — отмена
            restartIfFrozen()
            let mods = cg(ev.modifierFlags)
            guard HotkeyKeys.modifiersSufficient(keyCode: Int(ev.keyCode), mods: mods) else {
                warnInPanel(HotkeyGuard.needsModifierMessage(),
                            parts: HotkeyRecorderPanel.parts(mods: mods, keyLabel: KeyLabels.symbol(forKeyCode: Int(ev.keyCode))))
                return
            }
            let verdict = HotkeyGuard.verdict(keyCode: Int(ev.keyCode), mods: mods)
            if case .blocked(let busy) = verdict {
                warnInPanel(HotkeyGuard.busyMessage(busy),
                            parts: HotkeyRecorderPanel.parts(mods: mods, keyLabel: KeyLabels.symbol(forKeyCode: Int(ev.keyCode))))
                return
            }
            let kc = Int(ev.keyCode), label = KeyLabels.symbol(forKeyCode: Int(ev.keyCode))
            pendingApply = { [weak self] in
                guard let s = self?.settings else { return }
                s.voiceHotkeyMode = "key"; s.voiceHotkeyKeyCode = kc
                s.voiceHotkeyModifiers = mods.rawValue; s.voiceHotkeyKeyLabel = label
            }
            // Мягкий конфликт показываем ВМЕСТЕ с кандидатом: кнопка «Назначить» остаётся живой,
            // человек решает сам (автор 06.08).
            if case .warn(let who) = verdict {
                freeze(HotkeyRecorderPanel.parts(mods: mods, keyLabel: label), warning: HotkeyGuard.conflictMessage(who))
            } else {
                freeze(HotkeyRecorderPanel.parts(mods: mods, keyLabel: label))
            }
            return
        }
        // flagsChanged: одиночный модификатор = hold-to-talk (modkey).
        // Замороженный кандидат отпусканием не сбрасываем — иначе не донести мышь до «Назначить».
        let curMods = cg(ev.modifierFlags)
        // ⚠️ Показали отказ, а клавиши всё ещё ФИЗИЧЕСКИ зажаты. Их отпускание по одной приходит
        // сюда обычным flagsChanged, и накопитель принимает его за НАЧАЛО нового набора: в
        // кандидат уходит keyCode ОТПУСКАЕМОЙ клавиши с маской от тех, что ещё внизу. Человек
        // видит на экране «⌃», а записывается левый ⌥ с маской control: сочетание, которое не
        // сработает никогда, но при этом глотает модификатор у всей системы. Ждём чистого нуля.
        // (Найдено ревью 28.07 на сценарии «зажал ⌃⌥, нажал T, получил отказ, отпустил по одной».)
        if awaitingRelease {
            lastMods = curMods
            if curMods.isEmpty { awaitingRelease = false; resetPeaks() }
            return
        }
        if frozen, !shouldRestart(curMods) { lastMods = curMods; return }
        restartIfFrozen()
        lastMods = curMods
        if curMods.isEmpty {
            // Отпустили всё → предлагаем накопленный пик.
            if count(peak) >= 2 {
                // Комбинация модификаторов, напр. ⌥⌘. В режиме «удерживать» — зажал/разжал,
                // в «переключать» — тап. Обрабатывается в EventTap, ветка voiceHotkeyMode == "combo".
                //
                // Раньше комбинацию сюда было не ввести в принципе, поэтому и столкнуться с чужой
                // она не могла. Теперь может — а правило проекта «одна комбинация = одна функция»
                // требует не арбитраж в момент нажатия, а запрет в интерфейсе.
                if let busy = comboCollision(peak) {
                    warnInPanel(HotkeyGuard.busyMessage(busy), parts: HotkeyRecorderPanel.parts(mods: peak))
                    return
                }
                let p = peak
                pendingApply = { [weak self] in
                    guard let s = self?.settings else { return }
                    s.voiceHotkeyMode = "combo"
                    s.voiceHotkeyKeyCode = -1; s.voiceHotkeyModifiers = p.rawValue; s.voiceHotkeyKeyLabel = ""
                }
                freeze(HotkeyRecorderPanel.parts(mods: p))
            } else if count(peak) == 1, peakKey >= 0 {
                // Один модификатор (напр. правый ⌥) — прежнее поведение hold-to-talk.
                let p = peak, pk = peakKey
                pendingApply = { [weak self] in
                    guard let s = self?.settings else { return }
                    s.voiceHotkeyMode = "modkey"; s.voiceHotkeyKeyCode = pk
                    s.voiceHotkeyModifiers = p.rawValue; s.voiceHotkeyKeyLabel = ""
                }
                freeze(HotkeyRecorderPanel.parts(mods: p))
            } else { resetPeaks() }
        } else {
            if peak.isEmpty, count(curMods) == 1 { peakKey = Int(ev.keyCode) }   // ПЕРВЫЙ одиночный
            if count(curMods) >= count(peak) { peak = curMods }
            live(HotkeyRecorderPanel.parts(mods: curMods))
        }
    }

    /// keyCode физического модификатора → его CGEventFlags-маска.
    private static func flagFor(_ kc: Int) -> CGEventFlags {
        switch kc {
        case 54, 55: return .maskCommand
        case 58, 61: return .maskAlternate
        case 56, 60: return .maskShift
        case 59, 62: return .maskControl
        default: return []
        }
    }
    private func cg(_ f: NSEvent.ModifierFlags) -> CGEventFlags {
        var m: CGEventFlags = []
        if f.contains(.option) { m.insert(.maskAlternate) }
        if f.contains(.shift) { m.insert(.maskShift) }
        if f.contains(.command) { m.insert(.maskCommand) }
        if f.contains(.control) { m.insert(.maskControl) }
        return m
    }
}

/// Контрол выбора хоткея ПЕРЕВОДА (key + модификаторы, напр. ⌃⌥T). Пресеты + запись своего.
/// Перевод — это «тап» (не hold), поэтому только режим «key» (клавиша+модификаторы).
final class TranslateHotkeyControl: NSView {
    /// Копить нечего: здесь только «клавиша + модификаторы».
    private func resetPeaks() {}
    private let settings = AppSettings.shared
    private let pop = NSPopUpButton(frame: .zero, pullsDown: false)
    private var monitor: Any?
    /// Что применить, если человек нажмёт «Назначить» в окне записи. Пока nil — назначать нечего.
    private var pendingApply: (() -> Void)?
    /// Кандидат набран и ЗАМОРОЖЕН на экране: отпускание клавиш его больше не меняет.
    private var frozen = false
    /// Показали отказ, а клавиши ещё ФИЗИЧЕСКИ зажаты — ждём, пока отпустят всё. См. capture().
    private var awaitingRelease = false
    /// Предыдущий набор модификаторов — чтобы отличить «отпускает старое» от «начал новое».
    private var lastMods: CGEventFlags = []

    /// Человек начал набирать заново: модификаторы пошли вверх с нуля.
    private func shouldRestart(_ mods: CGEventFlags) -> Bool { !mods.isEmpty && lastMods.isEmpty }

    /// Сбросить замороженного кандидата перед новым набором.
    private func restartIfFrozen() {
        guard frozen else { return }
        frozen = false
        pendingApply = nil
        resetPeaks()
    }

    /// Живое отображение, пока клавиши зажаты.
    private func live(_ parts: [String]) {
        HotkeyRecorderPanel.shared.render(parts: parts, complete: false)
    }

    /// Зафиксировать набранное: остаётся на экране, кнопка «Назначить» становится активной.
    private func freeze(_ parts: [String], warning: String? = nil) {
        frozen = true
        HotkeyRecorderPanel.shared.render(parts: parts, complete: true, warning: warning)
    }

    /// Отказ БЕЗ прерывания записи: показываем причину в самом окне, человек жмёт другое сочетание.
    private func warnInPanel(_ text: String, parts: [String]) {
        frozen = false
        pendingApply = nil
        resetPeaks()
        awaitingRelease = true
        HotkeyRecorderPanel.shared.warn(text, parts: parts)
    }

    // (label, keyCode, modifiers)
    private static let presets: [(String, Int, UInt64)] = [
        ("⌃⌥T  Control+Option+T", 17, CGEventFlags([.maskControl, .maskAlternate]).rawValue),
        ("⌥T  Option+T",          17, CGEventFlags.maskAlternate.rawValue),
        ("⌃⌥E  Control+Option+E", 14, CGEventFlags([.maskControl, .maskAlternate]).rawValue),
        ("⇧⌘T  Shift+Command+T",  17, CGEventFlags([.maskShift, .maskCommand]).rawValue)
    ]

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 230, height: 26))
        pop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pop)
        NSLayoutConstraint.activate([
            pop.leadingAnchor.constraint(equalTo: leadingAnchor),
            pop.trailingAnchor.constraint(equalTo: trailingAnchor),
            pop.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 230)
        ])
        rebuild()
        pop.target = self
        pop.action = #selector(changed)
    }
    required init?(coder: NSCoder) { fatalError("no xib") }

    private func matched() -> Int? {
        Self.presets.firstIndex { (_, kc, mods) in
            kc == settings.translateHotkeyKeyCode && mods == settings.translateHotkeyModifiers
        }
    }
    private func display() -> String {
        let mods = CGEventFlags(rawValue: settings.translateHotkeyModifiers)
        var out = ""
        if mods.contains(.maskControl) { out += "⌃" }
        if mods.contains(.maskAlternate) { out += "⌥" }
        if mods.contains(.maskShift) { out += "⇧" }
        if mods.contains(.maskCommand) { out += "⌘" }
        let ks = KeyLabels.symbol(forKeyCode: settings.translateHotkeyKeyCode)   // подпись по keyCode
        out += ks.isEmpty ? "·" : ks
        return out
    }
    private func rebuild() {
        pop.removeAllItems()
        pop.addItems(withTitles: Self.presets.map { $0.0 })
        let custom = matched() == nil
        // Своя комбинация — ОТДЕЛЬНЫМ пунктом (без «карандаша»: он читался как часть сочетания,
        // особенно рядом с ⌃ — баг-репорт). Строка «Назначить свою…» остаётся ВСЕГДА
        // последней, иначе после назначения своей комбинации непонятно, куда нажать, чтобы сменить.
        if custom { pop.addItem(withTitle: display()) }
        pop.addItem(withTitle: L10n.t("hk.custom"))
        if let idx = matched() { pop.selectItem(at: idx) }
        else { pop.selectItem(at: Self.presets.count) }   // свой пункт стоит сразу за пресетами
    }
    @objc private func changed() {
        let i = pop.indexOfSelectedItem
        if i < Self.presets.count {
            let p = Self.presets[i]
            settings.translateHotkeyKeyCode = p.1
            settings.translateHotkeyModifiers = p.2
            settings.translateHotkeyKeyLabel = "T"
            if p.1 == 14 { settings.translateHotkeyKeyLabel = "E" }
            rebuild()
        } else if i == pop.numberOfItems - 1 {
            startRecording()          // последняя строка — «Назначить свою…» (есть ВСЕГДА)
        } else {
            rebuild()                 // выбрали свою уже назначенную комбинацию — менять нечего
        }
    }
    private func startRecording() {
        HotkeyRecording.begin(stop: { [weak self] in self?.stopRecording() }, in: self.window)   // tap не трогает наши хоткеи, пока пишем
        pendingApply = nil
        frozen = false; lastMods = []; awaitingRelease = false   // прошлую запись могли завершить с зажатыми модификаторами
        pop.item(at: Self.presets.count)?.title = L10n.t("hk.press")
        pop.synchronizeTitleAndSelectedItem()
        HotkeyRecorderPanel.shared.show(what: L10n.t("hkrec.what.translate"), over: self.window,
                                        onCommit: { [weak self] in self?.commitPending() },
                                        onCancel: { [weak self] in self?.stopRecording() })
        // Здесь ловим и flagsChanged — только ради живого показа зажатых модификаторов в окне.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] ev in
            self?.capture(ev); return nil
        }
    }
    private func commitPending() {
        let apply = pendingApply
        stopRecording()
        apply?()
        rebuild()
    }
    private func stopRecording() {
        HotkeyRecording.end()
        HotkeyRecorderPanel.shared.hide()
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        pendingApply = nil
        rebuild()
    }
    private func capture(_ ev: NSEvent) {
        HotkeyRecording.noteActivity()   // продлеваем сторожа: человек перебирает варианты, это не простой
        var m: CGEventFlags = []
        if ev.modifierFlags.contains(.option) { m.insert(.maskAlternate) }
        if ev.modifierFlags.contains(.shift) { m.insert(.maskShift) }
        if ev.modifierFlags.contains(.command) { m.insert(.maskCommand) }
        if ev.modifierFlags.contains(.control) { m.insert(.maskControl) }
        if ev.type == .flagsChanged {
            // ⚠️ Показали отказ, а клавиши всё ещё ФИЗИЧЕСКИ зажаты. Их отпускание по одной приходит
            // сюда обычным flagsChanged, и накопитель принимает его за НАЧАЛО нового набора: в
            // кандидат уходит keyCode ОТПУСКАЕМОЙ клавиши с маской от тех, что ещё внизу. Человек
            // видит на экране «⌃», а записывается левый ⌥ с маской control: сочетание, которое не
            // сработает никогда, но при этом глотает модификатор у всей системы. Ждём чистого нуля.
            // (Найдено ревью 28.07 на сценарии «зажал ⌃⌥, нажал T, получил отказ, отпустил по одной».)
            if awaitingRelease {
                lastMods = m
                if m.isEmpty { awaitingRelease = false; resetPeaks() }
                return
            }
            if frozen, !shouldRestart(m) { lastMods = m; return }
            restartIfFrozen()
            lastMods = m
            // ⚠️ Пустой набор НЕ рисуем: иначе отпускание модификаторов затирало бы предупреждение
            // «комбинация занята системой», и человек получал бы «нажал, ничего не произошло» —
            // то есть ровно то, ради устранения чего мы и убрали модальный алерт (ревью 28.07).
            if !m.isEmpty { live(HotkeyRecorderPanel.parts(mods: m)) }
            return
        }
        if ev.keyCode == 53 { stopRecording(); return }   // Esc — отмена
        restartIfFrozen()
        guard !m.isEmpty else {                            // нужен хотя бы один модификатор
            warnInPanel(HotkeyGuard.needsModifierMessage(),
                        parts: HotkeyRecorderPanel.parts(mods: m, keyLabel: KeyLabels.symbol(forKeyCode: Int(ev.keyCode))))
            return
        }
        let verdict = HotkeyGuard.verdict(keyCode: Int(ev.keyCode), mods: m)
        if case .blocked(let busy) = verdict {
                warnInPanel(HotkeyGuard.busyMessage(busy),
                            parts: HotkeyRecorderPanel.parts(mods: m, keyLabel: KeyLabels.symbol(forKeyCode: Int(ev.keyCode))))
                return
            }
        let kc = Int(ev.keyCode), label = KeyLabels.symbol(forKeyCode: Int(ev.keyCode))
        pendingApply = { [weak self] in
            guard let s = self?.settings else { return }
            s.translateHotkeyKeyCode = kc
            s.translateHotkeyModifiers = m.rawValue
            s.translateHotkeyKeyLabel = label
        }
        if case .warn(let who) = verdict {
            freeze(HotkeyRecorderPanel.parts(mods: m, keyLabel: label), warning: HotkeyGuard.conflictMessage(who))
        } else {
            freeze(HotkeyRecorderPanel.parts(mods: m, keyLabel: label))
        }
    }
}

/// Выбор комбинации для МГНОВЕННОГО ПЕРЕКЛЮЧЕНИЯ ЯЗЫКА (автор 24.07: «🌐 только на новых маках,
/// нужна свобода — любая комбинация»). Пресеты + запись своей, как у HotkeyControl.
///
/// Три вещи, которых здесь нельзя допустить (требование автора «без глюков и двойных срабатываний»):
///  1. Пересечение с НАШИМИ хоткеями (конверсия/диктовка/перевод) — отвергаем на этапе выбора;
///  2. Двойное срабатывание с системой — решается ГЛОТАНИЕМ события в EventTap (проверено 24.07);
///  3. Молчаливое затенение системной функции — предупреждаем текстом, что именно перестанет
///     работать (Spotlight на ⌘Space и т.п.), но НЕ запрещаем: свобода за пользователем.
final class InstantSwitchControl: NSView {
    private let settings = AppSettings.shared
    private let pop = NSPopUpButton(frame: .zero, pullsDown: false)
    private var monitor: Any?
    /// Что применить, если человек нажмёт «Назначить» в окне записи. Пока nil — назначать нечего.
    private var pendingApply: (() -> Void)?
    /// Кандидат набран и ЗАМОРОЖЕН на экране: отпускание клавиш его больше не меняет.
    private var frozen = false
    /// Показали отказ, а клавиши ещё ФИЗИЧЕСКИ зажаты — ждём, пока отпустят всё. См. capture().
    private var awaitingRelease = false
    /// Предыдущий набор модификаторов — чтобы отличить «отпускает старое» от «начал новое».
    private var lastMods: CGEventFlags = []

    /// Человек начал набирать заново: модификаторы пошли вверх с нуля.
    private func shouldRestart(_ mods: CGEventFlags) -> Bool { !mods.isEmpty && lastMods.isEmpty }

    /// Сбросить замороженного кандидата перед новым набором.
    private func restartIfFrozen() {
        guard frozen else { return }
        frozen = false
        pendingApply = nil
        resetPeaks()
    }

    /// Живое отображение, пока клавиши зажаты.
    private func live(_ parts: [String]) {
        HotkeyRecorderPanel.shared.render(parts: parts, complete: false)
    }

    /// Зафиксировать набранное: остаётся на экране, кнопка «Назначить» становится активной.
    private func freeze(_ parts: [String], warning: String? = nil) {
        frozen = true
        HotkeyRecorderPanel.shared.render(parts: parts, complete: true, warning: warning)
    }

    /// Отказ БЕЗ прерывания записи: показываем причину в самом окне, человек жмёт другое сочетание.
    private func warnInPanel(_ text: String, parts: [String]) {
        frozen = false
        pendingApply = nil
        resetPeaks()
        awaitingRelease = true
        HotkeyRecorderPanel.shared.warn(text, parts: parts)
    }
    private var peak: CGEventFlags = []
    private var peakKey: Int = -1
    private func resetPeaks() { peak = []; peakKey = -1 }
    /// Позвать после изменения — раздел настроек перерисует предупреждение под строкой.
    var onChange: (() -> Void)?

    // (лейбл, режим, keyCode, модификаторы)
    private static let presets: [(String, String, Int, UInt64)] = [
        ("🌐  Globe / Fn",        "globe",  63, 0),
        ("⌘Space",                "key",    49, CGEventFlags.maskCommand.rawValue),
        ("⌃Space",                "key",    49, CGEventFlags.maskControl.rawValue),
        ("⇪  Caps Lock",          "modkey", 57, CGEventFlags.maskAlphaShift.rawValue),
        ("⌥Space",                "key",    49, CGEventFlags.maskAlternate.rawValue),
        // Одиночный ⌃ добавлен в готовые варианты по просьбе пользователя (04.08.2026). Записать
        // его своей комбинацией было можно и раньше, но в списке его не было, а подсказка в окне
        // записи о такой возможности молчала, и человек считал, что одной клавишей нельзя.
        //
        // Почему ⌃ безопасен там, где ⇧ запрещён: Shift нажимается перед КАЖДОЙ заглавной буквой,
        // то есть тысячи раз в день, а одиночный ⌃ на маке сам по себе не делает ничего. Сочетания
        // вроде ⌃C не заденем: жест требует чистого тапа, без других клавиш между нажатием и
        // отпусканием.
        ("Left ⌃",                "modkey", 59, CGEventFlags.maskControl.rawValue),
        ("Right ⌃",               "modkey", 62, CGEventFlags.maskControl.rawValue),
    ]

    /// Что системного затеняет эта комбинация — для честного предупреждения.
    static func shadows(mode: String, keyCode: Int, mods: UInt64) -> String? {
        let f = CGEventFlags(rawValue: mods)
        if mode == "key", keyCode == 49, f.contains(.maskCommand) { return L10n.t("is.shadow.spotlight") }
        if mode == "key", keyCode == 49, f.contains(.maskControl) { return L10n.t("is.shadow.inputSrc") }
        if mode == "modkey", keyCode == 57 { return L10n.t("is.shadow.caps") }
        if mode == "globe" { return L10n.t("is.shadow.globe") }
        return nil
    }

    /// Одно и то же ли это нажатие. Сравниваем в первую очередь РЕЖИМ, а не пару (keyCode, mods).
    ///
    /// Для «голого модификатора» ключ сравнения — сама клавиша: маска из неё следует, а левый и
    /// правый ⌥ дают ОДНУ маску при разных keyCode, так что сравнение по маске здесь и слепит
    /// разные клавиши, и не различает одинаковые.
    private func sameTrigger(_ mode: String, _ keyCode: Int, _ mods: UInt64,
                             as other: (mode: String, keyCode: Int, mods: UInt64)) -> Bool {
        guard mode == other.mode else { return false }
        switch mode {
        case "globe":  return true                       // 🌐 одна на всех, сравнивать нечего
        case "modkey": return keyCode == other.keyCode
        default:       return keyCode == other.keyCode && mods == other.mods
        }
    }

    /// Занята ли комбинация нашими же хоткеями (конверсия / диктовка / перевод).
    ///
    /// ⚠️ Проверки диктовки и перевода стояли под `mode == "key"` (исправлено 28.07). То есть режим
    /// «голый модификатор» не проверялся ВООБЩЕ, а правый ⌥ (keyCode 61) — это заводская комбинация
    /// диктовки. Назначив его же на мгновенную смену языка, человек получал два действия на одно
    /// нажатие и ни одного предупреждения: правило проекта «одна комбинация = одна функция» молча
    /// не работало ровно в том случае, ради которого писалось.
    private func collides(mode: String, keyCode: Int, mods: UInt64) -> String? {
        let s = settings
        if sameTrigger(mode, keyCode, mods, as: (s.hotkeyMode, s.hotkeyKeyCode, s.hotkeyModifiers)) {
            return L10n.t("is.busy.convert")
        }
        if sameTrigger(mode, keyCode, mods, as: (s.voiceHotkeyMode, s.voiceHotkeyKeyCode, s.voiceHotkeyModifiers)) {
            return L10n.t("is.busy.voice")
        }
        // Перевод живёт только в режиме «клавиша + модификаторы», своего режима у него нет.
        if sameTrigger(mode, keyCode, mods, as: ("key", s.translateHotkeyKeyCode, s.translateHotkeyModifiers)) {
            return L10n.t("is.busy.translate")
        }
        return nil
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 230, height: 26))
        pop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pop)
        NSLayoutConstraint.activate([
            pop.leadingAnchor.constraint(equalTo: leadingAnchor),
            pop.trailingAnchor.constraint(equalTo: trailingAnchor),
            pop.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 230)
        ])
        rebuild()
        pop.target = self
        pop.action = #selector(changed)
    }
    required init?(coder: NSCoder) { fatalError("no xib") }

    private func matchedPreset() -> Int? {
        Self.presets.firstIndex { (_, mode, kc, mods) in
            mode == settings.instantSwitchMode && kc == settings.instantSwitchKeyCode
                && (mode == "globe" || mods == settings.instantSwitchMods)
        }
    }

    private func rebuild() {
        pop.removeAllItems()
        pop.addItems(withTitles: Self.presets.map { $0.0 })
        let custom = matchedPreset() == nil
        // Своя комбинация — ОТДЕЛЬНЫМ пунктом (без «карандаша»: он читался как часть сочетания,
        // особенно рядом с ⌃ — баг-репорт). Строка «Назначить свою…» остаётся ВСЕГДА
        // последней, иначе после назначения своей комбинации непонятно, куда нажать, чтобы сменить.
        if custom { pop.addItem(withTitle: instantSwitchDisplayString()) }
        pop.addItem(withTitle: L10n.t("hk.custom"))
        if let idx = matchedPreset() { pop.selectItem(at: idx) }
        else { pop.selectItem(at: Self.presets.count) }   // свой пункт стоит сразу за пресетами
    }

    @objc private func changed() {
        let i = pop.indexOfSelectedItem
        if i < Self.presets.count {
            let p = Self.presets[i]
            apply(mode: p.1, keyCode: p.2, mods: p.3, label: "")
        } else if i == pop.numberOfItems - 1 {
            startRecording()          // последняя строка — «Назначить свою…» (есть ВСЕГДА)
        } else {
            rebuild()                 // выбрали свою уже назначенную комбинацию — менять нечего
        }
    }

    /// Применить комбинацию, если она не конфликтует с нашими хоткеями.
    private func apply(mode: String, keyCode: Int, mods: UInt64, label: String) {
        if let busy = collides(mode: mode, keyCode: keyCode, mods: mods) {
            let a = NSAlert()
            a.messageText = L10n.t("is.busy.title")
            a.informativeText = String(format: L10n.t("is.busy.body"), busy)
            a.addButton(withTitle: "OK")
            a.runModal()
            rebuild()          // откатываем выбор на прежний
            return
        }
        settings.instantSwitchMode = mode
        settings.instantSwitchKeyCode = keyCode
        settings.instantSwitchMods = mods
        settings.instantSwitchKeyLabel = label
        rebuild()
        onChange?()
    }

    private func startRecording() {
        HotkeyRecording.begin(stop: { [weak self] in self?.stopRecording() }, in: self.window)   // tap не трогает наши хоткеи, пока пишем
        peak = []; peakKey = -1; pendingApply = nil
        frozen = false; lastMods = []; awaitingRelease = false   // прошлую запись могли завершить с зажатыми модификаторами
        pop.item(at: Self.presets.count)?.title = L10n.t("hk.press")
        pop.synchronizeTitleAndSelectedItem()
        HotkeyRecorderPanel.shared.show(what: L10n.t("hkrec.what.instant"), over: self.window,
                                        onCommit: { [weak self] in self?.commitPending() },
                                        onCancel: { [weak self] in self?.stopRecording() })
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] ev in
            self?.capture(ev); return nil
        }
    }
    private func commitPending() {
        let apply = pendingApply
        stopRecording()
        apply?()          // apply(mode:…) сам покажет алерт при коллизии и откатит выбор
    }
    private func stopRecording() {
        HotkeyRecording.end()
        HotkeyRecorderPanel.shared.hide()
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        pendingApply = nil
        rebuild()
    }

    private func capture(_ ev: NSEvent) {
        HotkeyRecording.noteActivity()   // продлеваем сторожа: человек перебирает варианты, это не простой
        var mods: CGEventFlags = []
        let f = ev.modifierFlags
        if f.contains(.option) { mods.insert(.maskAlternate) }
        if f.contains(.shift) { mods.insert(.maskShift) }
        if f.contains(.command) { mods.insert(.maskCommand) }
        if f.contains(.control) { mods.insert(.maskControl) }
        if f.contains(.capsLock) { mods.insert(.maskAlphaShift) }
        if ev.type == .keyDown {
            if ev.keyCode == 53 { stopRecording(); return }   // Esc — отмена записи
            restartIfFrozen()
            guard HotkeyKeys.modifiersSufficient(keyCode: Int(ev.keyCode), mods: mods) else {
                warnInPanel(HotkeyGuard.needsModifierMessage(),
                            parts: HotkeyRecorderPanel.parts(mods: mods, keyLabel: KeyLabels.symbol(forKeyCode: Int(ev.keyCode))))
                return
            }
            let verdict = HotkeyGuard.verdict(keyCode: Int(ev.keyCode), mods: mods)
            if case .blocked(let busy) = verdict {
                warnInPanel(HotkeyGuard.busyMessage(busy),
                            parts: HotkeyRecorderPanel.parts(mods: mods, keyLabel: KeyLabels.symbol(forKeyCode: Int(ev.keyCode))))
                return
            }
            let kc = Int(ev.keyCode), label = KeyLabels.symbol(forKeyCode: Int(ev.keyCode))
            // Занято НАШЕЙ же функцией — говорим об этом прямо в окне записи, не модальным алертом
            // поверх него: запись продолжается, человек тут же жмёт другое сочетание.
            if let busy = collides(mode: "key", keyCode: kc, mods: mods.rawValue) {
                warnInPanel(String(format: L10n.t("hkrec.warn.ours"), busy),
                            parts: HotkeyRecorderPanel.parts(mods: mods, keyLabel: label))
                return
            }
            pendingApply = { [weak self] in
                self?.apply(mode: "key", keyCode: kc, mods: mods.rawValue, label: label)
            }
            // Мягкий конфликт показываем ВМЕСТЕ с кандидатом: кнопка «Назначить» остаётся живой,
            // человек решает сам (автор 06.08).
            if case .warn(let who) = verdict {
                freeze(HotkeyRecorderPanel.parts(mods: mods, keyLabel: label), warning: HotkeyGuard.conflictMessage(who))
            } else {
                freeze(HotkeyRecorderPanel.parts(mods: mods, keyLabel: label))
            }
        } else {
            // ⚠️ Показали отказ, а клавиши всё ещё ФИЗИЧЕСКИ зажаты. Их отпускание по одной приходит
            // сюда обычным flagsChanged, и накопитель принимает его за НАЧАЛО нового набора: в
            // кандидат уходит keyCode ОТПУСКАЕМОЙ клавиши с маской от тех, что ещё внизу. Человек
            // видит на экране «⌃», а записывается левый ⌥ с маской control: сочетание, которое не
            // сработает никогда, но при этом глотает модификатор у всей системы. Ждём чистого нуля.
            // (Найдено ревью 28.07 на сценарии «зажал ⌃⌥, нажал T, получил отказ, отпустил по одной».)
            if awaitingRelease {
                lastMods = mods
                if mods.isEmpty { awaitingRelease = false; resetPeaks() }
                return
            }
            if frozen, !shouldRestart(mods) { lastMods = mods; return }
            restartIfFrozen()
            lastMods = mods
            if mods.isEmpty {
                if peak.rawValue != 0, peakKey >= 0 {
                    let p = peak, pk = peakKey
                    // Caps показываем его собственным символом: «⇪» понятнее пустоты.
                    let shown = pk == 57 ? ["⇪"] : HotkeyRecorderPanel.parts(mods: p)
                    // ⚠️ SHIFT НЕЛЬЗЯ (разбор 29.07, репорт #46). Shift нажимается перед КАЖДОЙ
                    // заглавной буквой, то есть тысячи раз в день, и вся защита от ложных
                    // срабатываний держится на одной улике «между нажатием и отпусканием не было
                    // обычной клавиши». Стоит этой улике потеряться — а при залипшем Secure Input
                    // macOS скрывает от нас ровно её, — и язык начинает переключаться после первой
                    // же заглавной буквы. У человека это выглядело так, что он выключил главную
                    // функцию продукта, лишь бы печатать. Запрет в интерфейсе надёжнее, чем
                    // вычищать последствия по одному месту.
                    if pk == 56 || pk == 60 {
                        warnInPanel(L10n.t("is.noShift"), parts: shown)
                        return
                    }
                    if let busy = collides(mode: "modkey", keyCode: pk, mods: p.rawValue) {
                        warnInPanel(String(format: L10n.t("hkrec.warn.ours"), busy), parts: shown)
                        return
                    }
                    pendingApply = { [weak self] in
                        self?.apply(mode: "modkey", keyCode: pk, mods: p.rawValue, label: "")
                    }
                    freeze(shown)
                } else { peak = []; peakKey = -1 }
            } else {
                if peak.isEmpty { peakKey = Int(ev.keyCode) }
                peak = mods
                live(HotkeyRecorderPanel.parts(mods: mods))
            }
        }
    }
}

/// Человекочитаемая запись текущей комбинации мгновенного переключения.
func instantSwitchDisplayString() -> String {
    let s = AppSettings.shared
    switch s.instantSwitchMode {
    case "globe":  return "🌐"
    case "modkey": return s.instantSwitchKeyCode == 57 ? "⇪" : modsPlusKey(CGEventFlags(rawValue: s.instantSwitchMods), -1)
    default:
        return modsPlusKey(CGEventFlags(rawValue: s.instantSwitchMods), s.instantSwitchKeyCode)
    }
}
