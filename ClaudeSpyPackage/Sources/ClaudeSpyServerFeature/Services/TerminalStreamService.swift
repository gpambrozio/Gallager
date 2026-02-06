import ClaudeSpyNetworking
import Foundation
import Logging

// MARK: - Terminal Stream Service

/// Manages live terminal streaming to connected viewers.
///
/// This service subscribes to PaneStreamManager for terminal data and forwards
/// it to viewers via the network layer. It handles data batching for efficient
/// transmission.
///
/// Usage:
/// 1. Call `startStreaming(paneId:target:...)` when a viewer requests a stream
/// 2. Data flows automatically from PaneStreamManager
/// 3. Call `stopStreaming(paneId:)` when the stream should end
@Observable
@MainActor
final public class TerminalStreamService {
    // MARK: - Properties

    private let logger = Logger(label: "com.claudespy.terminalstream")

    /// Reference to the device connection manager for sending messages
    private weak var connectionManager: ConnectedViewerManager?

    /// Reference to the pane stream manager
    private weak var paneStreamManager: PaneStreamManager?

    /// Active streams keyed by pane ID
    private var activeStreams: [String: StreamContext] = [:]

    // MARK: - Batching Configuration

    /// Minimum interval between stream messages (throttling)
    private let batchInterval: TimeInterval = 0.05 // 50ms = 20 updates/sec max

    /// Maximum batch size before forced send
    private let maxBatchSize = 8_192 // 8KB

    // MARK: - Initialization

    public init() { }

    /// Configure the service with required dependencies for multi-device support.
    ///
    /// Must be called before starting any streams.
    ///
    /// - Parameters:
    ///   - connectionManager: The ConnectedViewerManager to use for sending stream data to all viewers
    ///   - paneStreamManager: The PaneStreamManager to subscribe to for data
    public func configureWithConnectionManager(
        connectionManager: ConnectedViewerManager,
        paneStreamManager: PaneStreamManager
    ) {
        self.connectionManager = connectionManager
        self.paneStreamManager = paneStreamManager
    }

    // MARK: - Public API

    /// Check if a pane is currently streaming.
    public func isStreaming(paneId: String) -> Bool {
        activeStreams[paneId] != nil
    }

    /// Get all pane IDs that are currently streaming.
    public var streamingPaneIds: [String] {
        Array(activeStreams.keys)
    }

    /// Start streaming a pane to viewers.
    ///
    /// Subscribes to PaneStreamManager for data and sends it to iOS.
    /// The initial content is captured atomically with the subscription,
    /// ensuring no timing gap between initial state and live updates.
    ///
    /// - Parameters:
    ///   - paneId: The pane identifier (e.g., "%1")
    ///   - target: The pane target (e.g., "mysession:0.1")
    public func startStreaming(
        paneId: String,
        target: String
    ) async throws {
        guard let connectionManager else {
            logger.error("Connection manager not configured, cannot start streaming")
            throw StreamError.notConfigured
        }

        guard let paneStreamManager else {
            logger.error("Pane stream manager not configured, cannot start streaming")
            throw StreamError.notConfigured
        }

        // If a stream is already active for this pane, reuse it.
        // Multiple viewers can watch the same pane simultaneously.
        // We just increment the subscriber count and send the current state.
        if let context = activeStreams[paneId] {
            // Capture current content first — only increment count if we succeed.
            // This avoids inflating the count when the pane is no longer available.
            guard let current = await paneStreamManager.currentContent(for: paneId) else {
                logger.error("Failed to capture content for existing stream", metadata: [
                    "paneId": "\(paneId)",
                ])
                throw StreamError.paneNotAvailable
            }

            context.deviceSubscriberCount += 1

            logger.info("Additional device subscribing to existing stream", metadata: [
                "paneId": "\(paneId)",
                "subscriberCount": "\(context.deviceSubscriberCount)",
            ])

            // Send current state as initialState to all devices.
            // Existing viewers get a content refresh (cosmetic), new viewer gets the full state.
            let initialMessage = TerminalStreamMessage.initialState(
                paneId: paneId,
                width: current.width,
                height: current.height,
                content: current.content
            )
            await connectionManager.sendTerminalStreamToAll(initialMessage)

            return
        }

        logger.info("Starting terminal stream", metadata: [
            "paneId": "\(paneId)",
            "target": "\(target)",
        ])

        // Create context for batching
        let context = StreamContext(paneId: paneId)

        // Store context BEFORE subscribing so callbacks work immediately
        activeStreams[paneId] = context

        // Subscribe to PaneStreamManager for data
        // This returns initial content captured atomically with the subscription
        let result: PaneStreamManager.SubscriptionResult
        do {
            result = try await paneStreamManager.subscribe(
                paneId: paneId,
                target: target,
                onData: { [weak self] (data: Data) in
                    guard let self else { return }
                    // Look up context from activeStreams to ensure we're still active
                    guard let context = self.activeStreams[paneId] else { return }
                    Task {
                        await self.handleIncomingData(context: context, paneId: paneId, data: data)
                    }
                },
                onDimensionChange: { [weak self] (newWidth: Int, newHeight: Int) in
                    guard let self else { return }
                    Task {
                        await self.handleDimensionChange(paneId: paneId, width: newWidth, height: newHeight)
                    }
                }
            )
        } catch {
            // Clean up on failure
            activeStreams.removeValue(forKey: paneId)
            throw error
        }

        context.subscriptionId = result.subscriptionId

        logger.info("Stream subscribed", metadata: [
            "paneId": "\(paneId)",
            "dimensions": "\(result.width)x\(result.height)",
            "bufferSize": "\(result.initialContent.count)",
        ])

        // Send initial state to all viewers
        // The content was captured atomically with the subscription,
        // so there's no gap between this state and incoming live updates
        let initialMessage = TerminalStreamMessage.initialState(
            paneId: paneId,
            width: result.width,
            height: result.height,
            content: result.initialContent
        )
        await connectionManager.sendTerminalStreamToAll(initialMessage)
    }

