import Foundation

// Self-test детектора Keyboop: гоняет LayoutDetector на больших выборках из словарей.
// Сборка/запуск — run-selftest.sh (нужен KEYBOOP_DATA_DIR).

let data = LayoutData.shared
guard data.isLoaded else {
    print("❌ Данные не загрузились. Запускай через run-selftest.sh (KEYBOOP_DATA_DIR).")
    exit(1)
}
let exc = ExceptionStore.shared

func decide(_ w: String) -> SwapDecision { LayoutDetector.decide(word: w, exceptions: exc) }

/// Репрезентативная выборка фиксированного размера (детерминированно, через stride).
func sample(_ arr: [String], _ count: Int) -> [String] {
    guard arr.count > count, count > 0 else { return arr }
    let step = max(1, arr.count / count)
    return stride(from: 0, to: arr.count, by: step).map { arr[$0] }
}

// sorted() — детерминизм: порядок Set рандомизирован per-process (hash seed), без сортировки
// сэмплы плавают между запусками и метрики «дышат» (99.31↔99.38 — это был шум, не код).
let ruWords = Array(data.wordsRu).sorted()
let enWords = Array(data.wordsEn).sorted()
let N = 8000

print("=== Keyboop self-test детектора ===")
print("Словари: RU \(ruWords.count), EN \(enWords.count). Выборка по \(N) на сценарий.\n")

// 1. RU-негативы: валидные русские слова → НЕ трогать (.keep). convert = ложное срабатывание.
var ruN = 0, ruFP = 0; var ruFPex: [String] = []
for w in sample(ruWords, N) where w.count >= 2 && w.allSatisfy({ $0.isLetter }) {
    ruN += 1
    if case .convert = decide(w) { ruFP += 1; if ruFPex.count < 12 { ruFPex.append(w) } }
}

// 2. EN-негативы
var enN = 0, enFP = 0; var enFPex: [String] = []
for w in sample(enWords, N) where w.count >= 2 && w.allSatisfy({ $0.isLetter }) {
    enN += 1
    if case .convert = decide(w) { enFP += 1; if enFPex.count < 12 { enFPex.append(w) } }
}

// 3. RU-в-EN-раскладке: русское слово, набранное латиницей → ДОЛЖЕН переключить.
var ruPos = 0, ruMiss = 0; var ruMissEx: [String] = []
for w in sample(ruWords, N) where w.count >= 2 {
    let mis = Keymap.convert(w, toCyrillic: false) // ru → latin
    guard mis != w, mis.allSatisfy({ $0.isLetter }) else { continue }
    ruPos += 1
    if case .keep = decide(mis) { ruMiss += 1; if ruMissEx.count < 12 { ruMissEx.append("\(mis)→\(w)") } }
}

// 4. EN-в-RU-раскладке: английское слово, набранное кириллицей → ДОЛЖЕН переключить.
var enPos = 0, enMiss = 0; var enMissEx: [String] = []
for w in sample(enWords, N) where w.count >= 2 {
    let mis = Keymap.convert(w, toCyrillic: true) // en → cyrillic
    guard mis != w, mis.allSatisfy({ $0.isLetter }) else { continue }
    enPos += 1
    if case .keep = decide(mis) { enMiss += 1; if enMissEx.count < 12 { enMissEx.append("\(mis)→\(w)") } }
}

func pct(_ a: Int, _ b: Int) -> String {
    guard b > 0 else { return "—" }
    return String(format: "%.2f%%", Double(a) / Double(b) * 100)
}

print("── Ложные срабатывания (трогает валидное слово — ПЛОХО) ──")
print("RU валидные:  \(ruFP)/\(ruN) = \(pct(ruFP, ruN))   примеры: \(ruFPex.joined(separator: ", "))")
print("EN валидные:  \(enFP)/\(enN) = \(pct(enFP, enN))   примеры: \(enFPex.joined(separator: ", "))")
print()
print("── Пропуски (НЕ переключил кашу — ПЛОХО) ──")
print("RU-в-EN:      \(ruMiss)/\(ruPos) = \(pct(ruMiss, ruPos))   примеры: \(ruMissEx.joined(separator: ", "))")
print("EN-в-RU:      \(enMiss)/\(enPos) = \(pct(enMiss, enPos))   примеры: \(enMissEx.joined(separator: ", "))")
print()
let fpTotal = ruFP + enFP, negTotal = ruN + enN
let missTotal = ruMiss + enMiss, posTotal = ruPos + enPos
print("── ИТОГ ──")
print("Точность на валидных (не трогаем):  \(pct(negTotal - fpTotal, negTotal))  (ложных: \(fpTotal))")
print("Полнота на «каше» (ловим промах):   \(pct(posTotal - missTotal, posTotal))  (пропущено: \(missTotal))")

