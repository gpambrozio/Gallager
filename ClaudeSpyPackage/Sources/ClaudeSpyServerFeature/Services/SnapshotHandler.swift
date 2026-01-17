import ClaudeSpyNetworking
import Foundation
import Logging

/// Handles snapshot capture commands from iOS devices.
///
/// Snapshot commands are handled separately from regular commands because the captured
/// terminal content is sent as a `TerminalSnapshotMessage` rather than a `CommandResponseMessage`.
@MainActor
final public class SnapshotHandler {
    // MARK: - Properties

    private let logger = Logger(label: "com.claudespy.snapshot")
    private let tmuxService: TmuxService
    private let serverClient: ExternalServerClient

    // MARK: - Initialization

    public init(tmuxService: TmuxService, serverClient: ExternalServerClient) {
        self.tmuxService = tmuxService
        self.serverClient = serverClient
    }

    // MARK: - Public API

    /// Handles a snapshot capture command.
    ///
    /// - Parameters:
    ///   - command: The command message requesting the snapshot
    ///   - scrollbackMultiplier: How many screens of scrollback to capture
    /// - Returns: An error response on failure, or `nil` on success (the snapshot message is the response)
    public func handleSnapshotCommand(
        _ command: CommandMessage,
        scrollbackMultiplier: Int
    ) async -> CommandResponseMessage? {
        logger.info("handleSnapshotCommand started", metadata: ["paneId": "\(command.paneId)"])

        do {
            // Get pane dimensions first
            let (width, height) = try await tmuxService.getPaneDimensions(command.paneId)

            let (rawContent, totalLines) = try await tmuxService.capturePaneWithScrollback(
                command.paneId,
                scrollbackMultiplier: scrollbackMultiplier
            )

            // Add cursor positioning to each line (like capturePaneWithPositioning)
            let contentString = String(data: rawContent, encoding: .utf8) ?? ""
            let lines = contentString.split(separator: "\n", omittingEmptySubsequences: false)

            var positionedContent = "\u{1b}[H" // Cursor home
            for (index, line) in lines.enumerated() {
                positionedContent += "\u{1b}[\(index + 1);1H" // Move to row, col 1
                positionedContent += "\u{1b}[2K" // Clear line
                positionedContent += line
            }

            let content = Data(positionedContent.utf8)

            logger.info("Pane captured with scrollback", metadata: [
                "width": "\(width)",
                "height": "\(height)",
                "totalLines": "\(totalLines)",
                "contentBytes": "\(content.count)",
            ])

            // Create and send the snapshot - this IS the response
            let snapshot = TerminalSnapshotMessage(
                commandId: command.id,
                paneId: command.paneId,
                width: width,
                height: height,
                totalLines: totalLines,
                content: content
            )

            logger.debug("Sending snapshot via WebSocket")
            await serverClient.sendTerminalSnapshot(snapshot)
            logger.info("Snapshot sent successfully")

            // Return nil - the TerminalSnapshotMessage is the response
            return nil
        } catch {
            logger.error("Snapshot capture failed: \(error.localizedDescription)")
            return .failure(for: command.id, error: error.localizedDescription)
        }
    }
}
