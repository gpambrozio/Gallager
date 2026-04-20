import ClaudeSpyCommon
import ClaudeSpyNetworking
import Foundation
import Logging

/// Executes commands received from viewers via the relay server.
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

    /// Execute a command received from viewer
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

            case let .sendRawInput(spec):
                guard let data = spec.data, !data.isEmpty else {
                    throw CommandError.invalidPayload("Invalid base64 data in sendRawInput")
                }
                try await tmuxService.sendRawBytes(command.paneId, data: data)

            case .cancelOperation:
                try await tmuxService.sendInterrupt(command.paneId)

            case let .resizeTmuxPane(spec):
                try await tmuxService.resizePane(command.paneId, width: spec.width, height: spec.height)

            case let .splitTmuxPane(spec):
                let newPaneId = try await tmuxService.splitPane(
                    command.paneId,
                    horizontal: spec.direction == .horizontal
                )
                return .success(for: command.id, paneId: newPaneId)

            case .selectTmuxPane:
                try await tmuxService.selectPane(command.paneId)

            case .selectTmuxWindow:
                try await tmuxService.selectWindow(command.paneId)

            case .startTerminalStream,
                 .stopTerminalStream,
                 .createTmuxSession,
                 .createTmuxWindow,
                 .setYoloMode,
                 .markHandled,
                 .setSessionDescription,
                 .setWindowName,
                 .submitEditorContent,
                 .cancelEditorSession,
                 .checkRunningProcesses,
                 .killTmuxWindow,
                 .killTmuxSession:
                // These commands are handled by AppCoordinator, should not reach here
                logger.warning("Command should be handled by AppCoordinator, not executor")
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
        // Batch consecutive keys by literal mode to minimize tmux process spawns.
        // Literal text keys are concatenated into one `send-keys -l` call.
        // Special keys are sent as multiple arguments in one `send-keys` call.
        // Delays flush the current batch and insert a sleep.

        var batch: [TmuxKey] = []
        var batchIsLiteral = false

        for key in keys {
            if case let .delay(milliseconds) = key {
                try await flushBatch(paneId: paneId, keys: &batch, literal: batchIsLiteral)
                batchIsLiteral = false
                try await Task.sleep(for: .milliseconds(milliseconds))
                continue
            }

            let isLiteral = key.requiresLiteralMode

            if !batch.isEmpty && isLiteral != batchIsLiteral {
                try await flushBatch(paneId: paneId, keys: &batch, literal: batchIsLiteral)
            }

            batchIsLiteral = isLiteral
            batch.append(key)
        }

        try await flushBatch(paneId: paneId, keys: &batch, literal: batchIsLiteral)
    }

    private func flushBatch(paneId: String, keys: inout [TmuxKey], literal: Bool) async throws {
        guard !keys.isEmpty else { return }

        if literal {
            let text = keys.map(\.tmuxKeyName).joined()
            try await tmuxService.sendKeys(paneId, keys: text, literal: true)
        } else {
            try await tmuxService.sendBatchKeys(paneId, keys: keys.map(\.tmuxKeyName))
        }

        keys.removeAll()
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
