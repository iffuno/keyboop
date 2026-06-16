import Foundation

enum SwapDecision: Equatable {
    case keep
    case convert(toCyrillic: Bool)
}

/// Язык ПРЕДЫДУЩЕГО слова фразы (как оно выглядит на экране) — слабый приор для коротких
/// неоднозначных слов. Анализ (run-analyze.sh, 2026-06-09): ВСЕ промахи детектора — слова
/// 2–3 буквы (28.6% / 5.7%), и почти все они — словарные коллизии (yt↔не, in↔шт, th↔ер:
/// обе формы валидны, слово в вакууме нерешаемо). Контекст фразы — единственный сигнал,
/// который их разрешает. Стоимость: одно чтение последнего элемента массива + 1–2 Set-lookup,
/// которые и так выполняются, — в горячем пути ничего нового.
enum ContextHint {
    case none, cyrillic, latin

    static func of(_ word: String?) -> ContextHint {
        guard let w = word, !w.isEmpty else { return .none }
        if w.hasCyrillic { return .cyrillic }
        if w.hasLatinLetter { return .latin }
        return .none
    }
}

/// Двусторонний детектор «слово набрано не в той раскладке».
/// Каскад: guard'ы → force-swap → словарь → триграммная плаузивность (margin).
enum LayoutDetector {
    static let margin = 2.0

    /// Аббревиатуры без гласных — их статистика триграмм не вытягивает (факты, не копирайт).
    static let forceSwap: Set<String> = [
        "http","https","url","uri","api","rest","json","xml","yaml","csv","html","css",
        "sdk","cli","gui","ide","ssh","ftp","tcp","udp","ip","dns","vpn","ssl","tls",
        "smtp","jwt","cors","sql","nosql","git","npm","yarn","k8s","aws","gcp","kpi",
        "crm","seo","smm","mvp","cpu","gpu","ram","ssd","hdd","usb","pdf","mp3","mp4",
        "png","jpg","jpeg","svg","gif","ddos","iot","llm","gpt","ml","ai","ui","ux",
        "db","os","io","qa","ci","cd","jpg","webp","mvc","orm","cdn","dom","sdk"
    ]

    /// Однобуквенные RU-предлоги/союзы, набранные в EN-раскладке (f→а, d→в, b→и, r→к, j→о,
    /// e→у, z→я, c→с), — чиним. Их латинский исходник НЕ значимое английское слово. Только EN→RU.
    /// (Сверено по раскладке ЙЦУКЕН: я на клавише z, не q; q даёт й. Прежний коммент «q→я» был неверен.)
    /// Примечание: "c"→"с" добавлен (раньше был намеренно убран из-за «язык C»), но на практике
    /// одиночная «c» перед пробелом в русском тексте = предлог «с» в 99% случаев.
    static let ruSingleLetter: Set<String> = ["а", "в", "и", "к", "о", "с", "у", "я"]

    /// Символ — буква, ИЛИ его клавиша в другой раскладке даёт букву (х=[, ж=;, э=', ё=`, ъ=]).
    static func isLayoutLetter(_ c: Character) -> Bool {
        if c.isLetter { return true }
        let s = String(c)
        if let m = Keymap.enToRu[s], m.first?.isLetter == true { return true }
        if let m = Keymap.ruToEn[s], m.first?.isLetter == true { return true }
        return false
    }

    /// Буквенное ЯДРО для решения: срезаем ВЕДУЩИЕ и КОНЦЕВЫЕ символы-непары — скобки, кавычки, тире,
    /// пунктуацию: «(tckb»→«tckb», «tckb)»→«tckb», «„если"»→«если». Цифры НЕ срезаем (чтобы gj1/h2o/b2b
    /// остались keep по guard'у). Сама КОНВЕРСИЯ в Engine идёт по ПОЛНОМУ токену — скобка/кавычка
    /// проходят через Keymap.convert без изменений (та же клавиша в обеих раскладках). Прецедент: «(tckb»
    /// (= «(если») не чинилось, потому что core() срезал только концевые .,!?;:… (Иван 15.06).
    static func letterCore(of raw: String) -> String {
        var s = Substring(raw)
        while let f = s.first, !isLayoutLetter(f), !f.isNumber { s = s.dropFirst() }
        while let l = s.last,  !isLayoutLetter(l), !l.isNumber { s = s.dropLast() }
        return String(s)
    }

