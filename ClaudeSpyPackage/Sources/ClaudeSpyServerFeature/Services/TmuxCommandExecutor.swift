import ClaudeSpyCommon
import ClaudeSpyNetworking
import Foundation
import Logging

/// Executes commands received from iOS devices via the relay server.
///
/// Translates `CommandMessage` objects into tmux operations using `TmuxService`.
public actor TmuxCommandExecutor {
    // MARK: - Properties

    private let logger = Logger(label: "com.claudespy.commandexecutor")
    private let tmuxService: TmuxService

    // MARK: - Initialization

    public init(tmuxService: TmuxService) {
        self.tmuxService = tmuxService
    }

    // MARK: - Command Execution

    /// Execute a command received from iOS
    /// - Parameter command: The command to execute
    /// - Returns: Response indicating success or failure
    public func execute(_ command: CommandMessage) async -> CommandResponseMessage {
        logger.info("Executing command", metadata: [
            "command": "\(command.command)",
            "paneId": "\(command.paneId)",
        ])

        do {
            switch command.command {
            case let .sendKeystroke(spec):
                try await executeSendKeystroke(paneId: command.paneId, keys: spec.keystrokes)

            case .cancelOperation:
                try await tmuxService.sendInterrupt(command.paneId)

            case .startTerminalStream,
                 .stopTerminalStream:
                // Stream commands are handled by RemoteTerminalStreamManager, not here
                logger.info("Stream command received (will be handled by caller)")
            }

            logger.info("Command executed successfully", metadata: ["commandId": "\(command.id)"])
            return .success(for: command.id)

        } catch {
            logger.error("Command execution failed", metadata: [
                "commandId": "\(command.id)",
                "error": "\(error)",
            ])
            return .failure(for: command.id, error: error.localizedDescription)
        }
    }

    // MARK: - Private Command Handlers

    private func executeSendKeystroke(paneId: String, keys: [TmuxKey]) async throws {
        for key in keys {
            try await tmuxService.sendKeys(
                paneId,
                keys: key.tmuxKeyName,
                literal: key.isLiteral
            )
        }
    }
}

// MARK: - Command Errors

enum CommandError: LocalizedError {
    case invalidPayload(String)
    case paneNotFound(String)
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidPayload(message):
            "Invalid command payload: \(message)"
        case let .paneNotFound(paneId):
            "Pane not found: \(paneId)"
        case let .executionFailed(message):
            "Command execution failed: \(message)"
        }
    }
}
