import Foundation
import Logging
import ClaudeSpyCommon

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
            "type": "\(command.type)",
            "paneId": "\(command.paneId)",
        ])

        do {
            switch command.type {
            case .sendKeystroke:
                try await executeSendKeystroke(command)

            case .cancelOperation:
                try await executeCancelOperation(command)

            case .pauseMirror:
                // Pause mirror is handled at a higher level (MirrorWindowManager)
                // Just acknowledge it here
                logger.info("Pause mirror command received")

            case .resumeMirror:
                // Resume mirror is handled at a higher level (MirrorWindowManager)
                // Just acknowledge it here
                logger.info("Resume mirror command received")

            case .captureSnapshot:
                // Snapshot is handled specially - returns success here, data sent separately
                logger.info("Capture snapshot command received (will be handled by caller)")
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

    private func executeSendKeystroke(_ command: CommandMessage) async throws {
        guard let keysValue = command.payload["keys"],
              case let .string(keys) = keysValue.value
        else {
            throw CommandError.invalidPayload("Missing 'keys' in payload")
        }

        // Determine if we should send literally or interpret key names
        let literal: Bool
        if let literalValue = command.payload["literal"],
           case let .bool(literalBool) = literalValue.value
        {
            literal = literalBool
        } else {
            // Default: interpret key names for special keys, literal for regular text
            literal = !containsSpecialKeyNames(keys)
        }

        try await tmuxService.sendKeys(command.paneId, keys: keys, literal: literal)
    }

    private func executeCancelOperation(_ command: CommandMessage) async throws {
        try await tmuxService.sendInterrupt(command.paneId)
    }

    // MARK: - Helpers

    /// Check if the string contains tmux special key names
    private func containsSpecialKeyNames(_ keys: String) -> Bool {
        let specialKeys = [
            "Enter", "Escape", "Tab", "Space",
            "Up", "Down", "Left", "Right",
            "Home", "End", "PageUp", "PageDown",
            "BSpace", "Delete", "Insert",
            "C-", "M-", "S-",  // Ctrl, Meta/Alt, Shift prefixes
            "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
        ]
        return specialKeys.contains { keys.contains($0) }
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
