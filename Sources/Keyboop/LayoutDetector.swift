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

/// Форма именно СЛОВА через ASCII-дефис. Вынесена из словарного решения, чтобы до него не
/// добирались минусы, диапазоны, `--flags`, висячий/двойной дефис и идентификаторы. Обычные
/// внешние скобки и кавычки срезаются, но внешний `-` никогда не считается пунктуацией.
enum HyphenTokenShape {
    static func linguisticCore(
        of raw: String,
        isLayoutLetter: (Character) -> Bool
    ) -> String? {
        // Цифры считаем возможной границей ядра, но ниже не разрешаем внутри сегментов. Так `5-3`
        // и `2xnj-nj` отклоняются, а не превращаются в слово после тихого срезания цифр.
        // `isLayoutLetter` нужен и на границе: `[`, `;`, `'`, `,`, `.` могут быть буквами другой
        // раскладки, поэтому Character.isLetter здесь потерял бы «во-первых» (`dj-gthds[`).
        guard let first = raw.firstIndex(where: { isLayoutLetter($0) || $0.isNumber }),
              let last = raw.lastIndex(where: { isLayoutLetter($0) || $0.isNumber })
        else { return nil }

        if raw[raw.startIndex..<first].contains("-") { return nil }
        if raw[raw.index(after: last)...].contains("-") { return nil }

        var segment = ""
        var segments = 0
        for character in raw[first...last] {
            if character == "-" {
                guard !segment.isEmpty else { return nil }
                segment.removeAll(keepingCapacity: true)
                segments += 1
            } else {
                guard isLayoutLetter(character) else { return nil }
                segment.append(character)
            }
        }
        guard segments >= 1, !segment.isEmpty else { return nil }
        return String(raw[first...last])
    }
}

/// Двусторонний детектор «слово набрано не в той раскладке».
/// Каскад: guard'ы → force-swap → словарь → триграммная плаузивность (margin).
enum LayoutDetector {
    static let margin = 2.0
    /// Порог «EN-форма короткого кир-фрагмента — не мусор» (плаузибельность ≥ этого → реальное слово).
    /// Отсекает nm/cz/cm/tn (< −11), пропускает it/in/of/the/so (> −9.5). См. enSwapNotJunk в decide().
    static let shortEnSwapFloor = -10.0

    /// Аббревиатуры без гласных — их статистика триграмм не вытягивает (факты, не копирайт).
    static let forceSwap: Set<String> = [
        "http","https","url","uri","api","rest","json","xml","yaml","csv","html","css",
        "sdk","cli","gui","ide","ssh","ftp","tcp","udp","ip","dns","vpn","ssl","tls",
        "smtp","jwt","cors","sql","nosql","git","npm","yarn","k8s","aws","gcp","kpi",
        "crm","seo","smm","mvp","cpu","gpu","ram","ssd","hdd","usb","pdf","mp3","mp4",
        "png","jpg","jpeg","svg","gif","ddos","iot","llm","gpt","ml","ai","ui","ux",
        "db","os","io","qa","ci","cd","jpg","webp","mvc","orm","cdn","dom","sdk"
    ]

    /// Схлопнуть растянутые буквы: «круууто» → «круто», «нуууу» → «ну», «coooool» → «cool».
    /// nil, если растягивать нечего — тогда и проверять нечего, и лишней работы не будет.
    ///
    /// Порог ТРИ подряд, а не два: «ванна», «класс», «сумма», «Анна» — обычные слова, и схлопывать
    /// в них удвоение значило бы ломать орфографию ради выдуманной проблемы.
    /// ⚠️ ВАРИАНТОВ ДВА, И ОБА НУЖНЫ. Растянуть можно и букву, которая в слове законно удвоена:
    /// «класссно» это «классно» (сжать до двух), а «круууто» это «круто» (сжать до одной). Один
    /// вариант обязательно промахнётся, поэтому спрашиваем словарь про оба.
    static func deElongated(_ s: String) -> [String]? {
        var run = 0
        var prev: Character? = nil
        var hasElongation = false
        var toTwo = ""
        var toOne = ""
        for c in s {
            if c == prev { run += 1 } else { run = 1; prev = c }
            if run >= 3 { hasElongation = true }
            if run <= 2 { toTwo.append(c) }
            if run == 1 { toOne.append(c) }
        }
        guard hasElongation else { return nil }
        return toTwo == toOne ? [toOne] : [toTwo, toOne]
    }

    /// Настоящее слово перед КОНЦЕВОЙ пунктуацией важнее альтернативного прочтения той же клавиши
    /// как буквы другой раскладки. На русской клавише `ю` лежит английская `.`, на `б` — `,`, на
    /// `ж` — `;`: поэтому `it.` целиком выглядит как русское `шею`, хотя человек набрал корректное
    /// английское слово и точку. Это тот же strict-gate, только для семантического ядра до знака.
    ///
    /// Не защищаем `forceRuAmb`: для этих редких EN-форм продукт уже осознанно выбрал частое русское
    /// слово. Явный пользовательский force-swap проверяется позже и тоже остаётся сильнее guard'а.
    static func hasValidSourceBeforeTrailingPunctuation(
        _ rawCore: String,
        forcedSource: Set<String> = []
    ) -> Bool {
        let whole = rawCore.lowercased()
        let semantic = Keymap.core(of: whole)
        // Как и основной strict-gate, не доверяем односимвольным «словам» из шумного EN-словаря:
        // иначе `t.`/`e;` перестанут чиниться в настоящие `ею`/`уж`.
        guard semantic != whole, semantic.count >= 2 else { return false }
        let cyrillic = semantic.hasCyrillic
        let latin = semantic.hasLatinLetter
        guard cyrillic != latin else { return false }
        // `api.` и пользовательский победитель спорной пары должны вести себя ровно как `api`:
        // «всегда переключать» означает конвертировать В него, но не из него.
        if Self.forceSwap.contains(semantic) || forcedSource.contains(semantic) { return true }
        // ⚠️ «txt.», «yml,», «lgtm.» (задача 264, 26.09.2026): известный латинский токен со знаком
        // это тот же токен, а не русское «ечею». Список только латинский, кириллицу не задевает.
        if latin, ExtraWords.techLatinTokens.contains(semantic) { return true }
        if latin, ExtraWords.forceRuAmb.contains(semantic) { return false }
        let words = cyrillic ? LayoutData.shared.wordsRu : LayoutData.shared.wordsEn
        if words.contains(semantic) { return true }
        return Self.deElongated(semantic)?.contains(where: words.contains) ?? false
    }

