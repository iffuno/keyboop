// СТЕНД: ЧТО ИЗ НАШЕГО ПИСЬМА ПЕРЕЖИВАЕТ ЧУЖОЙ SECURE INPUT.
//
// # Зачем он понадобился
//
// Три отзыва подряд (#163, #166, #169) про одно: «не работает», «не вставляется диктовка»,
// «не вылезает из приватного режима». Общий корень — Secure Input, поднятый ЧУЖОЙ программой
// (Ghostty держал 34 минуты, Telegram не отпускал, loginwindow не отпустил никогда), а мы под
// этим флагом отказываемся писать вообще где-либо.
//
// Отказ завели не зря: 23.07.2026 диалог пароля украл фокус в конце диктовки, и текст ушёл бы
// в невидимое поле, а Backspace или Return могли подтвердить чужой запрос авторизации. Но правило
// вышло шире причины: оно молчит и тогда, когда флаг держит фоновая программа, а человек печатает
// в обычное поле в Заметках.
//
// # Почему это нельзя решить чтением документации
//
// Apple TN2150 перечисляет три механизма, которые Secure Input отключает: захват HID, event tap
// и GetKeys. Все три про ЧТЕНИЕ. Про запрет вбрасывать события там нет ничего — но это ОПРЕДЕЛЕНИЕ
// термина «keyboard intercept process», а не исчерпывающий список последствий, и делать из
// умолчания разрешение нельзя. Практика (Force Paste печатает в диалоги пароля с 2013 года,
// Alfred-воркфлоу SecureInputPaste, мейнтейнер espanso) говорит, что запись доходит, но это
// чужая практика на чужих версиях macOS.
//
// Поэтому спрашиваем систему сами, на этой машине и на этой macOS.
//
// # Устройство
//
// Флаг поднимает ОТДЕЛЬНЫЙ процесс (`Tools/SecureInputHolder.swift`), а пишем мы. Так честно
// воспроизводится случай из отзывов. Если бы флаг поднимали сами, проверялся бы противоположный
// случай — «держатель и есть тот, кто пишет», то есть поле пароля, где молчать правильно.
//
// ⚠️ КОНТРОЛЬНЫЙ ЗАМЕР ОБЯЗАТЕЛЕН И ИДЁТ ПЕРВЫМ. Постинг событий требует Accessibility, и если
// его нет, все три способа провалятся — но провалятся по ДРУГОЙ причине. Стенд, который спутает
// «запрещено Secure Input» с «нет прав», хуже отсутствующего: он даст ложный зелёный свет или
// ложный красный. Поэтому сперва меряем при выключенном флаге, и если там не прошло — стенд
// честно говорит «неубедительно» и не делает вывода вовсе.
import AppKit
import ApplicationServices
import Carbon

enum SecureInputProbe {

