import Foundation
import CoreGraphics
import AppKit
import QuartzCore

protocol EventTapHandler: AnyObject {
    func handleKeyDown(keyCode: Int64, characters: String, flags: CGEventFlags)
    func handleSwitchHotkey()
    func handleContextReset()
    func handleVoiceBegin()
    func handleVoiceEnd()
    func handleTranslateHotkey()
}

/// Глобальный наблюдатель клавиатуры (CGEventTap, АКТИВНЫЙ `.defaultTap` — нужен Accessibility,
/// НЕ listen-only/Input Monitoring) + настраиваемый хоткей. Active-tap обязателен, чтобы ГЛОТАТЬ
/// хоткеи (диктовка/перевод), иначе их клавиши печатаются.
/// Три режима: combo (⌥⇧), modkey (одна клавиша-модификатор — правый ⌥/⌘ и т.п.), key (клавиша+модификаторы).
final class EventTap {
    weak var handler: EventTapHandler?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var mouseMonitor: Any?

    private var comboArmed = false
    private var otherKeyDuringCombo = false
    private var modkeyArmed = false
    private var lastModTap: CFTimeInterval = 0
    private var otherKeyBetweenTaps = false
    private var voiceActive = false
    private var voiceKeyArmed = false
    private var lastVoiceToggle: TimeInterval = 0   // debounce toggle (не зависит от keyUp)

