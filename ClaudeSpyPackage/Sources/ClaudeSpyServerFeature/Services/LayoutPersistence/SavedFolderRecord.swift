#if os(macOS)
    import Foundation

    /// One persisted workbench record, keyed by **folder** (host + canonical
    /// project path). Layout state is tied to the folder, not to a tmux session
    /// name: any session on a folder restores that folder's layout, and the most
    /// recent live session to change it defines what the next-born session (or the
    /// next app launch) restores. See `docs/folder-layout-persistence-plan.md`.
    ///
    /// Keying by folder (rather than by `host + sessionName`) is deliberate: tmux
    /// session names are recycled (kill `ClaudeSpy-2`, later create a new one on
    /// the same repo), so a name is not a durable identity. A folder is.
    struct SavedFolderRecord: Codable, Sendable, Equatable {
        /// Host id used for locally-managed sessions. Remote/viewer records key on
        /// the host's `pairId` (UUID-shaped), which never equals this (issue #608).
        static let localHost = "local"

        /// Host identifier — `localHost` for local sessions, the host `pairId` for
        /// remote/viewer ones.
        var host: String
        /// Canonical project path this layout belongs to — the identity.
        var folder: String
        /// Last time a live session wrote this record. Drives "most recent write
        /// wins" (when two sessions share a folder) and prune-by-age.
        var lastActive: Date
        var layout: SavedFolderLayout

        /// Stable storage key for this record.
        var key: Key { Key(host: host, folder: folder) }

        struct Key: Hashable, Sendable {
            var host: String
            var folder: String
        }
    }
#endif
