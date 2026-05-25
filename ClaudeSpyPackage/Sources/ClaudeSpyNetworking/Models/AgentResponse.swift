import Foundation

// MARK: - Agent Response

/// Paired response vocabulary for `AgentResponseRequest`. iOS sends the user's
/// structured choices back; the **plugin sidecar** translates that into
/// whatever its host agent expects (keystrokes, HTTP, MCP, etc.). iOS never
/// builds agent-specific keystrokes itself.
///
/// Encoded on the wire as `{ "type": <case>, "body": <payload> }` with
/// snake_case discriminator values (`"prompt"`, `"reply_after_stop"`,
/// `"permission"`, `"ask_user_question"`, `"approve_plan"`).
public enum AgentResponse: Codable, Sendable, Equatable {
    case prompt(PromptResponse)
    case replyAfterStop(ReplyAfterStopResponse)
    case permission(PermissionResponse)
    case askUserQuestion(AskUserQuestionResponse)
    case approvePlan(ApprovePlanResponse)

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case type
        case body
    }

    private enum ResponseType: String, Codable {
        case prompt
        case replyAfterStop = "reply_after_stop"
        case permission
        case askUserQuestion = "ask_user_question"
        case approvePlan = "approve_plan"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ResponseType.self, forKey: .type)

        switch type {
        case .prompt:
            let body = try container.decode(PromptResponse.self, forKey: .body)
            self = .prompt(body)
        case .replyAfterStop:
            let body = try container.decode(ReplyAfterStopResponse.self, forKey: .body)
            self = .replyAfterStop(body)
        case .permission:
            let body = try container.decode(PermissionResponse.self, forKey: .body)
            self = .permission(body)
        case .askUserQuestion:
            let body = try container.decode(AskUserQuestionResponse.self, forKey: .body)
            self = .askUserQuestion(body)
        case .approvePlan:
            let body = try container.decode(ApprovePlanResponse.self, forKey: .body)
            self = .approvePlan(body)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .prompt(body):
            try container.encode(ResponseType.prompt, forKey: .type)
            try container.encode(body, forKey: .body)
        case let .replyAfterStop(body):
            try container.encode(ResponseType.replyAfterStop, forKey: .type)
            try container.encode(body, forKey: .body)
        case let .permission(body):
            try container.encode(ResponseType.permission, forKey: .type)
            try container.encode(body, forKey: .body)
        case let .askUserQuestion(body):
            try container.encode(ResponseType.askUserQuestion, forKey: .type)
            try container.encode(body, forKey: .body)
        case let .approvePlan(body):
            try container.encode(ResponseType.approvePlan, forKey: .type)
            try container.encode(body, forKey: .body)
        }
    }
}

// MARK: - Prompt

public struct PromptResponse: Codable, Sendable, Equatable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

// MARK: - Reply After Stop

public struct ReplyAfterStopResponse: Codable, Sendable, Equatable {
    /// The reply text. Empty string means "send nothing, just interrupt".
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

// MARK: - Permission

public struct PermissionResponse: Codable, Sendable, Equatable {
    public enum Decision: String, Codable, Sendable {
        case allow
        case deny
    }

    public let decision: Decision

    /// Suggestion ID picked by the user (e.g., "Always allow"). `nil` when the
    /// user chose a default allow/deny without applying a specific rule.
    public let appliedSuggestionId: String?

    public init(decision: Decision, appliedSuggestionId: String?) {
        self.decision = decision
        self.appliedSuggestionId = appliedSuggestionId
    }
}

// MARK: - Ask User Question

public struct AskUserQuestionResponse: Codable, Sendable, Equatable {
    /// One answer per question, in the same order as the request's questions.
    public let answers: [QuestionAnswer]

    public init(answers: [QuestionAnswer]) {
        self.answers = answers
    }

    public struct QuestionAnswer: Codable, Sendable, Equatable {
        /// Indices into the question's `options`.
        public let selectedOptionIndices: [Int]

        /// Free-text answer when the user picked the "Other" path. `nil`
        /// otherwise.
        public let freeText: String?

        public init(selectedOptionIndices: [Int], freeText: String?) {
            self.selectedOptionIndices = selectedOptionIndices
            self.freeText = freeText
        }
    }
}

// MARK: - Approve Plan

public struct ApprovePlanResponse: Codable, Sendable, Equatable {
    public enum Decision: String, Codable, Sendable {
        case approve
        case reject
    }

    public let decision: Decision

    /// Present only if the original request had `allowEdit == true` AND the
    /// user edited the plan.
    public let editedPlan: String?

    public init(decision: Decision, editedPlan: String?) {
        self.decision = decision
        self.editedPlan = editedPlan
    }
}
