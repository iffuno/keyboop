// Командная утилита для проверки решений детектора на любом вводе.
// Использует РЕАЛЬНЫЙ код приложения (LayoutDetector.decide и decidePair), без копий логики.
//
// Использование (см. scripts/decide.sh):
//   decide.sh [--profile ru|en|mixed] [--pair] [--clean] [строка ...]
//   decide.sh --cases scripts/cases.txt   (набор кейсов с ожидаемым результатом, код выхода 1 при расхождении)
//   decide.sh --keys scripts/keys-cases.txt   (нажатия через настоящий Engine, замены перехватываются, код выхода 1)
//   echo "ghbdtn" | decide.sh --profile ru
//   printf 'Email\njr\n' | decide.sh --profile ru
//   decide.sh --pair --profile ru "z" "вижу"
//
// Без --pair каждая строка — одно слово. С --pair строка — «предыдущее текущее» (два слова через пробел)
// или два аргумента подряд. Вывод: вход, решение (keep / convert→ru / convert→en) и результат замены.

import Foundation
import CoreGraphics

// Глобал из точки входа приложения (Sources/Keyboop/main.swift), на который ссылается AppDelegate.
// CLI до AppDelegate не доходит, поэтому фиксируем значение.
let keyboopGlobeFixRequested = false

func decideWord(_ raw: String) -> String {
    let decision = LayoutDetector.decide(word: raw, exceptions: ExceptionStore.shared)
    return describe(decision, raw)
}

func decidePairLine(_ prev: String, _ cur: String) -> String {
    let decision = LayoutDetector.decidePair(prev: prev, cur: cur)
    return describe(decision, prev + " " + cur)
}

func describe(_ decision: SwapDecision, _ raw: String) -> String {
    switch decision {
    case .keep:
        return "keep"
    case .convert(let toCyrillic):
        let out = Keymap.convert(raw, toCyrillic: toCyrillic)
        return "convert→\(toCyrillic ? "ru" : "en") = \(out)"
    }
}

// Набор кейсов: строка «вход<TAB>ожидаемое», директива «@profile ru|en|mixed» переключает профиль,
// «#» — комментарий. Ожидаемое пишется ровно так, как печатает describe: «keep» или «convert→ru = текст».
// Вход с пробелом — пара «предыдущее текущее». Возвращает код выхода: 0 — все прошли, 1 — есть расхождения.
func runCases(path: String) -> Int32 {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("не читается: \(path)")
        return 2
    }
    var passed = 0
    var failed = 0
    for (number, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        if line.hasPrefix("@profile") {
            let value = line.dropFirst("@profile".count).trimmingCharacters(in: .whitespaces)
            UserDefaults.standard.register(defaults: ["primaryLanguage": value])
            continue
        }
        let cols = raw.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard cols.count == 2 else {
            print("строка \(number + 1): нет табуляции между входом и ожидаемым")
            failed += 1
            continue
        }
        let input = cols[0]
        let expected = cols[1]
        let parts = input.split(separator: " ", maxSplits: 1).map(String.init)
        let got = parts.count == 2 ? decidePairLine(parts[0], parts[1]) : decideWord(input)
        if got == expected {
            passed += 1
        } else {
            failed += 1
            print("НЕ ПРОШЛО \(input): ожидал «\(expected)», получил «\(got)»")
        }
    }
    print("итого: прошло \(passed), не прошло \(failed)")
    return failed == 0 ? 0 : 1
}

// Режим --keys: набор нажатий через настоящий Engine. Замены, которые он отдаёт в TextReplacer, забирает
// перехватчик testSink, а экран моделируется здесь: клавиша дописывается, затем применяются замены, которые
// её вызвали. Строка файла: «набор<TAB>ожидаемый экран». Набор — ASCII-клавиши US-раскладки.
let usKeyCodes: [Character: Int64] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
    "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
    "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
    "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
    ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, " ": 49,
]

func pumpRunLoop(_ seconds: Double) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

