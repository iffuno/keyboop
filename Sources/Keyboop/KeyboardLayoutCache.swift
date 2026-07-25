import Carbon
import CoreGraphics
import Foundation
import QuartzCore   // CACurrentMediaTime — то же mach-время, что в EventTap

/// Символы нажатой клавиши БЕЗ AppKit — замена `NSEvent(cgEvent:)?.characters` в колбэке CGEventTap.
///
/// Зачем (ревью 21.07): `NSEvent(cgEvent:).characters` стоит ~74 мкс и лезет в AppKit с аллокациями,
/// прямо в обработчике события. `kCGEventTapDisabledByTimeout` меряется по round-trip
/// «WindowServer → mach-порт → ответ», а деградирует такой вызов ровно под тем давлением на память,
/// при котором нас и глушила система (инцидент 21.07: 12 отключений за 5 минут, ввод не проходил
/// нигде). Плюс AppKit из не-главного потока небезопасен — а перенос тапа на свой поток у нас
/// следующим шагом, так что уходим от него заранее.
///
/// Стратегия: primary — `CGEvent.keyboardGetUnicodeString` (0.1 мкс, без AppKit); fallback —
/// `UCKeyTranslate` по закэшированному layout-блобу. Fallback обязателен: на «холодном» потоке
/// CG-вариант может молча вернуть пустую строку, а пустая строка = `buffer.append("")` = авто-фикс
/// тихо мёртв, без единой строки в логе.
///
/// TIS/TSM — main-thread-only («Please call TIS/TSM in main thread!!!»), поэтому блоб снимаем
/// на main (`refreshOnMain`) и держим снимок под локом; читать его можно откуда угодно.
enum KeyboardLayoutCache {
    private static var lock = os_unfair_lock_s()
    private static var blob: Data?
    private static var kbdType: UInt32 = 0
    /// ТОЛЬКО с главного потока. Звать при старте и на ВНЕШНЮЮ смену раскладки (TIS-уведомление).
    /// ⚠️ НЕ звать сразу после НАШЕГО TISSelect: чтение «текущего» источника в этот момент
    /// возвращает СТАРЫЙ (стейл-баг kawa PR#21) — кэш заряжался старьём, и сверка алфавитов
    /// «чинила» правильные буквы в неправильные (50 ложных подмен за 9с, лог автора 24.07).
    /// Для наших переключений есть refresh(fromSelected:) — источник известен без чтения.
    /// true = блоб реально сменился (декод предыдущих клавиш шёл другой раскладкой).
    @discardableResult
    static func refreshOnMain() -> Bool {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return false }
        return refresh(fromSelected: src)
    }

    /// Загрузить кэш из ЗАРАНЕЕ ИЗВЕСТНОГО источника (наш selectLayout держит объект в руках) —
    /// ноль чтений «текущего», значит ноль шансов на стейл.
    @discardableResult
    static func refresh(fromSelected src: TISInputSource) -> Bool {
        guard let p = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return false }
        let cf = Unmanaged<CFData>.fromOpaque(p).takeUnretainedValue()
        // ГЛУБОКАЯ копия байтов (ревью research 24.07): Get-семантика — CFData живёт, пока жив
        // источник; бридж `as Data` может лишь удержать CFData, не байты. Блоб маленький (килобайты),
        // копия раз на переключение — дёшево, а use-after-free из tap-потока — бесценно.
        let d = Data(bytes: CFDataGetBytePtr(cf), count: CFDataGetLength(cf))
        let t = UInt32(LMGetKbdType())
        os_unfair_lock_lock(&lock)
        let changed = (blob != d)
        blob = d; kbdType = t
        os_unfair_lock_unlock(&lock)
        return changed
    }

    private static func snapshot() -> (Data, UInt32)? {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        guard let b = blob else { return nil }
        return (b, kbdType)   // Data — value type, безопасно уносить из-под лока
    }

    /// Безопасно с любого потока. `deadState` живёт у вызывающего (мёртвые клавиши: ⌥e затем e → é).
    /// options = 0, а НЕ kUCKeyTranslateNoDeadKeysBit: поведение должно совпадать с прежним
    /// `NSEvent.characters` (в DynamicKeymap флаг остаётся — там он уместен).
    static func characters(keyCode: Int64, flags: CGEventFlags, deadState: inout UInt32) -> String {
        guard let (data, kbd) = snapshot() else { return "" }
        var mods: UInt32 = 0
        if flags.contains(.maskShift)      { mods |= UInt32((shiftKey   >> 8) & 0xFF) }
        if flags.contains(.maskAlternate)  { mods |= UInt32((optionKey  >> 8) & 0xFF) }
        if flags.contains(.maskControl)    { mods |= UInt32((controlKey >> 8) & 0xFF) }
        if flags.contains(.maskAlphaShift) { mods |= UInt32((alphaLock  >> 8) & 0xFF) }
        var ds = deadState
        let out = data.withUnsafeBytes { rb -> String in
            guard let layout = rb.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return "" }
            var len = 0
            var buf = [UniChar](repeating: 0, count: 8)
            UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDown), mods,
                           kbd, 0, &ds, buf.count, &len, &buf)
            return String(utf16CodeUnits: buf, count: len)
        }
        deadState = ds
        return out
    }
}
