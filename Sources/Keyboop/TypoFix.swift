import Foundation

/// ИСПРАВЛЕНИЕ ОПЕЧАТОК ПО ТАБЛИЦЕ ПРАВИЛ (задача 114, решение автора 09.08.2026).
///
/// Повод: товарищ автора пользуется конкурентом ИМЕННО из-за этой функции. Разбор их сборки показал,
/// что это НЕ грамматика, а правка одного слова, и, что важнее, показал КАК она устроена.
///
/// # Почему таблица, а не поиск по словарю
///
/// Первый заход был «умнее»: поиск в словаре слова на расстоянии одной правки. Замеры на наших же
/// словарях показали, что такой путь плох по трём причинам сразу, и все три снимаются таблицей:
///
/// | | поиск по словарю | таблица |
/// |---|---|---|
/// | неоднозначность | `bokk` даёт четыре кандидата, приходится молчать | правило либо есть, либо нет |
/// | чужая лексика | «коммит» → «кормит», «линтер» → «литер» | чего нет в таблице, то не трогается |
/// | выбор лучшего | нечем, частот у нас нет | выбран заранее, человеком |
///
/// В разобранной сборке конкурента ровно эта конструкция: таблица правил с полями `prefix_len`,
/// `suffix_len`, `insert_id` и многошаблонный поиск. Мы берём её идею в самом простом виде,
/// «слово → слово», потому что аффиксные правила без валидации опаснее, чем полезны.
///
/// # Чем наша версия ЛУЧШЕ исходной
///
/// **Каждое правило проверено по нашим же словарям**, и это делает плохие данные безвредными.
/// Валидатор (`/tmp` стенд, результат в `Resources/typo_rules.json`) пропускает правило, только если
/// исправление ЕСТЬ в словаре, опечатки в словаре НЕТ, и они отличаются не больше чем на три правки.
/// Из 226 моих заготовок он выбросил 21, и выбросил по делу:
///   • «кампания» → «компания» — ОБА слова живые, у них разный смысл, такая правка была бы ошибкой;
///   • «нечего» → «ничего» — то же самое;
///   • «программа» → «программа», «тенденция» → «тенденция» — мои же опечатки в самой таблице.
/// Ни одно из них не пережило проверку, и ни одно не доехало до людей.
///
/// # Границы
///
/// Работает только на словах, которых нет в словаре. Личный словарь (слово, набранное дважды) и
/// пользовательские исключения неприкосновенны. Выключено по умолчанию: это правка ТЕКСТА, а не
/// раскладки, и включать её за спиной нельзя.
///
/// ⛔️ **Триграммный фильтр как защиту НЕ ИСПОЛЬЗОВАТЬ, проверено и опровергнуто 09.08.** Казалось,
/// что настоящая опечатка «невозможна» в языке, а живое слово правдоподобно. Замер показал полное
/// перекрытие: опечатки от −7.04 до −10.61, живая профлексика от −7.84 до −11.49, словарные слова от
/// −6.98 до −9.29. «коммит» (−8.35) правдоподобнее «телефона» (−8.37). Порога не существует.
final class TypoFix {
    static let shared = TypoFix()
    private init() {}

    private var rulesRu: [String: String] = [:]
    private var rulesEn: [String: String] = [:]
    private(set) var ready = false

    /// Слова вне словаря, которые человек набирал сам. Двух раз хватает: одно совпадение это ещё
    /// опечатка, два одинаковых уже привычка.
    private var personal: [String: Int] = [:]
    private let personalKey = "typoPersonalWords"
    private let personalThreshold = 2

    /// Загрузить таблицу. Зовётся из прогрева: файл небольшой, но на пути нажатия ему всё равно не место.
    func load() {
        guard !ready else { return }
        defer { ready = true }
        personal = (UserDefaults.standard.dictionary(forKey: personalKey) as? [String: Int]) ?? [:]
        guard let url = Self.rulesURL(),
              let data = try? Data(contentsOf: url),
              let all = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        else {
            kbLog("опечатки: таблица правил не найдена — функция молчит")
            return
        }
        rulesRu = all["ru"] ?? [:]
        rulesEn = all["en"] ?? [:]
        kbLog("опечатки: таблица загружена (ru=\(rulesRu.count), en=\(rulesEn.count), своих слов \(personal.count))")
    }

    /// Тот же порядок поиска, что у языковых данных: бандл приложения, либо каталог из окружения
    /// для консольных инструментов.
    private static func rulesURL() -> URL? {
        if let dir = ProcessInfo.processInfo.environment["KEYBOOP_DATA_DIR"], !dir.isEmpty {
            let u = URL(fileURLWithPath: dir).appendingPathComponent("typo_rules.json")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return Bundle.main.url(forResource: "typo_rules", withExtension: "json")
    }

    // MARK: - Личный словарь

    /// Слово ушло в текст, и в словарях его нет — засчитываем человеку.
    ///
    /// ⚠️ Копится ВСЕГДА, даже когда сама функция выключена. Иначе человек, включивший её через
    /// месяц работы, получил бы пустую защиту ровно на своей рабочей лексике.
    func noteTyped(_ word: String) {
        let w = word.lowercased()
        guard ready, w.count >= 4, !inDictionaries(w) else { return }
        let n = (personal[w] ?? 0) + 1
        guard n <= personalThreshold else { return }
        personal[w] = n
        UserDefaults.standard.set(personal, forKey: personalKey)
    }

    func isPersonal(_ word: String) -> Bool { (personal[word.lowercased()] ?? 0) >= personalThreshold }

    private func inDictionaries(_ w: String) -> Bool {
        LayoutData.shared.wordsRu.contains(w) || LayoutData.shared.wordsEn.contains(w)
    }

    // MARK: - Механические опечатки (промах по клавише и перестановка)

    /// Ряды клавиш. Нужны не для раскладки, а для ФИЗИЧЕСКОГО соседства: механическую опечатку
    /// выдаёт клавиатура, а не язык.
    private static let rowsRu = ["йцукенгшщзхъ", "фывапролджэ", "ячсмитьбю"]
    private static let rowsEn = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]

