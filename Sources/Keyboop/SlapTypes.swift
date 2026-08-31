import Foundation

/// Persisted sensitivity choices shared by settings, UI and the detector.
///
/// This type intentionally has no IOKit dependency so lightweight settings/test targets do not
/// have to compile the hardware implementation merely to restore a stored preference.
enum SlapSensitivity: String, CaseIterable {
    case balanced
    case high

    var l10nKey: String { "quick.sensitivity." + rawValue }

    /// Restores a stored setting without preserving removed modes in the runtime model. In
    /// particular, the legacy `low` value and unknown future values safely fall back to balanced.
    static func restored(from rawValue: String?) -> SlapSensitivity {
        SlapSensitivity(rawValue: rawValue ?? "") ?? .balanced
    }
}

/// Runtime state exposed to settings without exposing the IOKit-backed detector itself.
enum SlapDetectorAvailability: Equatable {
    case disabled
    case checking
    case unavailable
    case available
}
