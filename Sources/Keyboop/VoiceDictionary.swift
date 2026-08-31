import Foundation

/// СЛОВАРЬ ДИКТОВКИ: «как слышится → как пишется» (задачи 13/T35 и 126, опора 0.4).
///
/// Зачем. Модель распознавания не знает наших имён и раз за разом ломает одни и те же слова:
/// «кейбуп» вместо Keyboop, «клауд код» вместо Claude Code, «вайп» вместо «вайб». Поправить это
/// внутри модели нельзя, дообучать её на каждое имя тем более, а руками одно и то же слово человек
/// правит каждый день. Маленький список замен закрывает весь класс жалоб и, в отличие от всего
/// остального в диктовке, работает совершенно предсказуемо.
///
/// ⚠️ ЗАМЕНА ИДЁТ ОТ НАЧАЛА СЛОВА, А НЕ ПО ТОЧНОМУ СОВПАДЕНИЮ, и это прямое требование задачи 126:
/// «вайп» обязано превращаться в «вайб» и внутри «вайпкодинга». Правило одно и его легко объяснить:
/// **совпадение ищется с начала слова, хвост слова остаётся как был.** Цена известна и принята:
/// короткая запись цепляет однокоренные слова («вайп» превратит и «вайпер»), поэтому список
/// пользовательский и видимый, а не зашитый внутрь.
///
/// ⚠️ С 28.08.2026 ЕСТЬ ВТОРОЙ ПРОХОД, НЕЧЁТКИЙ, И У НЕГО ДРУГАЯ СЕМАНТИКА (задача 192). Точное
/// совпадение осталось префиксным, как описано выше. Нечёткое включается, только если точное
/// ничего не нашло, и сравнивает СЛОВО ЦЕЛИКОМ (или столько слов, сколько в образце). Причина
/// числовая: замер по корпусу в 163 тысячи русских слов показал, что префиксная нечёткость выводит
/// под удар 1027 живых слов, а нечёткость по целому слову — 129, при том же выигрыше. Разбор и
/// цифры — `Tools/VoiceFuzzySim.swift`, запуск `run-voicefuzzy.sh`.
///
/// Правило для человека формулируется одной фразой: **точное правится где угодно в начале слова,
/// похожее — только если слово похоже целиком.**
///
/// Чего словарь НЕ делает намеренно: не склоняет («кейбупом» станет «Keyboopом», а не «Keyboop'ом»)
/// и не работает по звучанию. Это требует морфологии русского языка, то есть отдельного движка, а
/// не списка из пяти строк. Человеку проще дописать вторую строку, чем разбираться, почему «умная»
/// замена сработала там, где он её не просил.
final class VoiceDictionary {
    static let shared = VoiceDictionary()
    private let d = UserDefaults.standard
    private let key = "voiceDictOrdered"        // [[слышится, пишется]] — порядок как у сниппетов
    private let seedKey = "voiceDictSeeded"

    private(set) var orderedPairs: [(String, String)] = []

    /// Готовые к матчу иглы: нормализованный образец → замена. Отсортированы по длине убыванием,
    /// чтобы «клауд код» побеждало «клауд», а не наоборот.
    private var needles: [(pattern: [Character], replacement: String)] = []
    /// Те же иглы, но пригодные для НЕЧЁТКОГО совпадения: только с ненулевым допуском, и с числом
    /// слов в образце — нечёткость сравнивает слово (или столько слов, сколько в образце) ЦЕЛИКОМ.
    /// `fuzzyNeedles` — компактный hot-path prefilter; `fullFuzzyNeedles` вызывается только после
    /// его попадания и сохраняет точный выбор/неоднозначность исходного полного набора.
    private var fuzzyNeedles: [(pattern: [Character], words: Int, tol: Int, replacement: String)] = []
    private var fullFuzzyNeedles: [(pattern: [Character], words: Int, tol: Int, replacement: String)] = []
    private var maxFuzzyWords = 0
    /// Первые слова замен, в которых есть заглавная. Их не трогает «не начинать с заглавной»:
    /// человек написал «Keyboop» с большой буквы осознанно, и настройка про обычные предложения
    /// не должна отменять его выбор.
    private(set) var caseKeepers: Set<String> = []

    private init() {
        if let arr = d.array(forKey: key) as? [[String]] {
            orderedPairs = arr.compactMap { $0.count >= 2 ? ($0[0], $0[1]) : nil }
        } else if !d.bool(forKey: seedKey) {
            // ⚠️ ЗАСЕВАЕМ ОДИН РАЗ И ТОЛЬКО ТЕМ, ЧТО ЛОМАЕТСЯ У ВСЕХ. Смысл словаря в том, что он
            // работает без настройки: пустой список у человека, который не знает о его
            // существовании, не чинит ничего. Записи обычные, их видно в редакторе и любую можно
            // удалить — засев это стартовое состояние, а не зашитое правило.
            orderedPairs = Self.seedPairs
            persist()
        }
        d.set(true, forKey: seedKey)
        mergeSeed2()
        rebuildIndex()
    }

