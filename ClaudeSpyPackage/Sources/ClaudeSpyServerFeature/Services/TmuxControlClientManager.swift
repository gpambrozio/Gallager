#if os(macOS)
    import Foundation
    import Logging

    /// Manages TmuxControlClient instances, one per tmux session.
    ///
    /// When multiple panes from the same session are being streamed, they share
    /// a single control mode connection. This reduces resource usage and ensures
    /// consistent event handling across all panes in a session.
    @Observable
    @MainActor
    final public class TmuxControlClientManager {
        private let logger = Logger(label: "com.claudespy.controlclientmanager")

        private let tmuxPath: String
        private let socketPath: String?

        /// Active control clients keyed by session name
        private var clients: [String: TmuxControlClient] = [:]

        /// Callback for dimension changes (forwarded to PaneStreamManager)
        private var _onDimensionChange: (@MainActor (String, Int, Int) -> Void)?

        /// Callback when panes may have changed (pane exited or session disconnected).
        /// Listeners should refresh their pane list and clean up stale sessions.
        private var _onPanesChanged: (@MainActor () -> Void)?

        public init(tmuxPath: String = "/opt/homebrew/bin/tmux", socketPath: String? = nil) {
            self.tmuxPath = tmuxPath
            self.socketPath = socketPath
        }

        /// Sets the callback for dimension changes.
        /// Called when any tracked pane's dimensions change.
        public func setOnDimensionChange(_ handler: @escaping @MainActor (String, Int, Int) -> Void) {
            _onDimensionChange = handler
        }

        /// Sets the callback for when panes may have changed.
        /// Called when a pane exits or a session disconnects.
        /// Listeners should refresh their pane list and clean up stale sessions.
        public func setOnPanesChanged(_ handler: @escaping @MainActor () -> Void) {
            _onPanesChanged = handler
        }

        /// Gets or creates a control client for the specified session.
        ///
        /// - Parameter sessionName: The tmux session name
        /// - Returns: The control client for this session
        /// - Throws: If connection fails
        func getClient(for sessionName: String) async throws -> TmuxControlClient {
            if let existing = clients[sessionName], await existing.isConnected {
                logger.debug("Reusing existing control client", metadata: [
                    "session": "\(sessionName)",
                ])
                return existing
            }

            logger.info("Creating new control client", metadata: [
                "session": "\(sessionName)",
            ])

            let client = TmuxControlClient(tmuxPath: tmuxPath, socketPath: socketPath)

            // Set up dimension change handler
            await client.setOnDimensionChange { [weak self] paneId, width, height in
                Task { @MainActor [weak self] in
                    self?.handleDimensionChange(paneId: paneId, width: width, height: height)
                }
            }

            // Set up pane exit handler (pane closed but session still running)
            await client.setOnPaneExited { [weak self] paneId in
                Task { @MainActor [weak self] in
                    self?.handlePanesChanged(reason: "pane \(paneId) exited")
                }
            }

            // Set up exit handler (entire session ended)
            await client.setOnExit { [weak self] reason in
                Task { @MainActor [weak self] in
                    self?.handleClientExit(sessionName: sessionName, reason: reason)
                }
            }

            try await client.connect(sessionTarget: sessionName)
            clients[sessionName] = client

            return client
        }

        /// Registers a pane for streaming via the control client.
        ///
        /// - Parameters:
        ///   - paneId: The pane ID (e.g., "%0")
        ///   - sessionName: The session this pane belongs to
        ///   - dimensions: Initial pane dimensions
        ///   - handler: Callback for incoming output data
        public func registerPane(
            paneId: String,
            sessionName: String,
            dimensions: (width: Int, height: Int),
            handler: @escaping @Sendable (Data) -> Void
        ) async throws {
            let client = try await getClient(for: sessionName)
            await client.registerPaneHandler(
                paneId: paneId,
                initialDimensions: dimensions,
                handler: handler
            )

            logger.info("Registered pane for streaming", metadata: [
                "paneId": "\(paneId)",
                "session": "\(sessionName)",
            ])
        }

        /// Sends a tmux command through the control client for the given session.
        /// Commands sent this way are ordered relative to `%output` events,
        /// ensuring capture results are consistent with live stream state.
        func sendCommand(
            _ command: String,
            sessionName: String,
            timeout: TimeInterval = 5
        ) async throws -> CommandResponse {
            let client = try await getClient(for: sessionName)
            return try await client.sendCommand(command, timeout: timeout)
        }

        /// Starts per-pane output buffering (discard mode) on the control client.
        /// While enabled, `%output` events for this pane are silently discarded.
        public func startPaneBuffering(paneId: String, sessionName: String) async throws {
            let client = try await getClient(for: sessionName)
            await client.startPaneBuffering(paneId: paneId)
        }

        /// Stops per-pane output buffering on the control client.
        /// After this call, `%output` events are delivered normally to the pane handler.
        public func stopPaneBuffering(paneId: String, sessionName: String) async throws {
            let client = try await getClient(for: sessionName)
            await client.stopPaneBuffering(paneId: paneId)
        }

        /// Unregisters a pane from streaming.
        ///
        /// - Parameters:
        ///   - paneId: The pane ID
        ///   - sessionName: The session this pane belongs to
        public func unregisterPane(paneId: String, sessionName: String) async {
            guard let client = clients[sessionName] else { return }
            await client.unregisterPaneHandler(paneId: paneId)

            logger.info("Unregistered pane from streaming", metadata: [
                "paneId": "\(paneId)",
                "session": "\(sessionName)",
            ])

            // Keep the connection alive for faster reconnection when new panes are added.
            // Client cleanup happens via handleClientExit when the session is destroyed.
        }

        /// Disconnects all control clients.
        public func disconnectAll() async {
            logger.info("Disconnecting all control clients")
            for (sessionName, client) in clients {
                await client.disconnect()
                logger.debug("Disconnected client", metadata: [
                    "session": "\(sessionName)",
                ])
            }
            clients.removeAll()
        }

        /// Extracts the session name from a pane target.
        ///
        /// Pane targets can be in various formats:
        /// - `session:window.pane` (e.g., "mysession:0.1")
        /// - `session:window` (e.g., "mysession:0")
        /// - `session` (e.g., "mysession")
        ///
        /// - Parameter target: The pane target string
        /// - Returns: The session name, or the full target if no colon is found
        public static func extractSessionName(from target: String) -> String {
            if let colonIndex = target.firstIndex(of: ":") {
                return String(target[..<colonIndex])
            }
            return target
        }

        // MARK: - Private Methods

        private func handleDimensionChange(paneId: String, width: Int, height: Int) {
            logger.debug("Dimension change from control client", metadata: [
                "paneId": "\(paneId)",
                "width": "\(width)",
                "height": "\(height)",
            ])
            _onDimensionChange?(paneId, width, height)
        }

        private func handlePanesChanged(reason: String) {
            logger.info("Panes changed", metadata: ["reason": "\(reason)"])
            _onPanesChanged?()
        }

        private func handleClientExit(sessionName: String, reason: String?) {
            logger.warning("Control client exited", metadata: [
                "session": "\(sessionName)",
                "reason": "\(reason ?? "unknown")",
            ])
            clients.removeValue(forKey: sessionName)
            handlePanesChanged(reason: "session \(sessionName) disconnected")
        }
    }
#endif