    /// Английские слова из двух букв, которые действительно пишут отдельным словом. Закрытый список:
    /// на двух буквах ни словарь, ни триграммы не отличают слово от мусора (см. `enSwapNotJunk`).
    static let commonEnTwoLetter: Set<String> = [
        "am","an","as","at","be","by","do","go","he","hi","if","in","is","it","me","my",
        "no","of","ok","on","or","so","to","up","us","we","id","ai","ui","ux","ok"
    ]

    /// Однобуквенные RU-предлоги/союзы, набранные в EN-раскладке (f→а, d→в, b→и, r→к, j→о,
    /// e→у, z→я, c→с), — чиним. Их латинский исходник НЕ значимое английское слово. Только EN→RU.
    /// (Сверено по раскладке ЙЦУКЕН: я на клавише z, не q; q даёт й. Прежний коммент «q→я» был неверен.)
    /// Примечание: "c"→"с" добавлен (раньше был намеренно убран из-за «язык C»), но на практике
    /// одиночная «c» перед пробелом в русском тексте = предлог «с» в 99% случаев.
    static let ruSingleLetter: Set<String> = ["а", "в", "и", "к", "о", "с", "у", "я"]

    /// СМАЙЛИК ЗАПАДНОГО ТИПА: «глаза» знаком, необязательный «нос», «рот». Никогда не трогаем.
    ///
    /// Отзывы #247–248 (@aklimov, 06.09.2026): «:D» превращалось в «:В», и человек не смог спастись
    /// даже исключением. Дело не в словаре: `letterCore` срезает ведущее двоеточие, остаётся «d», а
    /// «d»→«в» это правило одиночных русских предлогов, набранных в EN-раскладке. Тем же путём
    /// ломались «:C»→«:С», «:B»→«:И», «:-D», «=D». Предлог никогда не приклеен к двоеточию, поэтому
    /// смайлик отсекаем целиком и до всех правил. «;D», «:P», «XD» сегодня выживают СЛУЧАЙНО (так
    /// легли словарь и триграммы) — здесь они становятся осознанным keep, иначе следующая правка
    /// словаря сломает их молча.
    ///
    /// ⚠️ ПОЧЕМУ «ГЛАЗА» РАЗДЕЛЕНЫ НА ТРИ КЛАССА (замер: прогон всех 2545 коротких токенов до и
    /// после правки, разошлось 73 решения, все ожидаемые). `:` и `=` в русской раскладке букв не
    /// дают, пара с ними не может быть словом ни при каком чтении — там разрешён любой «рот».
    /// У `;` (русская «ж») и `8` строчный рот даёт живые токены («;t» = «же», «;l» = «жд»), поэтому
    /// рот обязан быть заглавным (второй заглавной в русском слове не бывает) или знаком. А `x` это
    /// «ч», и заглавный рот там сплошь живые аббревиатуры: «XG» = «ЧП», «XR» = «ЧК». Первая версия
    /// правила их ломала, поэтому у иксовых глаз оставлен ровно классический «XD».
    static func isEmoticon(_ raw: String) -> Bool {
        var s = Substring(raw)
        // Концевая пунктуация предложения смайлику не мешает: «:D.» и «:D,» это тот же смайлик.
        while let l = s.last, ".,!?…".contains(l) { s = s.dropLast() }
        guard let eyes = s.first else { return false }
        s = s.dropFirst()
        if let nose = s.first, s.count > 1, "-~^'".contains(nose) { s = s.dropFirst() }
        guard s.count == 1, let mouth = s.first else { return false }
        let mouthSymbols = ")(|/\\*$@[]{}3"
        switch eyes {
        case ":", "=":
            return mouth.isLetter || mouthSymbols.contains(mouth)
        case ";", "8":
            return (mouth.isLetter && mouth.isUppercase) || mouthSymbols.contains(mouth)
        case "X", "x":
            return mouth == "D" || mouth == "d"
        default:
            return false
        }
    }

    /// Кириллический токен `w` переводится в `swapped` ровно так, как по таблице Apple «Russian»
    /// (ЙЦУКЕН). Та же раскладка у «Russian - PC», а у фонетической буквы стоят на других клавишах.
    /// Нужна для узких списков из задачи 264: там кириллическая форма проверена только для ЙЦУКЕН.
    /// Дёшево: зовётся лишь после попадания в маленький список, на 2–4 буквах.
    static func isJCUKENSwap(_ w: String, _ swapped: String) -> Bool {
        var out = ""
        for ch in w {
            guard let m = Keymap.ruToEn[String(ch)] else { return false }
            out += m
        }
        return out.lowercased() == swapped
    }

    /// Кириллический `w` это латинский токен из `ExtraWords.techFromCyrillic`, набранный на ЙЦУКЕН.
    /// ⚠️ СПИСОК И ПРОВЕРКА РАСКЛАДКИ В ОДНОЙ ФУНКЦИИ НАРОЧНО (ревью задачи 264, 26.09.2026). Стенд
    /// проверял `isJCUKENSwap` отдельно, и когда её вызов убрали из `decide`, он остался зелёным:
    /// фонетическая раскладка молча начала бы превращать живое «ини» в «ini». Теперь стенд зовёт
    /// ровно то, что зовёт `decide`, и такая поломка его роняет.
    static func isTechTokenFromCyrillic(_ w: String, _ swapped: String) -> Bool {
        ExtraWords.techFromCyrillic.contains(swapped) && isJCUKENSwap(w, swapped)
    }

