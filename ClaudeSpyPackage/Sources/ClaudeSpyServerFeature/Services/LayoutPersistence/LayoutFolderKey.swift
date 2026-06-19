#if os(macOS)
    import Foundation

    /// Canonicalizes a working-directory / project path into the stable key used
    /// to associate a saved layout with a folder. Resolves `~`, symlinks, and
    /// relative segments and strips a trailing slash so `/Users/me/proj`,
    /// `~/proj`, and `/Users/me/proj/` all collide. See
    /// `docs/folder-layout-persistence-plan.md` §4.6.
    enum LayoutFolderKey {
        static func canonicalize(_ path: String?) -> String? {
            guard let path, !path.isEmpty else { return nil }
            let expanded = (path as NSString).expandingTildeInPath
            let resolved = URL(fileURLWithPath: expanded)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            var result = resolved.path
            while result.count > 1, result.hasSuffix("/") {
                result.removeLast()
            }
            return result.isEmpty ? nil : result
        }
    }
#endif
