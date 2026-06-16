import Foundation
import AppKit
import CoreGraphics

// Эмулятор клавиатуры для стресс-теста Keyboop: печатает поток слов в разных раскладках,
// удаляет бэкспейсом/⌥⌫, кликает мышью, переключает окна. Сборка/запуск — run-stress.sh.
// Запусти, переключись в TextEdit/Notes за 5 сек, дальше смотри как Keyboop реагирует.

@main
struct Stress {
    static let src = CGEventSource(stateID: .privateState)

    // Виртуальные коды
    static let vkSpace: CGKeyCode = 49
    static let vkReturn: CGKeyCode = 36
    static let vkBackspace: CGKeyCode = 51
    static let vkTab: CGKeyCode = 48

    static let ruPhrases = [
        "привет как дела", "что нового у тебя сегодня", "давай встретимся завтра вечером",
        "я работаю над интересным проектом", "сегодня прекрасная погода на улице",
        "нужно купить молоко хлеб и масло", "посмотри это очень красивое видео"
    ]
    static let enPhrases = [
        "hello how are you today", "what is going on with the project",
        "let us meet tomorrow evening", "this is a very interesting idea",
        "please send me the report", "the weather is nice outside today"
    ]

    static func main() {
        let minutes = CommandLine.arguments.count > 1 ? (Double(CommandLine.arguments[1]) ?? 3.0) : 3.0
        log("Стресс-тест \(minutes) мин. Переключись в целевое окно (TextEdit/Notes)…")
        for i in stride(from: 5, through: 1, by: -1) { log("старт через \(i)…"); usleep(1_000_000) }
        log("ПОШЛИ. Печатаю. (Ctrl+C чтобы прервать)\n")

        let deadline = Date().addingTimeInterval(minutes * 60)
        var iter = 0
        while Date() < deadline {
            iter += 1
            let roll = Int.random(in: 0..<100)
            switch roll {
            case 0..<28:
                let p = ruPhrases.randomElement()!
                log("[\(iter)] RU в EN-раскладке (должно чиниться): \(p)")
                typePhrase(p, mistypeToLatin: true)
            case 28..<48:
                let p = enPhrases.randomElement()!
                log("[\(iter)] EN в RU-раскладке (должно чиниться): \(p)")
                typePhrase(p, mistypeToCyrillic: true)
            case 48..<64:
                let p = ruPhrases.randomElement()!
                log("[\(iter)] RU правильно (НЕ трогать): \(p)")
                typePhrase(p)
            case 64..<78:
                let p = enPhrases.randomElement()!
                log("[\(iter)] EN правильно (НЕ трогать): \(p)")
                typePhrase(p)
            case 78..<86:
                let n = Int.random(in: 3...10)
                log("[\(iter)] бэкспейс ×\(n)")
                for _ in 0..<n { key(vkBackspace); usleep(40_000) }
            case 86..<92:
                log("[\(iter)] ⌥⌫ удалить слово ×2")
                key(vkBackspace, flags: .maskAlternate); usleep(120_000)
                key(vkBackspace, flags: .maskAlternate)
            case 92..<96:
                log("[\(iter)] Enter (новая строка)")
                key(vkReturn)
            case 96..<99:
                log("[\(iter)] КЛИК МЫШЬЮ (должен сбросить контекст буфера)")
                clickAtCursor()
            default:
                log("[\(iter)] смена окна Cmd+Tab (тест сброса контекста)")
                key(vkTab, flags: .maskCommand)
            }
            usleep(UInt32(Int.random(in: 300_000...700_000)))
        }
        log("\nГотово. \(iter) итераций. Проверь текст в окне — нет ли дублей/призраков/каши.")
    }

    /// Печать фразы пословно. mistype* — набрать «не в той раскладке» (конвертировать перед печатью).
    static func typePhrase(_ phrase: String, mistypeToLatin: Bool = false, mistypeToCyrillic: Bool = false) {
        let words = phrase.split(separator: " ").map(String.init)
        for (idx, word) in words.enumerated() {
            var w = word
            if mistypeToLatin { w = Keymap.convert(word, toCyrillic: false) }
            if mistypeToCyrillic { w = Keymap.convert(word, toCyrillic: true) }
            typeUnicode(w)
            if idx < words.count - 1 { key(vkSpace); usleep(180_000) } // пробел = триггер авто
            else { key(vkSpace); usleep(180_000) }
        }
    }

    static func typeUnicode(_ s: String) {
        for ch in s {
            let units = Array(String(ch).utf16)
            post(units, keyDown: true)
            post(units, keyDown: false)
            usleep(55_000) // ~55мс/символ — живая скорость печати
        }
    }

    static func post(_ units: [UniChar], keyDown: Bool) {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: keyDown) else { return }
        e.flags = []
        units.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
        e.post(tap: .cghidEventTap)
    }

    static func key(_ vk: CGKeyCode, flags: CGEventFlags = []) {
        if let d = CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: true) { d.flags = flags; d.post(tap: .cghidEventTap) }
        if let u = CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: false) { u.flags = flags; u.post(tap: .cghidEventTap) }
    }

    static func clickAtCursor() {
        let loc = CGEvent(source: nil)?.location ?? .zero
        if let d = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: loc, mouseButton: .left) { d.post(tap: .cghidEventTap) }
        usleep(30_000)
        if let u = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: loc, mouseButton: .left) { u.post(tap: .cghidEventTap) }
    }

    static func log(_ s: String) {
        FileHandle.standardError.write(("[\(Date())] " + s + "\n").data(using: .utf8)!)
    }
}
