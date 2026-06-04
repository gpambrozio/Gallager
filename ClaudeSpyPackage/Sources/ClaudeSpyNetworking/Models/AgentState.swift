/// The single, agent-blind description of a coding-agent session's current
/// state. Cores emit this directly; `AgentSession` stores exactly one. The open
/// response form, when any, rides the `awaiting*` cases — so it travels to
/// viewers as part of session state with no separate transport.
public enum AgentState: Codable, Sendable, Equatable {
    /// Actively processing.
    case working
    /// Blocked on a plan approval. `requestID` routes the structured answer back.
    case awaitingPlanApproval(ApprovePlanRequest, requestID: String)
    /// Blocked on a tool-use permission.
    case awaitingPermission(PermissionRequest, requestID: String)
    /// Blocked on one or more questions.
    case awaitingReplies(AskUserQuestionRequest, requestID: String)
    /// Stopped (clean or failure); `summary` carries the last message or error.
    case doneWorking(summary: String?)
    /// Fresh session, or one the user has viewed/handled.
    case idle

    /// True while the agent is actively processing (not waiting for input or done).
    public var isActiveWorking: Bool {
        if case .working = self { return true }
        return false
    }

    /// True whenever the session is blocked on a response or has finished and is awaiting the user.
    public var needsAttention: Bool {
        switch self {
        case .working,
             .idle:
            return false
        case .awaitingPlanApproval,
             .awaitingPermission,
             .awaitingReplies,
             .doneWorking:
            return true
        }
    }

    /// The open response form this state represents, if any (the `awaiting*`
    /// cases). Viewers render the form and submit the answer keyed by `requestID`.
    public var openForm: (request: AgentResponseRequest, requestID: String)? {
        switch self {
        case let .awaitingPlanApproval(plan, id): return (.approvePlan(plan), id)
        case let .awaitingPermission(perm, id): return (.permission(perm), id)
        case let .awaitingReplies(q, id): return (.askUserQuestion(q), id)
        case .working,
             .doneWorking,
             .idle: return nil
        }
    }
}
