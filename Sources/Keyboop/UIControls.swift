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
enum HotkeyRecording {
    /// Идёт запись комбинации (читает EventTap; всё на main-потоке, гонки нет).
    static var active = false
    /// Аварийный сброс: окно закрыли/потеряли фокус, не сняв флаг.
    static func reset() { active = false }
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
    static func showRejected(_ what: String) {
        let a = NSAlert()
        a.messageText = "Эта комбинация занята системой"
        a.informativeText = "\(what) нужен вам самому — копирование, отмена, закрытие окна. "
            + "Добавьте ⌥ или ⌃ (например ⌃⌥T), и Keyboop не будет мешать привычным сочетаниям."
        a.addButton(withTitle: "Понятно")
        a.runModal()
    }

    /// nil — комбинация допустима; иначе текст, чем именно она занята.
    static func rejection(keyCode: Int, mods: CGEventFlags) -> String? {
        let onlyCmd = mods == .maskCommand
        if onlyCmd, let name = cmdCritical[keyCode] { return name }
        // Одиночный ⌘+любая буква — почти всегда занято приложением; просим добавить ⌥ или ⌃.
        if onlyCmd { return "⌘ + клавиша" }
        return nil
    }
}

final class HotkeyControl: NSView {
    private let settings = AppSettings.shared
    private let pop = NSPopUpButton(frame: .zero, pullsDown: false)
    private var monitor: Any?
    private var peak: CGEventFlags = []
    private var peakKey: Int = -1   // keyCode ПЕРВОГО одиночного модификатора (для modkey, напр. левый Option)

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
        HotkeyRecording.active = true   // tap не трогает наши хоткеи, пока пишем
        peak = []; peakKey = -1
        pop.item(at: Self.presets.count)?.title = L10n.t("hk.press")
        pop.synchronizeTitleAndSelectedItem()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] ev in
            self?.capture(ev)
            return nil
        }
    }
    private func stopRecording() {
        HotkeyRecording.active = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        rebuild()
    }

    private func capture(_ ev: NSEvent) {
        let mods = cg(ev.modifierFlags)
        if ev.type == .keyDown {
            if ev.keyCode == 53 { stopRecording(); return } // Esc
            if let busy = HotkeyGuard.rejection(keyCode: Int(ev.keyCode), mods: mods) {
                stopRecording(); HotkeyGuard.showRejected(busy); return
            }
            settings.hotkeyMode = "key"
            settings.hotkeyKeyCode = Int(ev.keyCode)
            settings.hotkeyModifiers = mods.rawValue
            settings.hotkeyKeyLabel = KeyLabels.symbol(forKeyCode: Int(ev.keyCode))
            stopRecording()
        } else {
            if mods.isEmpty {
                // Отпустили все модификаторы → коммитим накопленный пик.
                if count(peak) >= 2 {
                    settings.hotkeyMode = "combo"          // ⌥⇧ и т.п.
                    settings.hotkeyKeyCode = -1
                    settings.hotkeyModifiers = peak.rawValue
                    settings.hotkeyKeyLabel = ""
                    stopRecording()
                } else if count(peak) == 1, peakKey >= 0 {
                    // ОДИН модификатор (напр. левый Option) → modkey: тап по нему = переключение.
                    // Без этой ветки одиночный модификатор НЕ записывался → запись висела «бесконечно».
                    settings.hotkeyMode = "modkey"
                    settings.hotkeyKeyCode = peakKey
                    settings.hotkeyModifiers = peak.rawValue
                    settings.hotkeyKeyLabel = ""
                    stopRecording()
                } else { peak = []; peakKey = -1 }
            } else {
                if peak.isEmpty, count(mods) == 1 { peakKey = Int(ev.keyCode) }  // ПЕРВЫЙ одиночный модификатор
                if count(mods) >= count(peak) { peak = mods }
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
            cue?.stop(); cue = NSSound(data: CueSynth.switchData); cue?.volume = vol; cue?.play()
        default:
            if let t = titleOfSelectedItem {
                settings.soundName = t
                let s = NSSound(named: t); s?.volume = vol; s?.play()
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
            preview = NSSound(data: CueSynth.translateData); preview?.volume = vol; preview?.play()
        case 1:
            settings.translateSoundName = ""
        default:
            if let t = titleOfSelectedItem {
                settings.translateSoundName = t
                let s = NSSound(named: t); s?.volume = vol; s?.play()
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
    private var pendingModKey: Int = -1
    private var pendingModFlag: CGEventFlags = []

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
        HotkeyRecording.active = true   // tap не трогает наши хоткеи, пока пишем
        pendingModKey = -1; pendingModFlag = []
        pop.item(at: Self.presets.count)?.title = L10n.t("hk.press")
        pop.synchronizeTitleAndSelectedItem()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] ev in
            self?.capture(ev); return nil
        }
    }
    private func stopRecording() {
        HotkeyRecording.active = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        rebuild()
    }

    private func capture(_ ev: NSEvent) {
        if ev.type == .keyDown {
            if ev.keyCode == 53 { stopRecording(); return }   // Esc — отмена
            if let busy = HotkeyGuard.rejection(keyCode: Int(ev.keyCode), mods: cg(ev.modifierFlags)) {
                stopRecording(); HotkeyGuard.showRejected(busy); return
            }
            settings.voiceHotkeyMode = "key"
            settings.voiceHotkeyKeyCode = Int(ev.keyCode)
            settings.voiceHotkeyModifiers = cg(ev.modifierFlags).rawValue
            settings.voiceHotkeyKeyLabel = KeyLabels.symbol(forKeyCode: Int(ev.keyCode))
            stopRecording()
            return
        }
        // flagsChanged: одиночный модификатор = hold-to-talk (modkey).
        let flag = Self.flagFor(Int(ev.keyCode))
        let isDown = !flag.isEmpty && cg(ev.modifierFlags).contains(flag)
        if isDown {
            pendingModKey = Int(ev.keyCode); pendingModFlag = flag
        } else if pendingModKey == Int(ev.keyCode) {     // тот же модификатор отпущен → коммит
            settings.voiceHotkeyMode = "modkey"
            settings.voiceHotkeyKeyCode = pendingModKey
            settings.voiceHotkeyModifiers = pendingModFlag.rawValue
            settings.voiceHotkeyKeyLabel = ""
            stopRecording()
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
    private let settings = AppSettings.shared
    private let pop = NSPopUpButton(frame: .zero, pullsDown: false)
    private var monitor: Any?

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
        HotkeyRecording.active = true   // tap не трогает наши хоткеи, пока пишем
        pop.item(at: Self.presets.count)?.title = L10n.t("hk.press")
        pop.synchronizeTitleAndSelectedItem()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] ev in
            self?.capture(ev); return nil
        }
    }
    private func stopRecording() {
        HotkeyRecording.active = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        rebuild()
    }
    private func capture(_ ev: NSEvent) {
        if ev.keyCode == 53 { stopRecording(); return }   // Esc — отмена
        var m: CGEventFlags = []
        if ev.modifierFlags.contains(.option) { m.insert(.maskAlternate) }
        if ev.modifierFlags.contains(.shift) { m.insert(.maskShift) }
        if ev.modifierFlags.contains(.command) { m.insert(.maskCommand) }
        if ev.modifierFlags.contains(.control) { m.insert(.maskControl) }
        guard !m.isEmpty else { return }   // нужен хотя бы один модификатор (иначе перехватит обычную T)
        if let busy = HotkeyGuard.rejection(keyCode: Int(ev.keyCode), mods: m) {
            stopRecording(); HotkeyGuard.showRejected(busy); return
        }
        settings.translateHotkeyKeyCode = Int(ev.keyCode)
        settings.translateHotkeyModifiers = m.rawValue
        settings.translateHotkeyKeyLabel = KeyLabels.symbol(forKeyCode: Int(ev.keyCode))
        stopRecording()
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
    private var peak: CGEventFlags = []
    private var peakKey: Int = -1
    /// Позвать после изменения — раздел настроек перерисует предупреждение под строкой.
    var onChange: (() -> Void)?

    // (лейбл, режим, keyCode, модификаторы)
    private static let presets: [(String, String, Int, UInt64)] = [
        ("🌐  Globe / Fn",        "globe",  63, 0),
        ("⌘Space",                "key",    49, CGEventFlags.maskCommand.rawValue),
        ("⌃Space",                "key",    49, CGEventFlags.maskControl.rawValue),
        ("⇪  Caps Lock",          "modkey", 57, CGEventFlags.maskAlphaShift.rawValue),
        ("⌥Space",                "key",    49, CGEventFlags.maskAlternate.rawValue),
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

    /// Занята ли комбинация нашими же хоткеями (конверсия / диктовка / перевод).
    private func collides(mode: String, keyCode: Int, mods: UInt64) -> String? {
        let s = settings
        if mode == s.hotkeyMode, keyCode == s.hotkeyKeyCode, mods == s.hotkeyModifiers { return L10n.t("is.busy.convert") }
        if mode == "key", keyCode == s.voiceHotkeyKeyCode, mods == s.voiceHotkeyModifiers { return L10n.t("is.busy.voice") }
        if mode == "key", keyCode == s.translateHotkeyKeyCode, mods == s.translateHotkeyModifiers { return L10n.t("is.busy.translate") }
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
        HotkeyRecording.active = true   // tap не трогает наши хоткеи, пока пишем
        peak = []; peakKey = -1
        pop.item(at: Self.presets.count)?.title = L10n.t("hk.press")
        pop.synchronizeTitleAndSelectedItem()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] ev in
            self?.capture(ev); return nil
        }
    }
    private func stopRecording() {
        HotkeyRecording.active = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        rebuild()
    }

    private func capture(_ ev: NSEvent) {
        var mods: CGEventFlags = []
        let f = ev.modifierFlags
        if f.contains(.option) { mods.insert(.maskAlternate) }
        if f.contains(.shift) { mods.insert(.maskShift) }
        if f.contains(.command) { mods.insert(.maskCommand) }
        if f.contains(.control) { mods.insert(.maskControl) }
        if f.contains(.capsLock) { mods.insert(.maskAlphaShift) }
        if ev.type == .keyDown {
            if ev.keyCode == 53 { stopRecording(); return }   // Esc — отмена записи
            if let busy = HotkeyGuard.rejection(keyCode: Int(ev.keyCode), mods: mods) {
                stopRecording(); HotkeyGuard.showRejected(busy); return
            }
            stopRecording()
            apply(mode: "key", keyCode: Int(ev.keyCode), mods: mods.rawValue,
                  label: KeyLabels.symbol(forKeyCode: Int(ev.keyCode)))
        } else {
            if mods.isEmpty {
                if peak.rawValue != 0, peakKey >= 0 {
                    stopRecording()
                    apply(mode: "modkey", keyCode: peakKey, mods: peak.rawValue, label: "")
                } else { peak = []; peakKey = -1 }
            } else {
                if peak.isEmpty { peakKey = Int(ev.keyCode) }
                peak = mods
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
