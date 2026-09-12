import Foundation

// ЕДИНАЯ ИСТОРИЯ: ДИКТОВКИ И ТЕКСТ ИЗ БУФЕРА ОБМЕНА (задача 228, 04.09.2026).
//
// Здесь лежит всё, что можно проверить без AppKit: тип записи, потолки по типам, поиск по обоим
// источникам, решение «записывать ли этот буфер» и реестр наших собственных записей в буфер.
// Файл компилируется стендом `run-clipboardhistory.sh` отдельно от приложения, поэтому в нём нет
// ни NSPasteboard, ни настроек, ни истории на диске: только чистые данные и функции над ними.
// Наблюдатель буфера с таймером живёт в `ClipboardWatcher.swift`, хранилище в `VoiceHistory.swift`.
//
// # Почему буфер вообще попал в историю диктовок
//
// Человеку всё равно, продиктовал он фразу или скопировал её из письма: через час он помнит только,
// что «где-то это было». Две разные истории заставили бы вспоминать ещё и источник. Поэтому лента
// одна, обратная по времени, а тип записи это подпись у строки, а не отдельное окно.
//
// # Границы первой версии (решение автора 04.09.2026)
//
//   • захват буфера это ОТДЕЛЬНЫЙ тумблер, выключенный по умолчанию; включённая история диктовок
//     сама его не включает, а выключенная история выключает и его;
//   • только обычный текст: без файлов, картинок и форматирования, с потолком длины и числа записей;
//   • ничего не записывается, пока в системе поднят Secure Input (где-то открыто поле пароля);
//   • не записываются буферы, помеченные менеджерами паролей и служебными маркерами;
//   • не записываются наши собственные операции с буфером: чтение выделения через ⌘C, вставка без
//     форматирования, «скопировать последнюю диктовку» и копирование из окна истории. Для этого у
//     КАЖДОЙ нашей записи в буфер есть обязанность отметиться в `PasteboardOwnership`;
//   • старые записи без поля `kind` читаются как диктовки: файл истории не мигрирует и не
//     переписывается, потому что у нас уже был случай, когда неосторожное поле обнулило бы историю
//     всем (см. `audio` в истории клипов).

/// Тип записи в единой истории.
enum HistoryKind: String, Codable {
    case dictation
    case clipboard
    /// Расшифровка импортированного аудиофайла (задача 229): живёт по своим правилам, см. `HistoryPolicy`.
    case imported
    /// Расшифровка записанного на Mac звонка (задача 230): те же правила, что у файла, своя подпись.
    case call
}

/// Одна запись истории. Раньше жила внутри `VoiceHistory` как `Entry`; вынесена сюда, чтобы стенд
/// мог проверить чтение старых файлов без самой истории.
///
/// ⚠️ ВСЕ ПОЛЯ, ПОЯВИВШИЕСЯ ПОСЛЕ ПЕРВОЙ ВЕРСИИ, ОБЯЗАНЫ ОСТАВАТЬСЯ Optional. Файл `history.enc`
/// у людей содержит записи без `audio` (до 08.08.2026), без `wave` (до 10.08.2026) и без `kind`
/// и `app` (до 04.09.2026). `JSONDecoder` читает их только потому, что отсутствующий ключ у
/// Optional это nil, а не ошибка. Сделать любое из них обязательным значит обнулить историю всем,
/// кто обновится.
struct HistoryEntry: Codable, Equatable {
    let date: Date
    let text: String
    var audio: String? = nil
    /// Огибающая для волны, 64 значения 0…15.
    var wave: [UInt8]? = nil
    /// nil у записей, сделанных до появления буфера в истории: все они диктовки.
    var kind: HistoryKind? = nil
    /// Источник для подписи и поиска: имя программы у записи буфера, имя файла у импорта.
    var app: String? = nil

    var resolvedKind: HistoryKind { kind ?? .dictation }
    var isClipboard: Bool { resolvedKind == .clipboard }
    /// «Длинные» записи с общими правилами: файл и звонок. Не по сроку хранения, свой потолок,
    /// не подменяют последнюю диктовку, есть «сохранить текст».
    var isImported: Bool { resolvedKind == .imported || resolvedKind == .call }
}

