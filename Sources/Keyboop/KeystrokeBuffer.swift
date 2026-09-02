import Foundation

/// Локальный буфер набранного — то, что приложение нам не отдаёт.
/// Храним текущее слово + последнее завершённое слово и хвост (пробел/таб после него).
/// Буфер сбрасывается на навигации/клике/смене окна, чтобы не чинить чужой текст.
final class KeystrokeBuffer {
    private(set) var currentWord = ""
    private(set) var lastWord = ""
    private(set) var lastTail = ""

    /// Интервал между ПЕРВЫМИ двумя ASCII-пробелами в хвосте завершённого слова.
    /// Нужен только для сохранения системной «точки по двойному пробелу»: если boundary-конверсия
    /// стартовала с задержкой, macOS уже могла заменить эти два физических пробела на `. `, а наша
    /// ретайп-замена раньше возвращала обратно `  `. Время монотонное; nil = доказанного быстрого
    /// двойного пробела нет, поэтому правило обязано молчать.
    private(set) var lastTailDoubleSpaceGap: TimeInterval?
    private var lastTailFirstSpaceAt: TimeInterval?

    /// История ЗАВЕРШЁННЫХ слов текущей сессии набора (между clear'ами) — для групповой
    /// конвертации нескольких слов одним хоткеем. Каждый элемент: слово + хвост (пробелы после).
    /// Чистится в clear() (навигация/клик/смена окна), поэтому курсор всегда в конце набранного.
    private(set) var sessionWords: [(word: String, tail: String)] = []
    /// Защитный кап: не конвертировать гигантскую историю одним махом (как clipboard-кап).
    private let groupMaxChars = 200
    /// Время последнего ввода — групповая сессия «протухает» через groupMaxIdle без активности
    /// (курсор-инвариант «в конце набранного» становится ненадёжным — юзер мог уйти и кликнуть).
    private var lastActivity = Date()
    private let groupMaxIdle: TimeInterval = 8

    /// САМАЯ ДЛИННАЯ ПАУЗА МЕЖДУ БУКВАМИ ВНУТРИ СЛОВА — отличает набор от нажатия команд.
    ///
    /// Заведено 23.08.2026 по наблюдению автора в Adobe Premiere: там горячие клавиши голые (C, V,
    /// N, Y, T), а пробел это воспроизведение. Для нас это выглядит буква-буква-граница, то есть
    /// в точности как набранное слово, и отличить одно от другого по БУКВАМ невозможно: «yf», «lj»,
    /// «nj» — законные русские предлоги и законные команды монтажа одновременно.
    ///
    /// Отличается не состав, а ритм. Слово набирают слитно, десятые доли секунды между буквами;
    /// команды разделены взглядом на экран и результатом предыдущей команды. Меряем поэтому паузу,
    /// а не длину.
    private(set) var currentWordGap: TimeInterval = 0
    /// То же для ЗАВЕРШЁННОГО слова: решение о конверсии принимается уже после boundary(), когда
    /// слово переехало в lastWord, поэтому его ритм обязан переехать вместе с ним.
    private(set) var lastWordGap: TimeInterval = 0

    func append(_ s: String) {
        let now = Date()
        // Пауза считается только МЕЖДУ буквами одного слова: перед первой буквой человек думал,
        // и эта пауза про предыдущее слово, а не про это.
        if !currentWord.isEmpty { currentWordGap = max(currentWordGap, now.timeIntervalSince(lastActivity)) }
        currentWord += s
        lastActivity = now
    }

    func backspace() {
        lastActivity = Date()
        if !currentWord.isEmpty {
            currentWord.removeLast()
            if currentWord.isEmpty {
                // слово стёрто целиком — контекст предыдущего слова больше не достоверен
                lastWord = ""
                lastTail = ""
                lastTailFirstSpaceAt = nil
                lastTailDoubleSpaceGap = nil
                // и групповая история ненадёжна (стёрли через границу) — рвём её, single-word живёт
                sessionWords.removeAll()
                // слова больше нет — его ритм тоже. Иначе следующее слово унаследует чужую паузу
                // и мягкий режим замолчит на ровном месте.
                currentWordGap = 0
            }
        } else if !lastTail.isEmpty {
            // Курсор стои́т ЗА завершённым словом: стираем его концевой пробел/таб — ужимаем хвост,
            // само слово ещё помним (держим консистентность с группой).
            lastTail.removeLast()
            if !sessionWords.isEmpty { sessionWords[sessionWords.count - 1].tail = lastTail }
            // После ручного стирания прежний ритм хвоста уже нельзя считать доказательством
            // двойного пробела. Следующая пара должна быть набрана заново.
            if !lastTail.hasPrefix("  ") {
                lastTailFirstSpaceAt = nil
                lastTailDoubleSpaceGap = nil
            }
        } else if !lastWord.isEmpty {
            // Хвост исчерпан → Backspace вошёл В само завершённое слово. «Раз-граничиваем» его обратно
            // в currentWord, чтобы дальнейшая правка шла по ВСЕМУ слову, а не теряла префикс. Раньше тут
            // был clear() (буфер забывал слово) → на границе конвертилось ЛИШЬ дописанное окончание —
            // баг «переключается только окончание» (workflow-диагностика 2026-06-28).
            currentWord = lastWord
            currentWordGap = lastWordGap   // слово вернулось из завершённых — вместе со своим ритмом
            if !sessionWords.isEmpty { sessionWords.removeLast() }
            lastWord = sessionWords.last?.word ?? ""
            lastTail = sessionWords.last?.tail ?? ""
            lastTailFirstSpaceAt = nil
            lastTailDoubleSpaceGap = nil
            currentWord.removeLast()
            if currentWord.isEmpty {
                lastWord = ""; lastTail = ""; sessionWords.removeAll(); currentWordGap = 0
                lastTailFirstSpaceAt = nil; lastTailDoubleSpaceGap = nil
            }
        } else {
            // редактируем что-то раньше (буфер пуст) — безопаснее забыть контекст
            clear()
        }
    }