    // Пороги для режима «на лету»: текущий язык должен быть ПРАКТИЧЕСКИ невозможен
    // (низкая плотность триграмм), а другой — заметно лучше. Строже обычного decide.
    static let liveImpossible = -13.0
    static let liveMargin = 6.0

    /// Решение для режима «чинить на лету» (мид-слово). Срабатывает только когда сочетание
    /// букв в текущем языке практически невозможно, а в другом — нормально. Без словаря-«авось».
    static func liveDecide(word raw: String) -> SwapDecision {
        var coreSub = Substring(Self.letterCore(of: raw))   // срезаем ведущие/концевые скобки/кавычки/тире
        while let f = coreSub.first, f.isNumber { coreSub = coreSub.dropFirst() }   // и ведущие/концевые цифры
        while let l = coreSub.last,  l.isNumber { coreSub = coreSub.dropLast() }
        let core = String(coreSub)
        let w = core.lowercased()
        guard w.count >= 4, w.allSatisfy(Self.isLayoutLetter) else { return .keep }
        let sourceCyrillic = w.hasCyrillic, sourceLatin = w.hasLatinLetter
        guard sourceCyrillic != sourceLatin else { return .keep }
        let toCyrillic = !sourceCyrillic
        let swapped = Keymap.convert(core, toCyrillic: toCyrillic).lowercased()
        guard swapped != w, swapped.allSatisfy({ $0.isLetter }) else { return .keep }
        let data = LayoutData.shared
        // валидное слово текущего языка — не трогаем
        if sourceLatin, data.wordsEn.contains(w) { return .keep }
        if !sourceLatin, data.wordsRu.contains(w) { return .keep }
        let orig = data.plausibility(w, cyrillic: sourceCyrillic)
        let swap = data.plausibility(swapped, cyrillic: toCyrillic)
        if orig <= liveImpossible && swap > orig + liveMargin {
            return .convert(toCyrillic: toCyrillic)
        }
        return .keep
    }