extension HistoryEntry {
    private enum CodingKeys: String, CodingKey { case date, text, audio, wave, kind, app }

    /// Чтение написано руками ради одного: неизвестное значение `kind` из более новой версии
    /// читается как nil (диктовка), а не роняет ВСЮ историю. `VoiceHistory.load()` оборачивает
    /// разбор в `try?`, и одна незнакомая запись иначе показала бы человеку пустое окно после
    /// отката на предыдущую версию. Запись остаётся синтезированной.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(Date.self, forKey: .date)
        text = try c.decode(String.self, forKey: .text)
        audio = try c.decodeIfPresent(String.self, forKey: .audio)
        wave = try c.decodeIfPresent([UInt8].self, forKey: .wave)
        kind = (try? c.decodeIfPresent(HistoryKind.self, forKey: .kind)) ?? nil
        app = try c.decodeIfPresent(String.self, forKey: .app)
    }
}

/// Правила самой ленты: потолки, «последняя диктовка», поиск.
enum HistoryPolicy {
    /// Потолок диктовок тот же, что был у истории до буфера: 50 записей.
    static let maxDictation = 50
    /// Буфер копируют чаще, чем диктуют, и его записи короче. Отдельный потолок, чтобы сотня
    /// скопированных строк не вытеснила диктовки, ради которых история и заведена.
    static let maxClipboard = 100
    /// Расшифровки файлов (задача 229) дорогие: час звонка это минуты работы движка. Свой потолок,
    /// чтобы их не вытесняли ни диктовки, ни буфер; по сроку хранения они тоже не удаляются.
    static let maxImported = 20

    /// Обрезать ленту по потолкам ОТДЕЛЬНО для каждого типа, сохранив порядок по времени.
    /// Возвращает то, что осталось, и то, что выброшено (у выброшенных диктовок надо унести клипы).
    static func capped(_ entries: [HistoryEntry],
                       maxDictation: Int = maxDictation,
                       maxClipboard: Int = maxClipboard,
                       maxImported: Int = maxImported) -> (kept: [HistoryEntry], dropped: [HistoryEntry]) {
        var room: [HistoryKind: Int] = [.dictation: maxDictation, .clipboard: maxClipboard,
                                        .imported: maxImported, .call: maxImported]
        var keptReversed: [HistoryEntry] = [], droppedReversed: [HistoryEntry] = []
        for e in entries.reversed() {
            let k = e.resolvedKind
            if (room[k] ?? 0) > 0 { room[k]! -= 1; keptReversed.append(e) } else { droppedReversed.append(e) }
        }
        return (Array(keptReversed.reversed()), Array(droppedReversed.reversed()))
    }

    /// Последняя ДИКТОВКА, а не последняя запись: пункт «Скопировать последнюю диктовку» обещает
    /// именно диктовку, и скопированная минуту назад строка из письма его обещанием не является.
    /// Расшифровка файла тоже не диктовка: положить часовой созвон в буфер по пункту меню было бы
    /// сюрпризом.
    static func lastDictation(_ entries: [HistoryEntry]) -> HistoryEntry? {
        entries.last { $0.resolvedKind == .dictation }
    }

    /// Последний текст, записанный из буфера, чтобы не плодить дубликаты подряд.
    static func lastClipboardText(_ entries: [HistoryEntry]) -> String? {
        entries.last { $0.isClipboard }?.text
    }

    /// Поиск по обоим типам сразу: по тексту и по имени программы, без учёта регистра.
    /// Пустой запрос совпадает со всем.
    static func matches(_ e: HistoryEntry, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return true }
        if e.text.lowercased().contains(q) { return true }
        if let app = e.app, app.lowercased().contains(q) { return true }
        return false
    }
}

/// Решение «записывать ли содержимое буфера в историю». Чистая функция от снимка буфера и
/// состояния системы; наблюдатель только собирает входные данные.
enum ClipboardCapturePolicy {
    /// Потолок длины одной записи. Скопированная книга в истории бесполезна и раздувает
    /// зашифрованный файл, который переписывается целиком на каждую запись.
    static let maxChars = 20_000

