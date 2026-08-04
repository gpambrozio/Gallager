#if canImport(UserNotifications)
    import Foundation
    import Testing
    @testable import ClaudeSpyNetworking

    @Suite("NotificationActionCategories")
    struct NotificationActionCategoriesTests {
        @Test("permission contexts map to the matching static category")
        func permissionCategorySelection() {
            let withAlways = NotificationActionContext(
                sessionId: "%1",
                pluginId: "p",
                requestId: "r1",
                form: .permission(PermissionActions(alwaysSuggestionID: "suggestion-0"))
            )
            let without = NotificationActionContext(
                sessionId: "%1",
                pluginId: "p",
                requestId: "r1",
                form: .permission(PermissionActions(alwaysSuggestionID: nil))
            )
            #expect(
                NotificationActionCategories.initialCategory(for: withAlways)?.identifier
                    == NotificationCategoryID.permission
            )
            #expect(
                NotificationActionCategories.initialCategory(for: without)?.identifier
                    == NotificationCategoryID.permissionNoAlways
            )
        }

        @Test("a question form with options builds a dynamic category")
        func questionCategoryBuilt() {
            let context = NotificationActionContext(
                sessionId: "%1",
                pluginId: "p",
                requestId: "r1",
                form: .askUserQuestion(QuestionActions(questions: [
                    QuestionActions.Question(
                        id: "q0",
                        question: "Pick",
                        options: [QuestionActions.Option(id: "q0-o0", label: "A")],
                        allowsFreeText: true
                    ),
                ]))
            )
            let result = NotificationActionCategories.initialCategory(for: context)
            #expect(result?.identifier == NotificationCategoryID.question(requestId: "r1", questionIndex: 0))
            let actionIds = result?.dynamicCategory?.actions.map(\.identifier)
            #expect(actionIds == [
                NotificationActionID.questionOption("q0-o0"),
                NotificationActionID.questionOther,
            ])
        }

        @Test("an empty wire-decoded question list degrades to no category instead of crashing")
        func emptyQuestionsDegrade() {
            // `make` never emits this, but both callers feed contexts decoded
            // off the wire — a buggy or version-skewed host must not crash the
            // NSE (issue #710 review).
            let context = NotificationActionContext(
                sessionId: "%1",
                pluginId: "p",
                requestId: "r1",
                form: .askUserQuestion(QuestionActions(questions: []))
            )
            #expect(NotificationActionCategories.initialCategory(for: context) == nil)
        }
    }
#endif