    /// Решение для АВТО-режима. Manual-хоткей в это не заходит (юзер решил сам).
    /// prev — ПРЕДЫДУЩЕЕ слово фразы (как на экране): из него берём язык-контекст (разрешает
    /// короткие коллизии) И проверку слова-классификатора (vitamin/gen/plan → буква-маркер).
    /// На однозначные и длинные слова (5+ букв, 100% точность) НЕ влияет.
    static func decide(word raw: String, exceptions: ExceptionStore,
                       prev: String? = nil) -> SwapDecision {
        let context = ContextHint.of(prev)
        // Анализируем БУКВЕННОЕ ЯДРО (без ведущих/концевых скобок, кавычек, тире, пунктуации):
        // "(tckb"→"tckb", "привет."→"привет". Решаем по ядру, конвертим (в Engine) полный токен.
        var coreSub = Substring(Self.letterCore(of: raw))
        // Слово с ЦИФРАМИ: берём буквенную часть (срезаем ведущие/концевые цифры) и чиним ТОЛЬКО
        // длинные однородные слова (≥4): «ghbdtn2»→ядро «ghbdtn»→«привет2». Короткие/внутренние
        // цифро-токены (gj1, h2o, b2b, d2, 2gis, i18n) остаются keep — ядро <4 или не сплошное буквенное.
        let hadDigits = coreSub.contains(where: { $0.isNumber })
        if hadDigits {
            while let f = coreSub.first, f.isNumber { coreSub = coreSub.dropFirst() }
            while let l = coreSub.last,  l.isNumber { coreSub = coreSub.dropLast() }
        }
        let coreRaw = String(coreSub)
        let w = coreRaw.lowercased()
        // Буква ИЛИ клавиша-буква в другой раскладке (х=[, ж=;, э=', ё=`, ъ=]) — иначе слова с х/ъ/ж/э/ё
        // не детектились бы. Цифро-слова — порог 4 (короткие коллизии вроде gj1→по1 не трогаем).
        guard w.count >= (hadDigits ? 4 : 1), w.allSatisfy(Self.isLayoutLetter) else { return .keep }
        if exceptions.ignored.contains(w) { return .keep }
        // Выученное на отмене — тоже .keep (юзер уже доказал откатами, что это слово трогать не надо).
        if exceptions.learned.contains(w) { return .keep }
        // Бренды/сервисы, которые НИКОГДА не трогаем (вк→dr и т.п.) — по умолчанию у всех,
        // в любом контексте. Раньше словаря и контекста: жёстче любого статистического сигнала.
        if ExtraWords.defaultKeep.contains(w) { return .keep }

        let sourceCyrillic = w.hasCyrillic
        let sourceLatin = w.hasLatinLetter
        // ровно одна система (не смешанное, не пусто)
        guard sourceCyrillic != sourceLatin else { return .keep }

        let toCyrillic = !sourceCyrillic
        let swapped = Keymap.convert(coreRaw, toCyrillic: toCyrillic).lowercased()
        guard swapped != w, swapped.allSatisfy({ $0.isLetter }) else { return .keep }

        // 1. Force-swap (до словаря): аббревиатуры. КРИТИЧНО (баг, ревизия 2026-06-13): встроенный
        //    forceSwap бил ДО словаря и без контекста → съедал ВАЛИДНЫЕ русские слова, чья латинская
        //    раскладка-форма совпала с аббревиатурой: «еды»→tls, «св»→cd, «шву»→ide. Поэтому форсим
        //    встроенным списком ТОЛЬКО если исходник — НЕ настоящее слово (гиббериш в своём языке).
        //    Пользовательский exceptions.forceSwap — явное намерение, уважаем без гейта.
        let sourceIsRealWord = LayoutData.shared.wordsRu.contains(w) || LayoutData.shared.wordsEn.contains(w)
        if forceSwap.contains(swapped), !sourceIsRealWord {
            return .convert(toCyrillic: toCyrillic)
        }
        if exceptions.forceSwap.contains(swapped) {
            return .convert(toCyrillic: toCyrillic)
        }
        if forceSwap.contains(w) || exceptions.forceSwap.contains(w) {
            return .keep // ввели "sql" осознанно — оставить
        }

        // ★ STRICT-GATE (принцип Ивана, 2026-06-14): СЛОВО, ВАЛИДНОЕ В ЯЗЫКЕ, НА КОТОРОМ НАБРАНО, —
        //   НИКОГДА не переключаем, даже если его раскладочная пара тоже валидное слово. Переключаем
        //   ТОЛЬКО кашу (не-слово). Прецедент: «her»(EN)→«рук»(RU) — недопустимо. Гейт по СЛОВАРЮ
        //   (sourceIsRealWord = слово в словаре своего языка), без статистики — надёжно. Стоит ВЫШЕ
        //   контекстно-словарной логики (чтобы «here» в рус.контексте тоже не ломалось) и одиночных
        //   букв (count==1 — отдельная тема, шаг 2). forceRuAmb (ns/yt/... — намеренный форс каши-
        //   токенов) ПРОПУСКАЕМ сквозь гейт: читаем ТОТ ЖЕ Set, без дублирования. «ghbdtn» нет в
        //   словаре → гейт не держит → дойдёт до триграмм и сконвертится (ядро цело).
        if w.count >= 2, sourceIsRealWord, !(sourceLatin && ExtraWords.forceRuAmb.contains(w)) {
            return .keep
        }

        // 2. Одиночные буквы. Короткие RU-предлоги, набранные в EN-раскладке (d→в, c→с, r→к, …),
        // починим — латинский исходник не значимое слово. Только EN→RU. Тонкость с контекстом:
        //   • после ОБЫЧНОГО английского слова («room d новой») — ЧИНИМ предлог;
        //   • после слова-КЛАССИФИКАТОРА («vitamin d», «gen z», «plan b») — буква-маркер, НЕ трогаем;
        //   • в режиме разработчика одиночные буквы вообще не доходят сюда (soft-фильтр в Engine).
        if w.count == 1 {
            if sourceLatin, Self.ruSingleLetter.contains(swapped) {
                if let p = prev?.lowercased() {
                    // буква-маркер после классификатора: «vitamin d» (англ.) ИЛИ «витамин d» (рус.).
                    if context == .latin, ExtraWords.labelClassifiers.contains(p) { return .keep }
                    if context == .cyrillic, ExtraWords.ruLabelClassifiers.contains(p) { return .keep }
                }
                return .convert(toCyrillic: true)
            }
            return .keep
        }

        let data = LayoutData.shared

        // 3. Словарь: валидно в текущей → keep; swap валиден в целевой → convert.
        //    КОЛЛИЗИИ (обе формы валидны: yt↔не, in↔шт — после обогащения словаря ~93 пары 2–5 букв)
        //    в вакууме нерешаемы,
        //    их разрешает контекст фразы: предыдущее слово русское → юзер пишет по-русски.
        if sourceLatin {
            // forceRuAmb: слова, технически есть в EN-словаре, но в RU-контексте
            // набираются в неверной раскладке (tot→еще).
            // Для них не делаем early-return на wordsEn — продолжаем в RU-проверку.
            if data.wordsEn.contains(w), !ExtraWords.forceRuAmb.contains(w) {
                if context == .cyrillic, data.wordsRu.contains(swapped),
                   !ExtraWords.enKeepShort.contains(w) {
                    return .convert(toCyrillic: true)   // «привет yt» → «привет не»
                }
                return .keep
            }
            if data.wordsRu.contains(swapped) {
                // Частый EN-токен вне словаря (vs, lol) при ЛАТИНСКОМ контексте («Loko vs CSKA»)
                // — намеренный английский, не каша. При русском/пустом — чиним (vs→мы).
                if context == .latin, ExtraWords.enKeepShort.contains(w) { return .keep }
                return .convert(toCyrillic: true)
            }
        } else {
            if data.wordsRu.contains(w) {
                if context == .latin, data.wordsEn.contains(swapped) {
                    return .convert(toCyrillic: false)  // «hello шт» → «hello in» (фраза EN в RU-раскладке)
                }
                return .keep
            }
            if data.wordsEn.contains(swapped) { return .convert(toCyrillic: false) }
        }

        // 4. Триграммы (словоформы, которых нет в плоском словаре) — ТОЛЬКО для слов
        //    от 4 букв. На коротких (≤3) статистика ненадёжна и даёт ложняки вида
        //    «тк»→«nr» (в EN нет слова «nr»): короткое слово переключаем строго по
        //    словарю/аббревиатурам/одиночным буквам (шаги 1–3 выше), иначе — оставляем.
        guard w.count >= 4 else { return .keep }
        let origScore = data.plausibility(w, cyrillic: sourceCyrillic)
        let swapScore = data.plausibility(swapped, cyrillic: toCyrillic)
        if swapScore > origScore + margin { return .convert(toCyrillic: toCyrillic) }
        // оригинал — сплошной мусор, swap заметно лучше
        if origScore <= -19.0 && swapScore > origScore + 1.0 {
            return .convert(toCyrillic: toCyrillic)
        }
        return .keep
    }
}