    /// Маркеры, при которых буфер не записываем. `org.nspasteboard.*` это общепринятое соглашение
    /// (nspasteboard.org): ConcealedType ставят менеджеры паролей на секреты, TransientType и
    /// AutoGeneratedType ставят утилиты на служебные записи (мы сами ставим TransientType на
    /// восстановление буфера). Остальные два — маркеры 1Password и Keyboard Maestro.
    static let concealedTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword",
        "de.petermaurer.TransientPasteboardType",
    ]

    struct Snapshot {
        let changeCount: Int
        let types: [String]
        /// nil, если текста в буфере нет ИЛИ его сознательно не читали (Secure Input).
        let text: String?
    }

    enum Reason: String {
        case ours          // наша собственная операция с буфером
        case secureInput   // где-то открыто поле пароля
        case concealed     // помечено как секрет или служебная запись
        case noText        // файл, картинка, что угодно без текста
        case empty         // одни пробелы
        case tooLong       // больше maxChars
        case duplicate     // тот же текст, что и последняя запись буфера
    }

    enum Verdict: Equatable {
        case store(String)
        case skip(Reason)
    }

    static func verdict(_ s: Snapshot,
                        ownChangeCounts: Set<Int>,
                        inOwnedWindow: Bool,
                        secureInput: Bool,
                        lastStored: String?) -> Verdict {
        if inOwnedWindow || ownChangeCounts.contains(s.changeCount) { return .skip(.ours) }
        if secureInput { return .skip(.secureInput) }
        if s.types.contains(where: { concealedTypes.contains($0) }) { return .skip(.concealed) }
        guard let text = s.text else { return .skip(.noText) }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .skip(.empty) }
        if text.count > maxChars { return .skip(.tooLong) }
        if text == lastStored { return .skip(.duplicate) }
        return .store(text)
    }
}

/// Реестр НАШИХ записей в буфер обмена.
///
/// У буфера нет понятия «кто записал»: `changeCount` растёт от любой записи, и наблюдатель истории
/// не отличил бы наше восстановление буфера после ⌘C от копирования человеком. Поэтому правило:
/// **каждая запись Keyboop в буфер регистрирует свой changeCount здесь** (`NSPasteboard.kbNoteOurs()`
/// в `ClipboardWatcher.swift`), а длинные операции из нескольких шагов (⌘C → чтение → восстановление)
/// заворачиваются в «окно владения», внутри которого наблюдатель не смотрит на буфер вовсе.
///
/// Окно нужно из-за гонки: пока `SelectionText` крутит runloop в ожидании ⌘C, таймер наблюдателя
/// успевает сработать и увидел бы выделение человека как «скопированный текст» раньше, чем мы
/// успели отметить его как своё.
enum PasteboardOwnership {
    private static let lock = NSLock()
    private static var counts: [Int] = []
    private static var windowDepth = 0
    private static let remembered = 32

    static func note(_ changeCount: Int) {
        lock.lock(); defer { lock.unlock() }
        counts.append(changeCount)
        if counts.count > remembered { counts.removeFirst(counts.count - remembered) }
    }

    static func isOurs(_ changeCount: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return counts.contains(changeCount)
    }

    static func ownCounts() -> Set<Int> {
        lock.lock(); defer { lock.unlock() }
        return Set(counts)
    }

    static func beginOwnedWindow() {
        lock.lock(); defer { lock.unlock() }
        windowDepth += 1
    }

    static func endOwnedWindow() {
        lock.lock(); defer { lock.unlock() }
        windowDepth = max(0, windowDepth - 1)
    }

    static var inOwnedWindow: Bool {
        lock.lock(); defer { lock.unlock() }
        return windowDepth > 0
    }

    /// Только для стенда: между проверками реестр должен быть пустым.
    static func resetForTests() {
        lock.lock(); defer { lock.unlock() }
        counts.removeAll(); windowDepth = 0
    }
}
