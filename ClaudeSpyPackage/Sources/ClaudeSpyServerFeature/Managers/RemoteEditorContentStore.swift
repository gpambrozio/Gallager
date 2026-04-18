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
    }
#endif
