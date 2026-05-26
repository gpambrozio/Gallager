import ClaudeSpyNetworking
import ConcurrencyExtras
import Foundation
import GallagerPluginProtocol
import Testing
@testable import ClaudeSpyPluginRuntime

@Suite("PluginEventDispatcher")
struct PluginEventDispatcherTests {
    // MARK: - Recording sinks

    /// One status sink call recorded with all of the args the dispatcher
    /// surfaced. Equatable so test assertions can compare a captured
    /// snapshot against an expected value.
    struct StatusCall: Equatable, Sendable {
        let pluginID: String
        let sessionID: String
        let tmuxPane: String?
        let working: Bool?
        let attention: Bool
    }

    struct NotificationCall: Equatable, Sendable {
        let pluginID: String
        let sessionID: String?
        let tmuxPane: String?
        let title: String
        let body: String
    }

    struct RequestCall: Equatable, Sendable {
        let pluginID: String
        let sessionID: String
        let tmuxPane: String?
        let requestID: String
        let request: AgentResponseRequest
        let isAutoApprovable: Bool
    }

    struct DismissCall: Equatable, Sendable {
        let pluginID: String
        let sessionID: String
        let requestID: String
    }

    struct AppActionCall: Equatable, Sendable {
        let pluginID: String
        let sessionID: String?
        let tmuxPane: String?
        let action: AppAction
    }

    struct AutoApproveCall: Equatable, Sendable {
        let pluginID: String
        let sessionID: String
        let requestID: String
    }

    /// Each sink stores its observations in a `LockIsolated` array so the
    /// async tests can read them off the main task without bridging an
    /// actor by hand.

    final class StatusSinkSpy: PluginSessionStatusSink, Sendable {
        private let _calls = LockIsolated<[StatusCall]>([])
        var calls: [StatusCall] { _calls.value }
        func updateStatus(
            pluginID: String,
            sessionID: String,
            tmuxPane: String?,
            projectPath _: String?,
            working: Bool?,
            attention: Bool
        ) async {
            _calls.withValue { $0.append(
                .init(
                    pluginID: pluginID,
                    sessionID: sessionID,
                    tmuxPane: tmuxPane,
                    working: working,
                    attention: attention
                )
            ) }
        }
    }

    final class NotificationSinkSpy: PluginNotificationSink, Sendable {
        private let _calls = LockIsolated<[NotificationCall]>([])
        var calls: [NotificationCall] { _calls.value }
        func deliverNotification(
            pluginID: String,
            sessionID: String?,
            tmuxPane: String?,
            projectPath _: String?,
            title: String,
            body: String
        ) async {
            _calls.withValue { $0.append(
                .init(
                    pluginID: pluginID,
                    sessionID: sessionID,
                    tmuxPane: tmuxPane,
                    title: title,
                    body: body
                )
            ) }
        }
    }

    final class ResponseSinkSpy: PluginResponseRequestSink, Sendable {
        private let _deliverCalls = LockIsolated<[RequestCall]>([])
        private let _dismissCalls = LockIsolated<[DismissCall]>([])
        var deliverCalls: [RequestCall] { _deliverCalls.value }
        var dismissCalls: [DismissCall] { _dismissCalls.value }
        func deliverRequest(
            pluginID: String,
            sessionID: String,
            tmuxPane: String?,
            projectPath _: String?,
            requestID: String,
            request: AgentResponseRequest,
            isAutoApprovable: Bool
        ) async {
            _deliverCalls.withValue { $0.append(
                .init(
                    pluginID: pluginID,
                    sessionID: sessionID,
                    tmuxPane: tmuxPane,
                    requestID: requestID,
                    request: request,
                    isAutoApprovable: isAutoApprovable
                )
            ) }
        }

        func dismissRequest(
            pluginID: String,
            sessionID: String,
            requestID: String
        ) async {
            _dismissCalls.withValue { $0.append(
                .init(pluginID: pluginID, sessionID: sessionID, requestID: requestID)
            ) }
        }
    }

