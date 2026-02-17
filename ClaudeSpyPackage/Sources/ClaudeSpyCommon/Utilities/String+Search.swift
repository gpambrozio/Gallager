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
}
