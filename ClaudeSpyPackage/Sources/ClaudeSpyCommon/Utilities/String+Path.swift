import Foundation

public extension String {
    /// Replaces the home directory prefix with ~ for display purposes.
    /// On iOS, returns the path unchanged since home directory abbreviation
    /// isn't applicable.
    var abbreviatedPath: String {
        #if os(macOS)
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            if hasPrefix(home) {
                return "~" + dropFirst(home.count)
            }
            return self
        #else
            return self
        #endif
    }
}
