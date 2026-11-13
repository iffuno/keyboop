// Командная утилита для проверки решений детектора на любом вводе.
// Использует РЕАЛЬНЫЙ код приложения (LayoutDetector.decide и decidePair), без копий логики.
//
// Использование (см. scripts/decide.sh):
//   decide.sh [--profile ru|en|mixed] [--pair] [--clean] [строка ...]
//   decide.sh --cases scripts/cases.txt   (набор кейсов с ожидаемым результатом, код выхода 1 при расхождении)
//   echo "ghbdtn" | decide.sh --profile ru
//   printf 'Email\njr\n' | decide.sh --profile ru
//   decide.sh --pair --profile ru "z" "вижу"
//
// Без --pair каждая строка — одно слово. С --pair строка — «предыдущее текущее» (два слова через пробел)
// или два аргумента подряд. Вывод: вход, решение (keep / convert→ru / convert→en) и результат замены.

import Foundation

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

// Настройки и исключения dev-приложения читаем регистрацией домена по умолчанию: это только чтение,
// домен ru.keyboop.app.dev не меняется. --clean — без них (чистый детектор, основной язык «mixed»).
// AppSettings и ExceptionStore читают UserDefaults.standard, поэтому видят те же значения, что и приложение.
let appDomain = "ru.keyboop.app.dev"
var args = Array(CommandLine.arguments.dropFirst())
var profile: String? = nil
var pairMode = false
var clean = false
var casesFile: String? = nil
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
    if a == "--cases", i + 1 < args.count {
        casesFile = args[i + 1]
        i += 2
        continue
    }
    positional.append(a)
    i += 1
}
// Набор кейсов всегда без настроек dev-приложения: результат не должен зависеть от личных исключений.
if casesFile != nil { clean = true }
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
