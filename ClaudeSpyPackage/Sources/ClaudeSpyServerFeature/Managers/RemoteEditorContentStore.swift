#if os(macOS)
    import Foundation

    /// Persists in-progress edits for remote viewer editor overlays.
    ///
    /// Keyed by editor session UUID so a new Ctrl-G session on the same pane
    /// naturally starts fresh (different UUID → no stored entry → falls back
    /// to the original file content from the host).
    @Observable
    @MainActor
    final public class RemoteEditorContentStore {
        public var editedContents: [UUID: String] = [:]

        public init() { }

        public func clear(sessionId: UUID) {
            editedContents.removeValue(forKey: sessionId)
        }

        /// Drops any stored edits whose `sessionId` is no longer in `activeSessionIds`.
        /// Call after each session-state update from the remote host so that entries
        /// for sessions ended by the host (not the local viewer) don't linger.
        public func retainOnly(activeSessionIds: Set<UUID>) {
            editedContents = editedContents.filter { activeSessionIds.contains($0.key) }
        }
    }
#endif