    /// ЗАСЕВ. Правило одно: слева то, что РЕАЛЬНО слышит распознавание, справа то, как это пишется.
    ///
    /// ⚠️ «Claude Code» разрослось в целый куст, и это не перестраховка (проверка автора 13.08:
    /// «Claude Code пока не очень получилось»). Имя иностранное, на слух ложится на десяток русских
    /// написаний, и подсказка распознаванию (`initial_prompt`) помогает не всегда: она смещает
    /// вероятности, но не диктует. Поэтому вторая линия — вот эти строки.
    ///
    /// ⚠️ «Cloud» ЛОВИМ ТОЛЬКО В ПАРЕ С «Code» (прямое требование автора). Само по себе cloud это
    /// обычное английское слово, и переписывать его в «Claude» значило бы ломать нормальную речь про
    /// облака. Пара «cloud code» такого смысла не имеет и почти наверняка означает нашего Клода.
    ///
    /// Дефис и пробел для нас одно и то же (см. `match`), поэтому «клауд-код» отдельной строкой не
    /// нужен — его накрывает «клауд код».
    static let seedPairs: [(String, String)] = [
        ("кейбуп", "Keyboop"),
        ("к-буп", "Keyboop"),
        ("вайп", "вайб"),
    ] + claudeHeardAs.map { ($0, "Claude Code") }
      + chatGPTHeardAs.map { ($0, "ChatGPT") }
      + usdtHeardAs.map { ($0, "USDT") }
      + vpnHeardAs.map { ($0, "VPN") }
      + zCodeHeardAs.map { ($0, "ZCode") }
      + aiNamesHeardAs

    /// Как распознавание слышит «Claude Code». Собрано как произведение слышимых «Клодов» на слышимые
    /// «коды»: перечислять руками все пары значит однажды забыть половину.
    static let claudeHeardAs: [String] = {
        let claude = ["клауд", "клод", "клоуд", "клауде", "клаус", "клауд", "cloud", "claud", "clode"]
        let code = ["код", "коуд", "кот", "code"]
        var out: [String] = []
        var seen = Set<String>()
        for c in claude {
            for k in code {
                let s = "\(c) \(k)"
                if seen.insert(s).inserted { out.append(s) }
            }
            // ⚠️ СЛИТНОЕ НАПИСАНИЕ НУЖНО ДЛЯ КАЖДОГО «кода», А НЕ ТОЛЬКО ДЛЯ РУССКОГО (жалоба пользователя
            // 17.08: диктовка снова написала «CloudCode»). Здесь склеивалось только с «код», то есть
            // из латинского «cloud» получалось «cloudкод» — сочетание, которого распознавание не
            // выдаёт никогда. А ровно тот случай, что приходит на практике, «cloudcode» одним
            // словом, в списке отсутствовал.
            for k in code {
                let glued = c + k
                if seen.insert(glued).inserted { out.append(glued) }
            }
        }
        return out
    }()

    /// Как распознавание слышит «ChatGPT» (автор 13.08: «чат GBT, чат-джепити, chat GPT, ChatGBT…»).
    ///
    /// Та же беда, что с Claude Code, и та же причина: иностранное имя из двух частей, каждая из
    /// которых ложится на слух десятком способов. «GPT» модель особенно любит превращать в «GBT» —
    /// глухая согласная на конце слышится звонкой.
    ///
    /// ⚠️ «чат» САМ ПО СЕБЕ НЕ ТРОГАЕМ. Это обычное русское слово, и переписывать его в «ChatGPT»
    /// значило бы ломать нормальную речь про чаты. Ловим только пару, ровно как с «cloud code».
    static let chatGPTHeardAs: [String] = {
        let chat = ["чат", "чад", "чет", "chat"]
        let gpt  = ["гпт", "жпт", "гбт", "жбт", "джипити", "джепити", "джи пи ти", "gpt", "gbt"]
        var out: [String] = []
        var seen = Set<String>()
        for c in chat {
            for g in gpt {
                for s in ["\(c) \(g)", c + g] where seen.insert(s).inserted { out.append(s) }
            }
        }
        return out
    }()

