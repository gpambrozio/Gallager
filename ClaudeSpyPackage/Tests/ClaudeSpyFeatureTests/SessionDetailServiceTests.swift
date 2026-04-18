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

        // Add a session to the store
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
        #expect(service.session?.paneId == "%1")
    }

    // MARK: - Response State Tests

    @Test("Response state is nil when session has no events")
    func responseStateNilWhenNoEvents() {
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

    @Test("Response state is created for latest event")
    func responseStateCreatedForLatestEvent() {
        let sessionStore = SessionStore()
        let relayClient = ViewerRelayClient()

        // Add a session with an event
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

        // Response state is now automatically updated during init via withObservationTracking
        #expect(service.responseState != nil)
        #expect(service.responseState?.event.id == event.id)
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

    // MARK: - Response Persistence Tests (Issue #31)
    // These tests use SessionStore.response(for:) / setResponse(_:for:)
    // which are only available on iOS.

    #if os(iOS)
        @Test("Response is persisted to SessionStore when set")
        func responsePersistsToStore() {
            let sessionStore = SessionStore()
            let relayClient = ViewerRelayClient()

            // Add a session with a permission request event
            let event = HookEvent(
                action: .permissionRequest(PermissionRequestBody.preview),
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

            // Set a response
            service.responseState?.response = .accepted

            // Verify response is persisted in the store
            #expect(sessionStore.response(for: event.id) == .accepted)
        }

        @Test("Response is restored when service is recreated")
        func responseRestoredOnServiceRecreation() {
            let sessionStore = SessionStore()
            let relayClient = ViewerRelayClient()

            // Add a session with a permission request event
            let event = HookEvent(
                action: .permissionRequest(PermissionRequestBody.preview),
                projectPath: nil,
                tmuxPane: "%1"
            )
            sessionStore.handleEvent(HookEventMessage(pairId: "test-pair", event: event))

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

            // Add a session with an event
            let event = HookEvent(
                action: .permissionRequest(PermissionRequestBody.preview),
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

            // Test different response types
            service.responseState?.response = .rejected
            #expect(sessionStore.response(for: event.id) == .rejected)

            service.responseState?.response = .allQuestionsAnswered
            #expect(sessionStore.response(for: event.id) == .allQuestionsAnswered)

            service.responseState?.response = .customInstructions("test input")
            if case let .customInstructions(text) = sessionStore.response(for: event.id) {
                #expect(text == "test input")
            } else {
                Issue.record("Expected customInstructions response")
            }
        }
    #endif
}
