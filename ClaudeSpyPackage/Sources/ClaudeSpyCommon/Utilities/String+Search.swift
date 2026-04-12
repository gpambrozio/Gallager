import Foundation

public extension String {
    /// Returns `true` if every character in `query` appears in this string
    /// in order (case-insensitive). For example, "clasp" matches "ClaudeSpy"
    /// because C-l-a-S-p appear in that order.
    ///
    /// Also matches plain substring containment, so "claude" still matches "ClaudeSpy".
    func fuzzyMatches(_ query: String) -> Bool {
        let source = lowercased()
        let search = query.lowercased()

        var sourceIndex = source.startIndex
        for char in search {
            guard let found = source[sourceIndex...].firstIndex(of: char) else {
                return false
            }
            sourceIndex = source.index(after: found)
        }
        return true
    }

    /// Ranks how well this string matches `query` for file-name search results.
    ///
    /// Higher scores indicate stronger matches:
    /// - `4`: exact case-insensitive match
    /// - `3`: case-insensitive prefix match
    /// - `2`: case-insensitive substring match
    /// - `1`: fuzzy match (see `fuzzyMatches(_:)`)
    /// - `0`: no match
    func fileSearchScore(for query: String) -> Int {
        let name = lowercased()
        let q = query.lowercased()
        if name == q { return 4 }
        if name.hasPrefix(q) { return 3 }
        if name.contains(q) { return 2 }
        if name.fuzzyMatches(q) { return 1 }
        return 0
    }
}
