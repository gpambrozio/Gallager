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
    /// When the GallagerEditor CLI connects via the socket server, this manager:
    /// 1. Reads the file content
    /// 2. Creates an EditorSession
    /// 3. Notifies the UI to show the editor overlay
    ///
    /// When the user submits or cancels, it:
    /// 1. Optionally writes the edited content back to the file
    /// 2. Signals the socket server to release the CLI
    /// 3. Removes the session from active sessions
    @Observable
    @MainActor
    final public class EditorSessionManager {
        /// Active editor sessions keyed by pane ID.
        /// Only one editor session per pane is supported.
        public private(set) var activeSessions: [String: EditorSession] = [:]

        private let socketServer: EditorSocketServer
        private let logger = Logger(label: "com.claudespy.editorsessionmanager")

        /// Called when an editor session opens or closes, to push state to viewers.
        public var onSessionChanged: (@MainActor @Sendable () async -> Void)?

        init(socketServer: EditorSocketServer) {
            self.socketServer = socketServer
        }

        // MARK: - Public API

        /// Handles an incoming edit request from the socket server.
        public func handleEditRequest(_ request: EditorRequest) {
            Task {
                // Read file content off the main actor
                let content: String
                do {
                    content = try await Task.detached {
                        try String(contentsOfFile: request.filePath, encoding: .utf8)
                    }.value
                } catch {
                    logger.error("Failed to read editor file: \(error)")
                    // Signal the CLI to exit immediately so Claude Code doesn't hang
                    await socketServer.completeSession(request.sessionId)
                    return
                }

                await registerSession(request, content: content)
            }
        }

        /// Registers a new editor session after file content has been read.
        private func registerSession(_ request: EditorRequest, content: String) async {
            // If there's already a session for this pane, complete the old one first
            if let existing = activeSessions[request.paneId] {
                logger.warning("Replacing existing editor session for pane \(request.paneId)")
                await socketServer.completeSession(existing.id)
            }

            let session = EditorSession(
                id: request.sessionId,
                paneId: request.paneId,
                filePath: request.filePath,
                originalContent: content
            )
            activeSessions[request.paneId] = session

            logger.info("Opened editor session for pane \(request.paneId)")

            // Bring app to front
            NSApplication.shared.activate(ignoringOtherApps: true)

            // Notify viewers
            await onSessionChanged?()
        }

        /// Submits edited content, writes it to the file, and signals the CLI to exit.
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

            // Signal the CLI to exit
            Task { await socketServer.completeSession(session.id) }
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

            // Signal the CLI to exit without writing changes
            Task { await socketServer.completeSession(session.id) }
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
