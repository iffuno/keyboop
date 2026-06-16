import Foundation
import CryptoKit

/// Небольшая история диктовок, зашифрованная AES-GCM (ключ — в локальном файле .histkey, 0600).
/// Никогда не покидает Mac (принцип №2). Можно выключить (voiceHistoryEnabled).
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
    func all() -> [Entry] { cache }
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

    /// Ключ AES-256 в защищённом файле (0600) рядом с данными.
    /// Почему НЕ Keychain: самоподписанное приложение (пока без Developer ID) → Keychain
    /// спрашивает пароль при КАЖДОМ доступе (cdhash меняется между сборками, «Always Allow»
    /// не держится). Это пугает пользователя. Файл с правами 0600 доступен только владельцу;
    /// шифрование защищает историю от случайного просмотра.
    /// TODO: при релизе с Developer ID вернуть Keychain (стабильная identity → без запросов).
    private static func key() -> SymmetricKey? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keyboop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keyURL = dir.appendingPathComponent(".histkey")
        if let data = try? Data(contentsOf: keyURL), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data(Array($0)) }
        try? keyData.write(to: keyURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        return key
    }
}