func applyEdit(_ edit: TextReplacer.TestEdit, to screen: inout [Character], log: inout [String]) {
    switch edit {
    case .replace(deleteCount: let n, text: let text, thenReturn: let ret):
        screen.removeLast(min(n, screen.count))
        screen.append(contentsOf: text)
        if ret { screen.append("\n") }
        log.append("замена -\(n) +«\(text)»")
    case .inline(deleteCount: let n, text: let text):
        screen.removeLast(min(n, screen.count))
        screen.append(contentsOf: text)
        log.append("встроенная замена -\(n) +«\(text)»")
    case .insert(text: let text, thenReturn: let ret):
        screen.append(contentsOf: text)
        if ret { screen.append("\n") }
        log.append("вставка «\(text)»")
    case .canvas(text: let text):
        log.append("замена объекта на холсте «\(text)» (на экран не моделируется)")
    }
}

func runKeys(path: String) -> Int32 {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("не читается: \(path)")
        return 2
    }
    if TextReplacer.secureInputActive {
        print("включён Secure Input (поле пароля): Engine молчит, тест не покажет замены")
        return 2
    }
    var pending: [TextReplacer.TestEdit] = []
    TextReplacer.testSink = { pending.append($0) }
    // Нейтральное приложение: иначе тест попадает в режим фронтового приложения (например, IDE).
    Engine.testBundleOverride = "ru.keyboop.test"
    // Система «английская» для всех чтений и переключений: раскладка машины не меняется.
    LayoutManager.testCyrillic = false
    Warm.prime()
    let warmDeadline = Date().addingTimeInterval(10)
    while !Warm.isReady && Date() < warmDeadline { pumpRunLoop(0.02) }
    guard Warm.isReady else {
        print("языковые данные не прогрелись за 10 с")
        return 2
    }
    var passed = 0
    var failed = 0
    for (number, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        if line.hasPrefix("@profile") {
            let value = line.dropFirst("@profile".count).trimmingCharacters(in: .whitespaces)
            UserDefaults.standard.register(defaults: ["primaryLanguage": value])
            continue
        }
        let cols = raw.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard cols.count == 2 else {
            print("строка \(number + 1): нет табуляции между набором и ожидаемым")
            failed += 1
            continue
        }
        let typed = cols[0]
        // В ожидаемом пробел пишется «␣»: конечные пробелы в файле теряются при правке.
        let expected = cols[1].replacingOccurrences(of: "␣", with: " ")
        guard typed.allSatisfy({ $0.isASCII && (usKeyCodes[Character($0.lowercased())] != nil) }) else {
            print("строка \(number + 1): в наборе есть символ вне US-раскладки: «\(typed)»")
            failed += 1
            continue
        }
        let engine = Engine()
        engine.refreshFrontmostAppCache()
        var screen: [Character] = []
        var log: [String] = []
        for ch in typed {
            let code = usKeyCodes[Character(ch.lowercased())] ?? 0
            let flags: CGEventFlags = ch.isUppercase ? .maskShift : []
            // true — движок забрал клавишу (замена через inline-путь): в поле она не попадает.
            let consumed = engine.handleKeyDown(keyCode: code, characters: String(ch), flags: flags,
                                                post: { _ in fatalError("тест: событие мимо перехватчика") })
            if !consumed { screen.append(ch) }
            pumpRunLoop(0.03)
            for edit in pending { applyEdit(edit, to: &screen, log: &log) }
            pending = []
        }
        pumpRunLoop(0.2)
        for edit in pending { applyEdit(edit, to: &screen, log: &log) }
        pending = []
        let got = String(screen)
        if got == expected {
            passed += 1
        } else {
            failed += 1
            print("НЕ ПРОШЛО «\(typed)»: ожидал «\(expected)», экран «\(got)» (\(log.joined(separator: "; ")))")
        }
    }
    print("набор нажатий: прошло \(passed), не прошло \(failed)")
    return failed == 0 ? 0 : 1
}

