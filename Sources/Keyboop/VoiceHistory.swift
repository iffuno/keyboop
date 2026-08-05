import Foundation
import CryptoKit
import Security

/// Небольшая история диктовок, зашифрованная AES-GCM (ключ — в Keychain). Никогда не покидает Mac
/// (принцип №2). Можно выключить (voiceHistoryEnabled).
final class VoiceHistory {
    static let shared = VoiceHistory()
    private let settings = AppSettings.shared
    private let maxEntries = 50
    private let fileURL: URL
    private var cache: [Entry] = []

    struct Entry: Codable { let date: Date; let text: String }

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keyboop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.enc")
        cache = load()
        if prune() { save() }   // на старте подчистить записи старше срока хранения
    }

    func add(_ text: String) {
        guard settings.voiceHistoryEnabled else { return }
        cache.append(Entry(date: Date(), text: text))
        _ = prune()
        if cache.count > maxEntries { cache.removeFirst(cache.count - maxEntries) }
        save()
        notifyChanged()
    }

    /// Удалить записи старше voiceHistoryMinutes (0 = хранить всё). true — если что-то удалили.
    @discardableResult
    func prune() -> Bool {
        let mins = settings.voiceHistoryMinutes
        guard mins > 0 else { return false }
        let cutoff = Date().addingTimeInterval(-Double(mins) * 60)
        let before = cache.count
        cache.removeAll { $0.date < cutoff }
        return cache.count != before
    }

    /// Применить новый срок хранения (зовётся из настроек) — подчистить + обновить окно.
    func applyRetention() {
        if prune() { save(); notifyChanged() }
    }
    /// Все записи, УЖЕ подчищенные по сроку хранения.
    ///
    /// ⚠️ ЧИСТИМ ПРЯМО ЗДЕСЬ (аудит умолчаний, 05.08.2026). Раньше `prune()` звался только на старте,
    /// при добавлении записи и при смене срока в настройках. То есть человек, продиктовавший один раз
    /// и больше не диктовавший, открывал окно истории через два часа и видел запись, срок которой
    /// вышел час назад: она лежала и в памяти, и в файле. Обходной путь для меню уже был
    /// (`lastVisible()` ниже), а окно и файл оставались честными только случайно.
    ///
    /// Это не про удобство, а про принцип №2: срок хранения это обещание, а не оформление.
    func all() -> [Entry] {
        if prune() { save() }
        return cache
    }

    /// Последняя диктовка, которую ПРЯМО СЕЙЧАС законно показать: история включена и запись ещё не
    /// просрочена по сроку хранения. Ничего не меняет и не пишет на диск — зовётся из сборки меню.
    ///
    /// Отдельно от `all().last`, потому что `cache` вычищается только в `prune()` (на добавлении и при
    /// смене срока в настройках), а между этими моментами в нём спокойно лежит запись, срок которой
    /// уже вышел. Пункт «Скопировать последнюю диктовку» опирается именно на этот метод, иначе он
    /// предлагал бы скопировать то, что человек велел удалить полчаса назад.
    func lastVisible() -> Entry? {
        guard settings.voiceHistoryEnabled, let e = cache.last else { return nil }
        let mins = settings.voiceHistoryMinutes
        guard mins > 0 else { return e }                       // 0 = хранить всё
        return e.date >= Date().addingTimeInterval(-Double(mins) * 60) ? e : nil
    }
    func remove(date: Date, text: String) {
        cache.removeAll { $0.date == date && $0.text == text }
        save()
        notifyChanged()
    }
    func clear() {
        cache.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
        notifyChanged()
    }

    /// Открытое окно истории слушает это и перестраивается мгновенно (не ждёт поллинга).
    private func notifyChanged() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: .keyboopVoiceHistoryChanged, object: nil) }
    }

    // MARK: - Шифрование

    private func save() {
        guard let key = Self.key() else { return }
        do {
            let data = try JSONEncoder().encode(cache)
            let sealed = try AES.GCM.seal(data, using: key)
            if let combined = sealed.combined {
                try combined.write(to: fileURL, options: [.atomic])
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            }
        } catch { kbLog("voice history save error: \(error)") }
    }
    private func load() -> [Entry] {
        guard let key = Self.key(),
              let blob = try? Data(contentsOf: fileURL),
              let box = try? AES.GCM.SealedBox(combined: blob),
              let data = try? AES.GCM.open(box, using: key),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return entries
    }

    // Ключ AES-256 живёт в Keychain (kSecAttrAccessibleWhenUnlockedThisDeviceOnly). Раньше лежал в
    // файле .histkey РЯДОМ с шифртекстом — при self-signed сборке Keychain переспрашивал пароль
    // (нестабильный cdhash), поэтому был выбран файл. Теперь приложение подписано Developer ID →
    // identity стабильна, ключ переехал в Keychain: локальный атакующий (тот же uid) больше НЕ читает
    // ключ вместе с шифртекстом (security-аудит M1, 01.07). Ключ per-bundle (service = bundle id).
    //
    // ⚠️ Два железных правила ПОСЛЕ инцидента 23.07.2026 (диалог «введи пароль связки» в конце
    // диктовки; он же включает secure input → guard в TextReplacer съедает распознанный текст):
    //  1. DEV-сборки (self-signed, подпись меняется каждой пересборкой) в связку НЕ ходят вообще —
    //     ключ в файле 0600. Иначе ACL перестаёт узнавать бинарь после КАЖДОЙ сборки.
    //  2. Любое чтение связки — БЕЗ ПРАВА НА ДИАЛОГ. Не узнала подпись (переезд на новый Mac,
    //     смена сертификата) — молча перевыпускаем ключ: история — журнал удобства на 50 записей,
    //     свежая пустая лучше пароля посреди диктовки («пользователь подумает, что вирус»).
    private static let keychainService = (Bundle.main.bundleIdentifier ?? "ru.keyboop.app") + ".voicehistory"
    private static let keychainAccount = "history-aes-key"
    private static var cachedKey: SymmetricKey?
    private static let devBuild = (Bundle.main.bundleIdentifier ?? "").hasSuffix(".dev")

    private static func key() -> SymmetricKey? {
        if let k = cachedKey { return k }
        let k = resolveKey(); cachedKey = k; return k
    }

    /// Достаём ключ. Prod: Keychain → миграция старого файлового ключа → генерация нового (фолбэк
    /// на файл, только если Keychain недоступен). Dev: файл → одноразовый переезд ИЗ связки → генерация.
    private static func resolveKey() -> SymmetricKey? {
        let keyURL = supportDir().appendingPathComponent(".histkey")

        if devBuild {
            if let data = try? Data(contentsOf: keyURL), data.count == 32 { return SymmetricKey(data: data) }
            if let data = keychainRead(), data.count == 32 {              // одноразовый переезд связка → файл
                writeKeyFile(data, to: keyURL)
                SecItemDelete(keychainBase as CFDictionary)
                kbLog("voice history key: dev — ключ перенесён из Keychain в файл (пересборки меняют подпись)")
                return SymmetricKey(data: data)
            }
            let key = SymmetricKey(size: .bits256)
            writeKeyFile(key.withUnsafeBytes { Data(Array($0)) }, to: keyURL)
            kbLog("voice history key: dev — новый файловый ключ")
            return key
        }

        if let data = keychainRead(), data.count == 32 { return SymmetricKey(data: data) }

        if let data = try? Data(contentsOf: keyURL), data.count == 32 {   // миграция файл → Keychain
            if keychainWrite(data) {
                try? FileManager.default.removeItem(at: keyURL)
                kbLog("voice history key: перенесён .histkey → Keychain")
            }
            return SymmetricKey(data: data)
        }

        let key = SymmetricKey(size: .bits256)                            // новый ключ
        let data = key.withUnsafeBytes { Data(Array($0)) }
        if !keychainWrite(data) {                                         // Keychain недоступен → файловый фолбэк 0600
            writeKeyFile(data, to: keyURL)
            kbLog("voice history key: Keychain недоступен → файловый фолбэк")
        }
        return key
    }

    private static func writeKeyFile(_ data: Data, to url: URL) {
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Форсировать миграцию файлового ключа в Keychain при запуске (после обновления) — БЕЗ загрузки
    /// записей. No-op, если старого `.histkey` нет (мигрировать нечего) или ключ уже в Keychain.
    static func migrateKeyIfNeeded() {
        guard FileManager.default.fileExists(atPath: supportDir().appendingPathComponent(".histkey").path) else { return }
        _ = key()   // резолвит: перенесёт .histkey → Keychain и удалит файл
    }

    private static func supportDir() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keyboop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var keychainBase: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: keychainAccount]
    }

    /// Чтение строго БЕЗ диалога: SecKeychainSetUserInteractionAllowed(false) на время запроса.
    /// errSecInteractionNotAllowed = связка узнала item, но не узнала НАС → это тот самый диалог;
    /// возвращаем nil, выше по стеку ключ молча перевыпустится (см. правило №2 в комменте у service).
    private static func keychainRead() -> Data? {
        var wasAllowed: DarwinBoolean = true
        SecKeychainGetUserInteractionAllowed(&wasAllowed)
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(wasAllowed.boolValue) }
        var q = keychainBase
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecInteractionNotAllowed {
            kbLog("voice history key: связка требует диалог (identity сменилась) — перевыпускаю ключ молча")
            return nil
        }
        guard st == errSecSuccess, let d = out as? Data else { return nil }
        return d
    }

    @discardableResult
    private static func keychainWrite(_ data: Data) -> Bool {
        SecItemDelete(keychainBase as CFDictionary)
        var add = keychainBase
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