print("\n── Конкретные кейсы: мат/сленг (должны → convert) ──")
let cases = ["охуенно","заебись","пиздец","кринж","ору","жесть","yeet","sus","rizz","bussin","slay","ngl"]
for word in cases {
    let cyr = word.hasCyrillic
    let mis = Keymap.convert(word, toCyrillic: !cyr) // набрано в неправильной раскладке
    if case .convert = decide(mis) { print("  \(mis)  →  \(word)   ✓") }
    else { print("  \(mis)  →  \(word)   ✗ не ловит") }
}

// ── Регрессия сессии 2026-06-09: одиночная «c» и forceRuAmb (tot/net) ──
// Печатаем ФАКТИЧЕСКУЮ конверсию (а не предполагаемую по раскладке) и решение детектора.
print("\n── Регрессия 0.1.52: одиночные буквы + forceRuAmb ──")
func showCase(_ input: String, expectConvert: Bool) {
    let d = decide(input)
    let toCyr: Bool
    switch d {
    case .convert(let c): toCyr = c
    case .keep: toCyr = !input.hasCyrillic
    }
    let result = Keymap.convert(input, toCyrillic: toCyr)
    let converted: Bool = { if case .convert = d { return true }; return false }()
    let ok = converted == expectConvert
    let arrow = converted ? "\(input) → \(result)" : "\(input) (keep)"
    print("  \(ok ? "✓" : "✗")  \(arrow)   ожидали \(expectConvert ? "convert" : "keep")")
}
showCase("c",   expectConvert: true)   // одиночная c → с (предлог)
showCase("tot", expectConvert: false)  // strict-gate: "tot" — реальное EN-слово (малыш) → keep (принцип 2026-06-14)
// контроль: настоящие англ. слова НЕ должны конвертиться
showCase("the", expectConvert: false)
showCase("a",   expectConvert: false)  // одиночная 'a' — англ. артикль, оставляем
showCase("no",  expectConvert: false)  // намеренно НЕ в forceRuAmb
showCase("net", expectConvert: false)  // net→«туе» (не «нет»!) + частое EN-слово → keep

