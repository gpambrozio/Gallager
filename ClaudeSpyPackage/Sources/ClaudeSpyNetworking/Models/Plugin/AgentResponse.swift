import Foundation

// MARK: - AgentResponse

/// The structured response iOS sends back for a previously-emitted
/// `AgentResponseRequest`, correlated by `requestID`. iOS sends **structured**
/// choices only; the owning plugin core translates them into agent-specific
/// keystrokes / HTTP / etc. iOS never builds agent-specific keystrokes.
///
/// Part of the durable plugin contract (spec §7.1).
public enum AgentResponse: Codable, Sendable, Equatable {
    /// Free-text prompt submission.
    case prompt(text: String)

    /// Reply after stop. An empty string means "send nothing, just interrupt".
    case replyAfterStop(text: String)

    /// A permission decision plus the id of an applied suggestion, if any.
    case permission(decision: PermissionDecision, appliedSuggestionID: String?)

    /// Answers to each question in an `AskUserQuestionRequest`.
    case askUserQuestion(answers: [QuestionAnswer])

    /// A plan decision plus an edited plan, if the user edited it.
    case approvePlan(decision: PlanDecision, editedPlan: String?)
}

/// The user's decision on a permission request.
public enum PermissionDecision: Codable, Sendable, Equatable {
    case allow
    case deny
    /// Deny while sending the agent free-text feedback / instructions.
    case denyWithFeedback(String)
}

/// The user's decision on a plan.
public enum PlanDecision: String, Codable, Sendable, Equatable {
    case approve
    case reject
}

/// The user's answer to one question in an `AskUserQuestionRequest`.
public struct QuestionAnswer: Codable, Sendable, Equatable {
    public let questionID: String
    /// Ids of the options the user selected (one for single-select, 0+ for
    /// multi-select).
    public let selectedOptionIDs: [String]
    /// Free-text "Other" answer, if the user provided one.
    public let freeText: String?

    public init(questionID: String, selectedOptionIDs: [String], freeText: String? = nil) {
        self.questionID = questionID
        self.selectedOptionIDs = selectedOptionIDs
        self.freeText = freeText
    }
}