    /// Завершение слова (пробел/таб/ввод).
    func boundary(_ whitespace: String,
                  at eventTime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lastActivity = Date()
        if !currentWord.isEmpty {
            sessionWords.append((currentWord, whitespace))
            lastWord = currentWord
            lastTail = whitespace
            lastTailFirstSpaceAt = whitespace == " " ? eventTime : nil
            lastTailDoubleSpaceGap = nil
            currentWord = ""
            lastWordGap = currentWordGap
            currentWordGap = 0
        } else if !lastWord.isEmpty {
            let previousTail = lastTail
            lastTail += whitespace
            if previousTail == " ", whitespace == " ", let first = lastTailFirstSpaceAt {
                lastTailDoubleSpaceGap = eventTime - first
            } else if previousTail.hasPrefix("  "), lastTailDoubleSpaceGap != nil {
                // Третий пробел/Tab/Enter не отменяет уже доказанную ведущую пару: правило меняет
                // только первые два символа и обязано сохранить весь остальной хвост как есть.
            } else if previousTail.isEmpty, whitespace == " " {
                lastTailFirstSpaceAt = eventTime
                lastTailDoubleSpaceGap = nil
            } else {
                lastTailFirstSpaceAt = nil
                lastTailDoubleSpaceGap = nil
            }
            // хвост последнего завершённого слова растёт вместе с lastTail (консистентность группы)
            if !sessionWords.isEmpty { sessionWords[sessionWords.count - 1].tail += whitespace }
        }
    }

    /// ⚠️ ОЧИСТКА НЕПУСТОГО БУФЕРА ПИШЕТСЯ В ЛОГ ВМЕСТЕ С ВИНОВНИКОМ (23.08.2026).
    ///
    /// Повод: жалоба «кликнул в поле, набрал букву, не переключается», и в логе каждый раз стояло
    /// «на границе слова буфер пуст». То есть слово исчезало У НАС, а не у человека, но кто именно
    /// его стёр, было не видно: `clear()` зовётся из полутора десятков мест, и все они законны по
    /// отдельности. Две попытки диагноза по косвенным уликам (запоздалый клик, вклинившаяся
    /// синтетика) не подтвердились — обе оставили бы свою строку, а её не было.
    ///
    /// Пустой буфер чистят постоянно и это шум, поэтому пишем только когда чистить БЫЛО ЧТО.
    /// Аргументы по умолчанию подставляют МЕСТО ВЫЗОВА, а не место объявления.
    func clear(_ caller: String = #function, _ line: Int = #line) {
        if !currentWord.isEmpty || !lastWord.isEmpty {
            kbLog("буфер очищен из \(caller):\(line) — было «\(currentWord.count) симв. + завершённое \(lastWord.count)»")
        }
        currentWord = ""
        lastWord = ""
        lastTail = ""
        lastTailFirstSpaceAt = nil
        lastTailDoubleSpaceGap = nil
        sessionWords.removeAll()
        currentWordGap = 0
        lastWordGap = 0
    }

    /// Мягкий сброс контекста: забываем ЗАВЕРШЁННОЕ слово + группу, но НЕ трогаем currentWord —
    /// пользователь продолжает ТО ЖЕ слово на том же месте. Для «фокус мигнул» (активация другого
    /// приложения уведомлением/баннером — каретка НЕ двигалась). Полный clear() здесь «сиротил»
    /// набираемое окончание (буфер забывал префикс → на пробеле конвертилось лишь дописанное, баг
    /// «переключается только окончание» / «ть»→«nm», workflow-диагностика 2026-06-29).
    func softContextReset() {
        lastWord = ""
        lastTail = ""
        lastTailFirstSpaceAt = nil
        lastTailDoubleSpaceGap = nil
        sessionWords.removeAll()
    }

    /// Сбросить ТОЛЬКО групповую историю (sessionWords), сохранив single-word контекст
    /// (currentWord/lastWord). Зовётся, когда курсор мог сместиться или экран изменился НЕ нашей
    /// группой (стрелки, клик, раскрытие сниппета, голосовая вставка) — чтобы группа не печатала
    /// вслепую по устаревшей модели. После этого группа не соберётся (нужно ≥2 слова), а ручное
    /// переключение одного слова продолжит работать.
    func invalidateGroupHistory() {
        sessionWords.removeAll()
    }