// ── Контекстный приор: предыдущее слово решает коллизии И классификаторы (vitamin d) ──
print("\n── Контекстный приор (prev-слово) ──")
func showCtx(_ input: String, prev: String?, expectConvert: Bool, _ note: String = "") {
    let d = LayoutDetector.decide(word: input, exceptions: exc, prev: prev)
    let conv: Bool = { if case .convert = d { return true }; return false }()
    let ok = conv == expectConvert
    let pn = prev == nil ? "—" : "«\(prev!)»"
    print("  \(ok ? "✓" : "✗")  \(input) [\(pn)] → \(conv ? "convert" : "keep")   ожидали \(expectConvert ? "convert" : "keep")  \(note)")
}
// коллизия yt↔не: решает контекст; без — статус-кво (keep); после обычного EN-слова keep
showCtx("yt", prev: "привет", expectConvert: true,  "(→не)")
showCtx("yt", prev: nil,      expectConvert: true)   // forceRuAmb: «yt»→«не» (#2 по частоте) даже standalone
showCtx("yt", prev: "room",   expectConvert: false)  // но после англ. слова бережём (enKeepShort)
// keep-список: частые EN-токены в русском тексте НЕ трогаем
showCtx("tv", prev: "смотрю", expectConvert: false, "(keep-список)")
showCtx("at", prev: "созвон", expectConvert: false, "(keep-список)")
showCtx("vs", prev: "спартак", expectConvert: false, "(strict-gate: «vs» — валидный EN-токен → keep даже в рус.фразе)")
showCtx("vs", prev: "loko",   expectConvert: false, "(«Loko vs CSKA»)")
showCtx("cv", prev: "пришли", expectConvert: false, "(keep-список)")
// ОДИНОЧНЫЕ ПРЕДЛОГИ — главное: чиним после ОБЫЧНОГО слова, бережём после КЛАССИФИКАТОРА
showCtx("c", prev: nil,       expectConvert: true)
showCtx("d", prev: nil,       expectConvert: true,  "(→в: предлог)")
showCtx("d", prev: "еду",     expectConvert: true,  "(«еду d город»)")
showCtx("d", prev: "room",    expectConvert: true,  "(«room d новой» → ЧИНИМ — room обычное)")
showCtx("d", prev: "dark",    expectConvert: true,  "(«dark d» → чиним)")
showCtx("d", prev: "vitamin", expectConvert: false, "(«vitamin d» — классификатор бережёт)")
showCtx("c", prev: "vitamin", expectConvert: false, "(«vitamin c»)")
showCtx("b", prev: "plan",    expectConvert: false, "(«plan b»)")
showCtx("z", prev: "gen",     expectConvert: false, "(«gen z»)")
showCtx("z", prev: nil,       expectConvert: true,  "(→я)")
showCtx("q", prev: nil,       expectConvert: false, "(q→й — не слово)")
// обратная сторона: RU-слово в латинском контексте (фраза EN в RU-раскладке)
showCtx("шт", prev: "hello",  expectConvert: false, "(strict-gate: «шт» — валидное RU-слово (штук) → keep)")
showCtx("шт", prev: "десять", expectConvert: false, "(«десять шт»)")
showCtx("шт", prev: nil,      expectConvert: false)
// defaultKeep: бренды (вк→dr) НЕ трогаем ни в каком контексте
showCtx("вк", prev: nil,      expectConvert: false, "(ВКонтакте — defaultKeep)")
showCtx("вк", prev: "мой",    expectConvert: false, "(«мой вк»)")
showCtx("вк", prev: "open",   expectConvert: false, "(даже после англ. слова)")
showCtx("тг", prev: nil,       expectConvert: false, "(Telegram → nu)")
showCtx("ок", prev: nil,       expectConvert: false, "(Окей → jr)")
showCtx("оз", prev: nil,       expectConvert: false, "(Ozon → jp)")
showCtx("лс", prev: nil,       expectConvert: false, "(личные сообщения → kc)")
showCtx("сек", prev: nil,      expectConvert: false, "(«сек, гляну» → ctr)")
showCtx("мск", prev: nil,      expectConvert: false, "(Москва → vcr)")
showCtx("зп", prev: nil,       expectConvert: false, "(зарплата → pg)")
showCtx("дз", prev: nil,       expectConvert: false, "(домашка → lp)")
showCtx("дс", prev: nil,       expectConvert: false, "(деньги/Дискорд → lc)")
showCtx("ндфл", prev: nil,     expectConvert: false, "(НДФЛ → ylak)")
// «ты» (ns) — частотное местоимение, форсим; но «ns» как наносекунды в англ. контексте бережём
showCtx("ns", prev: nil,       expectConvert: true,  "(→ты: standalone)")
showCtx("ns", prev: "привет",  expectConvert: true,  "(«привет ты»)")
showCtx("ns", prev: "delay",   expectConvert: false, "(«delay ns» — наносекунды, англ. контекст)")
// Группа B: служебные слова чиним standalone и после русского, бережём после английского
showCtx("yt", prev: nil,       expectConvert: true,  "(→не: standalone, #2 по частоте)")
showCtx("pf", prev: nil,       expectConvert: true,  "(→за)")
showCtx("bp", prev: nil,       expectConvert: true,  "(→из)")
showCtx("ye", prev: nil,       expectConvert: false, "(strict-gate: «ye» — реальное EN-слово (арх.) → keep)")
// ── STRICT-GATE (принцип «валидное слово в своём языке — НИКОГДА не трогаем», 2026-06-14) ──
// Прецедент-баг: «her»(EN)→«рук»(RU). Валидное слово keep ДАЖЕ в чужом контексте; каша по-прежнему чинится.
showCtx("her",  prev: "привет", expectConvert: false, "(БАГ ПОЧИНЕН: валидное EN her → keep, не рук)")
showCtx("here", prev: "привет", expectConvert: false, "(валидное EN → keep, не руку)")
showCtx("herb", prev: "привет", expectConvert: false, "(валидное EN → keep, не руки)")
showCtx("cat",  prev: "привет", expectConvert: false, "(валидное EN → keep)")
showCtx("key",  prev: "привет", expectConvert: false, "(валидное EN → keep)")
showCtx("ghbdtn", prev: "мой",  expectConvert: true,  "(ЯДРО: каша → привет, гейт пропускает)")
showCtx("bp", prev: "blood",   expectConvert: false, "(«blood bp» — англ. контекст, бережём)")
showCtx("yt", prev: "watch",   expectConvert: false, "(«watch yt» — YouTube, англ. контекст)")

