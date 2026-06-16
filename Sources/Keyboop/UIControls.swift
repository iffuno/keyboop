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
        return "2× мод."
    }
    if s.hotkeyMode == "modkey" {
        switch s.hotkeyKeyCode {
        case 61: return "Правый ⌥"
        case 58: return "Левый ⌥"
        case 54: return "Правый ⌘"
        case 55: return "Левый ⌘"
        case 60: return "Правый ⇧"
        case 62: return "Правый ⌃"
        default: return "клавиша"
        }
    }
    let mods = CGEventFlags(rawValue: s.hotkeyModifiers)
    var out = ""
    if mods.contains(.maskControl) { out += "⌃" }
    if mods.contains(.maskAlternate) { out += "⌥" }
    if mods.contains(.maskShift) { out += "⇧" }
    if mods.contains(.maskCommand) { out += "⌘" }
    if s.hotkeyMode == "key", s.hotkeyKeyCode >= 0 { out += s.hotkeyKeyLabel.isEmpty ? "·" : s.hotkeyKeyLabel }
    return out.isEmpty ? "—" : out
}

/// Хоткей: пресеты (combo + правые модификаторы) + «Свой…».
final class HotkeyControl: NSView {
    private let settings = AppSettings.shared
    private let pop = NSPopUpButton(frame: .zero, pullsDown: false)
    private var monitor: Any?
    private var peak: CGEventFlags = []

