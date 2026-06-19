#if os(macOS)
    import Foundation

    /// One persisted workbench record, keyed by a durable session identity
    /// (host + tmux session name). The tmux session name outlives the app, so on
    /// a cold launch a running session maps straight back to its record.
    ///
    /// `folder` is recorded so a recycled session name (kill `myproj`, later
    /// create a new `myproj` on a different project) can be detected: if the
    /// stored folder no longer matches the live session's folder, the record is
    /// ignored in favor of the folder default. See
    /// `docs/folder-layout-persistence-plan.md` §4.3.
    struct SavedSessionLayout: Codable, Sendable, Equatable {
        /// Local host identifier. v1 only persists local sessions.
        var host: String
        /// tmux session name — the durable identity across app restarts.
        var sessionName: String
        /// Canonical project path this layout was captured for.
        var folder: String
        /// Last time the live session wrote this record. Drives the
        /// "most recent on this folder" default query and pruning.
        var lastActive: Date
        var layout: SavedFolderLayout

        /// Stable storage key for this record.
        var key: Key { Key(host: host, sessionName: sessionName) }

        struct Key: Hashable, Sendable {
            var host: String
            var sessionName: String
        }
    }
#endif
