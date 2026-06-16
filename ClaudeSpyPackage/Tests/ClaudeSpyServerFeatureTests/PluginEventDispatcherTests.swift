#if os(macOS)
    import ClaudeSpyNetworking
    import Foundation
    import Testing
    @testable import ClaudeSpyServerFeature

    /// Records every sink invocation so a test can assert exactly which fields
    /// fanned out for a given `PluginEvent`. An `actor` so the dispatcher's
    /// `@Sendable` closures can mutate it across isolation domains.
    private actor DispatchRecorder {
        struct State: Equatable {
            let pluginID: String
            let sessionID: String
            let state: AgentState
            let tmuxPane: String?
            let projectPath: String?
            let permissionMode: String?
        }

        struct Notification: Equatable {
            let pluginID: String
            let sessionID: String
            let title: String
            let body: String
        }

        struct AutoApprove: Equatable {
            let pluginID: String
            let sessionID: String
            let requestID: String
        }

        private(set) var states: [State] = []
        private(set) var notifications: [Notification] = []
        private(set) var autoApprovals: [AutoApprove] = []
        private(set) var actions: [AppAction] = []

        func recordState(_ state: State) {
            states.append(state)
        }

        func recordNotification(_ notification: Notification) {
            notifications.append(notification)
        }

        func recordAutoApprove(_ approve: AutoApprove) {
            autoApprovals.append(approve)
        }

        func recordAction(_ action: AppAction) {
            actions.append(action)
        }
    }

    private func makeDispatcher(
        _ recorder: DispatchRecorder,
        yolo: Bool = false
    ) -> PluginEventDispatcher {
        PluginEventDispatcher(
            onState: { pluginID, sessionID, state, tmuxPane, projectPath, permissionMode in
                await recorder.recordState(.init(
                    pluginID: pluginID,
                    sessionID: sessionID,
                    state: state,
                    tmuxPane: tmuxPane,
                    projectPath: projectPath,
                    permissionMode: permissionMode
                ))
            },
            onNotification: { pluginID, sessionID, notification in
                await recorder.recordNotification(.init(
                    pluginID: pluginID,
                    sessionID: sessionID,
                    title: notification.title,
                    body: notification.body
                ))
            },
            onAutoApprove: { pluginID, sessionID, requestID in
                await recorder.recordAutoApprove(.init(
                    pluginID: pluginID,
                    sessionID: sessionID,
                    requestID: requestID
                ))
            },
            onAppAction: { action in
                await recorder.recordAction(action)
            },
            isYoloModeEnabled: { _ in yolo }
        )
    }

    @Suite("PluginEventDispatcher")
    struct PluginEventDispatcherTests {
        @Test("a state opinion fires the state sink with bootstrap fields")
        func stateFiresSink() async {
            let recorder = DispatchRecorder()
            let dispatcher = makeDispatcher(recorder)

            await dispatcher.dispatch(PluginEvent(
                pluginID: "echo",
                sessionID: "s1",
                state: .working,
                tmuxPane: "%3",
                projectPath: "/tmp/proj"
            ))

            let states = await recorder.states
            #expect(states == [
                .init(
                    pluginID: "echo", sessionID: "s1", state: .working,
                    tmuxPane: "%3", projectPath: "/tmp/proj", permissionMode: nil
                ),
            ])
        }

        @Test("a state event carries the hook-seeded permission mode to the state sink")
        func permissionModeFansOut() async {
            let recorder = DispatchRecorder()
            let dispatcher = makeDispatcher(recorder)

            await dispatcher.dispatch(PluginEvent(
                pluginID: "claude-code",
                sessionID: "s1",
                state: .working,
                tmuxPane: "%3",
                permissionMode: "bypassPermissions"
            ))

            let states = await recorder.states
            #expect(states.first?.permissionMode == "bypassPermissions")
        }

        @Test("a nil-state event fires no state sink but still pushes its notification")
        func nilStateNotificationOnly() async {
            let recorder = DispatchRecorder()
            let dispatcher = makeDispatcher(recorder)

            await dispatcher.dispatch(PluginEvent(
                pluginID: "echo",
                sessionID: "s1",
                notification: NotificationSpec(title: "Done", body: "Build finished")
            ))

            let states = await recorder.states
            let notifications = await recorder.notifications
            #expect(states.isEmpty)
            #expect(notifications == [
                .init(pluginID: "echo", sessionID: "s1", title: "Done", body: "Build finished"),
            ])
        }

        @Test("an awaiting state reaches the state sink (opening the form) plus its notification")
        func awaitingStateOpensForm() async {
            let recorder = DispatchRecorder()
            let dispatcher = makeDispatcher(recorder)

            let state = AgentState.awaitingReplies(
                AskUserQuestionRequest(questions: []), requestID: "r1"
            )
            await dispatcher.dispatch(PluginEvent(
                pluginID: "echo",
                sessionID: "s1",
                state: state,
                notification: NotificationSpec(title: "Q", body: "answer me"),
                tmuxPane: "%5"
            ))

            let states = await recorder.states
            let notifications = await recorder.notifications
            #expect(states.count == 1)
            #expect(states.first?.state == state)
            #expect(states.first?.state.openForm?.requestID == "r1")
            #expect(notifications.count == 1)
        }

        @Test("an auto-approvable permission under yolo auto-approves and stays working, suppressing the push")
        func yoloPermissionAutoApproves() async {
            let recorder = DispatchRecorder()
            let dispatcher = makeDispatcher(recorder, yolo: true)

            await dispatcher.dispatch(PluginEvent(
                pluginID: "echo",
                sessionID: "s1",
                state: .awaitingPermission(
                    PermissionRequest(title: "Bash", description: "ls", isAutoApprovable: true),
                    requestID: "r1"
                ),
                notification: NotificationSpec(title: "Perm", body: "approve?"),
                tmuxPane: "%1"
            ))

            let approvals = await recorder.autoApprovals
            let states = await recorder.states
            let notifications = await recorder.notifications
            #expect(approvals == [.init(pluginID: "echo", sessionID: "%1", requestID: "r1")])
            // Yolo kept the session working (the awaiting transition was dropped).
            #expect(states.count == 1)
            #expect(states.first?.state == .working)
            // The notification is suppressed for the silent approval.
            #expect(notifications.isEmpty)
        }

        @Test("an auto-approvable permission WITHOUT yolo opens the form and does not auto-approve")
        func nonYoloPermissionOpensForm() async {
            let recorder = DispatchRecorder()
            let dispatcher = makeDispatcher(recorder, yolo: false)

            let permission = PermissionRequest(title: "Bash", description: "ls", isAutoApprovable: true)
            await dispatcher.dispatch(PluginEvent(
                pluginID: "echo",
                sessionID: "s1",
                state: .awaitingPermission(permission, requestID: "r1"),
                tmuxPane: "%1"
            ))

            let approvals = await recorder.autoApprovals
            let states = await recorder.states
            #expect(approvals.isEmpty)
            #expect(states.first?.state == .awaitingPermission(permission, requestID: "r1"))
        }

        @Test("each app action fires the app-action sink in order")
        func appActionsFanOut() async {
            let recorder = DispatchRecorder()
            let dispatcher = makeDispatcher(recorder)

            let actions: [AppAction] = [
                .openFileSuggestion(sessionID: "s1", path: "/tmp/PLAN.md", displayName: "PLAN.md", isPlan: true, projectDir: nil),
                .dismissFileSuggestions(sessionID: "s1"),
                .sessionEnded(sessionID: "s1", closePaneEligible: true),
            ]
            await dispatcher.dispatch(PluginEvent(pluginID: "echo", sessionID: "s1", appActions: actions))

            let recorded = await recorder.actions
            #expect(recorded == actions)
        }
    }
#endif
