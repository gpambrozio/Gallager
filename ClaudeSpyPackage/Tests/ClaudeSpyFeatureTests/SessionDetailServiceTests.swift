import ClaudeSpyCommon
import ClaudeSpyNetworking
import Foundation
import Testing
@testable import ClaudeSpyFeature

@MainActor
@Suite("SessionDetailService Tests")
struct SessionDetailServiceTests {
    // MARK: - Initialization Tests

    @Test("Service initializes with correct pane ID")
    func serviceInitializesWithPaneId() {
        let sessionStore = SessionStore()
        let relayClient = ViewerRelayClient()
        let service = SessionDetailService(
            paneId: "%1",
            hostId: "test-pair",
            sessionStore: sessionStore,
            relayClient: relayClient
        )

        #expect(service.paneId == "%1")
        #expect(service.session == nil) // No session in store yet
        #expect(service.isPaneActive == false)
        #expect(service.isHostConnected == false)
    }

    @Test("Service finds existing session in store")
    func serviceFindsExistingSession() {
        let sessionStore = SessionStore()
        let relayClient = ViewerRelayClient()

        // Add a session via a hook event (transitional bridge; goes away in Task 20)
        let event = HookEvent(
            action: .sessionStart(SessionStartBody(sessionId: "test-session", hookEventName: "SessionStart")),
            projectPath: "/test/path",
            tmuxPane: "%1"
        )
        sessionStore.handleEvent(HookEventMessage(pairId: "test-pair", event: event))

        let service = SessionDetailService(
            paneId: "%1",
            hostId: "test-pair",
            sessionStore: sessionStore,
            relayClient: relayClient
        )

        #expect(service.session != nil)
        #expect(service.session?.tmuxPane == "%1")
    }

    // MARK: - Open Response Request Tests

    @Test("openResponseRequest is nil when no request matches the session")
    func openResponseRequestNilWhenNone() {
        let sessionStore = SessionStore()
        let relayClient = ViewerRelayClient()

        let service = SessionDetailService(
            paneId: "%1",
            hostId: "test-pair",
            sessionStore: sessionStore,
            relayClient: relayClient
        )

        #expect(service.openResponseRequest == nil)
    }

    @Test("openResponseRequest surfaces a matching response request from the store")
    func openResponseRequestMatchesStore() {
        let sessionStore = SessionStore()
        let relayClient = ViewerRelayClient()

        // Stand up a session for the pane.
        let event = HookEvent(
            action: .sessionStart(SessionStartBody(sessionId: "abc-123", hookEventName: "SessionStart")),
            projectPath: nil,
            tmuxPane: "%1"
        )
        sessionStore.handleEvent(HookEventMessage(pairId: "test-pair", event: event))

        let service = SessionDetailService(
            paneId: "%1",
            hostId: "test-pair",
            sessionStore: sessionStore,
            relayClient: relayClient
        )

        // Push a response request for the same `(host, pluginId, sessionId)`.
        let entry = ResponseRequestEntry(
            hostId: "test-pair",
            sessionId: "abc-123",
            pluginId: "claude-code",
            requestId: "req-1",
            request: .prompt(PromptRequest(placeholder: "say something"))
        )
        sessionStore.presentResponseRequest(entry)

        // SessionDetailService observes the store; force a sync update for the
        // test since `withObservationTracking` fires asynchronously.
        service.refreshOpenResponseRequestForTesting()

        #expect(service.openResponseRequest?.id == "req-1")
        if case let .prompt(prompt) = service.openResponseRequest?.request {
            #expect(prompt.placeholder == "say something")
        } else {
            Issue.record("Expected .prompt request")
        }
    }

