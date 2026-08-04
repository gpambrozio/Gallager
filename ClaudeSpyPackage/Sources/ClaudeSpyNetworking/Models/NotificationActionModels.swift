import Foundation

// MARK: - NotificationActionContext

/// Everything an iOS notification needs to answer an open response form
/// straight from its action buttons, without opening the app (issue #710).
///
/// Built Mac-side from the `awaiting*` `AgentState` that accompanies a
/// permission / question notification, and carried inside the encrypted
/// `NotificationContent` (APNs path) and `AgentNotificationMessage`
/// (live-socket fallback path). iOS turns it into notification categories and,
/// on an action tap, into the same `AgentResponseSubmissionMessage` the in-app
/// forms produce. The relay never sees it.
public struct NotificationActionContext: Codable, Sendable, Equatable {
    /// The session id to submit the answer under — the tmux pane id, exactly
    /// what the in-app forms send as `AgentResponseSubmissionMessage.sessionId`.
    public let sessionId: String

    /// The plugin that owns the form (routes `deliverResponse` on the host).
    public let pluginId: String

    /// Correlates the answer with the open form. The host drops submissions
    /// whose id no longer matches the pane's open form, so acting on a stale
    /// lock-screen notification is safe.
    public let requestId: String

    /// The form-specific action set.
    public let form: Form

    /// The action set a notification can offer for one open form. Only the
    /// forms that map cleanly onto notification buttons are represented;
    /// everything else stays a plain tap-to-open notification.
    public enum Form: Codable, Sendable, Equatable {
        /// Yes / Always / No buttons for a tool-use permission.
        case permission(PermissionActions)
        /// Per-option buttons, one question at a time.
        case askUserQuestion(QuestionActions)
    }

    public init(sessionId: String, pluginId: String, requestId: String, form: Form) {
        self.sessionId = sessionId
        self.pluginId = pluginId
        self.requestId = requestId
        self.form = form
    }
}

// MARK: - Permission actions

/// Action payload for a permission form: Yes and No are implicit; "Always"
/// applies a permission suggestion when the request carried one.
public struct PermissionActions: Codable, Sendable, Equatable {
    /// The suggestion id the "Always" button applies (the first suggestion —
    /// the same one the in-terminal menu binds to option 2). `nil` means the
    /// request carried no suggestions and the notification offers Yes / No only.
    public let alwaysSuggestionID: String?

    public init(alwaysSuggestionID: String?) {
        self.alwaysSuggestionID = alwaysSuggestionID
    }
}

// MARK: - Question actions

/// Action payload for an AskUserQuestion form, trimmed for the APNs size
/// budget: option labels only — descriptions and previews stay in-app.
/// Only built when every question is single-select (multi-select can't be
/// expressed with notification buttons).
public struct QuestionActions: Codable, Sendable, Equatable {
    public struct Question: Codable, Sendable, Equatable {
        public let id: String
        /// The question text (truncated), used as the follow-up notification body.
        public let question: String
        public let options: [Option]
        /// Whether the question offers a free-text "Other" answer.
        public let allowsFreeText: Bool

        public init(id: String, question: String, options: [Option], allowsFreeText: Bool) {
            self.id = id
            self.question = question
            self.options = options
            self.allowsFreeText = allowsFreeText
        }
    }

    public struct Option: Codable, Sendable, Equatable {
        public let id: String
        public let label: String

        public init(id: String, label: String) {
            self.id = id
            self.label = label
        }
    }

    public let questions: [Question]

    public init(questions: [Question]) {
        self.questions = questions
    }
}

// MARK: - Building from AgentState

extension NotificationActionContext {
    /// Truncation limits keeping the encrypted push payload well inside the
    /// APNs 4 KB budget. Labels/questions beyond these render with an ellipsis.
    public enum Limits {
        public static let questionLength = 150
        public static let optionLabelLength = 60
        public static let maxOptionsPerQuestion = 6
        /// The whole encoded context must fit this many bytes or the
        /// notification falls back to plain tap-to-open.
        ///
        /// Sized for the APNs envelope's DOUBLE base64: the context rides in
        /// the `NotificationContent` JSON (plaintext P ≈ context + title/body/
        /// ids, worst-case ~950 bytes without the context), which is sealed
        /// (+28 bytes) and base64'd into `EncryptedPayload.ciphertext`, whose
        /// JSON is base64'd AGAIN into the push's `encrypted` field — ~1.78×P
        /// total, plus ~300 bytes of `aps`/`pairId` envelope. At 1200 the
        /// worst-case push stays ≈ 3.6 KB < 4096; an oversized push is
        /// rejected wholesale by APNs (the user would get NO notification),
        /// so this errs low. Verified end-to-end by
        /// `NotificationActionWireTests.worstCaseAPNsEnvelopeFitsBudget`.
        public static let maxEncodedBytes = 1200
    }