    /// Errors that can occur during streaming
    public enum StreamError: Error {
        case notConfigured
        case paneNotAvailable
    }

    /// Stop streaming a pane.
    ///
    /// Decrements the device subscriber count. Only truly stops (unsubscribes, sends streamEnd)
    /// when the last subscriber leaves or when `force` is true.
    ///
    /// - Parameters:
    ///   - paneId: The pane identifier
    ///   - force: If true, stop immediately regardless of subscriber count (used for system cleanup)
    public func stopStreaming(paneId: String, force: Bool = false) async {
        guard let context = activeStreams[paneId] else {
            logger.debug("No active stream for pane \(paneId)")
            return
        }

        if !force {
            if context.deviceSubscriberCount <= 0 {
                // Count already at or below zero — force-stop to clean up inconsistent state
                logger.warning("Subscriber count already at \(context.deviceSubscriberCount), force-stopping", metadata: [
                    "paneId": "\(paneId)",
                ])
            } else {
                context.deviceSubscriberCount -= 1
                if context.deviceSubscriberCount > 0 {
                    logger.info("Device unsubscribed from stream, others still watching", metadata: [
                        "paneId": "\(paneId)",
                        "remainingSubscribers": "\(context.deviceSubscriberCount)",
                    ])
                    return
                }
            }
        }

        activeStreams.removeValue(forKey: paneId)

        logger.info("Stopping terminal stream", metadata: ["paneId": "\(paneId)"])

        // Cancel any pending batch send
        context.batchTask?.cancel()

        // Unsubscribe from PaneStreamManager
        if let subscriptionId = context.subscriptionId {
            await paneStreamManager?.unsubscribe(subscriptionId)
        }

        // Flush any pending data
        await flushPendingData(for: context, paneId: paneId)

        // Send stream end to all viewers
        guard let connectionManager else { return }
        let endMessage = TerminalStreamMessage.streamEnd(paneId: paneId)
        await connectionManager.sendTerminalStreamToAll(endMessage)
    }

    /// Stop all active streams.
    ///
    /// Called when viewers disconnect or the app is shutting down.
    /// Uses force to bypass subscriber count since this is a system-level cleanup.
    public func stopAllStreams() async {
        let paneIds = Array(activeStreams.keys)
        for paneId in paneIds {
            await stopStreaming(paneId: paneId, force: true)
        }
    }

    /// Stops streams for panes that are no longer in the provided list.
    ///
    /// Called when panes change to clean up streams for closed panes.
    /// This sends the streamEnd message to viewer so it can close the terminal view.
    ///
    /// - Parameter currentPanes: The list of currently existing panes
    public func stopStreamsForClosedPanes(currentPanes: [PaneInfo]) async {
        let existingPaneIds = Set(currentPanes.map(\.paneId))
        let streamsToStop = activeStreams.keys.filter { !existingPaneIds.contains($0) }

        for paneId in streamsToStop {
            logger.info("Stopping stream for closed pane", metadata: ["paneId": "\(paneId)"])
            await stopStreaming(paneId: paneId, force: true)
        }
    }

    // MARK: - Private Methods

    private func scheduleBatchSend(for context: StreamContext, paneId: String) {
        // Cancel existing scheduled send
        context.batchTask?.cancel()

        context.batchTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.batchInterval ?? 0.05))
            guard !Task.isCancelled, let self else { return }
            await self.flushPendingData(for: context, paneId: paneId)
        }
    }

    private func flushPendingData(for context: StreamContext, paneId: String) async {
        let dataToSend = context.flushPendingData()
        guard !dataToSend.isEmpty else { return }

        guard let connectionManager else { return }
        let message = TerminalStreamMessage.dataChunk(paneId: paneId, data: dataToSend)
        await connectionManager.sendTerminalStreamToAll(message)
    }

    /// Handle incoming data from PaneStreamManager
    private func handleIncomingData(context: StreamContext, paneId: String, data: Data) async {
        context.appendData(data)

        // Check if we should send immediately (batch full) or schedule
        if context.pendingDataSize >= maxBatchSize {
            await flushPendingData(for: context, paneId: paneId)
        } else {
            scheduleBatchSend(for: context, paneId: paneId)
        }
    }

    /// Handle dimension change from PaneStreamManager
    private func handleDimensionChange(paneId: String, width: Int, height: Int) async {
        guard activeStreams[paneId] != nil else { return }
        guard let connectionManager else { return }

        logger.info("Sending dimension change", metadata: [
            "paneId": "\(paneId)",
            "dimensions": "\(width)x\(height)",
        ])

        let message = TerminalStreamMessage.dimensionChange(paneId: paneId, width: width, height: height)
        await connectionManager.sendTerminalStreamToAll(message)
    }
}

// MARK: - Stream Context

/// Context for an active terminal stream, handles data batching.
@MainActor
final private class StreamContext {
    let paneId: String
    var subscriptionId: UUID?
    private var pendingData = Data()
    var batchTask: Task<Void, Never>?

    /// Number of viewers currently watching this pane's stream.
    /// The stream is only truly stopped when this reaches 0 (or forced).
    var deviceSubscriberCount = 1

    var pendingDataSize: Int { pendingData.count }

    init(paneId: String) {
        self.paneId = paneId
    }

    func appendData(_ data: Data) {
        pendingData.append(data)
    }

    func flushPendingData() -> Data {
        let data = pendingData
        pendingData = Data()
        return data
    }
}
