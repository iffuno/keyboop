import Foundation

/// Регистр готового текста диктовки. Чистая функция без AppKit, контактов, сети и системных
/// языковых моделей: один и тот же ввод всегда даёт один и тот же результат.
///
/// Настройка «Не начинать с заглавной» про оформление предложений, а не про уничтожение имён.
/// Поэтому здесь names-first граница: частые русские имена (включая краткие и падежные формы)
/// сохраняются даже при омонимии: «Роман», «Вера» и «Лев» считаются именами. Это может оставить
/// редкую лишнюю заглавную у нарицательного, зато больше не превращает имя человека в строчное.
enum VoiceOutputCase {
    typealias CaseKeeper = (String) -> Bool

    /// Точка после этих сокращений не завершает предложение. Набор перенесён без изменений из
    /// VoiceController: отдельная задача про имена не должна менять уже принятую пунктуацию.
    private static let notSentenceEnd: Set<String> = [
        "г", "гг", "д", "др", "е", "им", "каб", "корп", "кв", "млн", "млрд", "обл", "оф", "п", "пр",
        "проф", "рис", "руб", "с", "см", "стр", "т", "тел", "тыс", "ул", "эт",
        "mr", "mrs", "ms", "dr", "prof", "vs", "fig", "no", "etc", "e", "g", "i"
    ]

    /// Снять заглавную только у начала предложения, сохранив аббревиатуры, имена и слова с
    /// намеренным регистром из словаря диктовки.
    ///
    /// `keepsCase` получает ТОЧНЫЙ целый токен, а не префикс. Это важно: правило для `Keyboop`
    /// не должно автоматически защищать `Keyboopом`, если сам словарь такую форму не задал.
    static func lowercasedSentenceStarts(
        _ text: String,
        keepsCase: CaseKeeper = { _ in false }
    ) -> String {
        var characters = Array(text)
        var atSentenceStart = true
        var previousWord = ""

        // Дополнительное доказательство без догадок о языке: если редкое имя уже встретилось в
        // середине предложения как «Эразм», следующий ТОЧНО такой же токен в начале предложения
        // сохраняем. Формы не склеиваем: «Эразм» не является доказательством для «Эразму».
        var repeatedCapitalizedTokens = Set<String>()

        var i = 0
        while i < characters.count {
            let c = characters[i]
            if c.isLetter || c.isNumber {
                let start = i
                while i < characters.count, characters[i].isLetter || characters[i].isNumber {
                    i += 1
                }
                let token = String(characters[start..<i])
                let folded = foldToken(token)

                if atSentenceStart {
                    if shouldLower(
                        token,
                        folded: folded,
                        repeatedCapitalizedTokens: repeatedCapitalizedTokens,
                        keepsCase: keepsCase
                    ) {
                        // Unicode lowercase теоретически может разложить один Character в
                        // несколько. В таком экзотическом случае лучше оставить его как есть,
                        // чем менять индексы уже идущего прохода.
                        let lower = characters[start].lowercased()
                        if lower.count == 1, let replacement = lower.first {
                            characters[start] = replacement
                        }
                    }
                    atSentenceStart = false
                } else if isCapitalized(token) {
                    repeatedCapitalizedTokens.insert(folded)
                }

                previousWord = token
                continue
            }

            switch c {
            case ".":
                atSentenceStart = !notSentenceEnd.contains(foldToken(previousWord))
            case "!", "?", "…", "\n", "\r":
                atSentenceStart = true
            case " ", "\t", "«", "»", "‹", "›", "\"", "“", "”", "„", "‘", "’", "'",
                 "(", ")", "[", "]", "{", "}", "-", "—", "–", ":", ";", ",":
                // Обрамление не меняет уже установленный признак начала. В частности, `!»` и
                // `?)` должны пропустить начало следующего предложения сквозь закрывающий знак.
                break
            default:
                atSentenceStart = false
            }
            previousWord = ""
            i += 1
        }
        return String(characters)
    }

    private static func shouldLower(
        _ token: String,
        folded: String,
        repeatedCapitalizedTokens: Set<String>,
        keepsCase: CaseKeeper
    ) -> Bool {
        guard isCapitalized(token) else { return false }
        if isAcronym(token) { return false }
        if keepsCase(token) { return false }
        if commonRussianPersonalNames.contains(folded) { return false }
        if repeatedCapitalizedTokens.contains(folded) { return false }
        return true
    }

    private static func isCapitalized(_ token: String) -> Bool {
        token.first?.isUppercase == true
    }

    /// Сохраняем прежнюю полезную границу: две первые буквы слова заглавные — это аббревиатура.
    /// Цифры между буквами пропускаем, поэтому `GPT4` и `МФЦ` одинаково не портятся.
    private static func isAcronym(_ token: String) -> Bool {
        let firstTwo = Array(token.lazy.filter { $0.isLetter }.prefix(2))
        return firstTwo.count == 2 && firstTwo[0].isUppercase && firstTwo[1].isUppercase
    }

