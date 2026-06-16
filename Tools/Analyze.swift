import Foundation

// Анализ логики детектора на ДАННЫХ: коллизии словарей, классы промахов, пограничные зоны.
// Запуск — run-analyze.sh (нужен KEYBOOP_DATA_DIR).

@main
struct AnalyzeMain {
static func main() {
    let data = LayoutData.shared
    guard data.isLoaded else { print("❌ нет данных — run-analyze.sh"); exit(1) }
    let exc = ExceptionStore.shared
    func decide(_ w: String) -> SwapDecision { LayoutDetector.decide(word: w, exceptions: exc) }

    let ru = Array(data.wordsRu), en = Array(data.wordsEn)

    // 1. КОЛЛИЗИИ: латинское слово X есть в EN-словаре, и его RU-конверсия — валидное RU-слово.
    //    Это зона риска: detector держит .keep (EN-слово), но юзер мог иметь в виду RU.
    print("=== 1. Коллизии EN-слово ↔ валидное RU после конверсии (топ по частоте-длине) ===")
    var collisions: [(String, String)] = []
    for w in en where w.count >= 2 && w.count <= 5 && w.allSatisfy({ $0.isLetter }) {
        let cyr = Keymap.convert(w, toCyrillic: true).lowercased()
        if cyr != w, data.wordsRu.contains(cyr) { collisions.append((w, cyr)) }
    }
    print("всего коллизий EN→RU (слова 2–5 букв): \(collisions.count)")
    for (e, r) in collisions.sorted(by: { $0.0.count < $1.0.count }).prefix(30) {
        print("  \(e) ↔ \(r)")
    }

    // 2. Обратные коллизии: RU-слово, чья EN-конверсия — валидное EN-слово.
    print("\n=== 2. Обратные коллизии RU-слово ↔ валидное EN после конверсии ===")
    var rev: [(String, String)] = []
    for w in ru where w.count >= 2 && w.count <= 5 && w.allSatisfy({ $0.isLetter }) {
        let lat = Keymap.convert(w, toCyrillic: false).lowercased()
        if lat != w, data.wordsEn.contains(lat) { rev.append((w, lat)) }
    }
    print("всего коллизий RU→EN (слова 2–5 букв): \(rev.count)")
    for (r, e) in rev.sorted(by: { $0.0.count < $1.0.count }).prefix(30) {
        print("  \(r) ↔ \(e)")
    }

    // 3. ПРОМАХИ детектора: RU-слово набрано латиницей, но detector НЕ переключает (.keep).
    //    Разбиваем по длине — где статистика проваливается.
    print("\n=== 3. Промахи (RU-в-EN-раскладке → keep) по длине слова ===")
    var missByLen: [Int: (total: Int, miss: Int, examples: [String])] = [:]
    func sample(_ a: [String], _ n: Int) -> [String] {
        guard a.count > n else { return a }
        let step = a.count / n
        return stride(from: 0, to: a.count, by: step).map { a[$0] }
    }
    for w in sample(ru, 20000) where w.count >= 2 && w.allSatisfy({ $0.isLetter }) {
        let mis = Keymap.convert(w, toCyrillic: false)
        guard mis != w, mis.allSatisfy({ $0.isLetter }) else { continue }
        let L = min(w.count, 8)
        var rec = missByLen[L] ?? (0, 0, [])
        rec.total += 1
        if case .keep = decide(mis) {
            rec.miss += 1
            if rec.examples.count < 8 { rec.examples.append("\(mis)→\(w)") }
        }
        missByLen[L] = rec
    }
    for L in missByLen.keys.sorted() {
        let r = missByLen[L]!
        let pct = r.total > 0 ? Double(r.miss)/Double(r.total)*100 : 0
        print(String(format: "  длина %@: промахов %d/%d (%.1f%%)  напр: %@",
                     L == 8 ? "8+" : "\(L)", r.miss, r.total, pct, r.examples.prefix(6).joined(separator: ", ")))
    }

    // 4. ПОГРАНИЧНАЯ ЗОНА: слова где trigram-margin маленький (< 2× margin) — хрупкие решения.
    print("\n=== 4. Хрупкие решения (|origScore - swapScore| мал) — где детектор «почти угадал» ===")
    var fragile = 0, fragileEx: [String] = []
    for w in sample(ru, 8000) where w.count >= 4 && w.allSatisfy({ $0.isLetter }) {
        let mis = Keymap.convert(w, toCyrillic: false)
        guard mis != w, mis.allSatisfy({ $0.isLetter }), !data.wordsRu.contains(mis.lowercased()) else { continue }
        let o = data.plausibility(mis.lowercased(), cyrillic: false)
        let s = data.plausibility(w.lowercased(), cyrillic: true)
        if abs((s - o) - LayoutDetector.margin) < 1.0 {  // около порога
            fragile += 1
            if fragileEx.count < 10 { fragileEx.append("\(mis)→\(w) (Δ\(String(format: "%.1f", s-o)))") }
        }
    }
    print("  слов у самого порога margin=\(LayoutDetector.margin): \(fragile)")
    for e in fragileEx { print("    \(e)") }

    // 5. РАСПРЕДЕЛЕНИЕ длин слов в словарях (понять, где «вес» промахов)
    print("\n=== 5. Доля коротких слов в словарях (где детектор слабее) ===")
    func lenDist(_ a: [String]) -> [Int: Int] {
        var d: [Int: Int] = [:]
        for w in a where w.allSatisfy({ $0.isLetter }) { d[min(w.count, 8), default: 0] += 1 }
        return d
    }
    let rd = lenDist(ru), ed = lenDist(en)
    print("  RU: " + (2...8).map { "\($0 == 8 ? "8+" : "\($0)"):\(rd[$0] ?? 0)" }.joined(separator: " "))
    print("  EN: " + (2...8).map { "\($0 == 8 ? "8+" : "\($0)"):\(ed[$0] ?? 0)" }.joined(separator: " "))
}
}
