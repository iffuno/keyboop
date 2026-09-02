import Foundation

/// KEYBOOP-190-TAIL: repairs the race where macOS already produced ". " from two
/// typed ASCII spaces and Keyboop later retypes the buffered same-length tail.
/// Pure and stateless: no clocks, preferences, logging, or Unicode normalization.
enum DoubleSpacePeriodRule {
    /// Rewrites the leading two-space pair of `tail` to `". "` only when every
    /// guard holds, returning `tail` unchanged otherwise:
    /// 1. `systemEnabled` is true.
    /// 2. `tail` starts with the two-space ASCII pair.
    /// 3. `convertedWord` ends with a Unicode letter or number.
    /// 4. `doubleSpaceGap` is non-nil, finite, non-negative, and `<= maximumGap`.
    /// 5. `maximumGap` is finite and non-negative.
    /// Only the leading pair is replaced, so output length always equals input length.
    static func rewrittenTail(
        _ tail: String,
        after convertedWord: String,
        systemEnabled: Bool,
        doubleSpaceGap: TimeInterval?,
        maximumGap: TimeInterval
    ) -> String {
        guard systemEnabled else { return tail }
        guard tail.hasPrefix("  ") else { return tail }
        guard let ending = convertedWord.last, ending.isLetter || ending.isNumber else { return tail }
        guard maximumGap.isFinite, maximumGap >= 0 else { return tail }
        guard let gap = doubleSpaceGap, gap.isFinite, gap >= 0, gap <= maximumGap else { return tail }
        return ". " + String(tail.dropFirst(2))
    }
}