    /// Как распознавание слышит «USDT» (жалоба пользователя: «юс ди ти», «ЮСД», «УСД», «Юс Дт»,
    /// «Юис Д», «Юсдт», «Юс дити»).
    ///
    /// Та же болезнь, что у Claude Code и ChatGPT, но в чистом виде: это не слово, а ЧЕТЫРЕ БУКВЫ,
    /// продиктованные вслух. Модель слышит их как попало, потому что в её словаре нет ни одного
    /// целого английского слова на эту тему — есть только звуки.
    ///
    /// ⚠️ КАЖДЫЙ ОБРАЗЕЦ ПРОВЕРЕН ПО НАШИМ ЖЕ СЛОВАРЯМ, как правила опечаток. Совпадение ищется
    /// С НАЧАЛА СЛОВА, поэтому слитный образец, оказавшийся началом живого слова, испортил бы речь:
    /// «юсти» превратило бы «юстицию» в «USDTцию». Ни один из слитных образцов ниже не является
    /// началом слова из words_ru.json или words_en.json — это проверено перебором, а не на глаз.
    /// Многословные образцы вроде «юс ди ти» в русской речи не встречаются вовсе.
    ///
    /// ⚠️ «ЮСД» И «УСД» ОТДАНЫ ПОД USDT ПО ПРЯМОЙ ПРОСЬБЕ ИВАНА, И ЭТО РАЗМЕН. Те же звуки означают
    /// доллар (USD), и продиктовать «USD» теперь не выйдет — выйдет USDT. Разменяли сознательно:
    /// автор говорит про USDT, а не про USD, а лишнюю букву легко стереть. Если понадобится обратно,
    /// достаточно удалить две строки в редакторе словаря.
    static let usdtHeardAs: [String] = [
        "юс ди ти", "юс дити", "юс ди т", "юс д ти", "юс д т", "юс дт", "юс ти",
        "юсди ти", "юсдити", "юсдт", "юсд ти", "юсд т", "юсд",
        "юис ди ти", "юис дити", "юис дт", "юис д", "юисдт", "юисд",
        "усд ти", "усдт", "усд", "ус ди ти", "ус дт",
        "ю эс ди ти", "ю эс дт", "у эс ди ти",
        "юз ди ти", "юзди ти", "юздт",
    ]

    /// Как распознавание слышит «VPN» (жалоба пользователя: «впн», «впен», и почти всегда мимо).
    ///
    /// Тот же случай, что USDT: три буквы вслух, целого слова в словаре модели нет. Русское «впн»
    /// модель пишет как слышит, а человеку нужна латиница.
    ///
    /// ⚠️ Каждый слитный образец проверен по words_ru.json и words_en.json: ни один не является
    /// началом живого слова, значит правка от начала слова ничего не испортит. Многословные
    /// («ви пи эн») в русской речи не встречаются как обычная фраза.
    ///
    /// ⚠️ «vpn» латиницей тоже в списке: модель иногда пишет аббревиатуру строчными, а нужна она
    /// заглавными. Замена «vpn» → «VPN» это ровно тот случай, ради которого словарь и заведён.
    static let vpnHeardAs: [String] = [
        "впн", "впен", "впэн", "впиэн", "вэпэн", "випиэн", "vpn",
        "ви пи эн", "вэ пэ эн", "в пэ эн", "ви пи ен", "ви пиэн",
    ]

    /// Как распознавание пишет «Z-код» (просьба автора 30.08.2026). Латинскую Z модель обычно
    /// оставляет буквой или разворачивает в русское «зет», а `code` независимо выбирает кириллицей
    /// или латиницей. Пробел в образце уже покрывает пробел, дефис, длинное тире и их повторы.
    ///
    /// Эти четыре формы намеренно ТОЛЬКО ТОЧНЫЕ. Для `z код` одна разрешённая fuzzy-правка была бы
    /// слишком широкой: например, выдумала бы ZCode из совершенно другого «x код». Здесь вариантов
    /// мало и они известны, поэтому догадка не нужна.
    static let zCodeHeardAs: [String] = [
        "z код", "зет код", "z code", "зет code",
    ]
    private static let exactOnlySeedPatterns = Set(zCodeHeardAs.map { fold($0) })

    /// Имена нейросетей, которыми автор пользуется каждый день (просьба 18.08.2026). Тот же класс,
    /// что Claude Code: иностранное имя, которого в словаре модели нет, поэтому она пишет его как
    /// слышит — «сидэнс», «хигсвилд», а иногда латиницей, но врозь и со строчной: «Sea Dance»,
    /// «seaDream».
    ///
    /// ⚠️ Каждый СЛИТНЫЙ образец проверен по words_ru.json и words_en.json. Двое не прошли и в
    /// список не попали: «kling» латиницей (начало klingon, klinger) и «клинк» (начало «клинкера»).
    /// Русское «клинг» чисто — в словарях нет ни одного слова, которое с него начинается.
    static let aiNamesHeardAs: [(String, String)] = {
        var out: [(String, String)] = []
        for h in ["сидэнс", "сиданс", "сиденс", "сидинс", "сидэнц", "seedance", "seadance",
                  "си дэнс", "си данс", "sea dance", "си dance"] { out.append((h, "Seedance")) }
        for h in ["сидрим", "сидрем", "сидрым", "seedream", "seadream",
                  "си дрим", "си дрем", "sea dream", "си dream"] { out.append((h, "Seedream")) }
        // ⚠️ «klink» латиницей добавлен по просьбе автора 20.08: модель пишет имя именно так.
        // Проверено по словарям: «clink» брать НЕЛЬЗЯ (это живое английское слово, плюс clinker,
        // clinking), а русское «клинк» нельзя тем более — с него начинается «клинкер».
        for h in ["клинг", "клингг", "клин г", "klink", "клинк г"] { out.append((h, "Kling")) }
        for h in ["хигсфилд", "хиггсфилд", "хигсвилд", "хиггсвилд", "хиксфилд", "хигзфилд",
                  "хигсфилт", "хиггсфилт", "higgsfield",
                  "хигс филд", "хиггс филд", "хигс вилд"] { out.append((h, "Higgsfield")) }
        return out
    }()

