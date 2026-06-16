import Foundation

/// Пользовательские исключения: слова, которые НЕ переключать (ignored),
/// и слова, которые ВСЕГДА переключать (forceSwap). Хранятся в UserDefaults.
final class ExceptionStore {
    static let shared = ExceptionStore()
    private let d = UserDefaults.standard
    private let ignoredKey = "ignoredWords"
    private let forceKey = "forceSwapWords"
    private let appModesKey = "appExceptionModes"
    private let learnedKey = "learnedWords"

    private(set) var ignored: Set<String>
    private(set) var forceSwap: Set<String>
    /// Слова, ВЫУЧЕННЫЕ на отмене (отдельно от ручных `ignored` — прозрачность, отдельный UI,
    /// полностью обратимо). В detect-каскаде дают .keep так же, как ignored. См. UndoLearner.
    private(set) var learned: Set<String>
    /// Режим авто-переключения на приложение: bundleID → "off" (совсем не трогать) | "soft" (мягко).
    private(set) var appModes: [String: String]

    private init() {
        ignored = Set((d.array(forKey: ignoredKey) as? [String]) ?? [])
        forceSwap = Set((d.array(forKey: forceKey) as? [String]) ?? [])
        learned = Set((d.array(forKey: learnedKey) as? [String]) ?? [])
        appModes = (d.dictionary(forKey: appModesKey) as? [String: String]) ?? [:]
        // Пред-заполняем список исключений примерами «вк»/«тг» (один раз) — чтобы пользователь СРАЗУ
        // видел, как это работает. Конфликта с defaultKeep нет: decide проверяет ignored ПЕРВЫМ, оба
        // дают .keep. Если юзер удалит примеры — defaultKeep всё равно защитит бренды. Удалил — не
        // вернём (флаг didSeed). См. SettingsWindow «Исключения».
        if !d.bool(forKey: "didSeedExcExamples") {
            ignored.formUnion(["вк", "тг"])
            d.set(true, forKey: "didSeedExcExamples")
            d.set(Array(ignored), forKey: ignoredKey)
        }
    }

    /// Удалить одно слово из исключений (крестик на чипе).
    func removeIgnored(_ word: String) { ignored.remove(word.lowercased()); save() }

    func appMode(_ bundleID: String) -> String { appModes[bundleID] ?? "" }
    func setAppMode(_ bundleID: String, _ mode: String) {
        if mode.isEmpty { appModes.removeValue(forKey: bundleID) } else { appModes[bundleID] = mode }
        save()
    }
    func removeApp(_ bundleID: String) { appModes.removeValue(forKey: bundleID); save() }

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
    }
}
