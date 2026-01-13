import ClaudeSpyNetworking
import Foundation
import Logging

/// Manages terminal streaming sessions from Mac to iOS devices.
///
/// When iOS requests a terminal stream, this manager creates a PaneStream connection
/// and forwards terminal data to iOS via the ExternalServerClient.
@Observable
@MainActor
final public class RemoteTerminalStreamManager {
    // MARK: - Types

    /// Information about an active stream
    private struct ActiveStream {
        let paneId: String
        let paneStream: PaneStream
        let commandId: UUID
    }

    // MARK: - Properties

    private let logger = Logger(label: "com.claudespy.remoteterminalstream")

    /// The tmux service for creating pane streams
    private let tmuxService: TmuxService

    /// Callback to send messages to iOS
    private var sendToIOS: (@MainActor (WebSocketMessage) async -> Void)?

    /// Active streams keyed by pane ID
    private var activeStreams: [String: ActiveStream] = [:]

    // MARK: - Initialization

    public init(tmuxService: TmuxService) {
        self.tmuxService = tmuxService
    }

    // MARK: - Configuration

    /// Set the callback for sending messages to iOS
    public func setSendCallback(_ callback: @escaping @MainActor (WebSocketMessage) async -> Void) {
        sendToIOS = callback
    }

    // MARK: - Stream Management

    /// Start streaming a pane to iOS
    /// - Parameters:
    ///   - paneId: The pane ID to stream
    ///   - commandId: The command ID from iOS to respond to
    /// - Returns: The initial stream started message, or nil if failed
    public func startStream(paneId: String, commandId: UUID) async -> TerminalStreamStartedMessage? {
        // Check if already streaming this pane
        if activeStreams[paneId] != nil {
            logger.warning("Already streaming pane \(paneId)")
            return nil
        }

        // Look up the pane target from the pane ID
        guard let paneTarget = await findPaneTarget(for: paneId) else {
            logger.error("Could not find pane target for pane ID \(paneId)")
            return nil
        }

        logger.info("Starting remote terminal stream", metadata: [
            "paneId": "\(paneId)",
            "target": "\(paneTarget)",
        ])

        // Create pane stream
        let paneStream = PaneStream(target: paneTarget, tmuxService: tmuxService)

        // Set up data callback to forward to iOS
        paneStream.onData = { [weak self] data in
            guard let self else { return }
            Task {
                await self.forwardData(paneId: paneId, data: data)
            }
        }

        // Set up resize callback to forward to iOS
        paneStream.onDimensionChange = { [weak self] width, height in
            guard let self else { return }
            Task {
                await self.forwardResize(paneId: paneId, width: width, height: height)
            }
        }

        // Connect to the pane
        do {
            try await paneStream.connect()
        } catch {
            logger.error("Failed to connect to pane stream: \(error)")
            return nil
        }

        // Store the active stream
        activeStreams[paneId] = ActiveStream(
            paneId: paneId,
            paneStream: paneStream,
            commandId: commandId
        )

        // Get initial content
        let initialContent: Data
        do {
            initialContent = try await tmuxService.capturePaneWithPositioning(paneTarget)
        } catch {
            logger.error("Failed to capture initial pane content: \(error)")
            initialContent = Data()
        }

        // Create the response message
        let startedMessage = TerminalStreamStartedMessage(
            commandId: commandId,
            paneId: paneId,
            width: paneStream.width,
            height: paneStream.height,
            initialContent: initialContent
        )

        logger.info("Remote terminal stream started", metadata: [
            "paneId": "\(paneId)",
            "dimensions": "\(paneStream.width)x\(paneStream.height)",
        ])

        return startedMessage
    }

    /// Stop streaming a pane
    /// - Parameters:
    ///   - paneId: The pane ID to stop streaming
    ///   - reason: The reason for stopping
    public func stopStream(paneId: String, reason: String = "user_requested") async {
        guard let stream = activeStreams.removeValue(forKey: paneId) else {
            logger.warning("No active stream for pane \(paneId)")
            return
        }

        logger.info("Stopping remote terminal stream", metadata: [
            "paneId": "\(paneId)",
            "reason": "\(reason)",
        ])

        // Disconnect the pane stream
        await stream.paneStream.disconnect()

        // Notify iOS that the stream stopped
        let stoppedMessage = TerminalStreamStoppedMessage(paneId: paneId, reason: reason)
        await sendToIOS?(.terminalStreamStopped(stoppedMessage))
    }

    /// Stop all active streams (e.g., when iOS disconnects)
    public func stopAllStreams(reason: String = "ios_disconnected") async {
        let paneIds = Array(activeStreams.keys)
        for paneId in paneIds {
            await stopStream(paneId: paneId, reason: reason)
        }
    }

    // MARK: - Private Methods

    /// Forward terminal data to iOS
    private func forwardData(paneId: String, data: Data) async {
        guard activeStreams[paneId] != nil else { return }

        let message = TerminalStreamDataMessage(paneId: paneId, data: data)
        await sendToIOS?(.terminalStreamData(message))
    }

    /// Forward resize event to iOS
    private func forwardResize(paneId: String, width: Int, height: Int) async {
        guard activeStreams[paneId] != nil else { return }

        let message = TerminalStreamResizeMessage(paneId: paneId, width: width, height: height)
        await sendToIOS?(.terminalStreamResize(message))
    }

    /// Find the pane target for a given pane ID
    private func findPaneTarget(for paneId: String) async -> String? {
        // Refresh panes to get current list
        await tmuxService.refreshPanes()

        // Find the pane with matching ID
        for pane in tmuxService.panes where pane.paneId == paneId {
            return pane.target
        }

        return nil
    }
}