    /// Ровно одно нормализованное целое слово. Никаких префиксов и fuzzy: `Иван` защищает `Иван`,
    /// но не `Иваново`. `ё`/`е` складываются, потому что модели диктовки свободно чередуют их даже
    /// для одного и того же имени (`Артём`/`Артем`).
    private static func foldToken(_ token: String) -> String {
        token.lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    /// Частые русские личные имена. В исходнике перечислены канонические и разговорные формы, а
    /// безопасные падежи строятся по нескольким узким моделям. Никакого словаря нарицательных или
    /// догадки по суффиксу нет: неизвестное слово остаётся неизвестным.
    private static let commonRussianPersonalNames: Set<String> = {
        var result = Set<String>()

        func add(_ forms: [String]) {
            for form in forms { result.insert(VoiceOutputCase.foldToken(form)) }
        }

        // Твёрдая согласная: Иван → Ивана / Ивану / Иваном / Иване.
        func addMasculineConsonant(_ name: String) {
            add([name, name + "а", name + "у", name + "ом", name + "е"])
        }

        // -й: Андрей → Андрея / Андрею / Андреем / Андрее; у -ий предложный на -ии.
        func addMasculineY(_ name: String) {
            guard name.lowercased().hasSuffix("й") else { add([name]); return }
            let stem = String(name.dropLast())
            let prepositional = name.hasSuffix("ий") ? stem + "и" : stem + "е"
            add([name, stem + "я", stem + "ю", stem + "ем", prepositional])
        }

        // Мужское -ь: Игорь → Игоря / Игорю / Игорем / Игоре.
        func addMasculineSoftSign(_ name: String) {
            guard name.hasSuffix("ь") else { add([name]); return }
            let stem = String(name.dropLast())
            add([name, stem + "я", stem + "ю", stem + "ем", stem + "е"])
        }

        // -а для обоих родов и кратких форм. После г/к/х/ж/ч/ш/щ/ц родительный получает -и.
        func addAEnding(_ name: String) {
            guard name.lowercased().hasSuffix("а") else { add([name]); return }
            let stem = String(name.dropLast())
            let spellingRule: Set<Character> = ["г", "к", "х", "ж", "ч", "ш", "щ", "ц"]
            let genitiveEnding = stem.lowercased().last.map(spellingRule.contains) == true ? "и" : "ы"
            add([name, stem + genitiveEnding, stem + "е", stem + "у", stem + "ой", stem + "ою"])
        }

        // -я: Надя → Нади / Наде / Надю / Надей; Мария → Марии / Марию / Марией.
        func addYaEnding(_ name: String) {
            guard name.lowercased().hasSuffix("я") else { add([name]); return }
            let stem = String(name.dropLast())
            let dativeEnding = stem.lowercased().last == "и" ? "и" : "е"
            add([name, stem + "и", stem + dativeEnding, stem + "ю", stem + "ей", stem + "ею"])
        }

        let masculineConsonant = [
            "Александр", "Альберт", "Антон", "Артём", "Артур", "Богдан", "Борис", "Вадим",
            "Валентин", "Виктор", "Владимир", "Владислав", "Вячеслав", "Глеб", "Даниил",
            "Данил", "Денис", "Егор", "Иван", "Кирилл", "Константин", "Леонид", "Макар",
            "Максим", "Марк", "Михаил", "Олег", "Роберт", "Роман", "Руслан", "Семён",
            "Станислав", "Степан", "Фёдор", "Эдуард", "Ярослав", "Яков"
        ]
        masculineConsonant.forEach(addMasculineConsonant)

        let masculineY = [
            "Алексей", "Анатолий", "Андрей", "Аркадий", "Арсений", "Валерий", "Василий",
            "Виталий", "Геннадий", "Георгий", "Григорий", "Дмитрий", "Евгений", "Матвей",
            "Николай", "Сергей", "Тимофей", "Юрий"
        ]
        masculineY.forEach(addMasculineY)
        ["Игорь", "Лазарь", "Эмиль"].forEach(addMasculineSoftSign)

        let aEnding = [
            // Канонические женские и мужское Никита.
            "Александра", "Алина", "Алиса", "Алла", "Анна", "Валентина", "Вера", "Галина",
            "Диана", "Екатерина", "Елена", "Елизавета", "Жанна", "Зинаида", "Инна", "Ирина",
            "Карина", "Кира",
            "Кристина", "Лариса", "Людмила", "Маргарита", "Марина", "Надежда", "Нина",
            "Никита", "Оксана", "Ольга", "Полина", "Раиса", "Светлана", "Татьяна", "Ульяна",
            "Эмма", "Яна",
            // Самые обычные краткие формы.
            "Алёна", "Вика", "Гена", "Гриша", "Даша", "Дима", "Ира", "Ксюша", "Лена",
            "Лера", "Лиза", "Лида", "Люба", "Маша", "Миша", "Наташа", "Нюша",
            "Паша", "Рита", "Рома", "Саша", "Света", "Слава", "Серёжа", "Стёпа", "Тома",
            "Юра", "Яша", "Лёша", "Сёма", "Илюша", "Ильюша", "Тимоша"
        ]
        aEnding.forEach(addAEnding)

        let yaEnding = [
            // Канонические.
            "Анастасия", "Валерия", "Виктория", "Дарья", "Евгения", "Зоя", "Илья", "Ксения",
            "Лидия", "Майя", "Мария", "Наталья", "Олеся", "София", "Юлия",
            // Краткие формы обоих родов.
            "Аня", "Боря", "Валя", "Ваня", "Витя", "Володя", "Галя", "Даня", "Женя", "Катя",
            "Коля", "Костя", "Лёня", "Митя", "Надя", "Настя", "Оля", "Петя", "Поля", "Соня",
            "Таня", "Толя", "Федя", "Юля"
        ]
        yaEnding.forEach(addYaEnding)

        // Краткие формы на согласную склоняются как обычные мужские имена.
        ["Влад", "Вадик", "Макс", "Стас"].forEach(addMasculineConsonant)

        // Чередование основы нельзя безопасно получить общим окончанием — держим явно.
        add(["Павел", "Павла", "Павлу", "Павлом", "Павле"])
        add(["Пётр", "Петра", "Петру", "Петром", "Петре"])
        add(["Лев", "Льва", "Льву", "Львом", "Льве"])
        add(["Любовь", "Любови", "Любовью"])

        // Распространённые несклоняемые формы.
        add(["Мэри", "Николь"])
        return result
    }()
}
