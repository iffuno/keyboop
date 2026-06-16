import Foundation

// ───────────────────────────────────────────────────────────────────────────
// Машинный тест режима "group convert" (переключить несколько слов одним хоткеем).
// Чистая логика над "виртуальным экраном" — БЕЗ реальных событий клавиатуры.
//
// Идея (по реестру edge-cases G1–G19): держим ДВЕ независимые истины —
//   screen  — что РЕАЛЬНО на экране (видит пользователь),
//   buffer  — что думает группа (настоящий KeystrokeBuffer + sessionWords).
// Группа печатает по buffer; если он разъехался с экраном — порча. Тест это ловит.
//
// Переиспользуем НАСТОЯЩИЕ KeystrokeBuffer / LayoutDetector.decide / Keymap.
// convertGroup-логику зеркалим (она в Engine, который тянет AppKit/EventTap).
// Сборка/запуск — run-groupsim.sh (нужен KEYBOOP_DATA_DIR).
// ───────────────────────────────────────────────────────────────────────────

struct VirtualScreen {
    private(set) var chars: [Character] = []
    private(set) var caret = 0
    var text: String { String(chars) }

    mutating func insert(_ s: String) {
        let a = Array(s); chars.insert(contentsOf: a, at: caret); caret += a.count
    }
    /// Стереть deleteCount графем СЛЕВА от каретки и вставить `with`. Возвращает false, если
    /// слева недостаточно символов (INV-2: группа удаляет больше, чем набрано → ела бы чужое).
    @discardableResult
    mutating func applyReplace(deleteCount: Int, with: String) -> Bool {
        guard deleteCount >= 0, deleteCount <= caret else { return false }
        chars.removeSubrange((caret - deleteCount)..<caret)
        caret -= deleteCount
        let a = Array(with); chars.insert(contentsOf: a, at: caret); caret += a.count
        return true
    }
    mutating func setCaret(_ p: Int) { caret = max(0, min(chars.count, p)) }
}

struct SimSettings { var autoEnabled = false; var arrowsCancel = true }

final class Sim {
    let buffer = KeystrokeBuffer()
    var screen = VirtualScreen()
    var settings: SimSettings
    let exc = ExceptionStore.shared
    /// Граница "сессии" на экране — индекс, левее которого текст НЕ наш (для INV-5).
    var sessionStart = 0

    init(_ s: SimSettings = SimSettings()) { settings = s; sessionStart = 0 }

    // ── Ввод ──
    func type(_ s: String) {
        for ch in s { buffer.append(String(ch)); screen.insert(String(ch)) }
    }
    func boundary(_ ws: String) {
        buffer.boundary(ws); screen.insert(ws)
        if settings.autoEnabled { applyAutoAfterBoundary() }
    }
    func word(_ w: String, _ ws: String = " ") { type(w); boundary(ws) }

    func backspace() {
        buffer.backspace()
        screen.applyReplace(deleteCount: 1, with: "")
    }
    func arrowLeft() {
        screen.setCaret(screen.caret - 1)
        buffer.invalidateGroupHistory()
        if settings.arrowsCancel { buffer.clear() }
    }
    func mouseClick(at p: Int) {            // handleContextReset: клик двигает курсор
        screen.setCaret(p)
        buffer.invalidateGroupHistory()
        buffer.clear()
        sessionStart = p
    }
    /// Раскрытие сниппета: меняет экран НЕ 1:1 + инвалидирует группу (как Engine.expandSnippetIfMatch).
    func snippet(replace deleteCount: Int, with expansion: String) {
        screen.applyReplace(deleteCount: deleteCount, with: expansion)
        buffer.applyConversion(converted: expansion)
        buffer.invalidateGroupHistory()
    }
    /// Голосовая вставка: текст на экран + очистка буфера (как Engine по .keyboopVoiceInserted).
    func voiceInsert(_ s: String) {
        screen.insert(s); buffer.clear(); sessionStart = screen.caret
    }