    final class AppActionSinkSpy: PluginAppActionSink, Sendable {
        private let _calls = LockIsolated<[AppActionCall]>([])
        var calls: [AppActionCall] { _calls.value }
        func handle(
            pluginID: String,
            sessionID: String?,
            tmuxPane: String?,
            projectPath _: String?,
            action: AppAction
        ) async {
            _calls.withValue { $0.append(
                .init(
                    pluginID: pluginID,
                    sessionID: sessionID,
                    tmuxPane: tmuxPane,
                    action: action
                )
            ) }
        }
    }

    final class YoloSpy: YoloModeProvider, Sendable {
        private let yoloSessions: LockIsolated<Set<String>>
        init(yoloSessionIDs: Set<String> = []) {
            self.yoloSessions = LockIsolated(yoloSessionIDs)
        }

        convenience init(yolo: Bool, sessionID: String = "S1") {
            self.init(yoloSessionIDs: yolo ? [sessionID] : [])
        }

        func isYolo(forSessionID sessionID: String) async -> Bool {
            yoloSessions.value.contains(sessionID)
        }
    }

    final class AutoApprovalSpy: PluginEventDispatcher.AutoApprovalDelegate, Sendable {
        private let _calls = LockIsolated<[AutoApproveCall]>([])
        var calls: [AutoApproveCall] { _calls.value }
        func autoApprove(
            pluginID: String,
            sessionID: String,
            requestID: String
        ) async {
            _calls.withValue { $0.append(
                .init(pluginID: pluginID, sessionID: sessionID, requestID: requestID)
            ) }
        }
    }

    // MARK: - Helpers

    private func makeDispatcher(
        yolo: YoloSpy,
        autoApproval: AutoApprovalSpy? = nil
    ) -> (
        PluginEventDispatcher,
        StatusSinkSpy,
        NotificationSinkSpy,
        ResponseSinkSpy,
        AppActionSinkSpy
    ) {
        let s = StatusSinkSpy()
        let n = NotificationSinkSpy()
        let r = ResponseSinkSpy()
        let a = AppActionSinkSpy()
        let dispatcher = PluginEventDispatcher(
            statusSink: s,
            notificationSink: n,
            responseRequestSink: r,
            appActionSink: a,
            yoloProvider: yolo,
            autoApprovalDelegate: autoApproval
        )
        return (dispatcher, s, n, r, a)
    }

    private func makePermissionRequest(isAutoApprovable: Bool) -> AgentResponseRequest {
        .permission(PermissionRequest(
            toolName: "Bash",
            description: "Run `ls`",
            suggestions: [PermissionRequest.Suggestion(id: "once", label: "Allow once", badge: nil)],
            isAutoApprovable: isAutoApprovable
        ))
    }

    private func makeAskUserQuestionRequest() -> AgentResponseRequest {
        .askUserQuestion(AskUserQuestionRequest(
            questions: [
                AskUserQuestionRequest.Question(
                    prompt: "Pick one",
                    options: [
                        AskUserQuestionRequest.Option(label: "A", detail: nil),
                        AskUserQuestionRequest.Option(label: "B", detail: nil),
                    ],
                    allowMultiple: false,
                    allowFreeText: false
                ),
            ]
        ))
    }

    // MARK: - Tests

