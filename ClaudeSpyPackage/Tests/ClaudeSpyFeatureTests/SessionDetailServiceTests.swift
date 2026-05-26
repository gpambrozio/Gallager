import ClaudeSpyCommon
import ClaudeSpyNetworking
import Foundation
import Testing
@testable import ClaudeSpyFeature

@MainActor
@Suite("SessionDetailService Tests")
struct SessionDetailServiceTests {
    // MARK: - Helpers

    /// Seeds a `SessionStore` with one pane carrying an `AgentSession` for the
    /// given host. Mirrors what the relay's `agent_session_state` push would
    /// do, just synchronously so tests don't have to spin up the wire.
    private func seedSession(
        on store: SessionStore,
        hostId: String,
        paneId: String,
        sessionId: String,
        pluginID: String = "claude-code",
        projectPath: String? = nil
    ) {
        let session = AgentSession(
            id: sessionId,
            pluginID: pluginID,
            tmuxPane: paneId,
            projectPath: projectPath
        )
        let pane = PaneState(paneId: paneId, agentSession: session)
        let state = SessionStateMessage(
            pairId: hostId,
            paneStates: [paneId: pane]
        )
        store.handleStateUpdate(state)
    }

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

        seedSession(
            on: sessionStore,
            hostId: "test-pair",
            paneId: "%1",
            sessionId: "test-session",
            projectPath: "/test/path"
        )

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
        seedSession(
            on: sessionStore,
            hostId: "test-pair",
            paneId: "%1",
            sessionId: "abc-123"
        )

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

        seedSession(
            on: sessionStore,
            hostId: "test-pair",
            paneId: "%1",
            sessionId: "abc-123"
        )

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

        // Seed a pane with an active session.
        seedSession(
            on: sessionStore,
            hostId: "test-pair",
            paneId: "%1",
            sessionId: "test"
        )

        let service = SessionDetailService(
            paneId: "%1",
            hostId: "test-pair",
            sessionStore: sessionStore,
            relayClient: relayClient
        )

        #expect(service.isPaneActive == true)

        // Mac sends a fresh session state with the pane cleared of its agent
        // session — the equivalent of the agent ending its session. The store
        // overwrites the pane via `handleStateUpdate`.
        let endedState = SessionStateMessage(
            pairId: "test-pair",
            paneStates: ["%1": PaneState(paneId: "%1", agentSession: nil)]
        )
        sessionStore.handleStateUpdate(endedState)

        #expect(service.isPaneActive == false)
        #expect(service.session == nil) // Session removed
    }

    // MARK: - Cross-Host Pane Isolation Tests

    @Test("Same paneId from two hosts produces two distinct sessions")
    func samePaneIdAcrossHostsDoesNotCollide() {
        let sessionStore = SessionStore()
        let relayClient = ViewerRelayClient()

        // Two hosts emit session state for the same tmux pane id (`%0`).
        seedSession(
            on: sessionStore,
            hostId: "host-a",
            paneId: "%0",
            sessionId: "session-a",
            projectPath: "/host-a/path"
        )
        seedSession(
            on: sessionStore,
            hostId: "host-b",
            paneId: "%0",
            sessionId: "session-b",
            projectPath: "/host-b/path"
        )

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