    func start() -> Bool {
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            if CGEvent.tapIsEnabled(tap: tap) { return true }
            // «non-nil tap is not a healthy tap»: enable не оживил порт (система его прибила
            // и не пере-enable'нула) → сносим и пересоздаём ниже. Иначе вернули бы true для мёртвого.
            teardown()
        }
        // .defaultTap (active, не listen-only): нужен, чтобы ГЛОТАТЬ voice/перевод-хоткеи, иначе их
        // клавиши печатаются. Глотаем ТОЛЬКО эти события, всё остальное проходит насквозь.
        // ВАЖНО: возврат tapCreate — это ЖИВОЙ детектор доступа: не-nil ровно тогда, когда
        // Accessibility реально выдан СЕЙЧАС (без TCC-кэша, в отличие от залипающего AXIsProcessTrusted).
        let mask = bit(.keyDown) | bit(.flagsChanged) | bit(.keyUp)
        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = newTap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        // mouseMonitor ставим один раз (переживает пересоздание tap).
        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] _ in self?.handler?.handleContextReset() }
        }
        return true
    }

    /// Снести невалидный порт перед пересозданием (mouseMonitor НЕ трогаем — он независим).
    private func teardown() {
        if let s = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), s, .commonModes) }
        runLoopSource = nil
        tap = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // НАША СИНТЕТИКА (Backspace+Unicode из TextReplacer) помечена маркером в .eventSourceUserData.
        // Пропускаем её НАСКВОЗЬ, не трогая буфер/хоткей-состояние. Это надёжная замена временно́му
        // фильтру muted: реальный ввод пользователя теперь НИКОГДА не глотается (даже во время нашей
        // конверсии) → буфер не рассинхронивается с экраном (аудит 15.06, корни №1/№2).
        if (type == .keyDown || type == .keyUp),
           event.getIntegerValueField(.eventSourceUserData) == kbSyntheticMarker {
            return Unmanaged.passUnretained(event)
        }
        let s = AppSettings.shared
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            // Escape во время диктовки — отмена (если включено). Глотаем Esc, чтобы он не
            // улетел в активное приложение.
            if keyCode == 53, s.escCancelsDictation, VoiceController.shared.isRecording {
                VoiceController.shared.cancel()
                if s.voiceHoldMode == "toggle" { voiceKeyArmed = false } else { voiceActive = false }
                return nil
            }
            // Voice hold-хоткей (диктовка) — перехватываем и ГЛОТАЕМ (вкл. autorepeat),
            // чтобы клавиша (⌥`) не печаталась во время записи.
            if isVoiceHotkey(keyCode, event.flags) {
                // autorepeat зажатой клавиши НЕ должен дёргать toggle (иначе держишь хоткей чуть
                // дольше → повтор делает СТОП сразу после старта → запись отменяется как короткая,
                // «ничего не произошло» — баг 1-к-8). Реагируем только на ПЕРВОЕ нажатие.
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if !isRepeat {
                    if s.voiceHoldMode == "toggle" {
                        // Debounce по времени: надёжнее armed-флага (не застрянет, если keyUp потерян).
                        let now = ProcessInfo.processInfo.systemUptime
                        if now - lastVoiceToggle > 0.3 { lastVoiceToggle = now; toggleVoice() }
                    } else if !voiceActive {
                        voiceActive = true; handler?.handleVoiceBegin()
                    }
                }
                return nil   // глотаем ВСЕГДА (вкл. autorepeat) — чтобы клавиша не печаталась
            }
            // Перевод выделенного по хоткею (по умолчанию ⌃⌥T). Глотаем, чтобы 'T' не печаталась.
            if s.translateEnabled, keyCode == Int64(s.translateHotkeyKeyCode) {
                let want = relevantMods(CGEventFlags(rawValue: s.translateHotkeyModifiers))
                if !want.isEmpty, relevantMods(event.flags) == want {
                    handler?.handleTranslateHotkey()
                    return nil
                }
            }
            // key-режим: обычная клавиша + модификаторы.
            if s.hotkeyMode == "key", s.hotkeyKeyCode >= 0, keyCode == Int64(s.hotkeyKeyCode) {
                let target = relevantMods(CGEventFlags(rawValue: s.hotkeyModifiers))
                if !target.isEmpty, relevantMods(event.flags) == target {
                    handler?.handleSwitchHotkey()
                    return Unmanaged.passUnretained(event)
                }
            }
            // Любой обычный keyDown отменяет «вооружённые» модификаторные хоткеи.
            if comboArmed { otherKeyDuringCombo = true }
            modkeyArmed = false
            otherKeyBetweenTaps = true
            let chars = NSEvent(cgEvent: event)?.characters ?? ""
            handler?.handleKeyDown(keyCode: keyCode, characters: chars, flags: event.flags)
        case .keyUp:
            // Voice key-режим: в hold отпускание = стоп; в toggle keyUp лишь снимает armed.
            if s.voiceHotkeyMode == "key", event.getIntegerValueField(.keyboardEventKeycode) == Int64(s.voiceHotkeyKeyCode) {
                voiceKeyArmed = false
                if s.voiceHoldMode != "toggle", voiceActive {
                    voiceActive = false; handler?.handleVoiceEnd()
                }
                return nil
            }
        case .flagsChanged:
            handleFlags(event.flags, keyCode: event.getIntegerValueField(.keyboardEventKeycode))
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func handleFlags(_ flags: CGEventFlags, keyCode: Int64) {
        let s = AppSettings.shared
        // Voice modkey-hold (напр. удержание правого ⌥ = keyCode 61): зажал → запись, отпустил → стоп.
        if s.voiceEnabled, s.voiceHotkeyMode == "modkey", keyCode == Int64(s.voiceHotkeyKeyCode) {
            let mask = CGEventFlags(rawValue: s.voiceHotkeyModifiers)
            let down = !flags.intersection(mask).isEmpty
            if s.voiceHoldMode == "toggle" {
                if down { toggleVoice() }   // нажал → старт/стоп; отпускание игнорируем
            } else {
                if down && !voiceActive { voiceActive = true; handler?.handleVoiceBegin() }
                else if !down && voiceActive { voiceActive = false; handler?.handleVoiceEnd() }
            }
            return
        }
        switch s.hotkeyMode {
        case "modkey":
            // Конкретная клавиша-модификатор (правый ⌥ = keyCode 61 и т.п.) — tap по отпусканию.
            let mask = CGEventFlags(rawValue: s.hotkeyModifiers)
            guard !mask.isEmpty else { return }
            if keyCode == Int64(s.hotkeyKeyCode) {
                let down = !flags.intersection(mask).isEmpty
                if down {
                    modkeyArmed = true
                } else if modkeyArmed {
                    handler?.handleSwitchHotkey()
                    modkeyArmed = false
                }
            } else {
                modkeyArmed = false // другой модификатор вмешался
            }
        case "doubletap":
            // Двойное нажатие модификатора (напр. 2× Shift) в окне ~300 мс без других клавиш.
            let mask = CGEventFlags(rawValue: s.hotkeyModifiers)
            guard !mask.isEmpty else { return }
            let pressed = !flags.intersection(mask).isEmpty
            if keyCodeMatchesMask(keyCode, mask) && pressed {
                let now = CACurrentMediaTime()
                if now - lastModTap < 0.30 && !otherKeyBetweenTaps {
                    handler?.handleSwitchHotkey()
                    lastModTap = 0
                } else {
                    lastModTap = now
                }
                otherKeyBetweenTaps = false
            }
        case "combo":
            let target = relevantMods(CGEventFlags(rawValue: s.hotkeyModifiers))
            guard !target.isEmpty else { return }
            let now = relevantMods(flags)
            if now == target {
                comboArmed = true
                otherKeyDuringCombo = false
            } else if comboArmed {
                if !otherKeyDuringCombo { handler?.handleSwitchHotkey() }
                comboArmed = false
            }
        default:
            break
        }
    }

    /// toggle-режим: нажал → старт, нажал ещё раз → стоп.
    /// ИСТОЧНИК ИСТИНЫ — реальное состояние записи (VoiceController.isRecording), НЕ локальный
    /// флаг voiceActive: он рассинхронивался, если begin() молча не стартовал (busy / микрофон
    /// занят / нет модели) — тогда «нажал, ничего, нажал ещё — пошло» (баг 1-к-8, 2026-06-09).
    private func toggleVoice() {
        // isActive — СИНХРОННЫЙ флаг намерения (true сразу после begin), в отличие от isRecording,
        // который во время async-старта ещё false → быстрый второй тап рассинхронивал toggle (баг
        // «не сработало с первого раза»). Теперь старт/стоп детерминированы.
        if VoiceController.shared.isActive { handler?.handleVoiceEnd() }
        else { handler?.handleVoiceBegin() }
        voiceActive = VoiceController.shared.isActive
    }

    /// Совпадает ли событие с voice-хоткеем диктовки (клавиша + модификаторы).
    private func isVoiceHotkey(_ keyCode: Int64, _ flags: CGEventFlags) -> Bool {
        let s = AppSettings.shared
        // keyDown-путь — только для режима "key" (клавиша+модификаторы, напр. ⌥`).
        guard s.voiceEnabled, s.voiceHotkeyMode == "key", keyCode == Int64(s.voiceHotkeyKeyCode) else { return false }
        let want = relevantMods(CGEventFlags(rawValue: s.voiceHotkeyModifiers))
        guard !want.isEmpty else { return false }
        return relevantMods(flags) == want
    }

    /// keyCode принадлежит модификатору из mask (левый ИЛИ правый).
    private func keyCodeMatchesMask(_ kc: Int64, _ mask: CGEventFlags) -> Bool {
        if mask.contains(.maskShift) && (kc == 56 || kc == 60) { return true }
        if mask.contains(.maskAlternate) && (kc == 58 || kc == 61) { return true }
        if mask.contains(.maskCommand) && (kc == 55 || kc == 54) { return true }
        if mask.contains(.maskControl) && (kc == 59 || kc == 62) { return true }
        return false
    }

    private func relevantMods(_ flags: CGEventFlags) -> CGEventFlags {
        var m: CGEventFlags = []
        for f: CGEventFlags in [.maskAlternate, .maskShift, .maskCommand, .maskControl] {
            if flags.contains(f) { m.insert(f) }
        }
        return m
    }
    private func bit(_ t: CGEventType) -> CGEventMask { CGEventMask(1) << CGEventMask(t.rawValue) }
}

private func eventTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<EventTap>.fromOpaque(userInfo).takeUnretainedValue()
    return tap.handle(type: type, event: event)
}
