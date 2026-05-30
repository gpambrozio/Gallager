#if os(macOS)
    import ClaudeSpyNetworking
    import Foundation
    import Testing
    @testable import ClaudeSpyServerFeature

    /// Records every sink invocation so a test can assert exactly which fields
    /// fanned out for a given `PluginEvent`. An `actor` so the dispatcher's
    /// `@Sendable` closures can mutate it across isolation domains.
    private actor DispatchRecorder {
        struct Status: Equatable {
            let pluginID: String
            let sessionID: String
            let working: Bool?
            let attention: Bool
            let tmuxPane: String?
            let projectPath: String?
        }

        struct Notification: Equatable {
            let pluginID: String
            let sessionID: String
            let title: String
            let body: String
        }

        struct OpenRequest: Equatable {
            let pluginID: String
            let sessionID: String
            let requestID: String
        }

        struct RetractRequest: Equatable {
            let pluginID: String
            let sessionID: String
            let requestID: String
        }

        private(set) var statuses: [Status] = []
        private(set) var notifications: [Notification] = []
        private(set) var opens: [OpenRequest] = []
        private(set) var retracts: [RetractRequest] = []
        private(set) var openedRequests: [AgentResponseRequest] = []
        private(set) var actions: [AppAction] = []

        func recordStatus(_ status: Status) {
            statuses.append(status)
        }

        func recordNotification(_ notification: Notification) {
            notifications.append(notification)
        }

        func recordOpen(_ open: OpenRequest, request: AgentResponseRequest) {
            opens.append(open)
            openedRequests.append(request)
        }

        func recordRetract(_ retract: RetractRequest) {
            retracts.append(retract)
        }

        func recordAction(_ action: AppAction) {
            actions.append(action)
        }
    }

    private func makeDispatcher(_ recorder: DispatchRecorder) -> PluginEventDispatcher {
        PluginEventDispatcher(
            onStatus: { pluginID, sessionID, working, attention, tmuxPane, projectPath in
                await recorder.recordStatus(.init(
                    pluginID: pluginID,
                    sessionID: sessionID,
                    working: working,
                    attention: attention,
                    tmuxPane: tmuxPane,
                    projectPath: projectPath
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
            onOpenResponseRequest: { pluginID, sessionID, requestID, request in
                await recorder.recordOpen(
                    .init(pluginID: pluginID, sessionID: sessionID, requestID: requestID),
                    request: request
                )
            },
            onRetractResponseRequest: { pluginID, sessionID, requestID in
                await recorder.recordRetract(.init(pluginID: pluginID, sessionID: sessionID, requestID: requestID))
            },
            onAppAction: { action in
                await recorder.recordAction(action)
            }
        )
    }

    @Suite("PluginEventDispatcher")
    struct PluginEventDispatcherTests {
        @Test("working set fires the status sink with the working value and bootstrap fields")
        func workingFiresStatus() async {
            let recorder = DispatchRecorder()
            let dispatcher = makeDispatcher(recorder)

            await dispatcher.dispatch(PluginEvent(
                pluginID: "echo",
                sessionID: "s1",
                working: true,
                tmuxPane: "%3",
                projectPath: "/tmp/proj"
            ))

            let statuses = await recorder.statuses
            #expect(statuses == [
                .init(pluginID: "echo", sessionID: "s1", working: true, attention: false, tmuxPane: "%3", projectPath: "/tmp/proj"),
            ])
        }

        @Test("attention change fires status even when working is nil")
        func attentionChangeFiresStatus() async {
            let recorder = DispatchRecorder()
            let dispatcher = makeDispatcher(recorder)

            // First event: attention true, no working opinion → status fires (change from default false).
            await dispatcher.dispatch(PluginEvent(pluginID: "echo", sessionID: "s1", attention: true))
            // Second event: attention still true, no working → NO status (no change).
            await dispatcher.dispatch(PluginEvent(pluginID: "echo", sessionID: "s1", attention: true))
            // Third event: attention false, no working → status fires (change back).
            await dispatcher.dispatch(PluginEvent(pluginID: "echo", sessionID: "s1", attention: false))

            let statuses = await recorder.statuses
            #expect(statuses.count == 2)
            #expect(statuses.first?.attention == true)
            #expect(statuses.last?.attention == false)
        }

        @Test("event with no working opinion and unchanged attention does not fire status")
        func noOpinionNoChangeIsSilent() async {
            let recorder = DispatchRecorder()
            let dispatcher = makeDispatcher(recorder)

            // attention defaults to false; first event establishes false; a second
            // identical event should not re-fire status (working nil, attention unchanged).
            await dispatcher.dispatch(PluginEvent(pluginID: "echo", sessionID: "s1", working: false))
            let afterFirst = await recorder.statuses.count
            await dispatcher.dispatch(PluginEvent(pluginID: "echo", sessionID: "s1"))
            let afterSecond = await recorder.statuses.count

            #expect(afterFirst == 1)
            #expect(afterSecond == 1)
        }

        @Test("notification fires the notification sink")
        func notificationFires() async {
            let recorder = DispatchRecorder()
            let dispatcher = makeDispatcher(recorder)

            await dispatcher.dispatch(PluginEvent(
                pluginID: "echo",
                sessionID: "s1",
                notification: NotificationSpec(title: "Done", body: "Build finished")
            ))

            let notifications = await recorder.notifications
            #expect(notifications == [
                .init(pluginID: "echo", sessionID: "s1", title: "Done", body: "Build finished"),
            ])
        }

        @Test("responseRequest with a request opens the form")
        func responseRequestOpens() async {
            let recorder = DispatchRecorder()
            let dispatcher = makeDispatcher(recorder)

            let request = AgentResponseRequest.prompt(PromptRequest(title: "Ask"))
            await dispatcher.dispatch(PluginEvent(
                pluginID: "echo",
                sessionID: "s1",
                responseRequest: ResponseRequestPayload(requestID: "r1", request: request)
            ))

            let opens = await recorder.opens
            let openedRequests = await recorder.openedRequests
            let retracts = await recorder.retracts
            #expect(opens == [.init(pluginID: "echo", sessionID: "s1", requestID: "r1")])
            #expect(openedRequests == [request])
            #expect(retracts.isEmpty)
        }

        @Test("responseRequest with nil request retracts the form")
        func responseRequestRetracts() async {
            let recorder = DispatchRecorder()
            let dispatcher = makeDispatcher(recorder)

            await dispatcher.dispatch(PluginEvent(
                pluginID: "echo",
                sessionID: "s1",
                responseRequest: ResponseRequestPayload(requestID: "r1", request: nil)
            ))

            let opens = await recorder.opens
            let retracts = await recorder.retracts
            #expect(opens.isEmpty)
            #expect(retracts == [.init(pluginID: "echo", sessionID: "s1", requestID: "r1")])
        }

        @Test("nil responseRequest produces no response activity")
        func nilResponseRequestIsSilent() async {
            let recorder = DispatchRecorder()
            let dispatcher = makeDispatcher(recorder)

            await dispatcher.dispatch(PluginEvent(pluginID: "echo", sessionID: "s1", working: true))

            let opens = await recorder.opens
            let retracts = await recorder.retracts
            #expect(opens.isEmpty)
            #expect(retracts.isEmpty)
        }

        @Test("each app action fires the app-action sink in order")
        func appActionsFanOut() async {
            let recorder = DispatchRecorder()
            let dispatcher = makeDispatcher(recorder)

            let actions: [AppAction] = [
                .openFileSuggestion(sessionID: "s1", path: "/tmp/PLAN.md", displayName: "PLAN.md", isPlan: true),
                .dismissFileSuggestions(sessionID: "s1"),
                .sessionEnded(sessionID: "s1", closePaneEligible: true),
            ]
            await dispatcher.dispatch(PluginEvent(pluginID: "echo", sessionID: "s1", appActions: actions))

            let recorded = await recorder.actions
            #expect(recorded == actions)
        }
    }
#endif
