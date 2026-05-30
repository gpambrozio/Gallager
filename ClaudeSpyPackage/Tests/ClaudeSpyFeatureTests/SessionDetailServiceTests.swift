import ClaudeSpyCommon
import ClaudeSpyNetworking
import Foundation
import Testing
@testable import ClaudeSpyFeature

@MainActor
@Suite("SessionDetailService Tests")
struct SessionDetailServiceTests {
    // MARK: - Helpers

    /// Push a session status (the plugin-path replacement for hook events) so a
    /// pane registers an `AgentSession` in the store.
    private func pushStatus(
        _ store: SessionStore,
        pairId: String,
        sessionId: String,
        working: Bool = false,
        attention: Bool = false
    ) {
        store.handleAgentStatus(AgentSessionStatusMessage(
            pairId: pairId,
            sessionId: sessionId,
            pluginId: "claude-code",
            working: working,
            attention: attention,
            timestamp: Date()
        ))
    }

    /// Open (or, with `request == nil`, retract) a response form for a pane.
    private func openRequest(
        _ store: SessionStore,
        pairId: String,
        sessionId: String,
        requestId: String,
        request: AgentResponseRequest?
    ) {
        store.handleAgentResponseRequest(AgentResponseRequestMessage(
            pairId: pairId,
            sessionId: sessionId,
            pluginId: "claude-code",
            requestId: requestId,
            request: request
        ))
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

        pushStatus(sessionStore, pairId: "test-pair", sessionId: "%1", working: true)

        let service = SessionDetailService(
            paneId: "%1",
            hostId: "test-pair",
            sessionStore: sessionStore,
            relayClient: relayClient
        )

        #expect(service.session != nil)
        #expect(service.session?.paneId == "%1")
    }

    // MARK: - Response State Tests

    @Test("Response state is nil when no response form is open")
    func responseStateNilWhenNoOpenRequest() {
        let sessionStore = SessionStore()
        let relayClient = ViewerRelayClient()

        let service = SessionDetailService(
            paneId: "%1",
            hostId: "test-pair",
            sessionStore: sessionStore,
            relayClient: relayClient
        )

        #expect(service.responseState == nil)
    }

    @Test("Response state is created for an open request")
    func responseStateCreatedForOpenRequest() {
        let sessionStore = SessionStore()
        let relayClient = ViewerRelayClient()

        openRequest(
            sessionStore,
            pairId: "test-pair",
            sessionId: "%1",
            requestId: "%1:SessionStart",
            request: .prompt(PromptRequest(title: "Send a message"))
        )

        let service = SessionDetailService(
            paneId: "%1",
            hostId: "test-pair",
            sessionStore: sessionStore,
            relayClient: relayClient
        )

        // Response state is updated during init via withObservationTracking.
        #expect(service.responseState != nil)
        #expect(service.responseState?.requestID == "%1:SessionStart")
    }

    // MARK: - Cross-Host Pane Isolation Tests

    @Test("Same paneId from two hosts produces two distinct sessions")
    func samePaneIdAcrossHostsDoesNotCollide() {
        let sessionStore = SessionStore()
        let relayClient = ViewerRelayClient()

        // Two hosts emit status for the same tmux pane id (`%0`).
        pushStatus(sessionStore, pairId: "host-a", sessionId: "%0", working: true)
        pushStatus(sessionStore, pairId: "host-b", sessionId: "%0", attention: true)

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

        #expect(serviceA.session?.isWorking == true)
        #expect(serviceA.session?.needsAttention == false)
        #expect(serviceB.session?.isWorking == false)
        #expect(serviceB.session?.needsAttention == true)
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
    }

    // MARK: - Response Persistence Tests (Issue #31)
    // These tests use SessionStore.response(forRequestID:) / setResponse(_:forRequestID:)
    // which are only available on iOS.

    #if os(iOS)
        @Test("Response is persisted to SessionStore when set")
        func responsePersistsToStore() {
            let sessionStore = SessionStore()
            let relayClient = ViewerRelayClient()

            let requestId = "%1:PermissionRequest"
            openRequest(
                sessionStore,
                pairId: "test-pair",
                sessionId: "%1",
                requestId: requestId,
                request: .permission(PermissionRequest(title: "Bash", description: "ls"))
            )

            let service = SessionDetailService(
                paneId: "%1",
                hostId: "test-pair",
                sessionStore: sessionStore,
                relayClient: relayClient
            )

            // Set a response
            service.responseState?.response = .accepted

            // Verify response is persisted in the store (keyed by request id).
            #expect(sessionStore.response(forRequestID: requestId) == .accepted)
        }

        @Test("Response is restored when service is recreated")
        func responseRestoredOnServiceRecreation() {
            let sessionStore = SessionStore()
            let relayClient = ViewerRelayClient()

            let requestId = "%1:PermissionRequest"
            openRequest(
                sessionStore,
                pairId: "test-pair",
                sessionId: "%1",
                requestId: requestId,
                request: .permission(PermissionRequest(title: "Bash", description: "ls"))
            )

            // First service - set a response
            let service1 = SessionDetailService(
                paneId: "%1",
                hostId: "test-pair",
                sessionStore: sessionStore,
                relayClient: relayClient
            )
            service1.responseState?.response = .accepted

            // Create a new service (simulating navigation away and back)
            let service2 = SessionDetailService(
                paneId: "%1",
                hostId: "test-pair",
                sessionStore: sessionStore,
                relayClient: relayClient
            )

            // Response should be restored from the store
            #expect(service2.responseState?.response == .accepted)
        }

        @Test("Different response types are persisted correctly")
        func differentResponseTypesPersist() {
            let sessionStore = SessionStore()
            let relayClient = ViewerRelayClient()

            let requestId = "%1:PermissionRequest"
            openRequest(
                sessionStore,
                pairId: "test-pair",
                sessionId: "%1",
                requestId: requestId,
                request: .permission(PermissionRequest(title: "Bash", description: "ls"))
            )

            let service = SessionDetailService(
                paneId: "%1",
                hostId: "test-pair",
                sessionStore: sessionStore,
                relayClient: relayClient
            )

            // Test different response types
            service.responseState?.response = .rejected
            #expect(sessionStore.response(forRequestID: requestId) == .rejected)

            service.responseState?.response = .allQuestionsAnswered
            #expect(sessionStore.response(forRequestID: requestId) == .allQuestionsAnswered)

            service.responseState?.response = .customInstructions("test input")
            if case let .customInstructions(text) = sessionStore.response(forRequestID: requestId) {
                #expect(text == "test input")
            } else {
                Issue.record("Expected customInstructions response")
            }
        }
    #endif
}
