import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

/// Closure type for sending commands from response views.
/// Takes a CommandType directly - the calling view adds the paneId when sending.
typealias CommandSender = @MainActor (CommandType) async -> Void

// MARK: - Event Response Extension

extension HookEvent {
    /// Returns a contextual response view based on the event type, or nil if no response UI is needed.
    @MainActor
    func responseView(
        isYoloMode: Bool,
        isConnected: Bool,
        sendCommand: @escaping CommandSender,
        state: ResponseState
    ) -> AnyView? {
        switch action {
        case .sessionStart:
            return AnyView(PromptView(isConnected: isConnected, sendCommand: sendCommand, state: state))
        case let .stop(body):
            return AnyView(StopResponseView(
                lastAssistantMessage: body.lastAssistantMessage,
                isConnected: isConnected,
                sendCommand: sendCommand,
                state: state
            ))
        case let .permissionRequest(body):
            // In yolo mode, skip the response UI for auto-approvable events
            // (the host auto-sends Enter after 500ms)
            if isYoloMode, body.isYoloAutoApprovable {
                return nil
            }
            // Check for special tool types that need dedicated UIs
            if let toolInput = body.toolInput {
                switch toolInput {
                case let .askUserQuestion(params):
                    return AnyView(AskUserQuestionResponseView(
                        params: params,
                        isConnected: isConnected,
                        sendCommand: sendCommand,
                        state: state
                    ))
                case let .exitPlanMode(params):
                    return AnyView(ExitPlanModeResponseView(
                        params: params,
                        isConnected: isConnected,
                        sendCommand: sendCommand,
                        state: state
                    ))
                default:
                    break
                }
            }
            return AnyView(PermissionRequestResponseView(
                request: body,
                isConnected: isConnected,
                sendCommand: sendCommand,
                state: state
            ))
        case .setup,
             .sessionEnd,
             .preToolUse,
             .postToolUse,
             .postToolUseFailure,
             .postToolBatch,
             .permissionDenied,
             .notification,
             .userPromptSubmit,
             .userPromptExpansion,
             .stopFailure,
             .subagentStart,
             .subagentStop,
             .teammateIdle,
             .taskCreated,
             .taskCompleted,
             .preCompact,
             .postCompact,
             .instructionsLoaded,
             .configChange,
             .cwdChanged,
             .fileChanged,
             .elicitation,
             .elicitationResult,
             .worktreeCreate,
             .worktreeRemove,
             .unknown:
            return nil
        }
    }
}
