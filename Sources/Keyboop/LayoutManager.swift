import Foundation
import Carbon

/// Чтение и переключение системной раскладки через Text Input Source (TIS).
final class LayoutManager {

    /// Текущая раскладка — кириллическая?
    func currentIsCyrillic() -> Bool {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return false }
        return Self.languages(of: src).first?.hasPrefix("ru") ?? false
    }

    /// Короткий код текущей раскладки для индикатора ("RU"/"EN"/…).
    func currentCode() -> String {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return "??" }
        let lang = Self.languages(of: src).first ?? "en"
        return String(lang.prefix(2)).uppercased()
    }

    /// Переключить системную раскладку на кириллицу/латиницу (если такая включена).
    @discardableResult
    func selectLayout(cyrillic: Bool) -> Bool {
        let wanted = cyrillic ? "ru" : "en"
        guard let src = enabledKeyboardSources().first(where: {
            (Self.languages(of: $0).first ?? "").hasPrefix(wanted)
        }) else { return false }
        return TISSelectInputSource(src) == noErr
    }

    // MARK: - Внутреннее

    private func enabledKeyboardSources() -> [TISInputSource] {
        guard let cf = TISCreateInputSourceList(nil, false)?.takeRetainedValue() else { return [] }
        let count = CFArrayGetCount(cf)
        var result: [TISInputSource] = []
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(cf, i) else { continue }
            let src = Unmanaged<TISInputSource>.fromOpaque(raw).takeUnretainedValue()
            guard Self.stringProp(src, kTISPropertyInputSourceCategory) == (kTISCategoryKeyboardInputSource as String) else { continue }
            guard Self.boolProp(src, kTISPropertyInputSourceIsSelectCapable) else { continue }
            guard Self.boolProp(src, kTISPropertyInputSourceIsEnabled) else { continue }
            result.append(src)
        }
        return result
    }

    private static func languages(of src: TISInputSource) -> [String] {
        guard let raw = TISGetInputSourceProperty(src, kTISPropertyInputSourceLanguages) else { return [] }
        let arr = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as NSArray
        return arr.compactMap { $0 as? String }
    }

    private static func stringProp(_ src: TISInputSource, _ key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(src, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    private static func boolProp(_ src: TISInputSource, _ key: CFString) -> Bool {
        guard let raw = TISGetInputSourceProperty(src, key) else { return false }
        return Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue() == kCFBooleanTrue
    }
}
