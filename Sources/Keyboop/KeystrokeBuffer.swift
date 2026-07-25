import Foundation

/// Локальный буфер набранного — то, что приложение нам не отдаёт.
/// Храним текущее слово + последнее завершённое слово и хвост (пробел/таб после него).
/// Буфер сбрасывается на навигации/клике/смене окна, чтобы не чинить чужой текст.
final class KeystrokeBuffer {
    private(set) var currentWord = ""
    private(set) var lastWord = ""
    private(set) var lastTail = ""

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

    func append(_ s: String) {
        currentWord += s
        lastActivity = Date()
    }

    func backspace() {
        lastActivity = Date()
        if !currentWord.isEmpty {
            currentWord.removeLast()
            if currentWord.isEmpty {
                // слово стёрто целиком — контекст предыдущего слова больше не достоверен
                lastWord = ""
                lastTail = ""
                // и групповая история ненадёжна (стёрли через границу) — рвём её, single-word живёт
                sessionWords.removeAll()
            }
        } else if !lastTail.isEmpty {
            // Курсор стои́т ЗА завершённым словом: стираем его концевой пробел/таб — ужимаем хвост,
            // само слово ещё помним (держим консистентность с группой).
            lastTail.removeLast()
            if !sessionWords.isEmpty { sessionWords[sessionWords.count - 1].tail = lastTail }
        } else if !lastWord.isEmpty {
            // Хвост исчерпан → Backspace вошёл В само завершённое слово. «Раз-граничиваем» его обратно
            // в currentWord, чтобы дальнейшая правка шла по ВСЕМУ слову, а не теряла префикс. Раньше тут
            // был clear() (буфер забывал слово) → на границе конвертилось ЛИШЬ дописанное окончание —
            // баг «переключается только окончание» (workflow-диагностика 2026-06-28).
            currentWord = lastWord
            if !sessionWords.isEmpty { sessionWords.removeLast() }
            lastWord = sessionWords.last?.word ?? ""
            lastTail = sessionWords.last?.tail ?? ""
            currentWord.removeLast()
            if currentWord.isEmpty {
                lastWord = ""; lastTail = ""; sessionWords.removeAll()
            }
        } else {
            // редактируем что-то раньше (буфер пуст) — безопаснее забыть контекст
            clear()
        }
    }

    /// Завершение слова (пробел/таб/ввод).
    func boundary(_ whitespace: String) {
        lastActivity = Date()
        if !currentWord.isEmpty {
            sessionWords.append((currentWord, whitespace))
            lastWord = currentWord
            lastTail = whitespace
            currentWord = ""
        } else if !lastWord.isEmpty {
            lastTail += whitespace
            // хвост последнего завершённого слова растёт вместе с lastTail (консистентность группы)
            if !sessionWords.isEmpty { sessionWords[sessionWords.count - 1].tail += whitespace }
        }
    }

    func clear() {
        currentWord = ""
        lastWord = ""
        lastTail = ""
        sessionWords.removeAll()
    }

    /// Мягкий сброс контекста: забываем ЗАВЕРШЁННОЕ слово + группу, но НЕ трогаем currentWord —
    /// пользователь продолжает ТО ЖЕ слово на том же месте. Для «фокус мигнул» (активация другого
    /// приложения уведомлением/баннером — каретка НЕ двигалась). Полный clear() здесь «сиротил»
    /// набираемое окончание (буфер забывал префикс → на пробеле конвертилось лишь дописанное, баг
    /// «переключается только окончание» / «ть»→«nm», workflow-диагностика 2026-06-29).
    func softContextReset() {
        lastWord = ""
        lastTail = ""
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