    private final class Box {
        let window: NSWindow
        let field: NSTextField
        init() {
            field = NSTextField(frame: NSRect(x: 20, y: 20, width: 460, height: 44))
            field.font = .systemFont(ofSize: 18)
            field.placeholderString = "сюда пишет стенд"
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 84),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "Проба Secure Input"
            window.contentView?.addSubview(field)
            window.center()
        }
    }

    private struct Trial {
        let name: String
        let secure: Bool
        var landed: Bool = false
        var got: String = ""
    }

    static func run(holder: String?) {
        let box = Box()
        NSApp.setActivationPolicy(.regular)          // агенту без этого не дают ключевое окно
        NSApp.activate(ignoringOtherApps: true)
        box.window.makeKeyAndOrderFront(nil)
        box.window.makeFirstResponder(box.field)

        DispatchQueue.global(qos: .userInitiated).async {
            Thread.sleep(forTimeInterval: 0.8)       // окно должно реально получить фокус
            var trials: [Trial] = []

            // ── Контроль: флаг выключен ───────────────────────────────────────────────
            for (name, act) in methods {
                trials.append(measure(name: name, secure: false, box: box, act: act))
            }
            let controlOK = trials.filter { $0.landed }.count

            // ── Опыт: флаг держит чужой процесс ───────────────────────────────────────
            var holderProc: Process?
            if let holder {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: holder)
                p.arguments = ["8"]
                try? p.run()
                holderProc = p
                // Ждём ФАКТА подъёма флага, а не по таймеру: процесс стартует не мгновенно.
                var waited = 0.0
                while !IsSecureEventInputEnabled(), waited < 3.0 {
                    Thread.sleep(forTimeInterval: 0.1); waited += 0.1
                }
            }
            let secureUp = IsSecureEventInputEnabled()
            if secureUp {
                for (name, act) in methods {
                    trials.append(measure(name: name, secure: true, box: box, act: act))
                }
            }
            holderProc?.terminate()

            report(trials: trials, controlOK: controlOK, methodCount: methods.count, secureUp: secureUp)

            // ⚠️ ПРОВЕРЯЕМ САМО РЕШЕНИЕ, А НЕ ЕГО ЗАМЕНИТЕЛЬ. Выше мы мерили, доходит ли запись
            // физически. Но людям поедет не физика, а `SecureInputPolicy`, и стенд обязан спросить
            // именно её — иначе мы проверим одно, а выпустим другое.
            if secureUp {
                kbLog("проба политики: под чужим флагом в обычном поле canWrite=\(SecureInputPolicy.canWrite("проба"))")
            }

            // ── Вторая половина стенда: доходит ли ТРИГГЕР ────────────────────────────
            // Запись мы уже проверили. Но диктовку надо ещё чем-то запустить, а наш
            // единственный источник событий это тап, который под флагом слеп. Есть сходящиеся
            // косвенные данные, что Carbon RegisterEventHotKey работает сквозь Secure Input:
            // матч идёт внутри WindowServer, а не в «перехватчике» по терминологии TN2150.
            // Проверяем сами.
            probeSecureField()
            if ProcessInfo.processInfo.environment["KEYBOOP_SECUREPROBE"] == "manual" {
                probeHotkeyManual(holder: holder)
            } else {
                probeHotkey(holder: holder)
            }
            DispatchQueue.main.async {
                box.window.close()
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    // MARK: - Способы записи

    /// Три пути, которыми мы вообще умеем писать. Проверяем каждый отдельно: у них разные
    /// механизмы, и запрет на один ничего не говорит про другие.
    private static let methods: [(String, (String) -> Void)] = [
        ("печать Unicode (CGEventPost)", typeUnicode),
        ("вставка из буфера (⌘V)", pasteViaClipboard),
        ("запись через Accessibility", writeViaAX),
    ]

    private static func typeUnicode(_ text: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        var chars = Array(text.utf16)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { return }
        down.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
        up.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    private static func pasteViaClipboard(_ text: String) {
        // Буфер святой даже в стенде: снимок до, восстановление после (принцип №1).
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data] in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let v = item.data(forType: t) { d[t] = v } }
            return d
        }
        pb.clearContents()
        pb.setString(text, forType: .string)

        let src = CGEventSource(stateID: .hidSystemState)
        let vKey: CGKeyCode = 9                       // kVK_ANSI_V
        if let d = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true),
           let u = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false) {
            d.flags = .maskCommand; u.flags = .maskCommand
            d.post(tap: .cgSessionEventTap); u.post(tap: .cgSessionEventTap)
        }
        Thread.sleep(forTimeInterval: 0.35)
        pb.clearContents()
        for item in saved ?? [] {
            let it = NSPasteboardItem()
            for (t, v) in item { it.setData(v, forType: t) }
            pb.writeObjects([it])
        }
    }

    /// ⚠️ СТРОГО ЧЕРЕЗ main, И СТРОГО async. Обращение к элементу СВОЕГО процесса Accessibility
    /// обслуживает без IPC, прямо на вызывающем потоке, поэтому с фоновой очереди мы мутировали
    /// NSTextView не на главном и получили assert HIToolbox (падение при первом же прогоне,
    /// 24.08.2026: `_dispatch_assert_queue_fail` из `TSMInvalidateClientGeometry`). А `sync`
    /// сюда нельзя: обработчик сам ждёт главную очередь, и мы бы встали намертво.
    private static func writeViaAX(_ text: String) {
        DispatchQueue.main.async {
            let sys = AXUIElementCreateSystemWide()
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
                  let elem = focused, CFGetTypeID(elem) == AXUIElementGetTypeID() else { return }
            AXUIElementSetAttributeValue(elem as! AXUIElement, kAXValueAttribute as CFString, text as CFTypeRef)
        }
    }

    // MARK: - Замер

    private static func measure(name: String, secure: Bool, box: Box, act: (String) -> Void) -> Trial {
        let mark = secure ? "проба-под-флагом" : "проба-контроль"
        DispatchQueue.main.sync { box.field.stringValue = "" }
        act(mark)
        Thread.sleep(forTimeInterval: 0.45)
        let got = DispatchQueue.main.sync { box.field.stringValue }
        var t = Trial(name: name, secure: secure)
        t.got = got
        t.landed = got.contains(mark)
        return t
    }

    private static func report(trials: [Trial], controlOK: Int, methodCount: Int, secureUp: Bool) {
        var out = ["", "──── ПРОБА SECURE INPUT ────"]
        for t in trials {
            out.append("  \(t.secure ? "под флагом " : "контроль   ") · \(t.landed ? "ДОШЛО " : "не дошло") · \(t.name)"
                       + (t.landed ? "" : "  (в поле: «\(t.got)»)"))
        }
        if controlOK == 0 {
            out.append("")
            out.append("  ВЫВОД: НЕУБЕДИТЕЛЬНО. Контроль не прошёл ни одним способом — значит дело не в")
            out.append("  Secure Input, а в правах на постинг событий (Accessibility) или в фокусе окна.")
            out.append("  Судить о флаге по этому запуску нельзя.")
        } else if !secureUp {
            out.append("")
            out.append("  ВЫВОД: НЕУБЕДИТЕЛЬНО. Флаг поднять не удалось — холдер не запустился.")
        } else {
            let secured = trials.filter { $0.secure }
            let passed = secured.filter { $0.landed }.map { $0.name }
            let failed = secured.filter { !$0.landed }.map { $0.name }
            out.append("")
            out.append("  контроль прошёл способами: \(controlOK) из \(methodCount)")
            out.append("  ПОД ЧУЖИМ SECURE INPUT доходит: \(passed.isEmpty ? "ничего" : passed.joined(separator: ", "))")
            out.append("  ПОД ЧУЖИМ SECURE INPUT не доходит: \(failed.isEmpty ? "ничего" : failed.joined(separator: ", "))")
        }
        out.append("────────────────────────────")
        let text = out.joined(separator: "\n")
        print(text)
        kbLog("проба secure input:\n" + text)
        try? text.write(toFile: "/tmp/kb_secureprobe.txt", atomically: true, encoding: .utf8)
    }

    // MARK: - Триггер: доходит ли Carbon-хоткей сквозь Secure Input

    private static var carbonFired = 0
    private static var tapSaw = 0
    private static var hotKeyRef: EventHotKeyRef?
    private static var handlerRef: EventHandlerRef?
    private static var probeTap: CFMachPort?

    /// ⚠️ ВСТРОЕННЫЙ КОНТРОЛЬ ДОСТОВЕРНОСТИ, И БЕЗ НЕГО ОПЫТ НЕ СТОИТ НИЧЕГО.
    ///
    /// Нажать клавишу физически стенд не может, поэтому шлёт синтетику. Но синтетика вбрасывается
    /// НЕ там, где рождается настоящее нажатие, и вполне могла бы миновать тот самый фильтр,
    /// который мы изучаем. Тогда «Carbon сработал» означало бы только «синтетику не фильтруют»,
    /// и мы бы приняли артефакт за открытие.
    ///
    /// Поэтому тем же нажатием проверяем ВТОРОЕ: видит ли его обычный CGEventTap. Про тап мы
    /// твёрдо знаем, что под флагом он слепнет (это и есть наш симптом). Значит:
    ///   • тап ослеп, Carbon сработал  → синтетика фильтруется как настоящая, вывод чистый;
    ///   • тап всё видит               → синтетика идёт мимо фильтра, опыт НЕУБЕДИТЕЛЕН.
    /// Второй исход честнее записать, чем замолчать.
    private static func probeHotkey(holder: String?) {
        let keyCode: UInt32 = 113                     // F15 — на клавиатуре её нет, чужого не заденем
        let mods: UInt32 = UInt32(controlKey | optionKey | shiftKey)

        DispatchQueue.main.sync { installHotkey(keyCode: keyCode, mods: mods) }
        installProbeTap(keyCode: CGKeyCode(keyCode))
        defer {
            DispatchQueue.main.sync { removeHotkey() }
            removeProbeTap()
        }

        func trial(_ label: String) -> (carbon: Bool, tap: Bool) {
            carbonFired = 0; tapSaw = 0
            postCombo(keyCode: CGKeyCode(keyCode))
            Thread.sleep(forTimeInterval: 0.6)        // Carbon приходит через главный runloop
            return (carbonFired > 0, tapSaw > 0)
        }

        let control = trial("контроль")

        var holderProc: Process?
        if let holder {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: holder)
            p.arguments = ["6"]
            try? p.run()
            holderProc = p
            var waited = 0.0
            while !IsSecureEventInputEnabled(), waited < 3.0 { Thread.sleep(forTimeInterval: 0.1); waited += 0.1 }
        }
        let up = IsSecureEventInputEnabled()
        let secure = up ? trial("под флагом") : (carbon: false, tap: false)
        holderProc?.terminate()

        var out = ["", "──── ПРОБА ТРИГГЕРА (Carbon-хоткей против тапа) ────"]
        out.append("  контроль    · Carbon: \(control.carbon ? "СРАБОТАЛ" : "молчит") · тап: \(control.tap ? "видит" : "слеп")")
        if up {
            out.append("  под флагом  · Carbon: \(secure.carbon ? "СРАБОТАЛ" : "молчит") · тап: \(secure.tap ? "видит" : "слеп")")
        } else {
            out.append("  под флагом  · не проверено: флаг поднять не удалось")
        }
        out.append("")
        if !control.carbon {
            out.append("  ВЫВОД: НЕУБЕДИТЕЛЬНО — хоткей не сработал даже без флага (не зарегистрировался?).")
        } else if !up {
            out.append("  ВЫВОД: НЕУБЕДИТЕЛЬНО — холдер не поднял флаг.")
        } else if secure.tap {
            out.append("  ВЫВОД: НЕУБЕДИТЕЛЬНО — под флагом тап ПРОДОЛЖАЕТ видеть нажатие, значит")
            out.append("  синтетика идёт мимо изучаемого фильтра, и про настоящую клавишу опыт молчит.")
        } else if secure.carbon {
            out.append("  ВЫВОД: Carbon-хоткей РАБОТАЕТ сквозь Secure Input — тап ослеп, хоткей сработал.")
            out.append("  Значит триггер диктовки можно продублировать Carbon-ом и не терять его при залипании.")
        } else {
            out.append("  ВЫВОД: под Secure Input замолкают ОБА пути — и тап, и Carbon-хоткей.")
        }
        out.append("──────────────────────────────────────────────────")
        let text = out.joined(separator: "\n")
        print(text)
        kbLog("проба триггера:\n" + text)
        if let old = try? String(contentsOfFile: "/tmp/kb_secureprobe.txt", encoding: .utf8) {
            try? (old + text).write(toFile: "/tmp/kb_secureprobe.txt", atomically: true, encoding: .utf8)
        }
    }

    /// ⚠️ СТАТУСЫ ОБЕИХ РЕГИСТРАЦИЙ ПИШЕМ В ЛОГ. Первый прогон дал «Carbon молчит даже без флага»,
    /// и без кодов возврата это неотличимо от «сработало, но событие не дошло» — то есть стенд
    /// назвал бы неубедительным то, что на самом деле просто не зарегистрировалось.
    private static func installHotkey(keyCode: UInt32, mods: UInt32) {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let hs = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            SecureInputProbe.carbonFired += 1
            return noErr
        }, 1, &spec, nil, &handlerRef)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4B_42_4F_50), id: 1)   // 'KBOP'
        let rs = RegisterEventHotKey(keyCode, mods, id, GetApplicationEventTarget(), 0, &ref)
        hotKeyRef = ref
        kbLog("проба триггера: InstallEventHandler=\(hs) RegisterEventHotKey=\(rs) ref=\(ref != nil ? "есть" : "НЕТ")")
    }

    private static func removeHotkey() {
        if let h = hotKeyRef { UnregisterEventHotKey(h); hotKeyRef = nil }
        if let h = handlerRef { RemoveEventHandler(h); handlerRef = nil }
    }

    /// Собственный слушающий тап — эталон «что видно обычному перехватчику».
    private static func installProbeTap(keyCode: CGKeyCode) {
        let mask = (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: CGEventMask(mask),
                                          callback: { _, _, event, _ in
                                              if event.getIntegerValueField(.keyboardEventKeycode) == 113 {
                                                  SecureInputProbe.tapSaw += 1
                                              }
                                              return Unmanaged.passUnretained(event)
                                          }, userInfo: nil) else { return }
        probeTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private static func removeProbeTap() {
        if let t = probeTap { CGEvent.tapEnable(tap: t, enable: false); probeTap = nil }
    }

    private static func postCombo(keyCode: CGKeyCode) {
        let src = CGEventSource(stateID: .hidSystemState)
        let flags: CGEventFlags = [.maskControl, .maskAlternate, .maskShift]
        guard let d = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let u = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) else { return }
        d.flags = flags; u.flags = flags
        // ⚠️ ИМЕННО .cghidEventTap, а не сессионный. Матч Carbon-хоткея происходит ниже по
        // конвейеру, и событие, вброшенное на уровне сессии, может пройти мимо него — первый
        // прогон дал ровно это: тап нажатие видел, а хоткей молчал.
        d.post(tap: .cghidEventTap)
        u.post(tap: .cghidEventTap)
    }

    // MARK: - Живое нажатие: единственный честный способ проверить хоткей

    /// ⚠️ СИНТЕТИКОЙ CARBON-ХОТКЕЙ НЕ ПРОВЕРИТЬ, ЭТО ИЗМЕРЕНО, А НЕ ПРЕДПОЛОЖЕНО.
    ///
    /// Автоматический вариант выше шлёт событие сам, и хоткей молчал ДАЖЕ БЕЗ ФЛАГА, при том что
    /// обе регистрации вернули noErr и ref был получен, а наш тап то же самое нажатие видел. Значит
    /// матч Carbon-хоткея делается не над потоком CGEvent, и вброшенное событие до него не доходит
    /// ни на сессионном уровне, ни на .cghidEventTap.
    ///
    /// Вывод для будущих стендов: хоткеи вообще нельзя проверять синтетикой — она отвечает на
    /// другой вопрос. Нужен живой палец, поэтому здесь человек нажимает сам, дважды: один раз без
    /// флага (контроль, доказывает что регистрация жива) и один раз под флагом (собственно опыт).
    private static func probeHotkeyManual(holder: String?) {
        let keyCode: UInt32 = 40                      // 'k'
        let mods: UInt32 = UInt32(controlKey | optionKey | shiftKey)

        // ⚠️ ОКНО СТРОИТСЯ СТРОГО НА ГЛАВНОМ ПОТОКЕ. Мы внутри фоновой очереди, а `NSWindow.init`
        // с чужого потока бросает исключение и роняет приложение — поймано ровно здесь 24.08.2026
        // (`-[NSWindow _initContent:styleMask:backing:defer:contentView:]` в трассе). В `run()`
        // окно создаётся до ухода в фон и потому работало, а этот второй экран я построил на месте.
        var label: NSTextField!
        var win: NSWindow!
        DispatchQueue.main.sync {
            let l = NSTextField(labelWithString: "")
            l.font = .systemFont(ofSize: 17, weight: .medium)
            l.alignment = .center
            l.frame = NSRect(x: 20, y: 24, width: 520, height: 60)
            l.maximumNumberOfLines = 3
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 108),
                             styleMask: [.titled], backing: .buffered, defer: false)
            w.title = "Проба триггера"
            w.level = .floating                        // поверх всего: человек должен её видеть
            w.contentView?.addSubview(l)
            w.center()
            label = l; win = w
        }

        func say(_ t: String) { DispatchQueue.main.async { label.stringValue = t; win.makeKeyAndOrderFront(nil) } }

        DispatchQueue.main.sync { installHotkey(keyCode: keyCode, mods: mods) }
        installProbeTap(keyCode: CGKeyCode(keyCode))
        defer {
            DispatchQueue.main.sync { removeHotkey(); win.close() }
            removeProbeTap()
        }

        /// Ждём живого нажатия до `limit` секунд. Возвращаем, что успело сработать.
        func waitPress(_ limit: Double) -> (carbon: Bool, tap: Bool) {
            carbonFired = 0; tapSaw = 0
            var t = 0.0
            while t < limit, carbonFired == 0, tapSaw == 0 { Thread.sleep(forTimeInterval: 0.1); t += 0.1 }
            Thread.sleep(forTimeInterval: 0.3)         // добираем второй путь, если он чуть медленнее
            return (carbonFired > 0, tapSaw > 0)
        }

        say("Шаг 1 из 2, контроль.\nНажми ⌃⌥⇧K — обычным пальцем, флага пока нет.")
        let control = waitPress(60)

        var holderProc: Process?
        if let holder {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: holder)
            p.arguments = ["75"]
            try? p.run()
            holderProc = p
            var w = 0.0
            while !IsSecureEventInputEnabled(), w < 3.0 { Thread.sleep(forTimeInterval: 0.1); w += 0.1 }
        }
        let up = IsSecureEventInputEnabled()
        say(up ? "Шаг 2 из 2, флаг поднят.\nНажми ⌃⌥⇧K ещё раз."
               : "Флаг поднять не удалось. Закрываю.")
        let secure = up ? waitPress(60) : (carbon: false, tap: false)
        holderProc?.terminate()

        var out = ["", "──── ПРОБА ТРИГГЕРА (живое нажатие) ────"]
        out.append("  контроль    · Carbon: \(control.carbon ? "СРАБОТАЛ" : "молчит") · тап: \(control.tap ? "видит" : "слеп")")
        out.append("  под флагом  · Carbon: \(secure.carbon ? "СРАБОТАЛ" : "молчит") · тап: \(secure.tap ? "видит" : "слеп")")
        out.append("")
        if !control.carbon && !control.tap {
            out.append("  ВЫВОД: НЕУБЕДИТЕЛЬНО — на контроле не сработало ничего. Похоже, клавишу не нажали.")
        } else if !control.carbon {
            out.append("  ВЫВОД: НЕУБЕДИТЕЛЬНО — Carbon молчит даже без флага, регистрация не работает.")
        } else if !up {
            out.append("  ВЫВОД: НЕУБЕДИТЕЛЬНО — флаг поднять не удалось.")
        } else if secure.carbon && !secure.tap {
            out.append("  ВЫВОД: Carbon-хоткей ПРОБИВАЕТ Secure Input. Тап ослеп, хоткей сработал —")
            out.append("  значит триггер диктовки можно продублировать Carbon-ом, и при залипшем флаге")
            out.append("  человек хотя бы сможет надиктовать и вставить.")
        } else if secure.carbon && secure.tap {
            out.append("  ВЫВОД: Carbon сработал, но и тап всё видит — флаг, похоже, не действовал.")
        } else {
            out.append("  ВЫВОД: под Secure Input замолкают ОБА пути. Дублировать хоткей Carbon-ом смысла нет.")
        }
        out.append("─────────────────────────────────────────")
        let text = out.joined(separator: "\n")
        print(text)
        kbLog("проба триггера (живое):\n" + text)
        try? text.write(toFile: "/tmp/kb_secureprobe_hotkey.txt", atomically: true, encoding: .utf8)
    }

    // MARK: - Настоящее поле пароля: годится ли AX как сигнал, и что в него доходит

    /// Проверяем ФУНДАМЕНТ предлагаемой починки, а не саму починку.
    ///
    /// План был такой: перестать судить по глобальному флагу (он врёт про держателя) и судить по
    /// самому полю — если под кареткой `AXSecureTextField`, молчим, иначе пишем. Прежде чем это
    /// строить, надо убедиться в трёх вещах, и все три меряются без человека:
    ///   1. фокус в NSSecureTextField сам поднимает Secure Input (тогда глобальный флаг в нативе
    ///      И ЕСТЬ пофайловый признак, и городить AX незачем);
    ///   2. Accessibility честно называет такое поле `AXSecureTextField`;
    ///   3. что из наших трёх способов записи туда реально доходит.
    /// Поле здесь наше собственное и пустое, никаких чужих паролей опыт не касается.
    private static func probeSecureField() {
        var field: NSSecureTextField!
        var win: NSWindow!
        DispatchQueue.main.sync {
            let f = NSSecureTextField(frame: NSRect(x: 20, y: 20, width: 460, height: 44))
            f.font = .systemFont(ofSize: 18)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 84),
                             styleMask: [.titled], backing: .buffered, defer: false)
            w.title = "Проба: поле пароля"
            w.contentView?.addSubview(f)
            w.center()
            field = f; win = w
        }

        let before = IsSecureEventInputEnabled()
        DispatchQueue.main.sync {
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            win.makeFirstResponder(field)
        }
        Thread.sleep(forTimeInterval: 1.0)
        let after = IsSecureEventInputEnabled()

        // Что говорит Accessibility про сфокусированный элемент
        var role = "?", subrole = "?"
        DispatchQueue.main.sync {
            let sys = AXUIElementCreateSystemWide()
            var focused: CFTypeRef?
            if AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
               let el = focused, CFGetTypeID(el) == AXUIElementGetTypeID() {
                let e = el as! AXUIElement
                var r: CFTypeRef?, sr: CFTypeRef?
                if AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &r) == .success { role = (r as? String) ?? "?" }
                if AXUIElementCopyAttributeValue(e, kAXSubroleAttribute as CFString, &sr) == .success { subrole = (sr as? String) ?? "—" }
            }
        }

        // ⚠️ ВЕРДИКТ СНИМАЕМ, ПОКА ПОЛЕ ЕЩЁ В ФОКУСЕ. Первый прогон спрашивал политику ПОСЛЕ
        // закрытия окна и получил `ordinary` — стенд честно закричал «дыра», но дыра была в нём
        // самом. Ровно тот случай, когда проверка расходится с боевым кодом: чинить надо сперва
        // проверку.
        let verdict = SecureInputPolicy.focusedFieldVerdict()
        let allowed = SecureInputPolicy.canWrite("проба поля пароля")

        var landed: [String] = [], blocked: [String] = []
        for (name, act) in methods {
            DispatchQueue.main.sync { field.stringValue = "" }
            act("пробаПароль")
            Thread.sleep(forTimeInterval: 0.5)
            let got = DispatchQueue.main.sync { field.stringValue }
            (got.contains("пробаПароль") ? { landed.append(name) } : { blocked.append(name) })()
        }

        DispatchQueue.main.sync { win.close() }

        var out = ["", "──── ПРОБА: НАСТОЯЩЕЕ ПОЛЕ ПАРОЛЯ ────"]
        out.append("  Secure Input до фокуса: \(before ? "включён" : "выключен") · после фокуса: \(after ? "ВКЛЮЧЁН САМ" : "остался выключен")")
        out.append("  Accessibility про это поле: role=\(role) subrole=\(subrole)")
        out.append("  РЕШЕНИЕ ПОЛИТИКИ: вердикт=\(verdict) canWrite=\(allowed)\(allowed ? "  ⚠️ ЭТО ДЫРА" : "  ✓ молчим, как надо")")
        out.append("  доходит в поле пароля: \(landed.isEmpty ? "ничего" : landed.joined(separator: ", "))")
        out.append("  НЕ доходит: \(blocked.isEmpty ? "ничего" : blocked.joined(separator: ", "))")
        out.append("")
        if after && !before {
            out.append("  ВЫВОД 1: фокус в поле пароля сам поднимает флаг — значит в нативных полях")
            out.append("  глобальный флаг И ЕСТЬ признак «передо мной пароль», отдельный сигнал не нужен.")
        }
        if subrole == "AXSecureTextField" {
            out.append("  ВЫВОД 2: Accessibility честно называет поле AXSecureTextField — сигнал годный.")
        } else {
            out.append("  ВЫВОД 2: AX вернул subrole=\(subrole) — на этот сигнал опираться нельзя.")
        }
        out.append("────────────────────────────────────")
        let text = out.joined(separator: "\n")
        print(text)
        kbLog("проба поля пароля:\n" + text)
        try? text.write(toFile: "/tmp/kb_secureprobe_field.txt", atomically: true, encoding: .utf8)
    }
}