    // (label, mode, keyCode, modifiers)
    private static let presets: [(String, String, Int, UInt64)] = [
        ("⌥⇧  Option+Shift",      "combo",  -1, CGEventFlags([.maskAlternate, .maskShift]).rawValue),
        ("⌃⌥  Control+Option",    "combo",  -1, CGEventFlags([.maskControl, .maskAlternate]).rawValue),
        ("Правый ⌥  (right Option)",  "modkey", 61, CGEventFlags.maskAlternate.rawValue),
        ("Правый ⌘  (right Command)", "modkey", 54, CGEventFlags.maskCommand.rawValue),
        ("2× ⇧  (DoubleShift)",        "doubletap", 56, CGEventFlags.maskShift.rawValue)
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

    private func matchedPreset() -> Int? {
        Self.presets.firstIndex { (_, mode, kc, mods) in
            mode == settings.hotkeyMode && (mode == "combo" ? mods == settings.hotkeyModifiers : kc == settings.hotkeyKeyCode)
        }
    }

    private func rebuild() {
        pop.removeAllItems()
        pop.addItems(withTitles: Self.presets.map { $0.0 })
        let custom = matchedPreset() == nil
        pop.addItem(withTitle: custom ? "✎  \(hotkeyDisplayString())" : L10n.t("hk.custom"))
        if let idx = matchedPreset() { pop.selectItem(at: idx) } else { pop.selectItem(at: Self.presets.count) }
    }

    @objc private func changed() {
        let i = pop.indexOfSelectedItem
        if i < Self.presets.count {
            let p = Self.presets[i]
            settings.hotkeyMode = p.1
            settings.hotkeyKeyCode = p.2
            settings.hotkeyModifiers = p.3
            settings.hotkeyKeyLabel = ""
            rebuild()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        peak = []
        pop.item(at: Self.presets.count)?.title = L10n.t("hk.press")
        pop.synchronizeTitleAndSelectedItem()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] ev in
            self?.capture(ev)
            return nil
        }
    }
    private func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        rebuild()
    }

    private func capture(_ ev: NSEvent) {
        let mods = cg(ev.modifierFlags)
        if ev.type == .keyDown {
            if ev.keyCode == 53 { stopRecording(); return } // Esc
            settings.hotkeyMode = "key"
            settings.hotkeyKeyCode = Int(ev.keyCode)
            settings.hotkeyModifiers = mods.rawValue
            settings.hotkeyKeyLabel = (ev.charactersIgnoringModifiers ?? "").uppercased()
            stopRecording()
        } else {
            if mods.isEmpty {
                if count(peak) >= 2 {
                    settings.hotkeyMode = "combo"
                    settings.hotkeyKeyCode = -1
                    settings.hotkeyModifiers = peak.rawValue
                    settings.hotkeyKeyLabel = ""
                    stopRecording()
                } else { peak = [] }
            } else if count(mods) >= count(peak) {
                peak = mods
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

    init() {
        super.init(frame: .zero, pullsDown: false)
        addItem(withTitle: L10n.t("sound.none"))
        addItems(withTitles: Self.systemSounds())
        if settings.soundName.isEmpty { selectItem(at: 0) }
        else { selectItem(withTitle: settings.soundName) }
        target = self
        action = #selector(changed)
    }
    required init?(coder: NSCoder) { fatalError("no xib") }

    @objc private func changed() {
        if indexOfSelectedItem == 0 { settings.soundName = "" }
        else if let t = titleOfSelectedItem { settings.soundName = t; NSSound(named: t)?.play() }
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
        addItem(withTitle: L10n.t("sound.keyboop"))   // index 0 → "keyboop"
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
            case 61: return "Правый ⌥"; case 58: return "Левый ⌥"
            case 54: return "Правый ⌘"; case 55: return "Левый ⌘"
            case 60: return "Правый ⇧"; case 56: return "Левый ⇧"
            case 62: return "Правый ⌃"; case 59: return "Левый ⌃"
            default: return "клавиша"
            }
        }
        let mods = CGEventFlags(rawValue: settings.voiceHotkeyModifiers)
        var out = ""
        if mods.contains(.maskControl) { out += "⌃" }
        if mods.contains(.maskAlternate) { out += "⌥" }
        if mods.contains(.maskShift) { out += "⇧" }
        if mods.contains(.maskCommand) { out += "⌘" }
        out += settings.voiceHotkeyKeyLabel.isEmpty ? "·" : settings.voiceHotkeyKeyLabel
        return out
    }

    private func rebuild() {
        pop.removeAllItems()
        pop.addItems(withTitles: Self.presets.map { $0.0 })
        let custom = matched() == nil
        pop.addItem(withTitle: custom ? "✎  \(display())" : L10n.t("hk.custom"))
        if let idx = matched() { pop.selectItem(at: idx) } else { pop.selectItem(at: Self.presets.count) }
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
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        pendingModKey = -1; pendingModFlag = []
        pop.item(at: Self.presets.count)?.title = L10n.t("hk.press")
        pop.synchronizeTitleAndSelectedItem()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] ev in
            self?.capture(ev); return nil
        }
    }
    private func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        rebuild()
    }

    private func capture(_ ev: NSEvent) {
        if ev.type == .keyDown {
            if ev.keyCode == 53 { stopRecording(); return }   // Esc — отмена
            settings.voiceHotkeyMode = "key"
            settings.voiceHotkeyKeyCode = Int(ev.keyCode)
            settings.voiceHotkeyModifiers = cg(ev.modifierFlags).rawValue
            settings.voiceHotkeyKeyLabel = (ev.charactersIgnoringModifiers ?? "").uppercased()
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
        out += settings.translateHotkeyKeyLabel.isEmpty ? "·" : settings.translateHotkeyKeyLabel
        return out
    }
    private func rebuild() {
        pop.removeAllItems()
        pop.addItems(withTitles: Self.presets.map { $0.0 })
        let custom = matched() == nil
        pop.addItem(withTitle: custom ? "✎  \(display())" : L10n.t("hk.custom"))
        if let idx = matched() { pop.selectItem(at: idx) } else { pop.selectItem(at: Self.presets.count) }
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
        } else {
            startRecording()
        }
    }
    private func startRecording() {
        pop.item(at: Self.presets.count)?.title = L10n.t("hk.press")
        pop.synchronizeTitleAndSelectedItem()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] ev in
            self?.capture(ev); return nil
        }
    }
    private func stopRecording() {
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
        settings.translateHotkeyKeyCode = Int(ev.keyCode)
        settings.translateHotkeyModifiers = m.rawValue
        settings.translateHotkeyKeyLabel = (ev.charactersIgnoringModifiers ?? "").uppercased()
        stopRecording()
    }
}
