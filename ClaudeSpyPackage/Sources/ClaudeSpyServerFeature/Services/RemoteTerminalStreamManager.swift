import ClaudeSpyNetworking
import Foundation
import Logging

/// Manages terminal streaming sessions from Mac to iOS devices.
///
/// When iOS requests a terminal stream, this manager subscribes to the shared PaneStreamManager
/// and forwards terminal data to iOS via the ExternalServerClient.
@Observable
@MainActor
final public class RemoteTerminalStreamManager {
    // MARK: - Types

    /// Information about an active stream
    private struct ActiveStream {
        let paneId: String
        let subscription: PaneStreamSubscription
        let commandId: UUID
    }

    /// A queued message to send to iOS
    private enum QueuedMessage {
        case data(paneId: String, data: Data)
        case resize(paneId: String, width: Int, height: Int)
    }

    // MARK: - Properties

    private let logger = Logger(label: "com.claudespy.remoteterminalstream")

    /// The shared pane stream manager
    private let paneStreamManager: PaneStreamManager

    /// The tmux service for pane lookups
    private let tmuxService: TmuxService

    /// Callback to send messages to iOS
    private var sendToIOS: (@MainActor (WebSocketMessage) async -> Void)?

    /// Active streams keyed by pane ID
    private var activeStreams: [String: ActiveStream] = [:]

    /// Queue for messages to ensure in-order delivery
    private var messageQueue: [QueuedMessage] = []

    /// Whether the queue processor is currently running
    private var isProcessingQueue = false

    // MARK: - Initialization

    public init(paneStreamManager: PaneStreamManager, tmuxService: TmuxService) {
        self.paneStreamManager = paneStreamManager
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
        // Check if already streaming this pane to iOS
        if activeStreams[paneId] != nil {
            logger.warning("Already streaming pane \(paneId) to iOS")
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

        // Subscribe to the shared pane stream
        // Note: sendInitialContent=false because we handle initial content via TerminalStreamStartedMessage
        let subscription: PaneStreamSubscription
        do {
            subscription = try await paneStreamManager.subscribe(
                target: paneTarget,
                onData: { [weak self] data in
                    // Queue data synchronously to preserve order
                    self?.queueMessage(.data(paneId: paneId, data: data))
                },
                onDimensionChange: { [weak self] width, height in
                    self?.queueMessage(.resize(paneId: paneId, width: width, height: height))
                },
                sendInitialContent: false
            )
        } catch {
            logger.error("Failed to subscribe to pane stream: \(error)")
            return nil
        }

        // Store the active stream
        activeStreams[paneId] = ActiveStream(
            paneId: paneId,
            subscription: subscription,
            commandId: commandId
        )

        // Get initial content with scrollback history (~3 pages)
        let initialContent: Data
        do {
            initialContent = try await tmuxService.capturePaneWithPositioning(
                paneTarget,
                scrollbackLines: 150
            )
        } catch {
            logger.error("Failed to capture initial pane content: \(error)")
            initialContent = Data()
        }

        // Create the response message
        let startedMessage = TerminalStreamStartedMessage(
            commandId: commandId,
            paneId: paneId,
            width: subscription.width,
            height: subscription.height,
            initialContent: initialContent
        )

        logger.info("Remote terminal stream started", metadata: [
            "paneId": "\(paneId)",
            "dimensions": "\(subscription.width)x\(subscription.height)",
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

        // Unsubscribe from the shared pane stream
        await stream.subscription.unsubscribe()

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

    /// Queue a message for in-order delivery to iOS
    private func queueMessage(_ message: QueuedMessage) {
        messageQueue.append(message)
        processQueueIfNeeded()
    }

    /// Start processing the queue if not already running
    private func processQueueIfNeeded() {
        guard !isProcessingQueue else { return }
        isProcessingQueue = true

        Task {
            await processQueue()
        }
    }

    /// Process queued messages in order
    private func processQueue() async {
        while !messageQueue.isEmpty {
            let message = messageQueue.removeFirst()

            switch message {
            case let .data(paneId, data):
                guard activeStreams[paneId] != nil else { continue }
                let wsMessage = TerminalStreamDataMessage(paneId: paneId, data: data)
                await sendToIOS?(.terminalStreamData(wsMessage))

            case let .resize(paneId, width, height):
                guard activeStreams[paneId] != nil else { continue }
                let wsMessage = TerminalStreamResizeMessage(paneId: paneId, width: width, height: height)
                await sendToIOS?(.terminalStreamResize(wsMessage))
            }
        }

        isProcessingQueue = false
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