    /// Builds the action context for a notification that accompanies `state`,
    /// or `nil` when the state carries no form that maps onto notification
    /// buttons (plain notification).
    public static func make(
        state: AgentState,
        sessionId: String,
        pluginId: String
    ) -> NotificationActionContext? {
        let context: NotificationActionContext?
        switch state {
        case let .awaitingPermission(request, requestID):
            context = NotificationActionContext(
                sessionId: sessionId,
                pluginId: pluginId,
                requestId: requestID,
                form: .permission(PermissionActions(
                    alwaysSuggestionID: request.suggestions.first?.id
                ))
            )

        case let .awaitingReplies(request, requestID):
            guard let questions = questionActions(from: request) else { return nil }
            context = NotificationActionContext(
                sessionId: sessionId,
                pluginId: pluginId,
                requestId: requestID,
                form: .askUserQuestion(questions)
            )

        case .working,
             .awaitingPlanApproval,
             .doneWorking,
             .idle:
            context = nil
        }

        // Enforce the payload budget: an oversized context degrades to a plain
        // notification instead of risking APNs rejecting the whole push.
        guard
            let context,
            let encoded = try? JSONEncoder().encode(context),
            encoded.count <= Limits.maxEncodedBytes
        else { return nil }
        return context
    }

    /// Maps the full request onto the trimmed notification form, or `nil` when
    /// the questions can't be answered with buttons (any multi-select, or a
    /// question with no options and no free-text path).
    private static func questionActions(from request: AskUserQuestionRequest) -> QuestionActions? {
        guard !request.questions.isEmpty else { return nil }
        var questions: [QuestionActions.Question] = []
        for question in request.questions {
            guard !question.multiSelect else { return nil }
            guard !question.options.isEmpty || question.allowsFreeText else { return nil }
            guard question.options.count <= Limits.maxOptionsPerQuestion else { return nil }
            questions.append(QuestionActions.Question(
                id: question.id,
                question: question.question.truncated(to: Limits.questionLength),
                options: question.options.map {
                    QuestionActions.Option(
                        id: $0.id,
                        label: $0.label.truncated(to: Limits.optionLabelLength)
                    )
                },
                allowsFreeText: question.allowsFreeText
            ))
        }
        return QuestionActions(questions: questions)
    }
}

private extension String {
    /// Truncates to `limit` characters, appending an ellipsis when trimmed.
    func truncated(to limit: Int) -> String {
        guard count > limit else { return self }
        return String(prefix(limit)) + "…"
    }
}

// MARK: - NotificationActionProgress

/// Where a multi-question notification flow currently stands. Rides in the
/// follow-up local notification's `userInfo` (never on the wire), so the flow
/// survives the app being relaunched between questions with no local storage.
public struct NotificationActionProgress: Codable, Sendable, Equatable {
    /// Index into `QuestionActions.questions` of the question the notification
    /// carrying this progress is asking.
    public let questionIndex: Int

    /// Answers accumulated for questions before `questionIndex`.
    public let answers: [QuestionAnswer]

    public init(questionIndex: Int, answers: [QuestionAnswer]) {
        self.questionIndex = questionIndex
        self.answers = answers
    }
}

// MARK: - Identifiers

/// The `UNNotificationAction` identifiers used by actionable notifications.
/// Pure strings so the (Linux-built) relay target compiles them fine.
public enum NotificationActionID {
    public static let permissionAllow = "gallager.permission.allow"
    public static let permissionAlways = "gallager.permission.always"
    public static let permissionDeny = "gallager.permission.deny"
    /// Free-text "Other" answer for the current question.
    public static let questionOther = "gallager.question.other"
    /// Prefix for per-option actions: `"gallager.question.option.<optionId>"`.
    public static let questionOptionPrefix = "gallager.question.option."

    /// Builds the action id selecting `optionId` on the current question.
    public static func questionOption(_ optionId: String) -> String {
        questionOptionPrefix + optionId
    }

    /// Extracts the option id from a per-option action identifier, or `nil`
    /// when the identifier is not a question-option action.
    public static func optionId(fromActionIdentifier identifier: String) -> String? {
        guard identifier.hasPrefix(questionOptionPrefix) else { return nil }
        let id = String(identifier.dropFirst(questionOptionPrefix.count))
        return id.isEmpty ? nil : id
    }
}

