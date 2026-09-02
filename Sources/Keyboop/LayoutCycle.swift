import Foundation

/// Pure layout-cycle logic. Full TIS IDs are intentionally kept opaque: two input sources with
/// the same language or script must remain separate steps in the cycle.
enum LayoutCycle {
    /// Choose which exact ID is authoritative before advancing. A fresh Keyboop selection wins
    /// over lagging preferences during a rapid burst; after that short window the live HIToolbox
    /// value wins, so a missed external notification cannot leave stale memory authoritative.
    static func anchorID(remembered: String?,
                         live: String?,
                         rememberedIsFresh: Bool,
                         in ids: [String]) -> String? {
        let available = Set(ids)
        if rememberedIsFresh, let remembered, available.contains(remembered) { return remembered }
        if let live, available.contains(live) { return live }
        if let remembered, available.contains(remembered) { return remembered }
        return nil
    }

    static func nextID(afterCurrent current: String?, in ids: [String]) -> String? {
        var unique: [String] = []
        var seen = Set<String>()
        for id in ids where seen.insert(id).inserted {
            unique.append(id)
        }

        guard let first = unique.first else { return nil }
        guard let current, let index = unique.firstIndex(of: current) else { return first }
        let next = unique.index(after: index)
        return next == unique.endIndex ? first : unique[next]
    }
}
