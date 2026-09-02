import Foundation

/// Origin of a keyboard event, classified purely from event source metadata.
enum InputEventOrigin: Equatable {
    case real
    case synthetic
    case pauseMarker

    /// Pause wins whenever the source matches its marker, then synthetic, otherwise real.
    static func classify(sourceUserData: Int64, syntheticMarker: Int64, pauseMarker: Int64) -> InputEventOrigin {
        if sourceUserData == pauseMarker { return .pauseMarker }
        if sourceUserData == syntheticMarker { return .synthetic }
        return .real
    }

    var label: String {
        switch self {
        case .real:
            return "реальный ввод"
        case .synthetic:
            return "наша синтетика"
        case .pauseMarker:
            return "маркер паузы"
        }
    }
}

/// Durations of the tail phases that follow a key event conversion.
struct ConversionTailSpans: Equatable {
    var modelMs: Double
    var statsMs: Double
    var layoutMs: Double
    var callbackMs: Double
    var soundMs: Double
    var totalMs: Double

    /// Slow means the whole tail exceeds 10 ms or any single phase exceeds 5 ms.
    var isSlow: Bool {
        totalMs > 10.0
            || modelMs > 5.0
            || statsMs > 5.0
            || layoutMs > 5.0
            || callbackMs > 5.0
            || soundMs > 5.0
    }

    /// Stable content-free diagnostics line with an explicit POSIX locale.
    func logLine(manual: Bool) -> String {
        let path = manual ? "хоткей" : "авто"
        let arguments: [CVarArg] = [
            path,
            modelMs,
            statsMs,
            layoutMs,
            callbackMs,
            soundMs,
            totalMs,
        ]
        return String(
            format: "хвост конверсии медленный: путь=%@; модель=%.1f мс; статистика=%.1f мс; раскладка=%.1f мс; колбэк=%.1f мс; звук=%.1f мс; итого=%.1f мс",
            locale: Locale(identifier: "en_US_POSIX"),
            arguments: arguments
        )
    }
}
