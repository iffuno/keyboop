// КОГДА НАМ ДЕЙСТВИТЕЛЬНО НЕЛЬЗЯ ПИСАТЬ, А КОГДА МЫ ПРОСТО ПЕРЕСТРАХОВЫВАЛИСЬ.
//
// # Что было не так
//
// До 25.08.2026 ответ был один на всех: `IsSecureEventInputEnabled()` — и если флаг поднят, мы не
// писали НИГДЕ. Причина настоящая: 23.07.2026 диалог пароля украл фокус в конце диктовки, и текст
// ушёл бы в невидимое поле, а Backspace или Return могли подтвердить чужой запрос авторизации.
//
// Но флаг СЕССИОННЫЙ, а не пооконный. Его поднимает любая программа на любом своём поле пароля, и
// пока она его держит, мёртвыми становимся мы во всех остальных программах сразу. По отзывам за
// три дня держателями были Почта, Google Chrome, Safari, Telegram, Ghostty и терминал — то есть
// самые обычные программы, а не что-то экзотическое. У одного человека Safari был уже ЗАКРЫТ, а
// флаг не отпустило, и перезапуск Keyboop не помогал (#173). У другого это «несколько раз в день,
// программка просто умирает» (#189).
//
// # Что измерено, а не предположено
//
// `run-secureprobe.sh`, macOS 26.3.1, три прогона подряд с одинаковым результатом:
//
//   • Под флагом, поднятым ЧУЖИМ процессом, в ОБЫЧНОЕ поле доходят все три наших способа записи:
//     печать Unicode, вставка из буфера и запись через Accessibility. Флаг режет чтение, не письмо.
//   • Фокус в настоящем `NSSecureTextField` поднимает Secure Input САМ. То есть в нативных полях
//     флаг и есть признак «передо мной пароль» — отдельный детектор паролей не нужен.
//   • Accessibility честно отдаёт `subrole = AXSecureTextField` для такого поля.
//   • ⚠️ И в настоящее поле пароля наша запись ТОЖЕ доходит, включая ⌘V. Значит запрет не
//     формальность: кроме него, надиктованный текст ничто не остановит.
//
// # Правило, которое из этого следует
//
// Флага мало, держателя спрашивать нельзя (`kCGSSessionSecureInputPID` врёт: он застревает на
// первом, кто включил Secure Input за сессию, и в опыте называл посторонее приложение). Поэтому
// спрашиваем САМО ПОЛЕ:
//
//   1. AX говорит `AXSecureTextField` → молчим. Это точный ответ, а не догадка.
//   2. AX отвечает и поле обычное → пишем, даже если флаг поднят. Это и есть случай «чужой
//      программе приспичило, а человек печатает в Заметках».
//   3. AX не ответил (Electron, веб) → молчим, как раньше. Консервативно и честно: в браузере флаг
//      поднимает сам Chromium на фокусе в поле пароля, и залипший от настоящего мы там не отличим.
//
// Третий пункт — намеренная плата. Он оставляет мёртвой зоной ровно те программы, где AX слеп, и
// это осознанный размен в сторону «лучше промолчать, чем напечатать в чужой пароль».
import ApplicationServices
import Carbon
import Foundation

enum SecureInputPolicy {

    enum FieldVerdict {
        case secure       // под кареткой поле пароля — писать нельзя
        case ordinary     // обычное поле — писать можно
        case unknown      // AX не ответил — считаем опасным
    }

    /// Можно ли прямо сейчас постить синтетику. Зовётся из путей ЗАПИСИ (`TextReplacer`,
    /// `VoiceController`), не с горячего пути тапа.
    ///
    /// ⚠️ Быстрый выход, когда флага нет: подавляющее большинство вызовов приходится именно на
    /// него, и платить за них походом в Accessibility незачем.
    static func canWrite(_ what: @autoclosure () -> String) -> Bool {
        guard IsSecureEventInputEnabled() else { return true }
        switch focusedFieldVerdict() {
        case .ordinary:
            note("пишу под чужим Secure Input: поле обычное (\(what()))")
            return true
        case .secure:
            note("не пишу: под кареткой поле пароля (\(what()))")
            return false
        case .unknown:
            note("не пишу: Secure Input поднят, а поле не читается (\(what()))")
            return false
        }
    }

    /// Что под кареткой прямо сейчас.
    ///
    /// ⚠️ ЖЁСТКИЙ ТАЙМАУТ 50мс, как и во всех наших AX-чтениях. `AXUIElementCopy*` — синхронный
    /// IPC, который обслуживает main-цикл ЧУЖОГО приложения; занято оно спиннером — мы висим.
    /// Худший случай тут 2×50мс и честный `.unknown` (разбор — в шапке `AXScreenCheck`).
    static func focusedFieldVerdict() -> FieldVerdict {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.05)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedAny = focusedRef, CFGetTypeID(focusedAny) == AXUIElementGetTypeID() else { return .unknown }
        let el = unsafeDowncast(focusedAny as AnyObject, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(el, 0.05)

        var subroleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &subroleRef) == .success,
           let sub = subroleRef as? String {
            if sub == (kAXSecureTextFieldSubrole as String) { return .secure }
            return .ordinary
        }
        // Сабролей у элемента может не быть вовсе (обычный текстовый вид), и это НЕ повод молчать:
        // роль отвечает на тот же вопрос грубее, но достоверно — поле пароля без сабролей не бывает.
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef) == .success,
           roleRef as? String != nil {
            return .ordinary
        }
        return .unknown
    }

    // MARK: - Лог без спама

    /// Решение пишется в лог не чаще раза в две секунды на каждый ТИП решения: под залипшим флагом
    /// диктовка и конверсия зовут нас пачками, и построчный лог утопил бы всё остальное.
    private static var lastNote: [String: TimeInterval] = [:]
    private static let noteLock = NSLock()

    private static func note(_ message: String) {
        let key = String(message.prefix(24))
        let now = ProcessInfo.processInfo.systemUptime
        noteLock.lock()
        let recent = lastNote[key].map { now - $0 < 2.0 } ?? false
        if !recent { lastNote[key] = now }
        noteLock.unlock()
        if !recent { kbLog(message) }
    }
}
