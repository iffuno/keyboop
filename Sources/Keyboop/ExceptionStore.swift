import Foundation

/// Пользовательские исключения: слова, которые НЕ переключать (ignored),
/// и слова, которые ВСЕГДА переключать (forceSwap). Хранятся в UserDefaults.
final class ExceptionStore {
    static let shared = ExceptionStore()
    private let d = UserDefaults.standard
    private let ignoredKey = "ignoredWords"
    private let forceKey = "forceSwapWords"
    private let appModesKey = "appExceptionModes"
    private let appLayoutsKey = "appForcedLayouts"
    private let learnedKey = "learnedWords"
    private let seededAppsKey = "seededDefaultApps"   // bundle id, по которым уже применяли встроенный дефолт

    /// Bundle id, для которых встроенный дефолт-режим УЖЕ применяли (один раз). Если юзер потом удалил
    /// программу из списка — bid остаётся здесь, чтобы НЕ вернуть её при следующем запуске.
    private var seededApps: Set<String>

    private(set) var ignored: Set<String>
    private(set) var forceSwap: Set<String>
    /// Слова, ВЫУЧЕННЫЕ на отмене (отдельно от ручных `ignored` — прозрачность, отдельный UI,
    /// полностью обратимо). В detect-каскаде дают .keep так же, как ignored. См. UndoLearner.
    private(set) var learned: Set<String>
    /// Режим авто-переключения на приложение: bundleID → "off" (совсем не трогать) | "soft" (мягко).
    private(set) var appModes: [String: String]

    /// ЖЁСТКАЯ РАСКЛАДКА НА ПРОГРАММУ: bundleID → "en" | "ru". При активации такой программы
    /// переключаем систему на этот язык, что бы ни было до неё.
    ///
    /// Зачем (просьба Жени Сенина из BigGeek, 01.08.2026): в DaVinci Resolve при русской раскладке
    /// не работают горячие клавиши, и человек вынужден переключаться руками при каждом заходе в
    /// программу. То же верно для целого класса профессиональных приложений, где хоткеи привязаны к
    /// латинским буквам. Ровно такое поле есть и у платного конкурента (`switch_to_en_on_focus` в
    /// их пер-аппном профиле), только у них оно скрыто от пользователя и приезжает с сервера.
    ///
    /// ⚠️ ОТДЕЛЬНЫЙ СЛОВАРЬ, А НЕ ТРЕТЬЕ ЗНАЧЕНИЕ `appModes`. Две причины. Первая: это независимая
    /// ось. «Не конвертировать в DaVinci» и «всегда включать там английский» — разные желания, и
    /// человек вправе захотеть оба сразу (для DaVinci как раз так). Вторая: менять тип или
    /// семантику `appModes` опасно — он читается как `[String: String]`, и любая правка формы
    /// молча обнулила бы у всех список исключений при обновлении.
    private(set) var appLayouts: [String: String]

    private init() {
        ignored = Set((d.array(forKey: ignoredKey) as? [String]) ?? [])
        forceSwap = Set((d.array(forKey: forceKey) as? [String]) ?? [])
        learned = Set((d.array(forKey: learnedKey) as? [String]) ?? [])
        appModes = (d.dictionary(forKey: appModesKey) as? [String: String]) ?? [:]
        appLayouts = (d.dictionary(forKey: appLayoutsKey) as? [String: String]) ?? [:]
        seededApps = Set((d.array(forKey: seededAppsKey) as? [String]) ?? [])
        // ПОСЕВ ИСКЛЮЧЕНИЙ ПО УМОЛЧАНИЮ: «вк», «тг», «vk».
        //
        // Это НАСТОЯЩИЕ исключения пользователя, а не украшение (решение автора, 04.08.2026). Раньше
        // те же слова дополнительно лежали в `ExtraWords.defaultKeep`, и выходила ложь: человек
        // удалял чип, а слово всё равно не переключалось, потому что защита оставалась в глобальном
        // списке. Крестик был, а смысла у него не было. Теперь их там нет: удалил — снова
        // переключается, как интерфейс и обещает.
        //
        // Зачем именно эти три. У всех трёх раскладочная пара это валидное слово другого языка, то
        // есть без исключения детектор их честно ломает: вк→dr, тг→nu, а vk→«мл», потому что v=м и
        // k=л, и «мл» это миллилитр. Латинское «tg» не засеваем: его пара «еп» не слово, ломать
        // нечего, а лишняя запись только засоряет список.
        //
        // Удалил — не вернём: у каждого посева свой флаг, и повторно он не выполняется.
        if !d.bool(forKey: "didSeedExcExamples") {
            ignored.formUnion(["вк", "тг", "vk"])
            d.set(true, forKey: "didSeedExcExamples")
            d.set(Array(ignored), forKey: ignoredKey)
        }
        // Догоняющий посев для тех, кто поставил приложение ДО появления латинского «vk» в списке:
        // первый флаг у них давно стоит, и без этого шага они остались бы вообще без защиты, ведь из
        // глобального списка слово тоже убрано. Отдельный флаг, а не сброс первого: воскрешать «вк» и
        // «тг» тем, кто их осознанно удалил, мы не имеем права.
        if !d.bool(forKey: "didSeedExcVkLatin") {
            ignored.insert("vk")
            d.set(true, forKey: "didSeedExcVkLatin")
            d.set(Array(ignored), forKey: ignoredKey)
        }
        // РАЗОВАЯ ОТМЕНА ПОСЕВА: Spotlight больше не в «не конвертировать» (05.08.2026).
        //
        // 31.07 мы засеяли ему режим «выкл» из-за подсказки, съедавшей первый Backspace. Причина
        // ушла (`TextReplacer.killSpotlightSuggestion`), а запись у людей осталась бы навсегда: посев
        // добавляет её один раз и сам никогда не убирает. Без этого шага починка не дошла бы ни до
        // кого, кроме новых пользователей, и «в Spotlight не конвертирует» осталось бы жить.
        //
        // Снимаем ТОЛЬКО ровно тот режим, который сами и поставили: если человек с тех пор выбрал
        // Spotlight'у что-то своё (например «мягкий»), его выбор трогать нельзя.
        if !d.bool(forKey: "didUnseedExcSpotlight") {
            if appModes["com.apple.Spotlight"] == "off" { appModes.removeValue(forKey: "com.apple.Spotlight") }
            d.set(true, forKey: "didUnseedExcSpotlight")
            d.set(appModes, forKey: appModesKey)
        }
    }

