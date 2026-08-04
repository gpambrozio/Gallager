#if canImport(UserNotifications)
    import Foundation
    import UserNotifications

    /// Builds and registers the `UNNotificationCategory` set for actionable
    /// notifications (issue #710). Shared by the iOS app (launch registration,
    /// follow-up question notifications, live-socket fallback notifications)
    /// and the Notification Service Extension (per-push dynamic registration) —
    /// which is why it lives here rather than in an app-only target: the NSE
    /// links only ClaudeSpyNetworking + ClaudeSpyEncryption.
    public enum NotificationActionCategories {
        // MARK: - Static categories (permission)

        /// The fixed permission categories: Yes / Always / No, and the
        /// suggestion-less Yes / No variant. Registered at app launch and
        /// merge-registered defensively by the NSE (covering pushes that arrive
        /// before the app's first launch registration).
        public static var permissionCategories: [UNNotificationCategory] {
            let allow = UNNotificationAction(
                identifier: NotificationActionID.permissionAllow,
                title: "Yes",
                options: [.authenticationRequired]
            )
            let always = UNNotificationAction(
                identifier: NotificationActionID.permissionAlways,
                title: "Always",
                options: [.authenticationRequired]
            )
            let deny = UNNotificationAction(
                identifier: NotificationActionID.permissionDeny,
                title: "No",
                options: [.authenticationRequired, .destructive]
            )
            return [
                UNNotificationCategory(
                    identifier: NotificationCategoryID.permission,
                    actions: [allow, always, deny],
                    intentIdentifiers: []
                ),
                UNNotificationCategory(
                    identifier: NotificationCategoryID.permissionNoAlways,
                    actions: [allow, deny],
                    intentIdentifiers: []
                ),
            ]
        }

        // MARK: - Dynamic categories (questions)

        /// Builds the per-question category: one action per option plus a
        /// free-text "Other…" when the question allows it. Dynamic because the
        /// action titles ARE the option labels.
        public static func questionCategory(
            for question: QuestionActions.Question,
            requestId: String,
            questionIndex: Int
        ) -> UNNotificationCategory {
            var actions: [UNNotificationAction] = question.options.map { option in
                UNNotificationAction(
                    identifier: NotificationActionID.questionOption(option.id),
                    title: option.label,
                    options: [.authenticationRequired]
                )
            }
            if question.allowsFreeText {
                actions.append(UNTextInputNotificationAction(
                    identifier: NotificationActionID.questionOther,
                    title: "Other…",
                    options: [.authenticationRequired],
                    textInputButtonTitle: "Send",
                    textInputPlaceholder: "Your answer"
                ))
            }
            return UNNotificationCategory(
                identifier: NotificationCategoryID.question(
                    requestId: requestId,
                    questionIndex: questionIndex
                ),
                actions: actions,
                intentIdentifiers: []
            )
        }

        /// The category identifier (and any category needing dynamic
        /// registration) for the FIRST notification of an action context.
        /// Permission forms use the static set; question forms return their
        /// question-0 dynamic category.
        public static func initialCategory(
            for context: NotificationActionContext
        ) -> (identifier: String, dynamicCategory: UNNotificationCategory?) {
            switch context.form {
            case let .permission(actions):
                let identifier = actions.alwaysSuggestionID != nil
                    ? NotificationCategoryID.permission
                    : NotificationCategoryID.permissionNoAlways
                return (identifier, nil)

            case let .askUserQuestion(actions):
                // `make` guarantees at least one question.
                let category = questionCategory(
                    for: actions.questions[0],
                    requestId: context.requestId,
                    questionIndex: 0
                )
                return (category.identifier, category)
            }
        }

        // MARK: - Registration

        /// Registers `categories` by merging with the already-registered set
        /// (`setNotificationCategories` REPLACES, so a naive set would strip
        /// actions from every pending notification using another category).
        /// Same-identifier categories are replaced by the new ones.
        public static func registerMerging(
            _ categories: [UNNotificationCategory],
            center: UNUserNotificationCenter = .current()
        ) async {
            let existing = await center.notificationCategories()
            let newIdentifiers = Set(categories.map(\.identifier))
            let kept = existing.filter { !newIdentifiers.contains($0.identifier) }
            center.setNotificationCategories(kept.union(categories))
            // Registration is asynchronous fire-and-forget; give the system a
            // moment to absorb the new set before the caller delivers a
            // notification that references it (well-known NSE workaround).
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
#endif
