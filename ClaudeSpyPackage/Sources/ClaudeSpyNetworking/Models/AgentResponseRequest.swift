import Foundation

// MARK: - Agent Response Request

/// Closed-set response vocabulary that iOS understands. Plugin sidecars
/// translate their agent-specific events into one of these shapes when
/// forwarding to iOS for user interaction.
///
/// Encoded on the wire as `{ "type": <case>, "body": <payload> }` with
/// snake_case discriminator values (`"prompt"`, `"reply_after_stop"`,
/// `"permission"`, `"ask_user_question"`, `"approve_plan"`).
public enum AgentResponseRequest: Codable, Sendable, Equatable {
    /// Free-text prompt input (today's PromptView).
    case prompt(PromptRequest)

    /// Reply to the agent after it stops (today's StopResponseView).
    case replyAfterStop(ReplyAfterStopRequest)

    /// Approve / deny an action, possibly applying a specific permission rule.
    case permission(PermissionRequest)

    /// Pick from a structured list of options — possibly multiple questions in
    /// one prompt. Today's AskUserQuestionResponseView.
    case askUserQuestion(AskUserQuestionRequest)

    /// Approve / reject (and optionally edit) a multi-step plan.
    /// Today's ExitPlanModeResponseView.
    case approvePlan(ApprovePlanRequest)

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case type
        case body
    }

    private enum RequestType: String, Codable {
        case prompt
        case replyAfterStop = "reply_after_stop"
        case permission
        case askUserQuestion = "ask_user_question"
        case approvePlan = "approve_plan"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(RequestType.self, forKey: .type)

        switch type {
        case .prompt:
            let body = try container.decode(PromptRequest.self, forKey: .body)
            self = .prompt(body)
        case .replyAfterStop:
            let body = try container.decode(ReplyAfterStopRequest.self, forKey: .body)
            self = .replyAfterStop(body)
        case .permission:
            let body = try container.decode(PermissionRequest.self, forKey: .body)
            self = .permission(body)
        case .askUserQuestion:
            let body = try container.decode(AskUserQuestionRequest.self, forKey: .body)
            self = .askUserQuestion(body)
        case .approvePlan:
            let body = try container.decode(ApprovePlanRequest.self, forKey: .body)
            self = .approvePlan(body)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .prompt(body):
            try container.encode(RequestType.prompt, forKey: .type)
            try container.encode(body, forKey: .body)
        case let .replyAfterStop(body):
            try container.encode(RequestType.replyAfterStop, forKey: .type)
            try container.encode(body, forKey: .body)
        case let .permission(body):
            try container.encode(RequestType.permission, forKey: .type)
            try container.encode(body, forKey: .body)
        case let .askUserQuestion(body):
            try container.encode(RequestType.askUserQuestion, forKey: .type)
            try container.encode(body, forKey: .body)
        case let .approvePlan(body):
            try container.encode(RequestType.approvePlan, forKey: .type)
            try container.encode(body, forKey: .body)
        }
    }
}

// MARK: - Prompt

/// Free-text prompt input. iOS shows a text editor.
public struct PromptRequest: Codable, Sendable, Equatable {
    /// Placeholder copy for the input field, e.g., "Send a message to Claude...".
    public let placeholder: String?

    public init(placeholder: String?) {
        self.placeholder = placeholder
    }
}

// MARK: - Reply After Stop

/// Reply to the agent after it stops. iOS shows the last assistant message and
/// a reply text field (or "send nothing" submit path).
public struct ReplyAfterStopRequest: Codable, Sendable, Equatable {
    /// The last message from the assistant, if any. iOS renders as preview text.
    public let lastAssistantMessage: String?

    public init(lastAssistantMessage: String?) {
        self.lastAssistantMessage = lastAssistantMessage
    }
}

// MARK: - Permission

/// Approve / deny an action, possibly applying a specific permission rule.
/// `description` is rendered to plain text BY THE SIDECAR; iOS just displays.
public struct PermissionRequest: Codable, Sendable, Equatable {
    /// Tool name (e.g. "Bash", "Read"), if known. Optional.
    public let toolName: String?

    /// Plain-text description rendered by the sidecar. iOS displays verbatim.
    public let description: String

    /// User-selectable suggestions ("Allow once", "Always allow", ...).
    public let suggestions: [Suggestion]

    /// Sidecar's judgment that this action is safe for yolo mode. When `true`
    /// AND the user has yolo on for this pane, the Mac auto-approves without
    /// ever showing the iOS form. The sidecar doesn't know about yolo; it just
    /// states safety.
    public let isAutoApprovable: Bool

    public init(
        toolName: String?,
        description: String,
        suggestions: [Suggestion],
        isAutoApprovable: Bool
    ) {
        self.toolName = toolName
        self.description = description
        self.suggestions = suggestions
        self.isAutoApprovable = isAutoApprovable
    }

    /// One selectable permission suggestion (e.g., "Allow once",
    /// "Always allow") shown by the iOS permission form.
    ///
    /// Nested inside `PermissionRequest` to avoid colliding with the legacy
    /// top-level `PermissionSuggestion` in `HookModels.swift`, which is deleted
    /// in a later task of the plugin migration.
    public struct Suggestion: Codable, Sendable, Equatable {
        /// Sidecar-defined identifier; opaque to iOS. Round-trips back to the
        /// sidecar via `PermissionResponse.appliedSuggestionId`.
        public let id: String

        /// Human-readable label ("Allow once").
        public let label: String

        /// Optional emphasis badge ("ALWAYS", "THIS SESSION", ...).
        public let badge: String?

        public init(id: String, label: String, badge: String?) {
            self.id = id
            self.label = label
            self.badge = badge
        }
    }
}

// MARK: - Ask User Question

/// Pick from a structured list of options — possibly multiple questions in one
/// prompt. iOS renders this as a multi-step picker.
public struct AskUserQuestionRequest: Codable, Sendable, Equatable {
    /// One or more questions to answer. iOS walks them in order.
    public let questions: [Question]

    public init(questions: [Question]) {
        self.questions = questions
    }

    public struct Question: Codable, Sendable, Equatable {
        /// The question prompt text.
        public let prompt: String

        /// Selectable answer options.
        public let options: [Option]

        /// Whether the user can select multiple options.
        public let allowMultiple: Bool

        /// Whether iOS exposes an "Other" free-text field handled uniformly.
        public let allowFreeText: Bool

        public init(prompt: String, options: [Option], allowMultiple: Bool, allowFreeText: Bool) {
            self.prompt = prompt
            self.options = options
            self.allowMultiple = allowMultiple
            self.allowFreeText = allowFreeText
        }
    }

    public struct Option: Codable, Sendable, Equatable {
        /// Display label for this option.
        public let label: String

        /// Optional descriptive subtitle.
        public let detail: String?

        public init(label: String, detail: String?) {
            self.label = label
            self.detail = detail
        }
    }
}

// MARK: - Approve Plan

/// Approve / reject (and optionally edit) a multi-step plan. iOS renders the
/// plan as text; if `allowEdit` is true, the UI exposes an editable text area.
public struct ApprovePlanRequest: Codable, Sendable, Equatable {
    /// Plan text (markdown allowed; iOS renders as text).
    public let plan: String

    /// Whether the iOS UI exposes an editable text area.
    public let allowEdit: Bool

    public init(plan: String, allowEdit: Bool) {
        self.plan = plan
        self.allowEdit = allowEdit
    }
}