    /// Удалить одно слово из исключений (крестик на чипе).
    func removeIgnored(_ word: String) { ignored.remove(word.lowercased()); save() }

    func appMode(_ bundleID: String) -> String { appModes[bundleID] ?? "" }
    func setAppMode(_ bundleID: String, _ mode: String) {
        if mode.isEmpty { appModes.removeValue(forKey: bundleID) } else { appModes[bundleID] = mode }
        save()
    }
    func removeApp(_ bundleID: String) {
        appModes.removeValue(forKey: bundleID)
        appLayouts.removeValue(forKey: bundleID)   // удалили программу из списка — уносим ОБЕ настройки
        save()
    }

    /// Жёсткая раскладка для программы: "" (не трогать) | "en" | "ru".
    func appLayout(_ bundleID: String) -> String { appLayouts[bundleID] ?? "" }
    func setAppLayout(_ bundleID: String, _ lang: String) {
        if lang.isEmpty { appLayouts.removeValue(forKey: bundleID) } else { appLayouts[bundleID] = lang }
        save()
    }

    /// Предзаполнить список исключений ВСТРОЕННЫМИ дефолтами для УСТАНОВЛЕННЫХ программ (видеоредакторы/
    /// терминалы → off, код-редакторы → soft). Вызывает Engine со списком (bid, mode) найденных на машине.
    /// Каждую программу добавляем ОДИН раз (seededApps) и НЕ перетираем то, что юзер настроил вручную;
    /// удалённую юзером — не возвращаем. Возвращает true, если список изменился (для refresh настроек).
    @discardableResult
    func seedDefaultApps(_ pairs: [(bid: String, mode: String)]) -> Bool {
        var changed = false
        for (bid, mode) in pairs where !seededApps.contains(bid) {
            seededApps.insert(bid); changed = true
            if appModes[bid] == nil, !mode.isEmpty { appModes[bid] = mode }   // не трогаем ручной выбор
        }
        if changed { save() }
        return changed
    }

    func addIgnored(_ word: String) {
        let w = word.lowercased()
        guard !w.isEmpty else { return }
        ignored.insert(w)
        forceSwap.remove(w)
        save()
    }

    func addForceSwap(_ word: String) {
        let w = word.lowercased()
        guard !w.isEmpty else { return }
        forceSwap.insert(w)
        ignored.remove(w)
        save()
    }

    /// Убрать слово из «всегда переключать». Нужно странице спорных пар: при смене победителя
    /// проигравшую сторону надо снять, иначе две записи спорят на разных ветках каскада.
    func removeForceSwap(_ word: String) { forceSwap.remove(word.lowercased()); save() }

    /// Полностью заменить список исключений (из текстового поля настроек).
    func setIgnored(_ words: [String]) {
        ignored = Set(words.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
        save()
    }

    var ignoredSorted: [String] { ignored.sorted() }

    // MARK: - Выученные на отмене (учит UndoLearner; UI правит вручную)

    func addLearned(_ word: String) {
        let w = word.lowercased()
        guard !w.isEmpty else { return }
        learned.insert(w)
        save()
    }
    func removeLearned(_ word: String) {
        learned.remove(word.lowercased())
        save()
    }
    /// Полностью заменить список выученных (из текстового поля настроек).
    func setLearned(_ words: [String]) {
        learned = Set(words.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
        save()
    }
    func clearLearned() { learned.removeAll(); save() }
    var learnedSorted: [String] { learned.sorted() }

    private func save() {
        d.set(Array(ignored), forKey: ignoredKey)
        d.set(Array(forceSwap), forKey: forceKey)
        d.set(Array(learned), forKey: learnedKey)
        d.set(appModes, forKey: appModesKey)
        d.set(appLayouts, forKey: appLayoutsKey)
        d.set(Array(seededApps), forKey: seededAppsKey)
    }
}
