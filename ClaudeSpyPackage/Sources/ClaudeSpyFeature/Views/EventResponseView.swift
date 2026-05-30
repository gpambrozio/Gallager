import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

/// Closure the response views call to submit a structured `AgentResponse` back
/// to the host (which routes it to `core.deliverResponse`). iOS sends structured
/// choices only — it never builds agent-specific keystrokes (spec §7.1).
typealias ResponseSender = @MainActor (AgentResponse) async -> Void

// MARK: - Agent Response Request → View

extension AgentResponseRequest {
    /// Returns the contextual response view for this request's case. The five
    /// closed cases map 1:1 onto the existing iOS forms (spec §7.1).
    @MainActor
    func responseView(
        isConnected: Bool,
        submit: @escaping ResponseSender,
        state: ResponseState
    ) -> AnyView {
        switch self {
        case let .prompt(promptRequest):
            return AnyView(PromptView(
                request: promptRequest,
                isConnected: isConnected,
                submit: submit,
                state: state
            ))
        case let .replyAfterStop(replyRequest):
            return AnyView(StopResponseView(
                request: replyRequest,
                isConnected: isConnected,
                submit: submit,
                state: state
            ))
        case let .permission(permissionRequest):
            return AnyView(PermissionRequestResponseView(
                request: permissionRequest,
                isConnected: isConnected,
                submit: submit,
                state: state
            ))
        case let .askUserQuestion(questionRequest):
            return AnyView(AskUserQuestionResponseView(
                request: questionRequest,
                isConnected: isConnected,
                submit: submit,
                state: state
            ))
        case let .approvePlan(planRequest):
            return AnyView(ExitPlanModeResponseView(
                request: planRequest,
                isConnected: isConnected,
                submit: submit,
                state: state
            ))
        }
    }
}