    /// РАЗОВОЕ ДОБАВЛЕНИЕ НОВЫХ ЗАСЕВНЫХ СТРОК ТЕМ, У КОГО СЛОВАРЬ УЖЕ ЗАВЁЛСЯ.
    ///
    /// Первый засев случился 12.08, и у всех, кто успел им обзавестись, «Claude Code» лечился одной
    /// строкой из трёх нужных. Новые строки надо донести и им, иначе починка достанется только тем,
    /// кто поставит приложение впервые.
    ///
    /// ⚠️ Чужие записи не трогаем: добавляем только те образцы, которых в списке нет. Признаём
    /// честно — строку, которую человек удалил сам, мы вернём один раз. Разбирать «удалено» и
    /// «никогда не было» нам нечем, а цена ошибки здесь это одна лишняя видимая строка в редакторе.
    ///
    /// ⚠️ Номер версии засева поднимается КАЖДЫЙ раз, когда добавляем заготовки: иначе новые строки
    /// достанутся только тем, кто поставит приложение впервые. Сегодня это уже второй такой заход
    /// (Claude Code 12.08, ChatGPT 13.08), значит будет и третий.
    private func mergeSeed2() {
        // Девятый заход: ZCode (30.08). Номер обязан расти при каждом пополнении заготовок.
        let mark = "voiceDictSeed9"   // + Z-код → ZCode (30.08)
        guard !d.bool(forKey: mark) else { return }
        d.set(true, forKey: mark)
        guard !orderedPairs.isEmpty else { return }   // пустой список человек очистил намеренно
        let have = Set(orderedPairs.map { Self.fold($0.0) })
        let add = Self.seedPairs.filter { !have.contains(Self.fold($0.0)) }
        guard !add.isEmpty else { return }
        orderedPairs.append(contentsOf: add)
        persist()
        kbLog("словарь диктовки: добавлено \(add.count) новых заготовок (Claude Code и прочее)")
    }

    // MARK: - Хранение (протокол общего редактора пар)

    func pairs() -> [(String, String)] { orderedPairs }

    func setAll(_ pairs: [(String, String)]) {
        var out: [(String, String)] = []
        for (h, w) in pairs {
            let heard = h.trimmingCharacters(in: .whitespaces)
            let written = w.trimmingCharacters(in: .whitespaces)
            if heard.isEmpty { continue }
            let c = Self.fold(heard)
            if let idx = out.firstIndex(where: { Self.fold($0.0) == c }) {
                out[idx].1 = written        // тот же образец → обновляем замену, позицию сохраняем
            } else {
                out.append((heard, written))
            }
        }
        orderedPairs = out
        persist()
        rebuildIndex()
    }

    private func persist() { d.set(orderedPairs.map { [$0.0, $0.1] }, forKey: key) }