    @Test("openResponseRequest ignores requests for other sessions")
    func openResponseRequestIgnoresOtherSessions() {
        let sessionStore = SessionStore()
        let relayClient = ViewerRelayClient()

        let event = HookEvent(
            action: .sessionStart(SessionStartBody(sessionId: "abc-123", hookEventName: "SessionStart")),
            projectPath: nil,
            tmuxPane: "%1"
        )
        sessionStore.handleEvent(HookEventMessage(pairId: "test-pair", event: event))

        let service = SessionDetailService(
            paneId: "%1",
            hostId: "test-pair",
            sessionStore: sessionStore,
            relayClient: relayClient
        )

        // Push a request for a different session id.
        sessionStore.presentResponseRequest(
            ResponseRequestEntry(
                hostId: "test-pair",
                sessionId: "different-session",
                pluginId: "claude-code",
                requestId: "req-other",
                request: .prompt(PromptRequest(placeholder: nil))
            )
        )
        service.refreshOpenResponseRequestForTesting()

        #expect(service.openResponseRequest == nil)
    }

    // MARK: - Pane Active Status Tests

    @Test("Pane active status reflects session store state")
    func paneActiveStatusReflectsStore() {
        let sessionStore = SessionStore()
        let relayClient = ViewerRelayClient()

        // Add a session and mark pane as active
        let event = HookEvent(
            action: .sessionStart(SessionStartBody(sessionId: "test", hookEventName: "SessionStart")),
            projectPath: nil,
            tmuxPane: "%1"
        )
        sessionStore.handleEvent(HookEventMessage(pairId: "test-pair", event: event))

        let service = SessionDetailService(
            paneId: "%1",
            hostId: "test-pair",
            sessionStore: sessionStore,
            relayClient: relayClient
        )

        #expect(service.isPaneActive == true)

        // End the session
        let endEvent = HookEvent(
            action: .sessionEnd(SessionEndBody(sessionId: "test", hookEventName: "SessionEnd")),
            projectPath: nil,
            tmuxPane: "%1"
        )
        sessionStore.handleEvent(HookEventMessage(pairId: "test-pair", event: endEvent))

        #expect(service.isPaneActive == false)
        #expect(service.session == nil) // Session removed on end
    }

    // MARK: - Cross-Host Pane Isolation Tests

    @Test("Same paneId from two hosts produces two distinct sessions")
    func samePaneIdAcrossHostsDoesNotCollide() {
        let sessionStore = SessionStore()
        let relayClient = ViewerRelayClient()

        // Two hosts emit events for the same tmux pane id (`%0`).
        let eventA = HookEvent(
            action: .sessionStart(SessionStartBody(sessionId: "session-a", hookEventName: "SessionStart")),
            projectPath: "/host-a/path",
            tmuxPane: "%0"
        )
        let eventB = HookEvent(
            action: .sessionStart(SessionStartBody(sessionId: "session-b", hookEventName: "SessionStart")),
            projectPath: "/host-b/path",
            tmuxPane: "%0"
        )
        sessionStore.handleEvent(HookEventMessage(pairId: "host-a", event: eventA))
        sessionStore.handleEvent(HookEventMessage(pairId: "host-b", event: eventB))

        // Store keeps both panes separately rather than collapsing them.
        #expect(sessionStore.paneStates.count == 2)

        // A SessionDetailService scoped to host-a does not pick up host-b's session.
        let serviceA = SessionDetailService(
            paneId: "%0",
            hostId: "host-a",
            sessionStore: sessionStore,
            relayClient: relayClient
        )
        let serviceB = SessionDetailService(
            paneId: "%0",
            hostId: "host-b",
            sessionStore: sessionStore,
            relayClient: relayClient
        )

        // Sanity check: both SessionDetailServices saw their own session.
        #expect(serviceA.session != nil)
        #expect(serviceB.session != nil)
        #expect(serviceA.session?.id == "session-a")
        #expect(serviceB.session?.id == "session-b")
    }

    // MARK: - Mac Connection Status Tests

    @Test("Mac connection status reflects relay client state")
    func macConnectionStatusReflectsViewerRelayClient() {
        let sessionStore = SessionStore()
        let relayClient = ViewerRelayClient()

        let service = SessionDetailService(
            paneId: "%1",
            hostId: "test-pair",
            sessionStore: sessionStore,
            relayClient: relayClient
        )

        #expect(service.isHostConnected == false)

        // Note: In a real test, we'd need to mock RelayClient or use
        // dependency injection to set isHostConnected to true.
        // For now, this tests the property delegation works.
    }
}