    /// Авто-конверсия последнего слова (как Engine.convertFromBuffer manual:false). Меняет ЭКРАН и
    /// зовёт buffer.applyConversion — НО НЕ синхронизирует sessionWords (как в проде → ловим рассинхрон).
    private func applyAutoAfterBoundary() {
        guard let item = buffer.wordForConversion() else { return }
        switch LayoutDetector.decide(word: item.word, exceptions: exc) {
        case .convert(let c):
            let conv = Keymap.smartConvert(item.word, toCyrillic: c)
            guard conv != item.word, conv.count == item.word.count else { return }
            // на экране слово = последнее набранное перед хвостом: заменяем его (caret после хвоста)
            let tail = item.tail.count
            screen.setCaret(screen.caret - tail)
            screen.applyReplace(deleteCount: item.word.count, with: conv)
            screen.setCaret(screen.caret + tail)
            buffer.applyConversion(converted: conv)
        case .keep: break
        }
    }

    // ── Группа (зеркало Engine.convertGroup + guard !autoEnabled) ──
    struct GroupOutcome { var fired: Bool; var out: String; var deleteCount: Int }
    @discardableResult
    func pressGroupHotkey() -> GroupOutcome {
        guard !settings.autoEnabled else { return GroupOutcome(fired: false, out: "", deleteCount: 0) }
        guard let g = buffer.groupForConversion() else { return GroupOutcome(fired: false, out: "", deleteCount: 0) }
        var out = ""; var any = false
        var prevWord: String? = nil   // зеркало Engine.convertGroup: бегущее предыдущее слово
        for (w, t) in g.words {
            switch LayoutDetector.decide(word: w, exceptions: exc, prev: prevWord) {
            case .convert(let c):
                let conv = Keymap.smartConvert(w, toCyrillic: c)
                out += conv + t; any = true; prevWord = conv
            case .keep:
                out += w + t; prevWord = w
            }
        }
        guard any else { return GroupOutcome(fired: false, out: "", deleteCount: 0) }      // no-op
        guard out.count == g.deleteCount else { return GroupOutcome(fired: false, out: "", deleteCount: 0) }
        let ok = screen.applyReplace(deleteCount: g.deleteCount, with: out)
        if !ok { return GroupOutcome(fired: false, out: out, deleteCount: g.deleteCount) }  // INV-2 спас
        buffer.clear()
        return GroupOutcome(fired: true, out: out, deleteCount: g.deleteCount)
    }
}

// ───────────────────────── Тестовая обвязка ─────────────────────────