    /// ⚠️ ЧИСЛО СЛЕВА: «5 г», «100 гб», «1,5 фб» (отзыв #294, 26.09.2026). Токен из цифр и знаков
    /// «,.-–/», в нём есть хотя бы одна цифра. Буква после такого соседа это единица измерения
    /// или «г.» в дате, а не английское «u», набранное на русской раскладке.
    static func isNumericToken(_ s: String?) -> Bool {
        guard let s, !s.isEmpty else { return false }
        var hasDigit = false
        for ch in s {
            if ch.isNumber { hasDigit = true; continue }
            if ",.-–/".contains(ch) { continue }
            return false
        }
        return hasDigit
    }

    /// ⚠️ КИРИЛЛИЦА, КОТОРОЙ НЕ БЫВАЕТ В РУССКОМ (задача 258, уточнение автора 26.09.2026).
    /// Нужна единственному месту: правилу «аббревиатуру заглавными не трогаем». Русская
    /// аббревиатура (УФНС, МФТИ) выглядит как каша, но пишется русскими буквами по русским
    /// правилам. А «ЬФСИЩЩЛ» (MACBOOK на русской раскладке) по-русски написать нельзя в принципе:
    /// с мягкого знака слово не начинается. Такой токен точно набран не в той раскладке.
    ///
    /// Только жёсткие запреты орфографии, никакой статистики. Замер 26.09.2026 по words_ru.json
    /// вместе со всеми русскими списками ExtraWords (163 301 слово): ни одно слово не попадает.
    /// Сто с лишним живых аббревиатур (ГИБДД, ЕГРЮЛ, МВД, ЛУКОЙЛ, РОСНЕФТЬ…) тоже не попадают.
    ///   • начало с «ь» или «ы» (слов на «ы» в словаре нет; «ъ» не проверяем: он даёт «]», а
    ///     токен с таким знаком не конвертируется и без нас);
    ///   • «ьь», «ыы», «йй», «щщ»;
    ///   • «ь» или «ы» сразу после гласной.
    /// Токен из одной повторённой буквы («ЫЫЫЫ») сюда не относим: это междометие, а не слово
    /// другого языка, и заглавными его как раз надо оставить как есть.
    static func isImpossibleRussianSpelling(_ w: String) -> Bool {
        let chars = Array(w.lowercased())
        guard chars.count >= 2, Set(chars).count > 1 else { return false }
        if chars[0] == "ь" || chars[0] == "ы" { return true }
        for i in 0..<(chars.count - 1) {
            let a = chars[i], b = chars[i + 1]
            if a == b, "ьыйщ".contains(a) { return true }
            if Self.ruVowels.contains(a), b == "ь" || b == "ы" { return true }
        }
        return false
    }
    private static let ruVowels: Set<Character> = ["а", "е", "ё", "и", "о", "у", "ы", "э", "ю", "я"]

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
    /// (= «(если») не чинилось, потому что core() срезал только концевые .,!?;:… (автор 15.06).
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
        let letterCore = Self.letterCore(of: raw)
        let typed = Keymap.core(of: letterCore).lowercased()
        var coreSub = Substring(letterCore)   // срезаем ведущие/концевые скобки/кавычки/тире
        while let f = coreSub.first, f.isNumber { coreSub = coreSub.dropFirst() }   // и ведущие/концевые цифры
        while let l = coreSub.last,  l.isNumber { coreSub = coreSub.dropLast() }
        let core = String(coreSub)
        let w = core.lowercased()
        // Полное исключение проверяем ДО языкового решения: запись `1ghbdtn` не равна ядру
        // `ghbdtn`. На live-пути нужен и префикс, иначе слово успеет переключиться ещё до границы.
        // Для обычного слова typed == w, и второй одинаковый линейный обход малых Set'ов не нужен.
        if typed != w, Self.isExceptionOrPrefix(typed, cyrillic: typed.hasCyrillic) { return .keep }
        // `it.` — это настоящее EN `it` + точка, хотя полное чтение тех же клавиш даёт RU `шею`.
        // Live-fix обязан применить тот же strict-gate, что и boundary, иначе успеет испортить более
        // длинные варианты (`uhf,`, `cdt;`) ещё до пробела.
        if Self.hasValidSourceBeforeTrailingPunctuation(
            core,
            forcedSource: ExceptionStore.shared.forceSwap
        ) { return .keep }
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
        // Слово-исключение (пользовательское/бренд/extra-словарь) ИЛИ ЕГО ПРЕФИКС — на лету НЕ трогаем.
        // Решение принимается на НЕПОЛНОМ слове, поэтому ловим и префикс: иначе live-fix мечется, пока
        // дописываешь слово-исключение («гифк»→en на 4-й букве, затем «гифки»→ru — щёлканье туда-сюда).
        // Полный словарь не префиксуем (он Set), его ПОЛНЫЕ слова уже ловит wordsRu/wordsEn выше.
        if Self.isExceptionOrPrefix(w, cyrillic: sourceCyrillic) { return .keep }
        let orig = data.plausibility(w, cyrillic: sourceCyrillic)
        let swap = data.plausibility(swapped, cyrillic: toCyrillic)
        if orig <= liveImpossible && swap > orig + liveMargin {
            return .convert(toCyrillic: toCyrillic)
        }
        return .keep
    }

    /// `w` равно слову-исключению ИЛИ является его ПРЕФИКСОМ. Только для live-fix (мид-слово): пока
    /// пользователь дописывает слово-исключение, его префикс трогать нельзя (иначе щёлканье
    /// «гифк»→en→«гифки»→ru). Проверяем лишь МАЛЫЕ keep-наборы (исключения пользователя + extra-словарь
    /// брендов/слов); полный словарь — Set без префиксных запросов, а его полные слова и так держит
    /// wordsRu/wordsEn.contains. Дёшево: наборы по сотне слов, short-circuit, зовётся только при count≥4.
    static func isExceptionOrPrefix(_ w: String, cyrillic: Bool) -> Bool {
        guard w.count >= 2 else { return false }
        func hit(_ set: Set<String>) -> Bool {
            if set.contains(w) { return true }                              // точное слово-исключение
            return set.contains { $0.count > w.count && $0.hasPrefix(w) }   // w — префикс исключения
        }
        let exc = ExceptionStore.shared
        // Пользовательские исключения и бренды — в обе стороны (слово точное, язык не важен).
        if hit(exc.learned) || hit(exc.ignored) || hit(ExtraWords.defaultKeep) { return true }
        return cyrillic
            ? (hit(ExtraWords.ru) || hit(ExtraWords.ruAbbr) || hit(ExtraWords.ruShort))
            : (hit(ExtraWords.en) || hit(ExtraWords.enKeepShort))
    }

    /// СПАСЕНИЕ СМЕШАННОГО СЛОВА (кир+лат в одном токене). Такое слово — артефакт нашего же мид-слов-
    /// флипа раскладки + правки опечатки: live-fix перевёл начало в кириллицу и асинхронно щёлкнул
    /// системную раскладку, а дописанный/перепечатанный хвост успел декодироваться в другом скрипте
    /// («привtn», interleaved «приdет», или обратная полярность «ghbdет»). Обычный decide()/liveDecide()
    /// такие слова ВСЕГДА отдаёт .keep (guard sourceCyrillic != sourceLatin) — и слово застревает
    /// полуконвертированным: пользователь видит «переключилось только окончание».
    ///
    /// Чиним по СЛОВАРЮ, а не по сигнатуре артефакта: анкер live-fix (liveFixLast) к моменту границы уже
    /// сброшен, поэтому надёжность даёт валидность результата. Конвертим ВЕСЬ токен в каждую сторону и
    /// принимаем РОВНО ОДНУ, если она даёт валидное словарное слово (и не остаётся смешанной). Если
    /// валидны обе или ни одной — НЕ угадываем (намеренный билингв: «API-ключ», «C++код», «helloмир»,
    /// «ноутбукmac» не становятся словом ни в одну сторону → .keep, текст не портим). Whole-word —
    /// поэтому ловит и interleaved-артефакты, у которых нет «хвостового латинского run» для self-heal.
    static func mixedRescue(word raw: String) -> SwapDecision {
        guard raw.hasCyrillic, raw.hasLatinLetter else { return .keep }
        let core = letterCore(of: raw)
        guard core.count >= 2, core.allSatisfy(Self.isLayoutLetter) else { return .keep }
        let toRu = Keymap.convert(core, toCyrillic: true)
        let toEn = Keymap.convert(core, toCyrillic: false)
        let data = LayoutData.shared
        let ruOK = !toRu.hasLatinLetter && data.wordsRu.contains(toRu.lowercased())
        let enOK = !toEn.hasCyrillic   && data.wordsEn.contains(toEn.lowercased())
        if ruOK && !enOK { return .convert(toCyrillic: true) }
        if enOK && !ruOK { return .convert(toCyrillic: false) }
        return .keep
    }

    /// Узкий мост для русской фразы, внутри которой стоит латинская аббревиатура:
    /// `… касается iOS, nj` / `… нашего EPG, nj`. Непосредственный сосед тут латинский и обычный
    /// enKeepShort-гейт оставляет `nj`, хотя до него продолжается русская фраза.
    ///
    /// Не используем «язык большинства строки»: он сломал бы живое `Сегодня матч Loko vs CSKA`.
    /// Требуем одновременно точное строчное `nj`, запятую после ASCII-лейбла, минимум две заглавные
    /// буквы в нём и чисто кириллическое слово ещё левее. `New, NJ` и `the EPG, nj` остаются как есть.
    private static func russianNJAfterLatinLabel(word: String, rawCore: String,
                                                  prev: String?, earlier: String?) -> Bool {
        guard word == "nj", rawCore == word,
              let prev, prev.last == ",",
              let earlier, earlier.hasCyrillic, !earlier.hasLatinLetter else { return false }
        let label = prev.dropLast()
        guard !label.isEmpty,
              label.allSatisfy({ ch in
                  ch.isLetter && ch.unicodeScalars.allSatisfy({ $0.isASCII })
              }) else { return false }
        return label.filter({ $0.isUppercase }).count >= 2
    }

    /// Решение для АВТО-режима. Manual-хоткей в это не заходит (юзер решил сам).
    /// prev — ПРЕДЫДУЩЕЕ слово фразы (как на экране): из него берём язык-контекст (разрешает
    /// короткие коллизии) И проверку слова-классификатора (vitamin/gen/plan → буква-маркер).
    /// earlier — ещё одно слово слева в пределах той же строки; используется только узким мостом
    /// для `iOS, nj`, а не как общий языковой приор.
    /// На однозначные и длинные слова (5+ букв, 100% точность) НЕ влияет.
    /// `afterCaretJump` — это ПЕРВОЕ слово после того, как каретку двигали мышью или навигацией.
    /// Нужен только для одиночных букв: без него «нет соседей» означает сразу два разных случая,
    /// начало ввода и середину чужого слова, а поступать в них надо противоположно (см. ниже).
    static func decide(word raw: String, exceptions: ExceptionStore,
                       prev: String? = nil, earlier: String? = nil,
                       afterCaretJump: Bool = false) -> SwapDecision {
        let context = ContextHint.of(prev)
        let letterCore = Self.letterCore(of: raw)
        let literal = letterCore.lowercased()
        let typed = Keymap.core(of: letterCore).lowercased()
        // UI сохраняет полное исключение (`1gt.it`). Лингвистическое ядро ниже срежет ведущую `1`
        // и станет `gt.it`, поэтому точное намерение человека обязано победить ДО нормализации.
        // Проверяем и literal: интерфейс исторически разрешает сохранить конечную пунктуацию,
        // а `Keymap.core` её снимает. Затем проверяем форму без внешнего знака, чтобы обычное
        // исключение `1gt.it` защищало и предложение `1GT.IT.`.
        // ⚠️ И ПОЛНЫЙ ТОКЕН ЦЕЛИКОМ. Человек добавляет в исключения ровно то, что видит на экране
        // («:D», «и/или», «C++»), а оба ключа выше — это буквенное ядро, из которого ведущий знак уже
        // срезан. Исключение со знаком в начале не совпадало ни с одним ключом и молча не работало:
        // ровно на это жаловался @aklimov (#247–248, 06.09.2026), добавив «:D» и не получив ничего.
        let whole = raw.lowercased()
        if exceptions.ignored.contains(literal) || exceptions.learned.contains(literal)
            || exceptions.ignored.contains(typed) || exceptions.learned.contains(typed)
            || exceptions.ignored.contains(whole) || exceptions.learned.contains(whole) { return .keep }
        // Смайлик — не слово ни в одной раскладке (см. isEmoticon).
        if Self.isEmoticon(raw) { return .keep }
        // Анализируем БУКВЕННОЕ ЯДРО (без ведущих/концевых скобок, кавычек, тире, пунктуации):
        // "(tckb"→"tckb", "привет."→"привет". Решаем по ядру, конвертим (в Engine) полный токен.
        var coreSub = Substring(letterCore)
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
        // ДЕФИСНЫЕ СЛОВА. Обычный путь ниже для них бесполезен по устройству: он требует, чтобы
        // результат целиком состоял из букв, а дефис буквой не является. Даже ослабив это, мы
        // упрёмся в словарь, где слов с дефисом РОВНО НОЛЬ (замер 22.08.2026: ru=0, en=0).
        //
        // Раньше здесь был только allowlist (e-ink, wi-fi, t-shirt), а «что-то», «из-за», «по-моему»
        // честно отбивались. автор 21.08.2026: «xnj-nj не переключается, хотя должно, таких слов в
        // русском немало». Добавлен разбор ПО ЧАСТЯМ, и он же снимает возражение, записанное в
        // прежнем комментарии («у» в «у-штл» — валидный предлог): части короче двух букв мы не
        // рассматриваем вовсе, поэтому одиночный предлог сюда не попадает.
        //
        // Сначала отдельный shape-guard проверяет ИСХОДНЫЙ токен, до срезания внешних знаков.
        // Поэтому `(xnj-nj)` остаётся словом, а `--xnj-nj`, `-xnj-nj`, `xnj-nj-`, диапазоны и
        // повторный дефис не могут замаскироваться под него после `letterCore`.
        //
        // Дальше правило симметрично, и это его главное свойство:
        //   • все части ИСХОДНИКА — слова текущего языка → живое составное слово, не трогаем.
        //     Так защищены и «dry-run», «real-time», «well-known», и русское «что-то», набранное
        //     по-русски: оно не уедет в латиницу;
        //   • иначе все части ПОСЛЕ смены раскладки обязаны быть словами другого языка
        //     («xnj-nj» → «что» + «то», обе в словаре) → конвертируем;
        //   • всё остальное → молчим.
        //
        // Покрытие замерено на живых словах. Две короткие коллизии из карточки задачи (`ult`/`nj`
        // и `bp`/`pf`) ошибочно выглядят валидными английскими словами, поэтому для «где-то» и
        // «из-за» есть точный canonical override. Шире его делать нельзя: corpus-аудит нашёл
        // `ru-ru`→`кг-кг` и 156 одиночных cross-layout словарных коллизий.
        if w.contains("-") {
            guard let hyphenRaw = HyphenTokenShape.linguisticCore(
                of: raw,
                isLayoutLetter: Self.isLayoutLetter
            ) else { return .keep }
            let hyphenWord = hyphenRaw.lowercased()
            guard hyphenWord == w else { return .keep }

            let segs = hyphenWord.split(separator: "-", omittingEmptySubsequences: false)
            if hyphenWord.hasCyrillic != hyphenWord.hasLatinLetter {
                let toCyr = !hyphenWord.hasCyrillic
                let swapped = Keymap.convert(hyphenRaw, toCyrillic: toCyr).lowercased()
                if ExtraWords.hyphenTerms.contains(hyphenWord)
                    || ExtraWords.ruHyphenTerms.contains(hyphenWord) { return .keep }
                if ExtraWords.hyphenTerms.contains(swapped)
                    || ExtraWords.ruHyphenTerms.contains(swapped) {
                    return .convert(toCyrillic: toCyr)
                }
                let src = segs.map(String.init)
                let dst = swapped.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
                if src.count == dst.count, src.allSatisfy({ $0.count >= 2 }),
                   dst.allSatisfy({ $0.count >= 2 && $0.allSatisfy({ $0.isLetter }) }) {
                    let data = LayoutData.shared
                    let dictSrc = hyphenWord.hasLatinLetter ? data.wordsEn : data.wordsRu
                    let dictDst = hyphenWord.hasLatinLetter ? data.wordsRu : data.wordsEn
                    if src.allSatisfy({ dictSrc.contains($0) }) { return .keep }
                    if dst.allSatisfy({ dictDst.contains($0) }) { return .convert(toCyrillic: toCyr) }
                }
            }
            return .keep
        }
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
        // Внутренний апостроф разрешён: английские контракции (i'm, don't, let's) на RU-раскладке
        // дают «э» внутри слова; без этого они отсекались тут до forceEnAmb. Реальные слова с «э»
        // защищены strict-gate по словарю ниже, так что апостроф-релакс безопасен.
        // ⚠️ ЗАПЯТАЯ И ТОЧКА, НАБРАННЫЕ В РУССКОЙ РАСКЛАДКЕ, ПРИЕЗЖАЮТ СЮДА БУКВАМИ (отзыв
        // @ToshaSoft #121, 11.08.2026: «не просто лунищщзб а кейбупище»).
        //
        // На русской раскладке запятая это клавиша «б», точка это «ю», точка с запятой это «ж».
        // Человек, забывший переключиться, набирает «keyboop,» и получает «лунищщзб»: для нас это
        // один сплошной буквенный токен. Мы его переводили обратно правильно («keyboop,»), но до
        // перевода дело не доходило: проверка ниже требует, чтобы swapped состоял ИЗ ОДНИХ БУКВ, а
        // там запятая. Токен молча оставался как есть, и выглядело это так, будто программа не
        // видит очевидного. Стоит эта запятая в конце фразы часто, то есть промах не редкий.
        //
        // Чиним рекурсией по ядру: срезаем концевые буквы, дающие знак препинания, и решаем по тому,
        // что осталось. Решение принимается по слову, а конвертирует Engine токен ЦЕЛИКОМ, поэтому
        // знак остаётся на месте.
        //
        // Почему это безопасно для настоящих русских слов на «б», «ю», «ж» («нож», «пою», «дождь»):
        // рекурсия отдаёт решение по ядру, а ядро («но», «по») это словарное слово, и strict-gate
        // ниже его держит. Проверено стендом на этих же словах.
        // ⚠️ И ГЛАВНОЕ УСЛОВИЕ: сам токен не должен быть настоящим русским словом. Это тот же
        // strict-gate, только на уровень выше: «муж», «зуб», «штаб» тоже оканчиваются на «ж» и «б»,
        // и без этой проверки рекурсия судила по огрызку («му», «зу», «шта») и honestly ломала их.
        // Замерено: без неё 3 ложных срабатывания на 20 словах, с ней ноль.
        if sourceCyrillic, !LayoutData.shared.wordsRu.contains(w),
           let last = swapped.last, Keymap.trailingPunctuation.contains(last) {
            var trimmed = Substring(coreRaw)
            while let l = trimmed.last,
                  let mapped = Keymap.convert(String(l), toCyrillic: false).last,
                  Keymap.trailingPunctuation.contains(mapped) {
                trimmed = trimmed.dropLast()
            }
            guard !trimmed.isEmpty else { return .keep }
            return decide(word: String(trimmed), exceptions: exceptions, prev: prev, earlier: earlier,
                          afterCaretJump: afterCaretJump)
        }
        guard swapped != w, swapped.allSatisfy({ $0.isLetter || $0 == "'" }) else { return .keep }

        // 1. Force-swap (до словаря): аббревиатуры. КРИТИЧНО (баг, ревизия 2026-06-13): встроенный
        //    forceSwap бил ДО словаря и без контекста → съедал ВАЛИДНЫЕ русские слова, чья латинская
        //    раскладка-форма совпала с аббревиатурой: «еды»→tls, «св»→cd, «шву»→ide. Поэтому форсим
        //    встроенным списком ТОЛЬКО если исходник — НЕ настоящее слово (гиббериш в своём языке).
        //    Пользовательский exceptions.forceSwap — явное намерение, уважаем без гейта.
        // ⚠️ РАСТЯНУТОЕ СЛОВО — ЭТО ТОЖЕ СЛОВО (жалоба пользователя: «круууто» → «rheeenj»).
        //
        // Растягивание буквы это обычная русская (и английская) эмоция на письме: «круууто»,
        // «нуууу», «мдааа», «coooool». В словаре таких форм нет и быть не может — их бесконечно
        // много, — поэтому strict-gate их не держал, и слово уезжало к триграммам. А там растянутая
        // гласная штрафуется в ОБОИХ языках, и решает случайный перевес: «дааа» и «ооочень» уцелели,
        // «круууто» и «нуууу» нет. Для человека это выглядит хуже любой несделанной конверсии,
        // потому что латинский результат не значит вообще ничего.
        //
        // Схлопываем повтор от трёх букв и спрашиваем словарь о том, что получилось. Порог именно
        // три: две одинаковые подряд это нормальная орфография («ванна», «класс», «сумма»), а три —
        // всегда намеренное растягивание.
        let sourceIsRealWord = Self.hasValidSourceBeforeTrailingPunctuation(
                coreRaw,
                forcedSource: exceptions.forceSwap
            )
            || LayoutData.shared.wordsRu.contains(w)
            || LayoutData.shared.wordsEn.contains(w)
            || (Self.deElongated(w)?.contains {
                    LayoutData.shared.wordsRu.contains($0) || LayoutData.shared.wordsEn.contains($0)
                } ?? false)
        if forceSwap.contains(swapped), !sourceIsRealWord {
            return .convert(toCyrillic: toCyrillic)
        }
        // ⚠️ «ече» → «txt», НО ТОЛЬКО ОТДЕЛЬНЫМ СЛОВОМ (отзыв #310, решение автора 26.09.2026).
        //
        // автор: «если это отдельное слово, переключать; если часть другого слова, не трогать».
        // Часть слова мы видим одним способом: после прыжка каретки. Человек кликнул в конец
        // «встр» и дописал «ече», буфер очищен кликом, и нам достаётся голый хвост «встрече».
        // Когда слева настоящий пробел, там отдельное слово: «сохрани в ече» это «в txt», и сосед
        // слева тут не помеха, а обычный случай (кто пишет по-русски, тот и забыл переключиться).
        //
        // Вторая охрана: раскладка семейства ЙЦУКЕН. На фонетической те же латинские токены
        // набираются живыми русскими буквами («ини», «рсс»), и там конверсию не включаем вовсе.
        if sourceCyrillic, !sourceIsRealWord, !afterCaretJump,
           Self.isTechTokenFromCyrillic(w, swapped) {
            return .convert(toCyrillic: false)
        }
        if exceptions.forceSwap.contains(swapped) {
            return .convert(toCyrillic: toCyrillic)
        }
        if forceSwap.contains(w) || exceptions.forceSwap.contains(w) {
            return .keep // ввели "sql" осознанно — оставить
        }
        // Голое «xlsx» уходило в «чдыч» после любого соседа, даже после «the» (задача 264).
        if sourceLatin, ExtraWords.techLatinTokens.contains(w) { return .keep }

        // ★ STRICT-GATE (принцип автора, 2026-06-14): СЛОВО, ВАЛИДНОЕ В ЯЗЫКЕ, НА КОТОРОМ НАБРАНО, —
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

        // ⚠️ ЗАГЛАВНАЯ ПОСРЕДИ ФРАЗЫ — ЭТО ИМЯ (отзыв #122, 11.08.2026: «я работаю до 7 по Уфе»
        // превращалось в «по Eat»).
        //
        // Механика промаха: «уфе» это падежная форма города, в плоском словаре её нет, и strict-gate
        // не срабатывает. А латинская форма «eat» — настоящее английское слово, то есть сигнал
        // выглядит идеальным. Так ломается любое склонённое имя собственное, и таких слов бесконечно
        // много: города, фамилии, названия компаний. Словарём это не закрыть.
        //
        // Зато у имени есть дешёвый и надёжный признак: человек пишет его с заглавной ПОСРЕДИ
        // предложения. Начало фразы под это правило не попадает (там заглавная у любого слова),
        // и именно поэтому нужен `prev`: он и означает «мы не в начале».
        //
        // Что мы теряем: слово, набранное не в той раскладке и при этом зачем-то с заглавной, теперь
        // останется как есть. Это редкость, и цена ошибки несимметрична — сломанное имя человек
        // видит сразу и злится, а несконвертированное слово он просто дочинит хоткеем.
        if prev != nil, let first = coreRaw.first, first.isUppercase,
           coreRaw.dropFirst().contains(where: { $0.isLowercase }) {
            return .keep
        }

        // 2. Одиночные буквы. Короткие RU-предлоги, набранные в EN-раскладке (d→в, c→с, r→к, …),
        // починим — латинский исходник не значимое слово. Только EN→RU. Тонкость с контекстом:
        //   • после ОБЫЧНОГО английского слова («room d новой») — ЧИНИМ предлог;
        //   • после слова-КЛАССИФИКАТОРА («vitamin d», «gen z», «plan b») — буква-маркер, НЕ трогаем;
        //   • в режиме разработчика одиночные буквы вообще не доходят сюда (soft-фильтр в Engine).
        if w.count == 1 {
            // ⚠️ ПОСЛЕ ПРЫЖКА КАРЕТКИ ОДИНОЧНУЮ БУКВУ НЕ ТРОГАЕМ (баг-репорт, 02.08.2026).
            // Он правил опечатку внутри уже написанного слова: кликнул мышью, поставил правильную
            // «г», а мы вернули её в «u». Это хуже обычной ошибки: человек исправил, а программа
            // отменила исправление.
            //
            // Механика: клик чистит буфер, соседних слов не остаётся, `prev` = nil → context = .none.
            // Правило ниже спрашивает «контекст НЕ русский?», и пустота проходила эту проверку
            // наравне с английским. То есть ровно там, где мы не знаем ничего, мы разрешали себе
            // действовать. Замысел был обратный, ниже так и написано: «в ЯВНО русской фразе
            // одиночную букву не трогаем».
            //
            // Почему проверяем ИМЕННО прыжок, а не любой пустой контекст. Пустота бывает двух родов,
            // и они требуют противоположного. Начало ввода: слева ничего нет, одинокая буква — это
            // правда одинокая буква, и «d » в начале русской фразы честно чиним в «в» (а «У меня»,
            // «И вот», «В общем» — самые частые начала предложений, терять их нельзя). Прыжок
            // каретки: слева на экране стоит ЦЕЛОЕ слово, которого мы не видим, и наша «одиночная
            // буква» — на самом деле буква внутри чужого слова. Буфер в этот момент врёт, и верить
            // ему нельзя.
            //
            // Почему это не лечится списком значимых букв (обсуждали с автором 02.08): мы и так
            // никогда не превращаем букву в бессмысленную, обе ветки ниже проверяют РЕЗУЛЬТАТ по
            // словарю одиночных слов. Но «г» в русском не слово, а «u» в английском слово (пусть и
            // сокращение), так что по словарю конверсия законна. Спасает только контекст.
            if afterCaretJump, context == .none { return .keep }
            if sourceLatin, Self.ruSingleLetter.contains(swapped) {
                if let p = prev?.lowercased() {
                    // буква-маркер после классификатора: «vitamin d» (англ.) ИЛИ «витамин d» (рус.).
                    if context == .latin, ExtraWords.labelClassifiers.contains(p) { return .keep }
                    if context == .cyrillic, ExtraWords.ruLabelClassifiers.contains(p) { return .keep }
                }
                return .convert(toCyrillic: true)
            }
            // EN→RU: одиночные английские i/u/a, набранные на RU-раскладке (ш/г/ф — НЕ русские слова).
            // Раньше падали в keep (одиночные чинились только лат→кир) → 100% промах на 1 букве (фразовый
            // тест 2026-06-19). Опираемся на контекст: чиним при латинском/пустом (начало фразы, англ.
            // сосед); в ЯВНО русской фразе (prev — русское слово) одиночную букву НЕ трогаем (шум/опечатка).
            if sourceCyrillic, context != .cyrillic, ["i", "u", "a"].contains(swapped) {
                // ⚠️ ПОСЛЕ ЧИСЛА ЭТО ЕДИНИЦА, А НЕ «u» (отзыв #294, 26.09.2026). У числа нет букв,
                // поэтому «5» давало тот же пустой контекст, что и начало строки, и «5 г» уезжало
                // в «5 u», «100 гб» в «100 u,», «2024 г.» в «2024 u.». «гб» и «гю» приходят сюда
                // же, рекурсией по концевому знаку, с тем же соседом. «г» в начале строки НЕ
                // трогаем: там это и «u» из английской фразы, и «г. Москва», случай спорный.
                // Вариант «u только после латинского слова» замерен и отброшен: он сломал три
                // фразы стенда ([u free tonight], [u up?], [u always know what to say]).
                if Self.isNumericToken(prev) { return .keep }
                return .convert(toCyrillic: false)
            }
            return .keep
        }

        let data = LayoutData.shared

        // КОРОТКИЙ кир-фрагмент (≤3) → EN: словарное совпадение swapped НЕ доказывает раскладку —
        // EN-словарь полон 2-буквенного мусора (nm,cz,cm,tn), и короткое русское окончание («ть»,«ся»,
        // «ет») попадает на него случайно. Конвертим короткий кир→EN только если EN-форма достаточно
        // ПЛАУЗИБЕЛЬНА как английское: порог отсекает мусор (nm −12.6, cz −11.7, tn −11.9), но пропускает
        // реальные слова (it −8.6, in −6.5, of −9.2, the −7.5, so −8.5). EN→RU сторону (lj→до, rfr→как)
        // НЕ трогаем — там источник латинский гиббериш → реальное RU-слово, сигнал сильный, юзер не
        // жаловался. Длинные (≥4) словарю доверяем. Прецедент: «ть»→«nm» (автор 2026-06-29). Корень глубже —
        // буфер «сиротит» окончание (см. Engine pendingContextClear); это — дешёвая страховка-нетто.
        func enSwapNotJunk() -> Bool {
            // ⚠️ ДВУБУКВЕННЫЕ — ТОЛЬКО ПО ЗАКРЫТОМУ СПИСКУ (жалоба пользователя: «ке» → «rt»).
            //
            // Здесь стоял порог правдоподобия, и он не спасает: «rt» ЛЕЖИТ в английском словаре
            // (59 тысяч записей, там полно двубуквенного мусора), а по триграммам «rt» выглядит
            // отлично — оно встречается в «part», «start», «short». То есть оба сигнала, словарь и
            // статистика, дружно голосуют за слово, которое человек никогда не набирает отдельно.
            // Цена ошибки при этом максимальная: автор правил опечатку в окончании, а мы разворачивали
            // ему две буквы и заодно переключали раскладку.
            //
            // На двух буквах никакая статистика не работает, и признать это дешевле, чем крутить
            // пороги. Список закрытый и короткий: это ВСЕ английские двубуквенные слова, которые
            // реально пишут сами по себе. Не попал в список — оставляем как есть; человек, которому
            // нужно именно «rt», добавит своё исключение.
            if w.count == 2 { return Self.commonEnTwoLetter.contains(swapped) }
            return w.count >= 4 || data.plausibility(swapped, cyrillic: false) > Self.shortEnSwapFloor
        }

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
                // НЕ гейтим плаузибельностью: латинский гиббериш → реальное RU-слово = сильный сигнал
                // (RU-словарь = настоящие слова, не мусор), на эту сторону юзер не жаловался.
                if context == .latin, ExtraWords.enKeepShort.contains(w),
                   !Self.russianNJAfterLatinLabel(word: w, rawCore: coreRaw,
                                                  prev: prev, earlier: earlier) { return .keep }
                return .convert(toCyrillic: true)
            }
        } else {
            // forceEnAmb: частый англ. сленг/сокращения (idk/tbh/ngl…), которых нет в EN-словаре, а
            // кир-форма — гиббериш. Набраны на RU-раскладке → форсим в латиницу (симметрия forceRuAmb).
            if ExtraWords.forceEnAmb.contains(swapped), !data.wordsRu.contains(w) {
                return .convert(toCyrillic: false)
            }
            if data.wordsRu.contains(w) {
                if context == .latin, data.wordsEn.contains(swapped) {
                    return .convert(toCyrillic: false)  // «hello шт» → «hello in» (фраза EN в RU-раскладке)
                }
                return .keep
            }
            if data.wordsEn.contains(swapped), enSwapNotJunk() { return .convert(toCyrillic: false) }
        }

        // 4. Триграммы (словоформы, которых нет в плоском словаре) — ТОЛЬКО для слов
        //    от 4 букв. На коротких (≤3) статистика ненадёжна и даёт ложняки вида
        //    «тк»→«nr» (в EN нет слова «nr»): короткое слово переключаем строго по
        //    словарю/аббревиатурам/одиночным буквам (шаги 1–3 выше), иначе — оставляем.
        guard w.count >= 4 else { return .keep }
        // ⚠️ РУССКАЯ АББРЕВИАТУРА ЗАГЛАВНЫМИ ОСТАЁТСЯ КАК НАБРАНА (отзыв #291, задача 258, 26.09.2026).
        //
        // «УФНС» превращалось в «EAYC», «МФТИ» в «VANB», «ВГТРК» в «DUNHR». Словаря тут ни при чём:
        // аббревиатуры в нём нет, и решали триграммы, а для них сочетание согласных без гласных
        // одинаково чужое в обоих языках, и случайный перевес уходил английскому. Заглавные
        // целиком сами по себе сильный знак: так пишут аббревиатуры, и человек набрал их нарочно.
        //
        // Правило стоит ЗДЕСЬ, после словаря и списков, поэтому «ФЗШ» → API, «ЫЙД» → SQL,
        // «ОЫЩТ» → JSON, «ТФЫФ» → NASA работают как прежде: они решаются выше. Под правило
        // попадает только то, что вытягивали одни триграммы.
        //
        // Исключение попросил автор: «MACBOOK» заглавными должен переключаться на пробеле. Его
        // кириллическая форма «ЬФСИЩЩЛ» по-русски невозможна (с «ь» слово не начинается), значит,
        // это точно не аббревиатура, и решают триграммы, как раньше. OPENAI («ЩЗУТФШ»), IMAP и
        // JIRA так не выделить, их кириллица пишется по правилам, и на пробеле они теперь
        // остаются. Замер 26.09.2026 на 112 английских словах и брендах заглавными: на пробеле
        // переключалось 104, теперь 82 (ушли OPENAI, DOCKER, FIGMA, README и ещё 20, пришли WIP
        // и LGTM из задачи 264); 18 из ушедших по-прежнему чинит правка на лету посреди слова
        // там, где она работает (не в Chromium и не в мягком режиме).
        // На корпусе правильного текста (430 тысяч пар) правило не добавило ни одной конверсии.
        // Размен осознанный: испорченную аббревиатуру человек видит сразу, а несконвертированное
        // слово доделает хоткеем.
        //
        // ⚠️ ТОЛЬКО ГРАНИЦА СЛОВА, ПРАВКУ НА ЛЕТУ ЭТО ПРАВИЛО НЕ ТРОГАЕТ (ревью 26.09.2026). Так и
        // было обещано автору: OPENAI и IMAP правка на лету чинит по-прежнему. Цена: из двухсот с
        // лишним замеренных аббревиатур две, МГТУ и ФГУП, правка на лету всё ещё переводит на
        // четвёртой букве («VUNE», «AUEG») там, где она включена. Перенести правило и туда значит
        // потерять посреди слова DOCKER, FIGMA, README и ещё полтора десятка, а по порогам эти два
        // случая от английских не отделить (МГТУ +6.10, REDIS +6.08). Решает автор, пока не трогаем.
        //
        // Сначала дешёвая проверка регистра: обычное строчное слово отсекается без аллокации.
        if sourceCyrillic, !coreRaw.contains(where: { $0.isLowercase }),
           coreRaw.filter({ $0.isLetter }).count >= 2,
           !Self.isImpossibleRussianSpelling(w) {
            return .keep
        }
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
