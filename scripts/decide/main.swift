// Командная утилита для проверки решений детектора на любом вводе.
// Использует РЕАЛЬНЫЙ код приложения (LayoutDetector.decide и decidePair), без копий логики.
//
// Использование (см. scripts/decide.sh):
//   decide.sh [--profile ru|en|mixed] [--pair] [--clean] [строка ...]
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

// Настройки и исключения dev-приложения читаем регистрацией домена по умолчанию: это только чтение,
// домен ru.keyboop.app.dev не меняется. --clean — без них (чистый детектор, основной язык «mixed»).
// AppSettings и ExceptionStore читают UserDefaults.standard, поэтому видят те же значения, что и приложение.
let appDomain = "ru.keyboop.app.dev"
var args = Array(CommandLine.arguments.dropFirst())
var profile: String? = nil
var pairMode = false
var clean = false
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
    positional.append(a)
    i += 1
}
// Своя запись primaryLanguage от прежних запусков не должна перекрывать регистрацию.
UserDefaults.standard.removeObject(forKey: "primaryLanguage")
if !clean, let app = UserDefaults.standard.persistentDomain(forName: appDomain) {
    UserDefaults.standard.register(defaults: app)
}
if let profile {
    UserDefaults.standard.register(defaults: ["primaryLanguage": profile])
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
