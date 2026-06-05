import Foundation

// MARK: - AgentResponseRequest

/// The closed, app-defined vocabulary of response forms iOS can render.
///
/// A plugin core translates its agent-specific events into one of these cases
/// (anything outside the set stays Mac-only — no iOS form). iOS renders native
/// SwiftUI from these and never learns which plugin produced them. Any formatted
/// / human-readable strings are rendered **Mac-side by the core**; iOS just
/// displays them.
///
/// This is part of the durable plugin contract (spec §7.1) and is shared by the
/// Mac host, the relay, and the iOS viewer. It must not gain agent-specific
/// cases — new agents map onto the existing five.
public enum AgentResponseRequest: Codable, Sendable, Equatable {
    /// Free-text input (e.g. "send a message to the agent").
    case prompt(PromptRequest)

    /// Reply after the agent has stopped and is waiting for input.
    case replyAfterStop(ReplyAfterStopRequest)

    /// Approve / deny a tool-use permission (+ auto-approve hint & suggestions).
    case permission(PermissionRequest)

    /// One or more questions, each with options, optional multi-select and a
    /// free-text "Other".
    case askUserQuestion(AskUserQuestionRequest)

    /// Approve / reject a plan, optionally with an edited version.
    case approvePlan(ApprovePlanRequest)

    /// Whether this form blocks the agent until the user explicitly responds.
    ///
    /// Permission / question / plan-approval forms block — the agent is stalled
    /// waiting on the answer — so merely *viewing* the session must not clear its
    /// attention (`markSessionHandled` is a no-op while one is open). Prompt and
    /// reply-after-stop are optional input affordances: viewing clears them.
    public var isBlocking: Bool {
        switch self {
        case .prompt,
             .replyAfterStop: false
        case .permission,
             .askUserQuestion,
             .approvePlan: true
        }
    }
}

// MARK: - Prompt

/// Free-text prompt input.
public struct PromptRequest: Codable, Sendable, Equatable {
    /// Display title rendered above the input field (formatted Mac-side).
    public let title: String
    /// Optional placeholder hint for the text field.
    public let placeholder: String?

    public init(title: String, placeholder: String? = nil) {
        self.title = title
        self.placeholder = placeholder
    }
}

// MARK: - Reply after stop

/// Reply offered after the agent stops. Carries an optional summary of what the
/// agent last said (rendered collapsible on iOS). An empty reply means "send
/// nothing, just interrupt".
public struct ReplyAfterStopRequest: Codable, Sendable, Equatable {
    public let title: String
    /// The agent's last assistant message, if any (display-ready).
    public let summary: String?
    public let placeholder: String?

    public init(title: String, summary: String? = nil, placeholder: String? = nil) {
        self.title = title
        self.summary = summary
        self.placeholder = placeholder
    }
}

// MARK: - Permission

/// Approve / deny a tool-use permission request.
public struct PermissionRequest: Codable, Sendable, Equatable {
    /// Short title (e.g. the tool name), formatted Mac-side.
    public let title: String
    /// Human-readable description of what is being requested (formatted Mac-side).
    public let description: String
    /// When `true` and the pane is in yolo mode, the app auto-approves without
    /// showing an iOS form. The core states safety; it never learns about yolo.
    public let isAutoApprovable: Bool
    /// Agent-blind suggestion chips the user can apply. The core maps an applied
    /// id back to its agent-specific action.
    public let suggestions: [PermissionSuggestionOption]
    /// Whether the form offers a free-text "deny with feedback" field.
    public let allowsCustomInstructions: Bool

    public init(
        title: String,
        description: String,
        isAutoApprovable: Bool = false,
        suggestions: [PermissionSuggestionOption] = [],
        allowsCustomInstructions: Bool = false
    ) {
        self.title = title
        self.description = description
        self.isAutoApprovable = isAutoApprovable
        self.suggestions = suggestions
        self.allowsCustomInstructions = allowsCustomInstructions
    }
}

/// One applyable suggestion chip on a permission form. Agent-blind: iOS shows
/// the label/detail and returns the `id`; the core resolves the id.
public struct PermissionSuggestionOption: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let detail: String?

    public init(id: String, label: String, detail: String? = nil) {
        self.id = id
        self.label = label
        self.detail = detail
    }
}

// MARK: - AskUserQuestion

/// One or more questions with options. The core formats all display strings.
public struct AskUserQuestionRequest: Codable, Sendable, Equatable {
    public let questions: [Question]

    public init(questions: [Question]) {
        self.questions = questions
    }

    public struct Question: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let question: String
        /// Short label for chip/tag display.
        public let header: String
        public let options: [Option]
        public let multiSelect: Bool
        /// Whether a free-text "Other" answer is allowed.
        public let allowsFreeText: Bool

        public init(
            id: String,
            question: String,
            header: String,
            options: [Option],
            multiSelect: Bool,
            allowsFreeText: Bool = true
        ) {
            self.id = id
            self.question = question
            self.header = header
            self.options = options
            self.multiSelect = multiSelect
            self.allowsFreeText = allowsFreeText
        }
    }

    public struct Option: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String
        public let description: String
        public let preview: String?

        public init(id: String, label: String, description: String, preview: String? = nil) {
            self.id = id
            self.label = label
            self.description = description
            self.preview = preview
        }
    }
}

// MARK: - Approve plan

/// Approve / reject a plan, optionally with an edited version.
public struct ApprovePlanRequest: Codable, Sendable, Equatable {
    public let title: String
    /// The plan text (markdown), rendered collapsible on iOS.
    public let plan: String
    /// Whether the user may submit an edited plan.
    public let allowsEdit: Bool

    public init(title: String, plan: String, allowsEdit: Bool = false) {
        self.title = title
        self.plan = plan
        self.allowsEdit = allowsEdit
    }
}