// Режим --mixed FILE (замер): смешанные токены (кир+лат без пробела). Печатает решение mixedRescue, как в
// приложении, и решение триграммного кандидата. Кандидат в приложение не вносится.
func trigramMixedCandidate(_ raw: String) -> String {
    let core = String(raw.filter { $0.isLetter })
    guard core.count >= 4 else { return "keep" }
    let toRu = Keymap.convert(core, toCyrillic: true).lowercased()
    let toEn = Keymap.convert(core, toCyrillic: false).lowercased()
    let data = LayoutData.shared
    let ruScore = toRu.hasLatinLetter ? -99.0 : data.plausibility(toRu, cyrillic: true)
    let enScore = toEn.hasCyrillic ? -99.0 : data.plausibility(toEn, cyrillic: false)
    if ruScore > -9 && ruScore > enScore { return "convert→ru = \(Keymap.convert(raw, toCyrillic: true))" }
    if enScore > -9 && enScore > ruScore { return "convert→en = \(Keymap.convert(raw, toCyrillic: false))" }
    return "keep"
}

func runMixed(path: String) -> Int32 {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("не читается: \(path)")
        return 2
    }
    var nowCount = 0
    var candCount = 0
    for line in text.split(separator: "\n") {
        let token = String(line)
        let now = describe(LayoutDetector.mixedRescue(word: token), token)
        let cand = trigramMixedCandidate(token)
        if now != "keep" { nowCount += 1 }
        if cand != "keep" { candCount += 1 }
        print("\(token)\tсейчас: \(now)\tкандидат: \(cand)")
    }
    print("сейчас переключит \(nowCount), кандидат переключит \(candCount)")
    return 0
}

// Настройки и исключения dev-приложения читаем регистрацией домена по умолчанию: это только чтение,
// домен ru.keyboop.app.dev не меняется. --clean — без них (чистый детектор, основной язык «mixed»).
// AppSettings и ExceptionStore читают UserDefaults.standard, поэтому видят те же значения, что и приложение.
let appDomain = "ru.keyboop.app.dev"
var args = Array(CommandLine.arguments.dropFirst())
var profile: String? = nil
var pairMode = false
var clean = false
var casesFile: String? = nil
var keysFile: String? = nil
var mixedFile: String? = nil
var positional: [String] = []
var i = 0
while i < args.count {
    let a = args[i]
    if a == "--profile", i + 1 < args.count {
        profile = args[i + 1]
        i += 2
        continue
    }
    if a == "--pair" {
        pairMode = true
        i += 1
        continue
    }
    if a == "--clean" {
        clean = true
        i += 1
        continue
    }
    if a == "--mixed", i + 1 < args.count {
        mixedFile = args[i + 1]
        i += 2
        continue
    }
    if a == "--keys", i + 1 < args.count {
        keysFile = args[i + 1]
        i += 2
        continue
    }
    if a == "--cases", i + 1 < args.count {
        casesFile = args[i + 1]
        i += 2
        continue
    }
    positional.append(a)
    i += 1
}
// Набор кейсов всегда без настроек dev-приложения: результат не должен зависеть от личных исключений.
if casesFile != nil || keysFile != nil { clean = true }
// Своя запись primaryLanguage от прежних запусков не должна перекрывать регистрацию.
UserDefaults.standard.removeObject(forKey: "primaryLanguage")
if !clean, let app = UserDefaults.standard.persistentDomain(forName: appDomain) {
    UserDefaults.standard.register(defaults: app)
}
if let profile {
    UserDefaults.standard.register(defaults: ["primaryLanguage": profile])
}

if let casesFile {
    exit(runCases(path: casesFile))
}
if let keysFile {
    exit(runKeys(path: keysFile))
}
if let mixedFile {
    exit(runMixed(path: mixedFile))
}

var inputs: [String] = positional
if inputs.isEmpty {
    // Читаем stdin построчно, пропуская пустые строки.
    while let line = readLine(strippingNewline: true) {
        let t = line.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { inputs.append(t) }
    }
}

for item in inputs {
    if pairMode {
        let parts = item.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            print("\(item)\tошибка: для --pair нужна строка «предыдущее текущее»")
            continue
        }
        print("\(parts[0]) \(parts[1])\t\(decidePairLine(parts[0], parts[1]))")
    } else {
        print("\(item)\t\(decideWord(item))")
    }
}
