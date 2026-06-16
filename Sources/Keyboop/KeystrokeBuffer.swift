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
        } else {
            // редактируем что-то раньше — безопаснее забыть контекст
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
    func wordForConversion() -> (word: String, deleteCount: Int, tail: String)? {
        if !currentWord.isEmpty {
            return (currentWord, currentWord.count, "")
        }
        if !lastWord.isEmpty {
            return (lastWord, lastWord.count + lastTail.count, lastTail)
        }
        return nil
    }

    /// После замены обновляем внутреннее состояние, чтобы дальнейший ввод был корректным.
    /// ВАЖНО: синхронизируем и sessionWords — история должна отражать ЭКРАН, а не оригинал
    /// набора (корень G1 из docs/GROUP_CONVERT_EDGECASES.md; на этом же стоит контекстный
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
