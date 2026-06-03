import ClaudeSpyCommon
import ClaudeSpyNetworking
import Foundation
import Testing
@testable import ClaudeSpyFeature

@MainActor
@Suite("SessionDetailService Tests")
struct SessionDetailServiceTests {
    // MARK: - Helpers

    /// Push a session state (the plugin-path replacement for hook events) so a
    /// pane registers an `AgentSession` in the store.
    private func pushState(
        _ store: SessionStore,
        pairId: String,
        sessionId: String,
        state: AgentState
    ) {
        store.handleAgentStatus(AgentSessionStatusMessage(
            pairId: pairId,
            sessionId: sessionId,
            pluginId: "claude-code",
            state: state,
            timestamp: Date()
        ))
    }

    /// A connect snapshot carrying the given panes, each with an `AgentState`.
    /// The open response form rides `AgentSession.state`, so a form present here
    /// is delivered to a connecting viewer for free.
    private func snapshot(pairId: String, panes: [String: AgentState]) -> SessionStateMessage {
        var paneStates: [String: PaneState] = [:]
        for (paneId, state) in panes {
            paneStates[paneId] = PaneState(
                paneId: paneId,
                agentSession: AgentSession(paneId: paneId, pluginID: "claude-code", state: state)
            )
        }
        return SessionStateMessage(pairId: pairId, paneStates: paneStates)
    }

    /// The open form retained for a pane in the store, if any.
    private func openForm(
        _ store: SessionStore,
        sessionId: String,
        hostId: String
    ) -> (request: AgentResponseRequest, requestID: String)? {
        store.session(for: sessionId, hostId: hostId)?.state.openForm
    }

    private func askUserQuestion() -> AskUserQuestionRequest {
        AskUserQuestionRequest(questions: [
            .init(
                id: "q1",
                question: "Which?",
                header: "Pick",
                options: [.init(id: "a", label: "A", description: "first")],
                multiSelect: false
            ),
        ])
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

        pushState(sessionStore, pairId: "test-pair", sessionId: "%1", state: .working)

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

    @Test("Response state is created for an awaiting (blocking) state")
    func responseStateCreatedForOpenRequest() {
        let sessionStore = SessionStore()
        let relayClient = ViewerRelayClient()

        pushState(
            sessionStore,
            pairId: "test-pair",
            sessionId: "%1",
            state: .awaitingPermission(
                PermissionRequest(title: "Bash", description: "ls"),
                requestID: "%1:PermissionRequest"
            )
        )

        let service = SessionDetailService(
            paneId: "%1",
            hostId: "test-pair",
            sessionStore: sessionStore,
            relayClient: relayClient
        )

        // Response state is updated during init via withObservationTracking.
        #expect(service.responseState != nil)
        #expect(service.responseState?.requestID == "%1:PermissionRequest")
    }

    // MARK: - Snapshot Catch-Up Tests (offline-then-connect)

    @Test("A form that opened while offline renders from the connect snapshot")
    func snapshotSeedsOpenFormOnConnect() {
        let sessionStore = SessionStore()
        let relayClient = ViewerRelayClient()

        // The app was NOT running when the question arrived. Its only knowledge
        // is the snapshot fetched on connect — and the form rides the pane's
        // AgentSession.state, so the snapshot carries it.
        sessionStore.handleStateUpdate(snapshot(
            pairId: "test-pair",
            panes: ["%1": .awaitingReplies(askUserQuestion(), requestID: "%1:AskUserQuestion")]
        ))

        let service = SessionDetailService(
            paneId: "%1",
            hostId: "test-pair",
            sessionStore: sessionStore,
            relayClient: relayClient
        )

        #expect(service.responseState != nil)
        #expect(service.responseState?.requestID == "%1:AskUserQuestion")
    }

    @Test("A snapshot whose pane has advanced clears a stale form")
    func snapshotClearsStaleFormWhenStateAdvances() {
        let sessionStore = SessionStore()

        // A form is open locally (seen live before a brief disconnect)...
        pushState(
            sessionStore,
            pairId: "test-pair",
            sessionId: "%1",
            state: .awaitingPermission(
                PermissionRequest(title: "Bash", description: "ls"),
                requestID: "%1:PermissionRequest"
            )
        )
        #expect(openForm(sessionStore, sessionId: "%1", hostId: "test-pair") != nil)

        // ...but the reconnect snapshot shows the agent has moved on → no form.
        sessionStore.handleStateUpdate(snapshot(pairId: "test-pair", panes: ["%1": .working]))

        #expect(openForm(sessionStore, sessionId: "%1", hostId: "test-pair") == nil)
    }

    @Test("Snapshot reconcile is scoped to the snapshot's host")
    func snapshotReconcileIsHostScoped() {
        let sessionStore = SessionStore()

        // host-b has a live form open.
        pushState(
            sessionStore,
            pairId: "host-b",
            sessionId: "%1",
            state: .awaitingPermission(
                PermissionRequest(title: "Bash", description: "ls"),
                requestID: "host-b:r1"
            )
        )

        // host-a sends a snapshot — it must not touch host-b's form.
        sessionStore.handleStateUpdate(snapshot(pairId: "host-a", panes: [:]))

        #expect(openForm(sessionStore, sessionId: "%1", hostId: "host-b") != nil)
    }

    // MARK: - Cross-Host Pane Isolation Tests

    @Test("Same paneId from two hosts produces two distinct sessions")
    func samePaneIdAcrossHostsDoesNotCollide() {
        let sessionStore = SessionStore()
        let relayClient = ViewerRelayClient()

        // Two hosts emit state for the same tmux pane id (`%0`).
        pushState(sessionStore, pairId: "host-a", sessionId: "%0", state: .working)
        pushState(sessionStore, pairId: "host-b", sessionId: "%0", state: .doneWorking(summary: nil))

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
        private func openPermission(_ store: SessionStore, requestId: String) {
            pushState(
                store,
                pairId: "test-pair",
                sessionId: "%1",
                state: .awaitingPermission(
                    PermissionRequest(title: "Bash", description: "ls"),
                    requestID: requestId
                )
            )
        }

        @Test("Response is persisted to SessionStore when set")
        func responsePersistsToStore() {
            let sessionStore = SessionStore()
            let relayClient = ViewerRelayClient()

            let requestId = "%1:PermissionRequest"
            openPermission(sessionStore, requestId: requestId)

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
            openPermission(sessionStore, requestId: requestId)

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
            openPermission(sessionStore, requestId: requestId)

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
