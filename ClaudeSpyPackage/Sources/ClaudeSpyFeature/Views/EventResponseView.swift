import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

// MARK: - Open Response Request → View

extension OpenResponseRequest {
    /// Returns the appropriate `ResponseViews/` view for the wrapped
    /// `AgentResponseRequest`. The closed-set vocabulary (Spec §7.2) means we
    /// always have a concrete UI to show — there's no `nil` return path the
    /// caller has to handle.
    @MainActor
    @ViewBuilder
    func responseView(
        isConnected: Bool,
        submitter: AgentResponseSubmitter
    ) -> some View {
        switch request {
        case let .prompt(body):
            PromptView(
                hostID: hostID,
                sessionID: sessionID,
                pluginID: pluginID,
                requestID: id,
                request: body,
                isConnected: isConnected,
                submitter: submitter
            )
        case let .replyAfterStop(body):
            StopResponseView(
                hostID: hostID,
                sessionID: sessionID,
                pluginID: pluginID,
                requestID: id,
                request: body,
                isConnected: isConnected,
                submitter: submitter
            )
        case let .permission(body):
            PermissionRequestResponseView(
                hostID: hostID,
                sessionID: sessionID,
                pluginID: pluginID,
                requestID: id,
                request: body,
                isConnected: isConnected,
                submitter: submitter
            )
        case let .askUserQuestion(body):
            AskUserQuestionResponseView(
                hostID: hostID,
                sessionID: sessionID,
                pluginID: pluginID,
                requestID: id,
                request: body,
                isConnected: isConnected,
                submitter: submitter
            )
        case let .approvePlan(body):
            ExitPlanModeResponseView(
                hostID: hostID,
                sessionID: sessionID,
                pluginID: pluginID,
                requestID: id,
                request: body,
                isConnected: isConnected,
                submitter: submitter
            )
        }
    }
}
