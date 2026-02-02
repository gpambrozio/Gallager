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
        isConnected: Bool,
        sendCommand: @escaping CommandSender,
        state: ResponseState
    ) -> AnyView? {
        switch action {
        case .sessionStart,
             .stop:
            return AnyView(PromptView(isConnected: isConnected, sendCommand: sendCommand, state: state))
        case let .permissionRequest(body):
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
        default:
            return nil
        }
    }
}
