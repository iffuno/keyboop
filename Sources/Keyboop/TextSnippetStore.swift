import Foundation

/// Общий вид хранилища «список пар», чтобы редактор списка не был приколочен к одному источнику.
/// Ровно две операции: редактор больше ничего и не трогал.
protocol PairListStore: AnyObject {
    func pairs() -> [(String, String)]
    func setAll(_ pairs: [(String, String)])
}

extension SnippetStore: PairListStore {}

/// СНИППЕТЫ ДЛЯ ВСТАВКИ ПО СОЧЕТАНИЮ — отдельный список (решение автора 06.08.2026).
///
/// Почему не тот же список, что автозамена. Это разные способы жить: автозамена срабатывает САМА по
/// аббревиатуре, поэтому её записи короткие и с риском случайного попадания. Сниппет вставляют
/// ОСОЗНАННО, поэтому в нём место длинным консольным командам, реквизитам и шаблонам писем, то есть
/// ровно тому, что вешать на аббревиатуру страшно (отзыв #62).
///
/// Список стартует ПУСТЫМ (вариант А, выбор автора): ничего не копируем и не переносим сами. Копия
/// была бы двумя одинаковыми наборами без объяснений, а перенос по длине угадывал бы за человека.
/// В пустом списке стоит приглашение с кнопкой «скопировать из автозамены» — решает он.
final class TextSnippetStore: PairListStore {
    static let shared = TextSnippetStore()
    private let d = UserDefaults.standard
    private let key = "textSnippets"        // [[название, текст]], порядок = порядок вставки цифрой

    private(set) var orderedPairs: [(String, String)] = []

    private init() {
        if let arr = d.array(forKey: key) as? [[String]] {
            orderedPairs = arr.compactMap { $0.count >= 2 ? ($0[0], $0[1]) : nil }
        }
    }

    func pairs() -> [(String, String)] { orderedPairs }

    func setAll(_ pairs: [(String, String)]) {
        // Пустые строки не храним: редактор всегда держит одну такую в конце как приглашение к вводу.
        orderedPairs = pairs.filter { !$0.0.isEmpty || !$0.1.isEmpty }
        d.set(orderedPairs.map { [$0.0, $0.1] }, forKey: key)
    }

    var isEmpty: Bool { orderedPairs.isEmpty }

    /// Разовое копирование из автозамены по кнопке. Именно КОПИРОВАНИЕ: автозамену не трогаем,
    /// иначе человек нажал бы «скопировать» и молча лишился работающих аббревиатур.
    func copyFromAutoreplace() {
        let src = SnippetStore.shared.pairs().filter { !$0.0.isEmpty || !$0.1.isEmpty }
        guard !src.isEmpty else { return }
        var have = Set(orderedPairs.map { $0.0 })
        var out = orderedPairs
        for p in src where !have.contains(p.0) { out.append(p); have.insert(p.0) }
        setAll(out)
    }
}
