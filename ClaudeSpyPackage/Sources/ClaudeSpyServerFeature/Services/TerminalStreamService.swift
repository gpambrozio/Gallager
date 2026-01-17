import ClaudeSpyNetworking
import Foundation
import Logging

// MARK: - Terminal Stream Service

/// Manages live terminal streaming to connected iOS devices.
///
/// This service subscribes to PaneStreamManager for terminal data and forwards
/// it to iOS via the network layer. It handles data batching for efficient
/// transmission.
///
/// Usage:
/// 1. Call `startStreaming(paneId:target:...)` when iOS requests a stream
/// 2. Data flows automatically from PaneStreamManager
/// 3. Call `stopStreaming(paneId:)` when the stream should end
@Observable
@MainActor
final public class TerminalStreamService {
    // MARK: - Properties

    private let logger = Logger(label: "com.claudespy.terminalstream")

    /// Reference to the external server client for sending messages
    private weak var serverClient: ExternalServerClient?

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

    /// Configure the service with required dependencies.
    ///
    /// Must be called before starting any streams.
    ///
    /// - Parameters:
    ///   - serverClient: The ExternalServerClient to use for sending stream data
    ///   - paneStreamManager: The PaneStreamManager to subscribe to for data
    public func configure(serverClient: ExternalServerClient, paneStreamManager: PaneStreamManager) {
        self.serverClient = serverClient
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

    /// Start streaming a pane to iOS.
    ///
    /// Subscribes to PaneStreamManager for data and sends it to iOS.
    ///
    /// - Parameters:
    ///   - paneId: The pane identifier (e.g., "%1")
    ///   - target: The pane target (e.g., "mysession:0.1")
    ///   - width: Initial terminal width in columns
    ///   - height: Initial terminal height in rows
    ///   - initialContent: Current terminal buffer content (scrollback + visible)
    public func startStreaming(
        paneId: String,
        target: String,
        width: Int,
        height: Int,
        initialContent: Data
    ) async throws {
        guard activeStreams[paneId] == nil else {
            logger.info("Stream already active for pane \(paneId)")
            return
        }

        guard let serverClient else {
            logger.error("Server client not configured, cannot start streaming")
            throw StreamError.notConfigured
        }

        guard let paneStreamManager else {
            logger.error("Pane stream manager not configured, cannot start streaming")
            throw StreamError.notConfigured
        }

        logger.info("Starting terminal stream", metadata: [
            "paneId": "\(paneId)",
            "target": "\(target)",
            "dimensions": "\(width)x\(height)",
            "bufferSize": "\(initialContent.count)",
        ])

        // Create context for batching
        let context = StreamContext(paneId: paneId)

        // Subscribe to PaneStreamManager for data
        let subscriptionId = try await paneStreamManager.subscribe(
            paneId: paneId,
            target: target,
            onData: { [weak self, weak context] data in
                guard let self, let context else { return }
                Task {
                    await self.handleIncomingData(context: context, paneId: paneId, data: data)
                }
            },
            onDimensionChange: { [weak self] newWidth, newHeight in
                guard let self else { return }
                Task {
                    await self.handleDimensionChange(paneId: paneId, width: newWidth, height: newHeight)
                }
            }
        )

        context.subscriptionId = subscriptionId
        activeStreams[paneId] = context

        // Send initial state to iOS
        let initialMessage = TerminalStreamMessage.initialState(
            paneId: paneId,
            width: width,
            height: height,
            content: initialContent
        )
        await serverClient.sendTerminalStream(initialMessage)
    }

    /// Errors that can occur during streaming
    public enum StreamError: Error {
        case notConfigured
    }

    /// Stop streaming a pane.
    ///
    /// Unsubscribes from PaneStreamManager, flushes any pending data, and sends the stream end message.
    ///
    /// - Parameter paneId: The pane identifier
    public func stopStreaming(paneId: String) async {
        guard let context = activeStreams.removeValue(forKey: paneId) else {
            logger.debug("No active stream for pane \(paneId)")
            return
        }

        logger.info("Stopping terminal stream", metadata: ["paneId": "\(paneId)"])

        // Unsubscribe from PaneStreamManager
        if let subscriptionId = context.subscriptionId {
            await paneStreamManager?.unsubscribe(subscriptionId)
        }

        // Flush any pending data
        await flushPendingData(for: context, paneId: paneId)

        // Send stream end
        guard let serverClient else { return }
        let endMessage = TerminalStreamMessage.streamEnd(paneId: paneId)
        await serverClient.sendTerminalStream(endMessage)
    }

    /// Stop all active streams.
    ///
    /// Called when iOS disconnects or the app is shutting down.
    public func stopAllStreams() async {
        let paneIds = Array(activeStreams.keys)
        for paneId in paneIds {
            await stopStreaming(paneId: paneId)
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

        guard let serverClient else { return }
        let message = TerminalStreamMessage.dataChunk(paneId: paneId, data: dataToSend)
        await serverClient.sendTerminalStream(message)
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
        guard let serverClient else { return }

        logger.info("Sending dimension change", metadata: [
            "paneId": "\(paneId)",
            "dimensions": "\(width)x\(height)",
        ])

        let message = TerminalStreamMessage.dimensionChange(paneId: paneId, width: width, height: height)
        await serverClient.sendTerminalStream(message)
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
