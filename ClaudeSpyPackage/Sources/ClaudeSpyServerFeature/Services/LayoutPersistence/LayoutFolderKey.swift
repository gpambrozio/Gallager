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
            return stripTrailingSlash(resolved.path)
        }

        /// String-only normalization for a **remote** folder path (issue #608).
        ///
        /// Unlike `canonicalize`, this must NOT expand `~` or resolve symlinks:
        /// a remote path like `/home/user/project` lives on a *different*
        /// machine, so resolving it against the *viewer's* local disk would
        /// rewrite it to something meaningless (or to a path that happens to
        /// exist locally). It only strips a trailing slash so `/a/b` and
        /// `/a/b/` collide on the same record.
        static func canonicalizeRemote(_ path: String?) -> String? {
            guard let path, !path.isEmpty else { return nil }
            return stripTrailingSlash(path)
        }

        /// Drop a trailing slash, keeping root (`/`) intact. Both callers guard a
        /// non-empty input and the loop stops at `count > 1`, so the result is
        /// never empty — hence a non-optional return (coerces to the callers'
        /// `String?`).
        private static func stripTrailingSlash(_ path: String) -> String {
            var result = path
            while result.count > 1, result.hasSuffix("/") {
                result.removeLast()
            }
            return result
        }
    }
#endif
