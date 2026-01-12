import ClaudeSpyNetworking
import Foundation
import Logging

/// Manages terminal streams for remote iOS clients.
///
/// This manager coordinates between PaneStream (which reads from tmux)
/// and ExternalServerClient (which sends data to iOS).
@Observable
@MainActor
final public class RemoteTerminalStreamManager {
    private let tmuxService: TmuxService
    private weak var serverClient: ExternalServerClient?
    private let logger = Logger(label: "com.claudespy.remotestream")

    /// Active streams keyed by pane ID
    private var activeStreams: [String: PaneStream] = [:]

    public init(tmuxService: TmuxService, serverClient: ExternalServerClient) {
        self.tmuxService = tmuxService
        self.serverClient = serverClient
    }

    /// Start streaming a terminal pane to iOS
    /// - Parameters:
    ///   - paneId: The pane ID to stream (e.g., "%5")
    ///   - commandId: The command ID that initiated this stream
    /// - Returns: CommandResponseMessage indicating success or failure
    public func startStream(paneId: String, commandId: UUID) async -> CommandResponseMessage {
        // Check if already streaming this pane
        if activeStreams[paneId] != nil {
            logger.warning("Pane already streaming", metadata: ["paneId": "\(paneId)"])
            return .success(for: commandId)
        }

        logger.info("Starting remote stream", metadata: ["paneId": "\(paneId)"])

        // Create a PaneStream for this pane
        let stream = PaneStream(target: paneId, tmuxService: tmuxService)

        do {
            // Get dimensions FIRST so iOS can size terminal before receiving content
            // This matches how Mac local mirror works (resize before feeding data)
            let dims = try await tmuxService.getPaneDimensions(paneId)

            // Send dimensions to iOS BEFORE any content
            let started = TerminalStreamStarted(
                commandId: commandId,
                paneId: paneId,
                width: dims.width,
                height: dims.height
            )
            await serverClient?.sendTerminalStreamStarted(started)

            logger.info("Sent stream dimensions", metadata: [
                "paneId": "\(paneId)",
                "dimensions": "\(dims.width)x\(dims.height)",
            ])

            // Track whether we've sent the initial content
            var sentInitialContent = false

            // Set up callbacks to forward data to iOS
            stream.onData = { [weak self] data in
                guard let self, let client = self.serverClient else { return }

                // The first chunk is the initial terminal content (from capturePaneWithPositioning)
                // Mark it as initial so iOS knows to clear the terminal first
                let isInitial = !sentInitialContent
                sentInitialContent = true

                let chunk = TerminalStreamChunk(
                    paneId: paneId,
                    width: stream.width,
                    height: stream.height,
                    data: data,
                    isInitial: isInitial
                )
                Task {
                    await client.sendTerminalStreamChunk(chunk)
                }
            }

            stream.onDimensionChange = { [weak self] newWidth, newHeight in
                guard let self, let client = self.serverClient else { return }
                self.logger.debug("Dimensions changed", metadata: [
                    "paneId": "\(paneId)",
                    "newWidth": "\(newWidth)",
                    "newHeight": "\(newHeight)",
                ])

                // Notify iOS of dimension change so it can resize the terminal
                let dimensionUpdate = TerminalStreamStarted(
                    commandId: commandId,
                    paneId: paneId,
                    width: newWidth,
                    height: newHeight
                )
                Task {
                    await client.sendTerminalStreamStarted(dimensionUpdate)
                }
            }

            // NOW connect and start streaming (this sends initial content)
            try await stream.connect()

            // Store the active stream
            activeStreams[paneId] = stream

            logger.info("Remote stream started", metadata: [
                "paneId": "\(paneId)",
                "dimensions": "\(stream.width)x\(stream.height)",
            ])

            return .success(for: commandId)
        } catch {
            logger.error("Failed to start remote stream", metadata: [
                "paneId": "\(paneId)",
                "error": "\(error.localizedDescription)",
            ])
            return .failure(for: commandId, error: error.localizedDescription)
        }
    }

    /// Stop streaming a terminal pane
    /// - Parameters:
    ///   - paneId: The pane ID to stop streaming
    ///   - commandId: The command ID that initiated this stop
    ///   - reason: Optional reason for stopping (nil if user requested)
    /// - Returns: CommandResponseMessage indicating success or failure
    public func stopStream(paneId: String, commandId: UUID, reason: String? = nil) async -> CommandResponseMessage {
        guard let stream = activeStreams.removeValue(forKey: paneId) else {
            logger.warning("No active stream for pane", metadata: ["paneId": "\(paneId)"])
            return .success(for: commandId)
        }

        logger.info("Stopping remote stream", metadata: [
            "paneId": "\(paneId)",
            "reason": "\(reason ?? "user requested")",
        ])

        // Disconnect the stream
        await stream.disconnect()

        // Notify iOS
        let stopped = TerminalStreamStopped(paneId: paneId, reason: reason)
        await serverClient?.sendTerminalStreamStopped(stopped)

        return .success(for: commandId)
    }

    /// Stop all active streams
    public func stopAllStreams() async {
        logger.info("Stopping all remote streams", metadata: [
            "count": "\(activeStreams.count)",
        ])

        for (paneId, stream) in activeStreams {
            await stream.disconnect()

            let stopped = TerminalStreamStopped(paneId: paneId, reason: "session ended")
            await serverClient?.sendTerminalStreamStopped(stopped)
        }

        activeStreams.removeAll()
    }

    /// Check if a pane is currently being streamed
    public func isStreaming(paneId: String) -> Bool {
        activeStreams[paneId] != nil
    }

    /// Get list of currently streaming pane IDs
    public var streamingPaneIds: [String] {
        Array(activeStreams.keys)
    }
}