// Flip-аудит безопасности: валидные слова, меняющие решение под контекстом.
// prev для ru-контекста — «привет», для en — «room» (обычное слово, НЕ классификатор).
var enFlip = 0; var enFlipEx: [String] = []
for w in enWords where w.count >= 2 && w.count <= 5 && w.allSatisfy({ $0.isLetter }) {
    if case .convert = LayoutDetector.decide(word: w, exceptions: exc, prev: "привет"),
       case .keep = LayoutDetector.decide(word: w, exceptions: exc, prev: nil) {
        enFlip += 1
        if enFlipEx.count < 25 { enFlipEx.append("\(w)→\(Keymap.convert(w, toCyrillic: true))") }
    }
}
var ruFlip = 0; var ruFlipEx: [String] = []
for w in ruWords where w.count >= 2 && w.count <= 5 && w.allSatisfy({ $0.isLetter }) {
    if case .convert = LayoutDetector.decide(word: w, exceptions: exc, prev: "room"),
       case .keep = LayoutDetector.decide(word: w, exceptions: exc, prev: nil) {
        ruFlip += 1
        if ruFlipEx.count < 25 { ruFlipEx.append("\(w)→\(Keymap.convert(w, toCyrillic: false))") }
    }
}
print("\n── Flip-аудит: валидные слова, меняющие решение ТОЛЬКО под контекстом ──")
print("EN при ru-ctx: \(enFlip)   \(enFlipEx.joined(separator: ", "))")
print("RU при en-ctx: \(ruFlip)   \(ruFlipEx.joined(separator: ", "))")
// Безопасность совпадающего контекста: ложных срабатываний быть НЕ должно
var enSafe = 0, ruSafe = 0
for w in sample(enWords, 6000) where w.count >= 2 && w.allSatisfy({ $0.isLetter }) {
    if ExtraWords.forceRuAmb.contains(w) { continue }   // tot и др. конвертятся всегда by design
    if case .convert = LayoutDetector.decide(word: w, exceptions: exc, prev: "room") { enSafe += 1 }
}
for w in sample(ruWords, 6000) where w.count >= 2 && w.allSatisfy({ $0.isLetter }) {
    if case .convert = LayoutDetector.decide(word: w, exceptions: exc, prev: "привет") { ruSafe += 1 }
}
print("Совпадающий контекст (EN+en-ctx, RU+ru-ctx) ложных: \(enSafe) + \(ruSafe)  (ожидаем 0+0)")

// Микробенчмарк: затраты decide() на слово (требование Ивана: быстро, без ресурсов)
let benchWords = sample(ruWords, 200).map { Keymap.convert($0, toCyrillic: false) }
var sink = 0
let bt0 = CFAbsoluteTimeGetCurrent()
for _ in 0..<100 {
    for w in benchWords {
        if case .convert = LayoutDetector.decide(word: w, exceptions: exc, prev: "привет") { sink += 1 }
    }
}
let perOp = (CFAbsoluteTimeGetCurrent() - bt0) / Double(100 * benchWords.count) * 1e6
print(String(format: "\n── Микробенч: decide(+context) = %.1f мкс/слово (раз на пробел; sink=%d) ──", perOp, sink))

// ── Exhaustive forceSwap × словарь (ревизия 2026-06-13): forceSwap бьёт ДО словаря и без
//    контекста. Sample-тест 8k из 162k это пропускал → баг «еды»→tls/«св»→cd/«шву»→ide.
//    Проверяем ПОЛНЫЙ словарь: ни одна встроенная аббревиатура не должна съедать валидное RU-слово. ──
print("\n── forceSwap × словарь: затеняемые валидным RU-словом аббревиатуры ──")
var fsShadow: [String] = []
var fsBug = 0
for abbr in LayoutDetector.forceSwap {
    let ruPre = Keymap.convert(abbr, toCyrillic: true).lowercased()  // что юзер набрал бы в RU-раскладке
    guard ruPre != abbr, LayoutData.shared.wordsRu.contains(ruPre) else { continue }
    fsShadow.append("\(abbr)↔\(ruPre)")
    if case .convert = decide(ruPre) {            // валидное слово ОБЯЗАНО остаться (guard в decide)
        fsBug += 1
        print("  ✗ БАГ: валидное «\(ruPre)» конвертится из-за forceSwap «\(abbr)»")
    }
}
print("  затеняемых: \(fsShadow.count) (\(fsShadow.sorted().joined(separator: ", ")))")
print("  багов (валидное слово → конверт): \(fsBug)  (ожидаем 0 — иначе forceSwap ест слово)")

// ── Групповая конвертация (H): пословный decide() — валидные слова НЕ трогаем ──
// Та же логика, что Engine.convertGroup: по каждому слову decide → convert/keep.
print("\n── Групповая конвертация (пословный decide) ──")
func groupConvert(_ phrase: String) -> String {
    phrase.split(separator: " ").map { tok -> String in
        let w = String(tok)
        switch decide(w) {
        case .convert(let toCyr): return Keymap.smartConvert(w, toCyrillic: toCyr)
        case .keep:               return w
        }
    }.joined(separator: " ")
}
func showGroup(_ input: String, _ expect: String) {
    let got = groupConvert(input)
    print("  \(got == expect ? "✓" : "✗")  «\(input)» → «\(got)»   ожидали «\(expect)»")
}
showGroup("ghbdtn rfr", "привет как")        // оба — каша → конвертим
showGroup("hello ghbdtn", "hello привет")    // hello валидное EN → keep; ghbdtn → привет
showGroup("ghbdtn world", "привет world")    // world валидное EN → keep