    @Test("status-only event hits only the status sink")
    func statusOnly() async throws {
        let yolo = YoloSpy(yolo: false)
        let (dispatcher, s, n, r, a) = makeDispatcher(yolo: yolo)

        await dispatcher.dispatch(PluginEvent(
            pluginID: "claude-code",
            sessionID: "S1",
            working: true,
            attention: false,
            notification: nil,
            responseRequest: nil,
            appActions: []
        ))

        #expect(s.calls == [
            .init(
                pluginID: "claude-code",
                sessionID: "S1",
                tmuxPane: nil,
                working: true,
                attention: false
            ),
        ])
        #expect(n.calls.isEmpty)
        #expect(r.deliverCalls.isEmpty)
        #expect(r.dismissCalls.isEmpty)
        #expect(a.calls.isEmpty)
    }

    @Test("status-skip when working is nil and attention is false")
    func noStatusOpinionSkipsSink() async throws {
        let yolo = YoloSpy(yolo: false)
        let (dispatcher, s, _, _, _) = makeDispatcher(yolo: yolo)

        await dispatcher.dispatch(PluginEvent(
            pluginID: "p",
            sessionID: "S1",
            working: nil,
            attention: false,
            notification: nil,
            responseRequest: nil,
            appActions: []
        ))

        #expect(s.calls.isEmpty)
    }

    @Test("notification + response request together fan out to both sinks")
    func notificationAndRequestFanOut() async throws {
        let yolo = YoloSpy(yolo: false)
        let (dispatcher, s, n, r, _) = makeDispatcher(yolo: yolo)

        let request = makeAskUserQuestionRequest()
        await dispatcher.dispatch(PluginEvent(
            pluginID: "claude-code",
            sessionID: "S1",
            working: false,
            attention: true,
            notification: .init(title: "Heads up", body: "Need input"),
            responseRequest: .init(requestID: "req-1", request: request),
            appActions: []
        ))

        #expect(s.calls == [
            .init(
                pluginID: "claude-code",
                sessionID: "S1",
                tmuxPane: nil,
                working: false,
                attention: true
            ),
        ])
        #expect(n.calls == [
            .init(
                pluginID: "claude-code",
                sessionID: "S1",
                tmuxPane: nil,
                title: "Heads up",
                body: "Need input"
            ),
        ])
        #expect(r.deliverCalls == [
            .init(
                pluginID: "claude-code",
                sessionID: "S1",
                tmuxPane: nil,
                requestID: "req-1",
                request: request,
                isAutoApprovable: false
            ),
        ])
    }

    @Test("openFileSuggestion AppAction reaches the app-action sink")
    func openFileSuggestionRouted() async throws {
        let yolo = YoloSpy(yolo: false)
        let (dispatcher, _, _, _, a) = makeDispatcher(yolo: yolo)

        let action = AppAction.openFileSuggestion(
            sessionId: "S1",
            path: "/tmp/plan.md",
            displayName: "plan.md",
            isPlan: true
        )
        await dispatcher.dispatch(PluginEvent(
            pluginID: "claude-code",
            sessionID: "S1",
            working: nil,
            attention: false,
            notification: nil,
            responseRequest: nil,
            appActions: [action]
        ))

        #expect(a.calls == [
            .init(pluginID: "claude-code", sessionID: "S1", tmuxPane: nil, action: action),
        ])
    }

    @Test("dismissFileSuggestions AppAction reaches the app-action sink")
    func dismissFileSuggestionsRouted() async throws {
        let yolo = YoloSpy(yolo: false)
        let (dispatcher, _, _, _, a) = makeDispatcher(yolo: yolo)

        let action = AppAction.dismissFileSuggestions(sessionId: "S1")
        await dispatcher.dispatch(PluginEvent(
            pluginID: "claude-code",
            sessionID: "S1",
            working: nil,
            attention: false,
            notification: nil,
            responseRequest: nil,
            appActions: [action]
        ))

        #expect(a.calls == [
            .init(pluginID: "claude-code", sessionID: "S1", tmuxPane: nil, action: action),
        ])
    }

    @Test("yolo + auto-approvable permission short-circuits to the auto-approval delegate")
    func yoloAutoApproveBypassesResponseSink() async throws {
        let yolo = YoloSpy(yolo: true, sessionID: "S1")
        let autoApproval = AutoApprovalSpy()
        let (dispatcher, _, _, r, _) = makeDispatcher(yolo: yolo, autoApproval: autoApproval)

        let request = makePermissionRequest(isAutoApprovable: true)
        await dispatcher.dispatch(PluginEvent(
            pluginID: "claude-code",
            sessionID: "S1",
            working: nil,
            attention: false,
            notification: nil,
            responseRequest: .init(requestID: "req-yolo", request: request),
            appActions: []
        ))

        #expect(autoApproval.calls == [
            .init(pluginID: "claude-code", sessionID: "S1", requestID: "req-yolo"),
        ])
        // The response sink must NOT see the request — that's the whole
        // point of the carve-out.
        #expect(r.deliverCalls.isEmpty)
    }

    @Test("yolo + non-auto-approvable permission still surfaces to the user")
    func yoloNonAutoApprovableStillFires() async throws {
        let yolo = YoloSpy(yolo: true, sessionID: "S1")
        let autoApproval = AutoApprovalSpy()
        let (dispatcher, _, _, r, _) = makeDispatcher(yolo: yolo, autoApproval: autoApproval)

        let request = makePermissionRequest(isAutoApprovable: false)
        await dispatcher.dispatch(PluginEvent(
            pluginID: "claude-code",
            sessionID: "S1",
            working: nil,
            attention: false,
            notification: nil,
            responseRequest: .init(requestID: "req-2", request: request),
            appActions: []
        ))

        #expect(autoApproval.calls.isEmpty)
        #expect(r.deliverCalls == [
            .init(
                pluginID: "claude-code",
                sessionID: "S1",
                tmuxPane: nil,
                requestID: "req-2",
                request: request,
                isAutoApprovable: false
            ),
        ])
    }

    @Test("no yolo + auto-approvable permission still surfaces to the user (with isAutoApprovable=true)")
    func nonYoloAutoApprovableSurfaces() async throws {
        let yolo = YoloSpy(yolo: false)
        let autoApproval = AutoApprovalSpy()
        let (dispatcher, _, _, r, _) = makeDispatcher(yolo: yolo, autoApproval: autoApproval)

        let request = makePermissionRequest(isAutoApprovable: true)
        await dispatcher.dispatch(PluginEvent(
            pluginID: "claude-code",
            sessionID: "S1",
            working: nil,
            attention: false,
            notification: nil,
            responseRequest: .init(requestID: "req-3", request: request),
            appActions: []
        ))

        #expect(autoApproval.calls.isEmpty)
        #expect(r.deliverCalls == [
            .init(
                pluginID: "claude-code",
                sessionID: "S1",
                tmuxPane: nil,
                requestID: "req-3",
                request: request,
                isAutoApprovable: true
            ),
        ])
    }

    @Test("non-permission response requests carry isAutoApprovable=false regardless of yolo")
    func nonPermissionAlwaysFalse() async throws {
        let yolo = YoloSpy(yolo: true, sessionID: "S1")
        let autoApproval = AutoApprovalSpy()
        let (dispatcher, _, _, r, _) = makeDispatcher(yolo: yolo, autoApproval: autoApproval)

        let request = makeAskUserQuestionRequest()
        await dispatcher.dispatch(PluginEvent(
            pluginID: "claude-code",
            sessionID: "S1",
            working: nil,
            attention: false,
            notification: nil,
            responseRequest: .init(requestID: "req-4", request: request),
            appActions: []
        ))

        #expect(autoApproval.calls.isEmpty)
        #expect(r.deliverCalls.count == 1)
        #expect(r.deliverCalls.first?.isAutoApprovable == false)
    }

    @Test("event's tmuxPane is forwarded to every sink")
    func tmuxPaneFannedOutToSinks() async throws {
        let yolo = YoloSpy(yolo: false)
        let (dispatcher, s, n, r, a) = makeDispatcher(yolo: yolo)

        let action = AppAction.openFileSuggestion(
            sessionId: "S1",
            path: "/tmp/note.md",
            displayName: "note.md",
            isPlan: false
        )
        await dispatcher.dispatch(PluginEvent(
            pluginID: "echo",
            sessionID: "S1",
            working: true,
            attention: true,
            notification: .init(title: "T", body: "B"),
            responseRequest: .init(
                requestID: "req-1",
                request: makeAskUserQuestionRequest()
            ),
            appActions: [action],
            tmuxPane: "%42"
        ))

        #expect(s.calls.map(\.tmuxPane) == ["%42"])
        #expect(n.calls.map(\.tmuxPane) == ["%42"])
        #expect(r.deliverCalls.map(\.tmuxPane) == ["%42"])
        #expect(a.calls.map(\.tmuxPane) == ["%42"])
        #expect(a.calls.map(\.sessionID) == ["S1"])
    }
}