    /// Нормализация для сравнения: без регистра и без разницы «ё»/«е». Модель ставит «ё» как
    /// придётся, и заставлять человека заводить две записи на одно слово было бы издевательством.
    static func fold(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    private func rebuildIndex() {
        let indexed = orderedPairs.enumerated().compactMap { index, pair ->
            (pattern: [Character], replacement: String, order: Int)? in
            let (h, w) = pair
            let f = Self.fold(h.trimmingCharacters(in: .whitespaces))
            guard !f.isEmpty, !w.isEmpty else { return nil }
            return (Array(f), w, index)
        }
        needles = indexed.sorted {
            if $0.pattern.count != $1.pattern.count { return $0.pattern.count > $1.pattern.count }
            return $0.order < $1.order
        }.map { ($0.pattern, $0.replacement) }
        let fuzzyIndexed = indexed.filter {
            !Self.exactOnlySeedPatterns.contains(String($0.pattern))
        }
        fullFuzzyNeedles = fuzzyIndexed.compactMap { n in
            let tolerance = Self.fuzzyTolerance(n.pattern.count)
            guard tolerance > 0 else { return nil }
            return (n.pattern, max(n.pattern.split(separator: " ").count, 1),
                    tolerance, n.replacement)
        }

        // 222 видимые записи засева НЕЛЬЗЯ удалять: старые и пользовательские варианты обязаны
        // по-прежнему работать как ТОЧНЫЕ ПРЕФИКСНЫЕ замены. Схлопываем только второй, нечёткий
        // индекс. Внутри одной замены оставляем опорный вариант, если уже выбранная опора не
        // дотягивается до него своим допуском И сравнивает столько же слов. Последнее важно:
        // «хиггс филд» близко к «хиггсфилд» по Левенштейну, но двухсловная опора физически не
        // проверяется на однословном кандидате. На заводском засеве hot-path проходит 89 опор вместо
        // 207 пригодных по длине. Если опора заметила возможное совпадение, ответ перепроверяется
        // полным набором: так сокращение не меняет ни победителя, ни решение «неоднозначно».
        // Все 222 точные записи остаются на месте и в настройках.
        var groups: [String: [(pattern: [Character], replacement: String, order: Int)]] = [:]
        var groupOrder: [String] = []
        for n in fuzzyIndexed {
            if groups[n.replacement] == nil { groupOrder.append(n.replacement) }
            groups[n.replacement, default: []].append(n)
        }
        var compact: [(pattern: [Character], words: Int, tol: Int,
                       replacement: String, order: Int)] = []
        for replacement in groupOrder {
            let candidates = (groups[replacement] ?? []).sorted {
                if $0.pattern.count != $1.pattern.count { return $0.pattern.count > $1.pattern.count }
                return $0.order < $1.order
            }
            var anchors: [(pattern: [Character], replacement: String, order: Int)] = []
            for candidate in candidates {
                let covered = anchors.contains { anchor in
                    guard anchor.pattern.split(separator: " ").count
                            == candidate.pattern.split(separator: " ").count else { return false }
                    let tolerance = Self.fuzzyTolerance(anchor.pattern.count)
                    return tolerance > 0
                        && Self.editDistance(anchor.pattern, candidate.pattern, upTo: tolerance) <= tolerance
                }
                if !covered { anchors.append(candidate) }
            }
            for anchor in anchors {
                let tolerance = Self.fuzzyTolerance(anchor.pattern.count)
                guard tolerance > 0 else { continue }
                let words = max(anchor.pattern.split(separator: " ").count, 1)
                compact.append((anchor.pattern, words, tolerance, anchor.replacement, anchor.order))
            }
        }
        fuzzyNeedles = compact.sorted {
            if $0.pattern.count != $1.pattern.count { return $0.pattern.count > $1.pattern.count }
            return $0.order < $1.order
        }.map { ($0.pattern, $0.words, $0.tol, $0.replacement) }
        maxFuzzyWords = fuzzyNeedles.map { $0.words }.max() ?? 0
        caseKeepers = Set(orderedPairs.compactMap { (_, w) in
            guard let first = w.split(separator: " ").first, first.contains(where: { $0.isUppercase })
            else { return nil }
            return String(first)
        })
    }

    /// Слово написано в словаре с заглавной и должно её сохранить.
    func keepsCase(_ word: String) -> Bool { caseKeepers.contains(word) }

    // MARK: - Нечёткое совпадение (задача 192)

    /// Два независимых предохранителя: готовность данных И проверка отдельного слова. Одного
    /// замыкания недостаточно — если words_ru/words_en не прочитались, их Set всё равно содержит
    /// ExtraWords, и «нет в урезанном Set» ошибочно означало бы «можно нечётко переписать».
    /// Поэтому готовность по умолчанию false и проверяется ДО любого fuzzy-кандидата.
    private static var fuzzyLanguageDataReady = false
    private static var isWordOfTheLanguage: (String) -> Bool = { _ in false }

    /// Подключить языковой предохранитель. `isReady=false` полностью отключает нечёткость, даже если
    /// переданное замыкание отвечает false для каждого слова. Это fail-closed граница между
    /// загрузчиком ресурсов и независимым `VoiceDictionary`; стенд подменяет её напрямую.
    static func configureFuzzyLanguageGuard(
        isReady: Bool,
        isWordOfTheLanguage: @escaping (String) -> Bool
    ) {
        fuzzyLanguageDataReady = isReady
        self.isWordOfTheLanguage = isWordOfTheLanguage
    }

    /// `LayoutData.isLoaded` исторически проверяет ещё триграммы, но не умеет отличить пустой
    /// words-файл от маленького набора ExtraWords. Полные комплектные словари на два порядка больше
    /// этого порога (сейчас 163k RU / 59k EN); отсутствие или битый JSON fail-closed отключает fuzzy.
    static func fuzzyLanguageResourcesAreReady(
        layoutDataLoaded: Bool,
        wordsRuCount: Int,
        wordsEnCount: Int
    ) -> Bool {
        layoutDataLoaded && wordsRuCount > 1_000 && wordsEnCount > 1_000
    }

    /// Видно стенду без раскрытия самих игл. Exact остаётся 222 на заводском засеве, hot-path fuzzy
    /// после безопасного схлопывания — 89, полный верификатор — 207 и работает только после hit.
    var indexCounts: (exact: Int, fuzzy: Int, fuzzyVerification: Int) {
        (needles.count, fuzzyNeedles.count, fullFuzzyNeedles.count)
    }

    /// Сколько правок прощаем образцу длины n.
    ///
    /// ⚠️ ЦИФРЫ ВЫБРАНЫ ЗАМЕРОМ, А НЕ НА ГЛАЗ (`run-voicefuzzy.sh`, 28.08.2026, корпус 163k русских
    /// и 60k английских слов). У соседей порог мягче (5–8 → len/3), и на нашем засеве он выводит под
    /// удар 129 живых слов против 13 у этой политики. После учёта реального числа слов в образце
    /// средняя политика сокращает hot-path prefilter 207→89 (мягкая — до 66).
    ///
    /// Короче пяти символов нечёткости нет вовсе: «юсдт», «впн», «апи» это четыре символа и меньше,
    /// у них любая правка меняет слово целиком.
    static func fuzzyTolerance(_ n: Int) -> Int {
        if n < 5 { return 0 }
        return n <= 8 ? 1 : 2
    }

    /// Расстояние Левенштейна с ранним отказом: считать точное значение незачем, нужен ответ
    /// «влезает ли в допуск». Полоса вокруг диагонали шириной `limit` — за её пределами ответ
    /// заведомо больше допуска.
    static func editDistance(_ a: [Character], _ b: [Character], upTo limit: Int) -> Int {
        let n = a.count, m = b.count
        if abs(n - m) > limit { return limit + 1 }
        if n == 0 { return m }
        var prev = Array(0...m)
        var cur = [Int](repeating: 0, count: m + 1)
        for i in 1...n {
            cur[0] = i
            var rowMin = i
            let lo = max(1, i - limit), hi = min(m, i + limit)
            if lo > 1 { cur[lo - 1] = limit + 1 }
            for j in lo...hi {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                rowMin = min(rowMin, cur[j])
            }
            if hi < m { cur[hi + 1] = limit + 1 }
            if rowMin > limit { return limit + 1 }
            swap(&prev, &cur)
        }
        return prev[m]
    }

    // MARK: - Подсказка распознаванию

    /// СЛОВА ДЛЯ `initial_prompt`: смещаем не результат, а само распознавание (задача 143).
    ///
    /// Словарь выше правит текст ПОСЛЕ распознавания — надёжно, но лечит следствие: модель всё равно
    /// слышит «кейбуп», просто мы переписываем вывод. У whisper.cpp есть второй рычаг: слова из
    /// `initial_prompt` становятся вероятнее при декодировании. Значит те же самые записи можно
    /// подложить модели ЗАРАНЕЕ, и часть слов она угадает сама.
    ///
    /// Отдаём ПРАВУЮ колонку, «как пишется»: смещать надо к правильному написанию, а не к тому, что
    /// нам послышалось.
    ///
    /// ⚠️ БЮДЖЕТ ОБЯЗАТЕЛЕН. Окно промпта у whisper ограничено (~224 токена), и там уже лежит фраза
    /// для пунктуации, которая нам дороже: без неё модель в трети случаев уходит в режим без знаков
    /// препинания (замер 11.07). Поэтому словарь добирает ОСТАТОК, а не занимает окно целиком.
    ///
    /// ⚠️ ИМЕНА ВПЕРЁД. При нехватке места первыми идут записи с заглавной буквы: это имена
    /// собственные, которых модель не знает в принципе. Обычные слова вроде «вайб» она слышит верно
    /// или почти верно, и им достаточно правки на выходе.
    func recognitionHint(maxChars: Int = 180) -> String? {
        guard !orderedPairs.isEmpty else { return nil }
        var seen = Set<String>()
        let words = orderedPairs.map { $0.1 }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !words.isEmpty else { return nil }
        let named = words.filter { $0.contains(where: { $0.isUppercase }) }
        let plain = words.filter { !$0.contains(where: { $0.isUppercase }) }
        var out: [String] = []
        var used = 0
        for w in named + plain {
            let cost = w.count + 2                     // само слово плюс «, »
            if used + cost > maxChars { continue }     // не влезло — пробуем следующее, оно короче
            out.append(w); used += cost
        }
        return out.isEmpty ? nil : out.joined(separator: ", ")
    }

    // MARK: - Применение

    /// Пройти по распознанному тексту и заменить всё, что нашлось. Возвращает исходную строку, если
    /// словарь пуст: это самый частый случай, и платить за него разбором текста незачем.
    func apply(_ text: String) -> String {
        guard !needles.isEmpty, !text.isEmpty else { return text }
        let src = Array(text)
        var out = String(); out.reserveCapacity(text.count + 16)
        var i = 0
        var hits = 0
        var fuzzyHits = 0
        while i < src.count {
            // Замена начинается ТОЛЬКО с начала слова: иначе «код» внутри «кодировки» жил бы своей
            // жизнью, а человек не смог бы предсказать ни одной замены.
            let atWordStart = (i == 0) || !isWordChar(src[i - 1])
            if atWordStart, let (end, needle) = match(src, from: i) {
                out += cased(needle.replacement, likeSourceAt: src, i)
                i = end
                hits += 1
                continue
            }
            // Нечёткое — ТОЛЬКО когда точное не нашлось: точное дешевле и предсказуемее, и пока оно
            // срабатывает, гадать не о чем.
            if atWordStart, let (end, replacement) = fuzzyMatch(src, from: i) {
                out += cased(replacement, likeSourceAt: src, i)
                i = end
                hits += 1
                fuzzyHits += 1
                continue
            }
            out.append(src[i])
            i += 1
        }
        if hits > 0 { kbLog("словарь диктовки: заменено \(hits)\(fuzzyHits > 0 ? " (из них нечётко \(fuzzyHits))" : "")") }
        return out
    }

    private func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    /// Разрыв слов. Дефис для нас то же, что пробел — см. разбор в `match`.
    private func isBreak(_ c: Character) -> Bool { c.isWhitespace || c == "-" || c == "–" }

    // MARK: - Нечёткое совпадение

    /// НЕЧЁТКОЕ СОВПАДЕНИЕ ИДЁТ ПО СЛОВУ ЦЕЛИКОМ, А НЕ ОТ НАЧАЛА СЛОВА, И ЭТО ГЛАВНОЕ ОТЛИЧИЕ ОТ
    /// ТОЧНОГО. Разница не вкусовая, она измерена (`run-voicefuzzy.sh`, 28.08.2026): на нашем засеве
    /// префиксная нечёткость выводит под удар 1027 живых слов, а нечёткость по целому слову — 129,
    /// то есть в восемь раз меньше при том же выигрыше. Причина понятна: у образца «сидрем» с
    /// допуском 2 в русском языке сотни слов, начинающихся похоже («систематичность», «стремнина»,
    /// «задремывавший»), и все они стали бы кандидатами.
    ///
    /// Точное совпадение при этом остаётся префиксным, как было: «вайп» обязано чинить и
    /// «вайпкодинг» (задача 126). То есть правило для человека простое: **точное правится где угодно
    /// в начале слова, похожее — только если слово похоже целиком.**
    ///
    /// Побеждает наименьшее расстояние; при равенстве — более длинный образец, как и в точном.
    private func fuzzyMatch(_ src: [Character], from i: Int) -> (Int, String)? {
        // Отдельный ready-бит обязателен: пустой/битый words-файл оставляет в LayoutData набор
        // ExtraWords, поэтому по одному `contains` отличить полный словарь от обломка нельзя.
        guard Self.fuzzyLanguageDataReady, !fuzzyNeedles.isEmpty else { return nil }
        let ahead = wordsAhead(src, from: i, max: maxFuzzyWords)
        guard !ahead.isEmpty else { return nil }

        // Каждая удалённая из hot-path игла B покрыта опорой A: d(A,B) ≤ tol(A), число слов равно.
        // Если B могла совпасть с вводом X, то по неравенству треугольника
        // d(A,X) ≤ tol(A)+tol(B) ≤ tol(A)+2. Поэтому расширенный prefilter НЕ теряет ни одного
        // полного кандидата, а точный ответ затем выбирается по исходным 207 иглам.
        let possible = fuzzyNeedles.contains { n in
            guard n.words <= ahead.count else { return false }
            let cand = ahead[n.words - 1]
            guard !allWordsOfTheLanguage(cand.text) else { return false }
            let prefilterTolerance = n.tol + 2       // максимальный production-допуск любой иглы
            guard abs(cand.text.count - n.pattern.count) <= prefilterTolerance else { return false }
            return Self.editDistance(n.pattern, cand.text, upTo: prefilterTolerance)
                <= prefilterTolerance
        }
        guard possible else { return nil }

        var best: (d: Int, len: Int, end: Int, replacement: String)?
        var bestIsAmbiguous = false
        for n in fullFuzzyNeedles {
            guard n.words <= ahead.count else { continue }
            let cand = ahead[n.words - 1]
            guard abs(cand.text.count - n.pattern.count) <= n.tol else { continue }
            // ⚠️ ПРЕДОХРАНИТЕЛЬ, БЕЗ КОТОРОГО ВСЁ ОСТАЛЬНОЕ БЕССМЫСЛЕННО: живое слово языка не
            // трогаем никогда. «сиденс» с допуском 1 дотягивается до «сидение», «сиденья»,
            // «сиденье» — это обычная русская речь, и переписать её в «Seedance» недопустимо.
            // Для многословного образца условие «все слова живые»: «когда код» защищено, а
            // «клоуд кот» нет, потому что «клоуд» словом не является.
            if allWordsOfTheLanguage(cand.text) { continue }
            let d = Self.editDistance(n.pattern, cand.text, upTo: n.tol)
            guard d <= n.tol else { continue }
            if best == nil || d < best!.d || (d == best!.d && n.pattern.count > best!.len) {
                best = (d, n.pattern.count, cand.end, n.replacement)
                bestIsAmbiguous = false
            } else if d == best!.d, n.pattern.count == best!.len,
                      n.replacement != best!.replacement {
                // Две одинаково хорошие догадки с разными ответами — это не повод выбирать по
                // случайному порядку словаря. Exact уже проверен выше; fuzzy здесь fail-closed.
                bestIsAmbiguous = true
            }
        }
        guard let b = best, !bestIsAmbiguous else { return nil }
        return (b.end, b.replacement)
    }

    /// Каждое ли слово кандидата — живое слово языка. Пустой кандидат живым не считаем.
    private func allWordsOfTheLanguage(_ text: [Character]) -> Bool {
        let parts = text.split(separator: " ")
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { Self.isWordOfTheLanguage(String($0)) }
    }

    /// Слова, начинающиеся в позиции `i`, нарастающим итогом: `[0]` это первое слово, `[1]` —
    /// «первое второе» и так далее. Нормализованы тем же `fold`, что и образцы, а `end` указывает в
    /// ИСХОДНЫЙ текст, чтобы замена отрезала ровно столько, сколько прочитала.
    private func wordsAhead(_ src: [Character], from i: Int, max maxWords: Int) -> [(text: [Character], end: Int)] {
        guard maxWords > 0 else { return [] }
        var out: [(text: [Character], end: Int)] = []
        var acc: [Character] = []
        var si = i
        while out.count < maxWords {
            var w: [Character] = []
            while si < src.count, isWordChar(src[si]) {
                w.append(contentsOf: Self.fold(String(src[si])))
                si += 1
            }
            if w.isEmpty { break }
            if !acc.isEmpty { acc.append(" ") }
            acc.append(contentsOf: w)
            out.append((acc, si))
            var bi = si
            while bi < src.count, isBreak(src[bi]) { bi += 1 }
            if bi == si { break }        // разрыва нет — следующего слова тоже
            si = bi
        }
        return out
    }

    /// Первое (самое длинное) совпадение образца в позиции `i`. Возвращает конец совпадения.
    private func match(_ src: [Character], from i: Int) -> (Int, (pattern: [Character], replacement: String))? {
        for needle in needles {
            var pi = 0, si = i
            var ok = true
            while pi < needle.pattern.count {
                let pc = needle.pattern[pi]
                if pc == " " {
                    // Пробел в образце значит «здесь разрыв слов», а каким знаком его изобразила
                    // модель, нас не касается.
                    //
                    // ⚠️ ДЕФИС СЧИТАЕТСЯ ТАКИМ ЖЕ РАЗРЫВОМ (автор 13.08). Распознавание пишет составные
                    // вещи как придётся: «клауд код», «клауд-код», «вайб кодинг», «вайб-кодинг». Без
                    // этого на каждый вариант написания заводилась бы отдельная строка словаря, то
                    // есть человек вручную перечислял бы то, что мы и так можем считать одинаковым.
                    guard si < src.count, isBreak(src[si]) else { ok = false; break }
                    while si < src.count, isBreak(src[si]) { si += 1 }
                    pi += 1
                    continue
                }
                guard si < src.count, Self.fold(String(src[si])) == String(pc) else { ok = false; break }
                si += 1; pi += 1
            }
            if ok { return (si, needle) }
        }
        return nil
    }

    /// Регистр замены. Если человек написал замену с заглавной («Keyboop»), она такая всегда: это
    /// имя, а не слово предложения. Если замена целиком строчная («вайб»), она перенимает регистр
    /// того, что заменяет, иначе фраза, начинавшаяся с «Вайпкодинг», продолжилась бы со строчной.
    private func cased(_ replacement: String, likeSourceAt src: [Character], _ i: Int) -> String {
        guard replacement.allSatisfy({ !$0.isUppercase }), src[i].isUppercase,
              let first = replacement.first else { return replacement }
        return String(first).uppercased() + replacement.dropFirst()
    }
}

extension VoiceDictionary: PairListStore {}
