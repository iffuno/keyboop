import Foundation

// Аудит ПРОМАХОВ детектора на ЧАСТОТНЫХ русских словах: какие частотные слова, набранные в
// EN-раскладке, детектор НЕ чинит (оставляет латинскую кашу/коллизию). Вход — частотный список
// (KEYBOOP_FREQ=/tmp/ru_freq.txt, формат «слово частота», по убыванию). Запуск — run-missaudit.sh.
//
// Тиры промаха:
//   T1 SEVERE   — .keep И standalone, И в русском контексте (prev=рус. слово) → НИКОГДА не чинится.
//   T2 STANDALONE — .keep standalone, но чинится в русском контексте → ломается только как 1-е слово.
// Поднклассы по латинской форме: [gibberish] — lat НЕ англ. слово (безопасно форсить);
//   [en:WORD] — lat валидное англ. слово (коллизия, форсить осторожно / решает контекст).

@main
struct MissAuditMain {
static func main() {
    let data = LayoutData.shared
    guard data.isLoaded else { print("❌ нет данных — нужен KEYBOOP_DATA_DIR"); exit(1) }
    let exc = ExceptionStore.shared

    let freqPath = ProcessInfo.processInfo.environment["KEYBOOP_FREQ"] ?? "/tmp/ru_freq.txt"
    guard let raw = try? String(contentsOfFile: freqPath, encoding: .utf8) else {
        print("❌ нет частотного файла \(freqPath)"); exit(1)
    }
    let topN = Int(ProcessInfo.processInfo.environment["KEYBOOP_TOPN"] ?? "3000") ?? 3000

    // (rank, слово) — только кириллические слова длиной 2…6, в порядке частоты.
    var ranked: [(rank: Int, w: String)] = []
    var rank = 0
    for line in raw.split(separator: "\n") {
        let parts = line.split(separator: " ")
        guard let first = parts.first else { continue }
        let w = String(first).lowercased()
        rank += 1
        if rank > topN { break }
        guard w.count >= 2, w.count <= 6, w.allSatisfy({ $0.isLetter && String($0).hasCyrillic }) else { continue }
        ranked.append((rank, w))
    }

    func decide(_ lat: String, prev: String?) -> Bool {   // true = .convert
        if case .convert = LayoutDetector.decide(word: lat, exceptions: exc, prev: prev) { return true }
        return false
    }

    struct Miss { let rank: Int; let w: String; let lat: String; let latIsEn: Bool }
    var t1: [Miss] = []   // severe: keep даже в рус. контексте
    var t2: [Miss] = []   // standalone-only

    for (rank, w) in ranked {
        let lat = Keymap.convert(w, toCyrillic: false).lowercased()
        guard lat != w, lat.allSatisfy({ $0.isLetter }) else { continue }   // только буквенная форма
        // обратная проверка: lat действительно конвертится обратно в w? (1:1 раскладка)
        guard Keymap.convert(lat, toCyrillic: true).lowercased() == w else { continue }
        let standalone = decide(lat, prev: nil)
        let inRu = decide(lat, prev: "привет")
        let m = Miss(rank: rank, w: w, lat: lat, latIsEn: data.wordsEn.contains(lat))
        if !standalone && !inRu { t1.append(m) }
        else if !standalone && inRu { t2.append(m) }
    }

    func dump(_ title: String, _ arr: [Miss]) {
        print("\n\(title)  — всего \(arr.count)")
        let gib = arr.filter { !$0.latIsEn }
        let col = arr.filter { $0.latIsEn }
        print("  • [gibberish] lat НЕ англ.слово (безопасно форсить) — \(gib.count):")
        for m in gib.prefix(60) { print(String(format: "      #%-5d %@ → %@", m.rank, m.w, m.lat)) }
        print("  • [collision] lat валидное англ.слово (осторожно) — \(col.count):")
        for m in col.prefix(60) { print(String(format: "      #%-5d %@ → %@  (en:%@)", m.rank, m.w, m.lat, m.lat)) }
    }

    print("=== АУДИТ ПРОМАХОВ на топ-\(topN) частотных рус. словах (длина 2–6) ===")
    print("Проверено кандидатов: \(ranked.count)")
    dump("T1 SEVERE — НЕ чинится никогда (даже в русском контексте)", t1.sorted { $0.rank < $1.rank })
    dump("T2 STANDALONE — не чинится как 1-е слово (в русском контексте чинится)", t2.sorted { $0.rank < $1.rank })

    // JSON-выгрузка для агентов-кураторов (KEYBOOP_OUT=path).
    if let out = ProcessInfo.processInfo.environment["KEYBOOP_OUT"] {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\"", with: "\\\"") }
        func arr(_ a: [Miss], _ tier: String) -> [String] {
            a.sorted { $0.rank < $1.rank }.map {
                "{\"tier\":\"\(tier)\",\"rank\":\($0.rank),\"ru\":\"\(esc($0.w))\",\"lat\":\"\(esc($0.lat))\",\"latIsEn\":\($0.latIsEn)}"
            }
        }
        let all = arr(t1, "T1") + arr(t2, "T2")
        let json = "[\n  " + all.joined(separator: ",\n  ") + "\n]\n"
        try? json.write(toFile: out, atomically: true, encoding: .utf8)
        print("\nJSON-кандидаты записаны: \(out) (\(all.count) шт.)")
    }
}
}