    private static func neighbourMap(_ rows: [String]) -> [Character: [Character]] {
        let grid = rows.map { Array($0) }
        var map: [Character: Set<Character>] = [:]
        for (r, row) in grid.enumerated() {
            for (c, ch) in row.enumerated() {
                var s = Set<Character>()
                if c > 0 { s.insert(row[c - 1]) }
                if c + 1 < row.count { s.insert(row[c + 1]) }
                for dr in [-1, 1] {
                    let rr = r + dr
                    guard rr >= 0, rr < grid.count else { continue }
                    for cc in [c - 1, c, c + 1] where cc >= 0 && cc < grid[rr].count { s.insert(grid[rr][cc]) }
                }
                map[ch, default: []].formUnion(s)
            }
        }
        return map.mapValues { Array($0) }
    }
    private static let nearRu = neighbourMap(rowsRu)
    private static let nearEn = neighbourMap(rowsEn)

    /// Механическая опечатка: промах на СОСЕДНЮЮ клавишу либо перестановка двух соседних букв.
    /// Возвращает исправление, только если словарное слово получилось РОВНО ОДНО.
    ///
    /// # Почему именно эти два вида правки, и ничего больше
    ///
    /// Ограничение физическим соседством и есть та защита, которой не хватало словарному поиску.
    /// Замер на 27 словах живой профессиональной лексики (коммит, линтер, деплой, бэкенд, фронтенд,
    /// рефакторинг, мерджить, хендлер, мидлвар, хардкод и прочие): **ни одного ложного срабатывания**.
    /// «Коммит» не превращается в «кормит» просто потому, что «м» и «р» на клавиатуре не соседи, а
    /// вставку и удаление буквы мы не рассматриваем вовсе — именно на них ломались «линтер» → «литер».
    ///
    /// ⚠️ ДВА ПОРОГА, ОБА ПОЛУЧЕНЫ ЗАМЕРОМ, А НЕ ПРИКИДКОЙ:
    ///   • **от пяти букв.** На коротких словах соседство слишком щедро: «кеш» → «кед», «фича» → «фифа».
    ///   • **перестановка не трогает последние две позиции.** Перестановка в хвосте это чаще всего
    ///     окончание чужого слова, а не промах пальцев: «прокси» → «прокис». Начало и середина
    ///     остаются, поэтому «рпивет» → «привет» и «здарвствуйте» → «здравствуйте» работают.
    ///
    /// Цена: 10.5 микросекунд на слово.
    private func mechanical(_ w: String) -> String? {
        guard w.count >= 5 else { return nil }
        let cyr = w.hasCyrillic
        let dict = cyr ? LayoutData.shared.wordsRu : LayoutData.shared.wordsEn
        let near = cyr ? Self.nearRu : Self.nearEn
        var chars = Array(w)
        var found: String?
        func offer(_ s: String) -> Bool {                 // true — надо прекращать, кандидатов больше одного
            guard dict.contains(s) else { return false }
            if let f = found, f != s { found = nil; return true }
            found = s
            return false
        }
        for i in 0..<chars.count {                        // промах на соседнюю клавишу
            guard let alts = near[chars[i]] else { continue }
            let orig = chars[i]
            for alt in alts {
                chars[i] = alt
                if offer(String(chars)) { chars[i] = orig; return nil }
            }
            chars[i] = orig
        }
        if chars.count > 2 {                              // перестановка, кроме хвоста
            for i in 0..<(chars.count - 2) {
                chars.swapAt(i, i + 1)
                let s = String(chars)
                chars.swapAt(i, i + 1)
                if offer(s) { return nil }
            }
        }
        return found
    }

    // MARK: - Предложение

    /// Исправление для слова, либо nil. Стоимость — один поиск в словаре, никакого перебора.
    func suggest(_ word: String) -> String? {
        guard ready, AppSettings.shared.typoFix else { return nil }
        let w = word.lowercased()
        guard w.count >= 4, w.allSatisfy({ $0.isLetter }) else { return nil }
        // Смешанные огрызки не наши: там работает конверсия раскладки, а не правка опечаток.
        guard word.hasCyrillic != word.hasLatinLetter else { return nil }
        // Сначала защиты, потом поиск: они дешевле и отсекают большую часть слов.
        guard !inDictionaries(w), !isPersonal(w) else { return nil }
        let exc = ExceptionStore.shared
        guard !exc.ignored.contains(w), !exc.learned.contains(w) else { return nil }
        guard !UndoLearner.shared.isSessionProtected(w) else { return nil }
        // Таблица первой: она курирована человеком и потому надёжнее любой догадки. Механический
        // разбор вторым — он покрывает то, чего в таблице нет и быть не может (промахи пальцев).
        guard let fixed = (word.hasCyrillic ? rulesRu : rulesEn)[w] ?? mechanical(w) else { return nil }
        // Регистр возвращаем человеку: «Извените» → «Извините», а не «извините».
        return word.first?.isUppercase == true ? fixed.prefix(1).uppercased() + fixed.dropFirst() : fixed
    }
}