/// The `UNNotificationCategory` identifiers used by actionable notifications.
public enum NotificationCategoryID {
    /// Permission form with an "Always" suggestion: Yes / Always / No.
    public static let permission = "gallager.permission"
    /// Permission form without suggestions: Yes / No.
    public static let permissionNoAlways = "gallager.permission.no-always"
    /// Prefix shared by all dynamically-registered question categories, so
    /// registration merges can tell them apart from the static set.
    public static let questionPrefix = "gallager.question."

    /// The per-question category id. Unique per request AND question so a
    /// follow-up question's actions never collide with an earlier delivery.
    public static func question(requestId: String, questionIndex: Int) -> String {
        "\(questionPrefix)\(requestId).q\(questionIndex)"
    }
}

/// Shared `userInfo` keys for actionable notifications (NSE → app, and app →
/// follow-up local notifications).
public enum NotificationUserInfoKey {
    /// JSON-encoded `NotificationActionContext`.
    public static let actionContext = "actionContext"
    /// JSON-encoded `NotificationActionProgress` (question flows only).
    public static let actionProgress = "actionProgress"
}

// MARK: - NotificationActionPlanner

/// Pure decision logic for an action tapped on a notification: maps the tapped
/// action identifier (plus accumulated progress) to either a submission or the
/// next question to ask. Stateless and platform-neutral so it is unit-testable
/// everywhere; the iOS service executes the returned plan.
public enum NotificationActionPlanner {
    /// What the app should do after an action tap.
    public enum Plan: Equatable, Sendable {
        /// Submit this response for the context's request.
        case submit(AgentResponse)
        /// Ask the next question via a follow-up local notification.
        case nextQuestion(index: Int, progress: NotificationActionProgress)
    }

    /// Plans the reaction to `actionIdentifier`, or `nil` when the identifier
    /// is not one of ours (default tap / dismiss / unknown) or doesn't apply
    /// to the form — the caller falls back to the regular tap behavior.
    ///
    /// - Parameters:
    ///   - context: The action context from the notification's `userInfo`.
    ///   - progress: Question-flow progress, `nil` on the first question.
    ///   - actionIdentifier: `UNNotificationResponse.actionIdentifier`.
    ///   - userText: Text from a `UNTextInputNotificationResponse`, if any.
    public static func plan(
        context: NotificationActionContext,
        progress: NotificationActionProgress?,
        actionIdentifier: String,
        userText: String?
    ) -> Plan? {
        switch context.form {
        case let .permission(actions):
            return permissionPlan(actions: actions, actionIdentifier: actionIdentifier)
        case let .askUserQuestion(actions):
            return questionPlan(
                actions: actions,
                progress: progress,
                actionIdentifier: actionIdentifier,
                userText: userText
            )
        }
    }

    private static func permissionPlan(
        actions: PermissionActions,
        actionIdentifier: String
    ) -> Plan? {
        switch actionIdentifier {
        case NotificationActionID.permissionAllow:
            return .submit(.permission(decision: .allow, appliedSuggestionID: nil))
        case NotificationActionID.permissionAlways:
            // Degrade to a plain allow if the context somehow lost its
            // suggestion — never drop an explicit approval on the floor.
            return .submit(.permission(
                decision: .allow,
                appliedSuggestionID: actions.alwaysSuggestionID
            ))
        case NotificationActionID.permissionDeny:
            return .submit(.permission(decision: .deny, appliedSuggestionID: nil))
        default:
            return nil
        }
    }

    private static func questionPlan(
        actions: QuestionActions,
        progress: NotificationActionProgress?,
        actionIdentifier: String,
        userText: String?
    ) -> Plan? {
        let index = progress?.questionIndex ?? 0
        guard actions.questions.indices.contains(index) else { return nil }
        let question = actions.questions[index]

        let answer: QuestionAnswer
        if actionIdentifier == NotificationActionID.questionOther {
            let trimmed = userText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard question.allowsFreeText, !trimmed.isEmpty else { return nil }
            answer = QuestionAnswer(questionID: question.id, selectedOptionIDs: [], freeText: trimmed)
        } else if let optionId = NotificationActionID.optionId(fromActionIdentifier: actionIdentifier) {
            guard question.options.contains(where: { $0.id == optionId }) else { return nil }
            answer = QuestionAnswer(questionID: question.id, selectedOptionIDs: [optionId])
        } else {
            return nil
        }

        let answers = (progress?.answers ?? []) + [answer]
        let nextIndex = index + 1
        if actions.questions.indices.contains(nextIndex) {
            return .nextQuestion(
                index: nextIndex,
                progress: NotificationActionProgress(questionIndex: nextIndex, answers: answers)
            )
        }
        return .submit(.askUserQuestion(answers: answers))
    }
}
