#if os(macOS)
    import AppKit
    import ClaudeSpyNetworking
    import Foundation
    import Logging

    /// An active editor session, tracking the file being edited and how to signal completion.
    public struct EditorSession: Identifiable, Sendable {
        public let id: UUID
        /// The tmux pane ID this editor session belongs to
        public let paneId: String
        /// Path to the temp file on the host (only meaningful on the host)
        public let filePath: String
        /// The content of the file when the editor was opened
        public let originalContent: String
    }

    /// Manages active prompt editor sessions across all panes.
    ///
    /// When the Gallager CLI sends an `editor.open` request via the API socket,
    /// this manager:
    /// 1. Reads the file content
    /// 2. Creates an EditorSession
    /// 3. Notifies the UI to show the editor overlay
    /// 4. Blocks the API response until the user submits or cancels
    ///
    /// When the user submits or cancels, it:
    /// 1. Optionally writes the edited content back to the file
    /// 2. Resumes the continuation (unblocking the API response to the CLI)
    /// 3. Removes the session from active sessions
    @Observable
    @MainActor
    final public class EditorSessionManager {
        /// Active editor sessions keyed by pane ID.
        /// Only one editor session per pane is supported.
        public private(set) var activeSessions: [String: EditorSession] = [:]

        /// Per-session continuations that block the API response until editing completes.
        private var completionContinuations: [UUID: CheckedContinuation<Void, Never>] = [:]

        private let logger = Logger(label: "com.claudespy.editorsessionmanager")

        /// Called when an editor session opens or closes, to push state to viewers.
        public var onSessionChanged: (@MainActor @Sendable () async -> Void)?

        public init() { }

        /// Resumes all pending continuations on shutdown to avoid leaked continuation warnings.
        public func cancelAll() {
            for (paneId, _) in activeSessions {
                logger.info("Cleaning up editor session for pane \(paneId) on shutdown")
            }
            for (_, continuation) in completionContinuations {
                continuation.resume()
            }
            completionContinuations.removeAll()
            activeSessions.removeAll()
        }

        // MARK: - Public API

        /// Handles an editor.open API request. Blocks until the user submits or cancels.
        ///
        /// Called by the API request router. The router's response is held until
        /// this method returns, which happens when `submitSession` or `cancelSession`
        /// resumes the stored continuation.
        public func handleAPIEditRequest(paneId: String, filePath: String) async {
            let sessionId = UUID()

            // Read file content off the main actor
            let content: String
            do {
                content = try await Task.detached {
                    try String(contentsOfFile: filePath, encoding: .utf8)
                }.value
            } catch {
                logger.error("Failed to read editor file: \(error)")
                return
            }

            // If there's already a session for this pane, complete the old one first
            if let existing = activeSessions[paneId] {
                logger.warning("Replacing existing editor session for pane \(paneId)")
                completionContinuations.removeValue(forKey: existing.id)?.resume()
            }

            let session = EditorSession(
                id: sessionId,
                paneId: paneId,
                filePath: filePath,
                originalContent: content
            )
            activeSessions[paneId] = session

            logger.info("Opened editor session for pane \(paneId)")

            // Bring app to front
            NSApplication.shared.activate(ignoringOtherApps: true)

            // Notify viewers
            await onSessionChanged?()

            // Block until submit/cancel resumes the continuation
            await withCheckedContinuation { continuation in
                completionContinuations[sessionId] = continuation
            }
        }

        /// Submits edited content, writes it to the file, and unblocks the API response.
        public func submitSession(paneId: String, content: String) {
            guard let session = activeSessions.removeValue(forKey: paneId) else {
                logger.warning("No active editor session for pane \(paneId)")
                return
            }

            // Write the edited content back to the temp file
            do {
                try content.write(toFile: session.filePath, atomically: true, encoding: .utf8)
            } catch {
                logger.error("Failed to write edited content: \(error)")
            }

            // Resume the continuation, which unblocks the API response
            completionContinuations.removeValue(forKey: session.id)?.resume()
            logger.info("Submitted editor session for pane \(paneId)")

            // Notify viewers
            Task { await onSessionChanged?() }
        }

        /// Cancels an editor session without saving changes.
        /// The original content remains in the file, so Claude Code sees no change.
        public func cancelSession(paneId: String) {
            guard let session = activeSessions.removeValue(forKey: paneId) else {
                logger.warning("No active editor session for pane \(paneId)")
                return
            }

            // Resume the continuation, which unblocks the API response
            completionContinuations.removeValue(forKey: session.id)?.resume()
            logger.info("Cancelled editor session for pane \(paneId)")

            // Notify viewers
            Task { await onSessionChanged?() }
        }

        /// Handles a remote viewer submitting editor content for a pane.
        public func handleRemoteSubmit(paneId: String, content: String) {
            // Same as local submit — first one wins
            submitSession(paneId: paneId, content: content)
        }

        /// Handles a remote viewer cancelling an editor session.
        public func handleRemoteCancel(paneId: String) {
            cancelSession(paneId: paneId)
        }

        /// Returns the active editor session for a pane, if any.
        public func session(for paneId: String) -> EditorSession? {
            activeSessions[paneId]
        }

        /// Returns info about active editor sessions for inclusion in PaneState sync.
        public func editorSessionInfo(for paneId: String) -> EditorSessionInfo? {
            guard let session = activeSessions[paneId] else { return nil }
            return EditorSessionInfo(
                sessionId: session.id,
                content: session.originalContent
            )
        }
    }
#endif
