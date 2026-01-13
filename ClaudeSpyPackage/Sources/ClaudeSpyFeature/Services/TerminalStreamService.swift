#if os(iOS)
    import ClaudeSpyNetworking
    import Foundation
    import Observation
    import os

    /// State of the terminal stream
    public enum TerminalStreamState: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case error(String)

        public var isActive: Bool {
            self == .connected
        }
    }

    /// Service for managing live terminal streaming from Mac to iOS.
    ///
    /// This service handles the lifecycle of a terminal stream:
    /// 1. Send StartTerminalStream command to Mac
    /// 2. Receive initial content and dimensions
    /// 3. Receive streaming data chunks
    /// 4. Handle resize events
    /// 5. Stop streaming when done
    @Observable
    @MainActor
    final public class TerminalStreamService {
        // MARK: - Dependencies

        /// The pane ID being streamed
        public let paneId: String

        /// Reference to the relay client for communication
        private let relayClient: RelayClient

        // MARK: - Observable State

        /// Current streaming state
        public private(set) var state: TerminalStreamState = .disconnected

        /// Terminal width in columns
        public private(set) var width = 80

        /// Terminal height in rows
        public private(set) var height = 24

        // MARK: - Callbacks

        /// Called when initial content is received
        public var onInitialContent: (@MainActor (Data) -> Void)?

        /// Called when streaming data is received
        public var onData: (@MainActor (Data) -> Void)?

        /// Called when terminal is resized
        public var onResize: (@MainActor (Int, Int) -> Void)?

        /// Called when streaming stops
        public var onStopped: (@MainActor (String) -> Void)?

        // MARK: - Private

        private let logger = Logger(subsystem: "com.claudespy.ios", category: "TerminalStreamService")

        // MARK: - Initialization

        public init(paneId: String, relayClient: RelayClient) {
            self.paneId = paneId
            self.relayClient = relayClient
        }

        // MARK: - Streaming Control

        /// Start streaming terminal data from the Mac
        public func startStreaming() async throws {
            guard state == .disconnected || state == .error("") else {
                logger.warning("Already streaming or connecting")
                return
            }

            let targetPaneId = paneId
            state = .connecting
            logger.info("Starting terminal stream for pane \(targetPaneId)")

            let command = StartTerminalStream()
            let result = await relayClient.sendCommand(command, paneId: targetPaneId, timeout: 30)

            switch result {
            case let .success(startedMessage):
                width = startedMessage.width
                height = startedMessage.height
                state = .connected

                logger.info("Terminal stream started: \(startedMessage.width)x\(startedMessage.height)")

                // Feed initial content
                if let content = startedMessage.initialContent {
                    onInitialContent?(content)
                }

            case let .failure(error):
                let errorMessage = error.localizedDescription
                state = .error(errorMessage)
                logger.error("Failed to start terminal stream: \(errorMessage)")
                throw error
            }
        }

        /// Stop streaming terminal data
        public func stopStreaming() async {
            guard state == .connected || state == .connecting else {
                return
            }

            let targetPaneId = paneId
            logger.info("Stopping terminal stream for pane \(targetPaneId)")

            let command = StopTerminalStream()
            _ = await relayClient.sendCommand(command, paneId: targetPaneId, timeout: 5)

            state = .disconnected
        }

        // MARK: - Handle Incoming Messages

        /// Handle incoming terminal stream data from Mac
        public func handleStreamData(_ message: TerminalStreamDataMessage) {
            guard message.paneId == paneId, state == .connected else { return }

            if let data = message.data {
                onData?(data)
            }
        }

        /// Handle incoming terminal resize from Mac
        public func handleStreamResize(_ message: TerminalStreamResizeMessage) {
            guard message.paneId == paneId, state == .connected else { return }

            width = message.width
            height = message.height
            onResize?(message.width, message.height)
        }

        /// Handle stream stopped notification from Mac
        public func handleStreamStopped(_ message: TerminalStreamStoppedMessage) {
            guard message.paneId == paneId else { return }

            logger.info("Terminal stream stopped: \(message.reason)")
            state = .disconnected
            onStopped?(message.reason)
        }
    }
#endif
