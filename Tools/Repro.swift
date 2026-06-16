import Foundation

// Прицельная репродукция бага «слово после слова другого языка не переключается».
// Прогоняем фразу ПОСЛОВНО, поддерживая prev = предыдущее слово КАК НА ЭКРАНЕ (после конверсии) —
// ровно так буфер в проде кормит контекст детектору. Показываем решение по каждому слову.
// Запуск: run-repro.sh

@main
struct ReproMain {
static func main() {
    let data = LayoutData.shared
    guard data.isLoaded else { print("❌ нет данных — нужен KEYBOOP_DATA_DIR"); exit(1) }
    let exc = ExceptionStore.shared

    // Фразы в ТИПИЗИРОВАННОЙ форме (как реально попадает в буфер, т.е. в неверной раскладке).
    // Комментарий справа — что юзер ИМЕЛ В ВИДУ.
    let phrases: [(typed: String, intent: String)] = [
        ("hello ghbdtn",        "hello + привет(в EN-раскладке) → ждём ghbdtn→привет"),
        ("hello ghbdtn rjycjkm","hello + привет + консоль → каждое рус-в-EN должно чиниться"),
        ("привет hello",        "привет(RU) + hello(EN, верно) → hello остаётся"),
        ("привет руддщ",        "привет + hello(в RU-раскладке) → ждём руддщ→hello"),
        ("жопа ass жопа фыы",   "жопа + ass(EN?) + жопа + ass(в RU=фыы) → фыы→ass"),
        ("ghbdtn",              "привет(в EN) standalone → ждём →привет"),
        ("руддщ",               "hello(в RU) standalone → ждём →hello"),
    ]

    func decideStr(_ w: String, prev: String?) -> (label: String, screen: String) {
        switch LayoutDetector.decide(word: w, exceptions: exc, prev: prev) {
        case .keep: return ("keep   ", w)
        case .convert(let toCyr):
            let conv = Keymap.smartConvert(w, toCyrillic: toCyr)
            return ("CONVERT→\(toCyr ? "RU" : "EN")", conv)
        }
    }

    print("=== РЕПРО детектора (контекст = предыдущее слово КАК НА ЭКРАНЕ) ===\n")
    for (typed, intent) in phrases {
        print("ФРАЗА: «\(typed)»   — \(intent)")
        var prevScreen: String? = nil
        for word in typed.split(separator: " ").map(String.init) {
            let (label, screen) = decideStr(word, prev: prevScreen)
            let flag = (label == "keep   ") ? " " : "★"
            print(String(format: "   %@ %-8@ prev=%-10@ → %@", flag, word, prevScreen ?? "—", "\(label)  «\(screen)»"))
            prevScreen = screen   // следующий контекст — это слово как теперь на экране
        }
        print("")
    }

    // Дополнительно: ТОЧЕЧНО показать, КАК контекст влияет на спорные слова (standalone vs после EN/RU).
    print("=== ВЛИЯНИЕ КОНТЕКСТА на ключевые слова ===")
    for w in ["ghbdtn", "руддщ", "фыы", "ass"] {
        let sa = decideStr(w, prev: nil).label
        let afterEn = decideStr(w, prev: "hello").label
        let afterRu = decideStr(w, prev: "привет").label
        let inEn = data.wordsEn.contains(w.lowercased())
        let inRu = data.wordsRu.contains(w.lowercased())
        print(String(format: "   %-8@ standalone=%@  afterEN=%@  afterRU=%@   (wordsEn=%@ wordsRu=%@)",
                     w, sa, afterEn, afterRu, "\(inEn)", "\(inRu)"))
    }
}
}