    /// Группа для конвертации нескольких слов: все завершённые слова сессии + текущее (если есть).
    /// Возвращает слова с хвостами и общее число символов для удаления (Backspace), либо nil, если
    /// группа недействительна. Защиты (по реестру edge-cases): протухшая сессия (G15), составные
    /// графемы/суррогаты где Backspace в web/Electron считает иначе (G7), \n/\t в хвостах ≠ 1 символ
    /// на экране (G9), <2 слов, превышен кап длины.
    func groupForConversion() -> (words: [(word: String, tail: String)], deleteCount: Int)? {
        guard Date().timeIntervalSince(lastActivity) <= groupMaxIdle else { return nil }   // G15
        var words = sessionWords
        if !currentWord.isEmpty { words.append((currentWord, "")) }
        guard words.count >= 2 else { return nil }   // группа осмысленна от 2 слов
        for (w, t) in words {
            if w.unicodeScalars.count != w.count { return nil }              // G7: составные графемы
            if t.contains("\n") || t.contains("\t") { return nil }           // G9: перенос/таб
        }
        let total = words.reduce(0) { $0 + $1.word.count + $1.tail.count }
        guard total > 0, total <= groupMaxChars else { return nil }
        return (words, total)
    }

    /// Что конвертировать по запросу: текущее слово (без хвоста), иначе последнее (с хвостом).
    /// Возвращает (слово, сколько символов удалить, хвост).
    /// completedOnly (аудит C2, 24.07): boundary-конверсия стартует через +30мс, и если юзер успел
    /// начать СЛЕДУЮЩЕЕ слово, обычный порядок вернул бы его огрызок («x»), а завершённое слово
    /// осиротело бы и молча не сконвертировалось («иногда не переключается» у быстрых печатающих).
    /// completedOnly целится строго в завершённое слово; начатый огрызок уходит в tail — замена
    /// считается от каретки, поэтому удаляем и перепечатываем ОБА куска: «ghbdtn x» → «привет x».
    func wordForConversion(completedOnly: Bool = false) -> (word: String, deleteCount: Int, tail: String)? {
        if completedOnly {
            guard !lastWord.isEmpty else { return nil }
            return (lastWord, lastWord.count + lastTail.count + currentWord.count, lastTail + currentWord)
        }
        if !currentWord.isEmpty {
            return (currentWord, currentWord.count, "")
        }
        if !lastWord.isEmpty {
            return (lastWord, lastWord.count + lastTail.count, lastTail)
        }
        return nil
    }

    /// Пара к completedOnly-конверсии: обновить именно ЗАВЕРШЁННОЕ слово, не трогая начатое следующее.
    func applyCompletedConversion(converted: String) {
        guard !lastWord.isEmpty else { return }
        lastWord = converted
        if !sessionWords.isEmpty { sessionWords[sessionWords.count - 1].word = converted }
    }

    /// Boundary-конверсия перепечатала хвост той же длины (например, `  ` → `. `). Модель обязана
    /// повторить экран, иначе поздний хоткей/групповая конверсия вернёт два пробела обратно.
    func applyCompletedTail(_ tail: String) {
        guard !lastWord.isEmpty else { return }
        lastTail = tail
        if !sessionWords.isEmpty { sessionWords[sessionWords.count - 1].tail = tail }
        lastTailFirstSpaceAt = nil
        lastTailDoubleSpaceGap = nil
    }

    /// Зафиксировать раскрытие сниппета: текущее слово (триггер) превратилось в раскрытие, затем —
    /// граница (проглоченный пробел/таб/Enter печатается нами). На экране: раскрытие + разделитель,
    /// курсор в начале нового слова. Зовётся синхронно, чтобы дальнейший ввод видел верный буфер.
    func commitSnippet(expansion: String, whitespace: String) {
        currentWord = expansion
        boundary(whitespace)
    }

    /// После замены обновляем внутреннее состояние, чтобы дальнейший ввод был корректным.
    /// ВАЖНО: синхронизируем и sessionWords — история должна отражать ЭКРАН, а не оригинал
    /// набора (корень G1 групповой конвертации; на этом же стоит контекстный
    /// приор детектора — язык предыдущего слова берётся отсюда).
    func applyConversion(converted: String) {
        if !currentWord.isEmpty {
            currentWord = converted
        } else if !lastWord.isEmpty {
            lastWord = converted
            if !sessionWords.isEmpty { sessionWords[sessionWords.count - 1].word = converted }
        }
    }

    /// Слово, ПРЕДШЕСТВУЮЩЕЕ тому, что сейчас решается детектором, — как оно выглядит на
    /// экране (после applyConversion). Для текущего слова (мид-ввод) это последнее завершённое;
    /// для только что завершённого — предыдущее завершённое. O(1), без аллокаций.
    func contextWord(forCurrent: Bool) -> String? {
        forCurrent ? sessionWords.last?.word : sessionWords.dropLast().last?.word
    }
}