@main
struct GroupSimMain {
static func main() {

let data = LayoutData.shared
guard data.isLoaded else { print("❌ Данные не загрузились — запускай через run-groupsim.sh"); exit(1) }

var pass = 0, fail = 0
var fails: [String] = []
func check(_ cond: Bool, _ name: String) {
    if cond { pass += 1 } else { fail += 1; fails.append(name) }
}

// === 1. КОНТРОЛЬНЫЕ КЕЙСЫ (вход → ожидаемый экран), авто ВЫКЛ ===
func ctrl(_ name: String, _ build: (Sim) -> Void, expect: String) {
    let s = Sim(SimSettings(autoEnabled: false))
    build(s)
    s.pressGroupHotkey()
    check(s.screen.text == expect, "CTRL \(name): got «\(s.screen.text)» want «\(expect)»")
}
ctrl("две каши", { $0.type("ghbdtn"); $0.boundary(" "); $0.type("rfr") }, expect: "привет как")
ctrl("валидное+каша", { $0.type("hello"); $0.boundary(" "); $0.type("ghbdtn") }, expect: "hello привет")
ctrl("каша+валидное EN", { $0.type("ghbdtn"); $0.boundary(" "); $0.type("world") }, expect: "привет world")
ctrl("три слова", { $0.word("ghbdtn"); $0.word("rfr"); $0.type("ltkf") }, expect: "привет как дела")
ctrl("хвост-пробел сохраняется", { $0.word("ghbdtn"); $0.word("vbh") }, expect: "привет мир ")
// бегущий контекст в группе: после «привет» коллизия yt разрешается в «не»
ctrl("контекст в группе (yt→не)", { $0.type("ghbdtn"); $0.boundary(" "); $0.type("yt") }, expect: "привет не")
ctrl("keep-список в группе (tv)", { $0.type("ghbdtn"); $0.boundary(" "); $0.type("tv") }, expect: "привет tv")
// предлог после обычного слова чинится, после классификатора — нет
ctrl("предлог после обычного (room d)", { $0.type("room"); $0.boundary(" "); $0.type("d") }, expect: "room в")
ctrl("классификатор в группе (vitamin d)", { $0.type("vitamin"); $0.boundary(" "); $0.type("d") }, expect: "vitamin d")

// === 2. NO-OP / ЗАЩИТЫ: группа НЕ должна срабатывать, экран НЕ меняется ===
func guardCase(_ name: String, _ build: (Sim) -> Void) {
    let s = Sim(SimSettings(autoEnabled: false))
    build(s)
    let before = s.screen.text
    let r = s.pressGroupHotkey()
    check(!r.fired && s.screen.text == before, "GUARD \(name): fired=\(r.fired) экран изменился=\(s.screen.text != before)")
}
guardCase("одно слово (нет группы)", { $0.type("ghbdtn") })
guardCase("всё валидное (no-op)", { $0.type("hello"); $0.boundary(" "); $0.type("world") })
guardCase("стрелка инвалидирует (G2)", { $0.word("ghbdtn"); $0.type("rfr"); $0.arrowLeft() })
guardCase("клик инвалидирует (G10)", { $0.word("ghbdtn"); $0.type("rfr"); $0.mouseClick(at: 0) })
guardCase("сниппет инвалидирует (G1)", { $0.word("ghbdtn"); $0.snippet(replace: 0, with: "X"); $0.type("rfr") })
guardCase("голос чистит буфер (G3)", { $0.word("ghbdtn"); $0.voiceInsert("привет "); $0.type("rfr") })
guardCase("emoji → нет группы (G7)", { $0.type("ghbdtn"); $0.boundary(" "); $0.type("👨‍👩‍👧") })
guardCase("Enter в хвосте → нет группы (G9)", { $0.word("ghbdtn", "\n"); $0.type("rfr") })
guardCase("Tab в хвосте → нет группы (G9)", { $0.word("ghbdtn", "\t"); $0.type("rfr") })

// G15: протухшая сессия (имитируем idle вручную не можем — Date реальный; проверяем что свежая
// сессия группируется, а >200 символов отсекается).
guardCase("кап длины >200 (G17)", { s in
    for _ in 0..<40 { s.word("ghbdtn") }   // 40×7 ≈ 280 симв > 200
})

// G5: при auto ON группа не трогает (guard !autoEnabled)
do {
    let s = Sim(SimSettings(autoEnabled: true))
    s.type("ghbdtn"); s.boundary(" "); s.type("rfr")
    let before = s.screen.text
    let r = s.pressGroupHotkey()
    check(!r.fired, "GUARD auto-on: группа сработала при включённом авто (не должна)")
    check(s.screen.text == before, "GUARD auto-on: экран изменился при авто")
}

// === 3. ИНВАРИАНТЫ на МАССОВОЙ генерации (детерминированно, без random) ===
// Генерим фразы из слов RU/EN: реальные слова + "каша" (RU-слово, набранное латиницей).
let ruSample = Array(data.wordsRu).filter { $0.count >= 3 && $0.count <= 8 && $0.allSatisfy { $0.isLetter } }
let enSample = Array(data.wordsEn).filter { $0.count >= 3 && $0.count <= 8 && $0.allSatisfy { $0.isLetter } }
func pick(_ arr: [String], _ i: Int) -> String { arr[(i * 2654435761 % max(1, arr.count) + arr.count) % arr.count] }

var massCases = 0
for i in stride(from: 0, to: 6000, by: 1) {
    // строим фразу 2–4 слова: миксы «каша» (ru→latin) и валидных EN
    let n = 2 + (i % 3)
    let s = Sim(SimSettings(autoEnabled: false))
    var expectedWords: [String] = []
    var eprev: String? = nil   // эталон зеркалит бегущее предыдущее слово группы (как Engine)
    for k in 0..<n {
        let kind = (i / 3 + k) % 3
        let wRaw: String
        if kind == 0 {                                   // каша: RU-слово латиницей → должно convert
            let ru = pick(ruSample, i + k)
            wRaw = Keymap.convert(ru, toCyrillic: false) // ru → latin (как набрано в EN-раскладке)
        } else if kind == 1 {                            // валидное EN → keep
            wRaw = pick(enSample, i + k * 7)
        } else {                                          // валидное RU → keep
            wRaw = pick(ruSample, i + k * 13)
        }
        // эталон: пословный decide с тем же бегущим предыдущим словом, что у convertGroup
        switch LayoutDetector.decide(word: wRaw, exceptions: ExceptionStore.shared, prev: eprev) {
        case .convert(let c):
            let conv = Keymap.smartConvert(wRaw, toCyrillic: c)
            expectedWords.append(conv); eprev = conv
        case .keep:
            expectedWords.append(wRaw); eprev = wRaw
        }
        if k < n - 1 { s.type(wRaw); s.boundary(" ") } else { s.type(wRaw) }
    }
    let prefixLen = s.screen.caret - s.screen.text.count  // 0; сессия с начала
    let g = s.buffer.groupForConversion()
    let r = s.pressGroupHotkey()
    massCases += 1
    if let g = g, r.fired {
        // INV-1: out.count == deleteCount
        check(r.out.count == r.deleteCount, "MASS#\(i) INV-1 длина")
        // INV-4: экран == эталон (пословный decide по тому, что РЕАЛЬНО набрано)
        let expected = expectedWords.joined(separator: " ")
        check(s.screen.text == expected, "MASS#\(i) INV-4: got «\(s.screen.text)» want «\(expected)»")
        // INV-2: не удалили больше, чем было
        check(r.deleteCount <= expected.count, "MASS#\(i) INV-2 deleteCount")
        _ = g; _ = prefixLen
    }
}

// === 4. INV-5: группа НЕ трогает текст ЛЕВЕЕ начала сессии ===
do {
    let s = Sim(SimSettings(autoEnabled: false))
    s.screen.insert("ЧУЖОЙ ТЕКСТ ")     // предыдущий текст (не наша сессия)
    s.mouseClick(at: s.screen.caret)     // курсор в конце, новая сессия
    let prefix = "ЧУЖОЙ ТЕКСТ "
    s.type("ghbdtn"); s.boundary(" "); s.type("rfr")
    s.pressGroupHotkey()
    check(s.screen.text.hasPrefix(prefix), "INV-5: чужой префикс затронут: «\(s.screen.text)»")
    check(s.screen.text == prefix + "привет как", "INV-5 результат: «\(s.screen.text)»")
}

// ───────────────────────── Итог ─────────────────────────
print("=== Group Convert — машинный тест ===")
print("Словари: RU \(data.wordsRu.count), EN \(data.wordsEn.count). Массовых сценариев: \(massCases)\n")
print("PASS: \(pass)   FAIL: \(fail)")
if fail > 0 {
    print("\nПровалы (первые 25):")
    for f in fails.prefix(25) { print("  ✗ \(f)") }
    exit(1)
} else {
    print("\n✓ Все инварианты и контрольные кейсы зелёные.")
}

}   // static func main
}   // struct GroupSimMain
