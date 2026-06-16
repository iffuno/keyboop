import Foundation
import CoreGraphics

/// Маркер «это наша синтетика» в поле `.eventSourceUserData` каждого синтетического события.
/// EventTap фильтрует наши события ПО ЭТОМУ МАРКЕРУ (а не по временно́му флагу muted) → различение
/// «наше/чужое» становится свойством СОБЫТИЯ, а не тайминга. Раньше единственным барьером был muted,
/// который в окне постинга+дренажа РОНЯЛ реальные нажатия быстрого набора (буфер↔экран рассинхрон →
/// «иногда не переключается», «gпривет»). 'KBOP' = 0x4B42_4F50. (Аудит 15.06, корни №1/№2.)
let kbSyntheticMarker: Int64 = 0x4B42_4F50

/// Замена текста БЕЗ буфера обмена: синтетические Backspace + печать Unicode напрямую
/// через `keyboardSetUnicodeString` (минуя раскладку). Краеугольный принцип Keyboop.
enum TextReplacer {

    private static let backspaceKey: CGKeyCode = 51

    /// ВСЯ синтетика (Backspace + печать Unicode) с usleep-паузами идёт на ВЫДЕЛЕННОЙ serial-очереди,
    /// а НЕ на главном потоке. На main живёт активный CGEventTap (.defaultTap, глотает ввод); синхронные
    /// usleep там морозили бы доставку ВСЕГО ввода системы (security review 15.06 — класс бага уже был
    /// в 0.1.34). `completion` зовётся на main по факту завершения постинга — там вызывающий снимает
    /// `muted` (с дренаж-задержкой), а не по фикс-таймеру, иначе размьютит до того, как синтетика отыграет.
    private static let synthQueue = DispatchQueue(label: "ru.keyboop.synth", qos: .userInteractive)

    /// Впечатать текст без удаления (для голосового ввода / перевода).
    static func insert(_ text: String, completion: (() -> Void)? = nil) {
        synthQueue.async {
            typeUnicode(text, source: CGEventSource(stateID: .privateState))
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    /// Удалить `deleteCount` символов и впечатать `text`.
    static func replace(deleteCount: Int, with text: String, completion: (() -> Void)? = nil) {
        synthQueue.async {
            // privateState — чтобы не наследовать зажатые пользователем модификаторы (⌥⇧ хоткея).
            let src = CGEventSource(stateID: .privateState)
            let n = max(0, deleteCount)
            if n > 0 {
                // Небольшая пауза перед ПЕРВЫМ Backspace — иначе он иногда теряется, прилетая слишком
                // рано после клавиши-триггера, и первый символ остаётся в старой раскладке («gривет»).
                usleep(9_000)
                for _ in 0..<n {
                    postKey(backspaceKey, source: src)
                    usleep(1800)
                }
            }
            typeUnicode(text, source: src)
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    private static func postKey(_ key: CGKeyCode, source: CGEventSource?) {
        if let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true) {
            down.flags = []
            down.setIntegerValueField(.eventSourceUserData, value: kbSyntheticMarker)   // «это наше»
            down.post(tap: .cghidEventTap)
        }
        usleep(900)   // короткое «удержание» down→up — некоторые поля не видят мгновенный тап
        if let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) {
            up.flags = []
            up.setIntegerValueField(.eventSourceUserData, value: kbSyntheticMarker)
            up.post(tap: .cghidEventTap)
        }
    }

    /// Печать строки как Unicode. Лимит ~20 UTF-16 единиц на событие → бьём по 12.
    private static func typeUnicode(_ string: String, source: CGEventSource?) {
        let units = Array(string.utf16)
        guard !units.isEmpty else { return }
        var i = 0
        let chunkSize = 12
        while i < units.count {
            let chunk = Array(units[i..<min(i + chunkSize, units.count)])
            postUnicodeChunk(chunk, keyDown: true, source: source)
            postUnicodeChunk(chunk, keyDown: false, source: source)
            i += chunkSize
            usleep(800)
        }
    }

    private static func postUnicodeChunk(_ chunk: [UniChar], keyDown: Bool, source: CGEventSource?) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { return }
        event.flags = []
        event.setIntegerValueField(.eventSourceUserData, value: kbSyntheticMarker)   // «это наше»
        chunk.withUnsafeBufferPointer { buf in
            event.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
        }
        event.post(tap: .cghidEventTap)
    }
}
