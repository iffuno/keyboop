import AppKit
import CryptoKit
import CommonCrypto

/// Опциональный пароль на окно истории диктовок (идея пользователя из комментариев, 23.07.2026).
/// По умолчанию ВЫКЛЮЧЕН — включается тумблером в настройках голоса.
///
/// Честная модель угроз (см. подпись тумблера): это защита от любопытных глаз за твоим же Mac
/// (коллега/родня открыли историю), а НЕ от злоумышленника с доступом к диску — сама история и так
/// зашифрована AES-GCM (VoiceHistory). Диктовка при закрытой истории работает как обычно.
///
/// Хранение: PBKDF2-веритель в файле `.histgate` (0600) в Application Support. СОЗНАТЕЛЬНО не
/// Keychain: пароль вводит сам пользователь, секрет не хранится (только соль+хэш), а связка ключей
/// умеет внезапно спрашивать пароль логин-связки от нашего имени — этот класс диалогов мы только
/// что истребили (инцидент 23.07.2026).
enum HistoryGate {

    // Формат файла: [1B версия=1][16B соль][4B итерации BE][32B PBKDF2-SHA256]
    private static let fileVersion: UInt8 = 1
    private static let iterations: UInt32 = 210_000
    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keyboop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(".histgate")
    }

    static var enabled: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    // MARK: - Крипта

    private static func derive(_ password: String, salt: Data, iterations: UInt32) -> Data {
        var out = Data(repeating: 0, count: 32)
        let pw = Array(password.utf8)
        _ = out.withUnsafeMutableBytes { outB in
            salt.withUnsafeBytes { saltB in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     pw.map { Int8(bitPattern: $0) }, pw.count,
                                     saltB.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                                     outB.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        return out
    }

    @discardableResult
    static func setPassword(_ password: String) -> Bool {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        var blob = Data([fileVersion])
        blob.append(salt)
        var iterBE = iterations.bigEndian
        blob.append(Data(bytes: &iterBE, count: 4))
        blob.append(derive(password, salt: salt, iterations: iterations))
        do {
            try blob.write(to: fileURL, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            kbLog("hist gate: пароль установлен")
            return true
        } catch {
            kbLog("hist gate: не удалось сохранить веритель: \(error)")
            return false
        }
    }

    static func verify(_ password: String) -> Bool {
        guard let blob = try? Data(contentsOf: fileURL), blob.count == 1 + 16 + 4 + 32,
              blob[0] == fileVersion else { return false }
        let salt = blob.subdata(in: 1..<17)
        let iter = blob.subdata(in: 17..<21).withUnsafeBytes { UInt32(bigEndian: $0.load(as: UInt32.self)) }
        let want = blob.subdata(in: 21..<53)
        let got = derive(password, salt: salt, iterations: iter)
        // Сравнение за константное время — HMAC-обёртка вместо == (таймингу тут взяться неоткуда,
        // но привычка дешевле дискуссии).
        let key = SymmetricKey(size: .bits256)
        return HMAC<SHA256>.authenticationCode(for: want, using: key)
            == HMAC<SHA256>.authenticationCode(for: got, using: key)
    }

    static func removePassword() {
        try? FileManager.default.removeItem(at: fileURL)
        kbLog("hist gate: пароль снят")
    }

    // MARK: - Диалоги (все — наши NSAlert, никакой системщины)

    /// Спросить пароль перед открытием истории. `completion(true)` — пароль верный (или гейт выключен).
    /// «Забыл пароль…» — честный аварийный выход: стереть историю и снять пароль (восстановления нет).
    static func promptUnlock(completion: @escaping (Bool) -> Void) {
        guard enabled else { completion(true); return }
        askOnce(errorLine: nil, completion: completion)
    }

    private static func askOnce(errorLine: String?, completion: @escaping (Bool) -> Void) {
        let a = NSAlert()
        a.messageText = L10n.t("hist.lock.title")
        a.informativeText = errorLine ?? L10n.t("hist.lock.msg")
        a.addButton(withTitle: L10n.t("hist.lock.open"))
        a.addButton(withTitle: L10n.t("common.cancel"))
        a.addButton(withTitle: L10n.t("hist.lock.forgot"))
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        a.accessoryView = field
        a.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        let r = a.runModal()
        switch r {
        case .alertFirstButtonReturn:
            if verify(field.stringValue) {
                completion(true)
            } else {
                Thread.sleep(forTimeInterval: 0.4)   // ленивый анти-брутфорс
                askOnce(errorLine: L10n.t("hist.lock.wrong"), completion: completion)
            }
        case .alertThirdButtonReturn:
            let c = NSAlert()
            c.messageText = L10n.t("hist.lock.forgot.title")
            c.informativeText = L10n.t("hist.lock.forgot.confirm")
            c.alertStyle = .critical
            c.addButton(withTitle: L10n.t("hist.lock.forgot.wipe"))
            c.addButton(withTitle: L10n.t("common.cancel"))
            if c.runModal() == .alertFirstButtonReturn {
                VoiceHistory.shared.clear()
                removePassword()
                kbLog("hist gate: «забыл пароль» — история стёрта, пароль снят")
                completion(true)      // истории больше нет — открываем пустое окно без пароля
            } else {
                askOnce(errorLine: nil, completion: completion)
            }
        default:
            completion(false)
        }
    }

    /// Задать пароль (включение тумблера). `completion(true)` — пароль установлен.
    static func promptSetPassword(completion: @escaping (Bool) -> Void) {
        let a = NSAlert()
        a.messageText = L10n.t("hist.lock.set.title")
        a.informativeText = L10n.t("hist.lock.set.msg")
        a.addButton(withTitle: L10n.t("hist.lock.set.ok"))
        a.addButton(withTitle: L10n.t("common.cancel"))
        let p1 = NSSecureTextField(frame: NSRect(x: 0, y: 30, width: 240, height: 24))
        let p2 = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        p1.placeholderString = L10n.t("hist.lock.set.p1")
        p2.placeholderString = L10n.t("hist.lock.set.p2")
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 54))
        box.addSubview(p1); box.addSubview(p2)
        a.accessoryView = box
        a.window.initialFirstResponder = p1
        guard a.runModal() == .alertFirstButtonReturn else { completion(false); return }
        let pw = p1.stringValue
        if pw.count < 4 {
            errorAlert(L10n.t("hist.lock.set.short")); completion(false); return
        }
        if pw != p2.stringValue {
            errorAlert(L10n.t("hist.lock.set.mismatch")); completion(false); return
        }
        completion(setPassword(pw))
    }

    /// Снять пароль (выключение тумблера) — сначала подтверждаем текущим паролем.
    static func promptDisable(completion: @escaping (Bool) -> Void) {
        promptUnlock { ok in
            if ok { removePassword() }
            completion(ok)
        }
    }

    private static func errorAlert(_ text: String) {
        let a = NSAlert()
        a.messageText = text
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}
