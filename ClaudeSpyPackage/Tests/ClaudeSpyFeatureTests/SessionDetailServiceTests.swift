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
        let relayClient = RelayClient()
        let service = SessionDetailService(
            paneId: "%1",
            sessionStore: sessionStore,
            relayClient: relayClient
        )

        #expect(service.paneId == "%1")
        #expect(service.session == nil) // No session in store yet
        #expect(service.isPaneActive == false)
        #expect(service.isMacConnected == false)
    }

    @Test("Service finds existing session in store")
    func serviceFindsExistingSession() {
        let sessionStore = SessionStore()
        let relayClient = RelayClient()

        // Add a session to the store
        let event = HookEvent(
            action: .sessionStart(SessionStartBody(sessionId: "test-session", hookEventName: "SessionStart")),
            projectPath: "/test/path",
            tmuxPane: "%1"
        )
        sessionStore.handleEvent(HookEventMessage(pairId: "test-pair", event: event))

        let service = SessionDetailService(
            paneId: "%1",
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
        let relayClient = RelayClient()

        let service = SessionDetailService(
            paneId: "%1",
            sessionStore: sessionStore,
            relayClient: relayClient
        )

        #expect(service.responseState == nil)
    }

    @Test("Response state is created for latest event")
    func responseStateCreatedForLatestEvent() {
        let sessionStore = SessionStore()
        let relayClient = RelayClient()

        // Add a session with an event
        let event = HookEvent(
            action: .sessionStart(SessionStartBody(sessionId: "test", hookEventName: "SessionStart")),
            projectPath: nil,
            tmuxPane: "%1"
        )
        sessionStore.handleEvent(HookEventMessage(pairId: "test-pair", event: event))

        let service = SessionDetailService(
            paneId: "%1",
            sessionStore: sessionStore,
            relayClient: relayClient
        )

        #expect(service.responseState != nil)
        #expect(service.responseState?.event.id == event.id)
    }

    @Test("Response state updates when latest event changes")
    func responseStateUpdatesWithNewEvent() {
        let sessionStore = SessionStore()
        let relayClient = RelayClient()

        // Add initial event
        let event1 = HookEvent(
            action: .sessionStart(SessionStartBody(sessionId: "test", hookEventName: "SessionStart")),
            projectPath: nil,
            tmuxPane: "%1"
        )
        sessionStore.handleEvent(HookEventMessage(pairId: "test-pair", event: event1))

        let service = SessionDetailService(
            paneId: "%1",
            sessionStore: sessionStore,
            relayClient: relayClient
        )

        let firstEventId = service.responseState?.event.id

        // Add a permission request event (simpler structure)
        let event2 = HookEvent(
            action: .permissionRequest(PermissionRequestBody.preview),
            projectPath: nil,
            tmuxPane: "%1"
        )
        sessionStore.handleEvent(HookEventMessage(pairId: "test-pair", event: event2))

        // Manually trigger update (in real app, view onChange would do this)
        service.updateResponseState()

        #expect(service.responseState?.event.id != firstEventId)
        #expect(service.responseState?.event.id == event2.id)
    }

    // MARK: - Pane Active Status Tests

    @Test("Pane active status reflects session store state")
    func paneActiveStatusReflectsStore() {
        let sessionStore = SessionStore()
        let relayClient = RelayClient()

        // Add a session and mark pane as active
        let event = HookEvent(
            action: .sessionStart(SessionStartBody(sessionId: "test", hookEventName: "SessionStart")),
            projectPath: nil,
            tmuxPane: "%1"
        )
        sessionStore.handleEvent(HookEventMessage(pairId: "test-pair", event: event))

        let service = SessionDetailService(
            paneId: "%1",
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
    func macConnectionStatusReflectsRelayClient() {
        let sessionStore = SessionStore()
        let relayClient = RelayClient()

        let service = SessionDetailService(
            paneId: "%1",
            sessionStore: sessionStore,
            relayClient: relayClient
        )

        #expect(service.isMacConnected == false)

        // Note: In a real test, we'd need to mock RelayClient or use
        // dependency injection to set isMacConnected to true.
        // For now, this tests the property delegation works.
    }

    // MARK: - Snapshot Loading State Tests

    @Test("Initial snapshot state is empty")
    func initialSnapshotStateIsEmpty() {
        let sessionStore = SessionStore()
        let relayClient = RelayClient()

        let service = SessionDetailService(
            paneId: "%1",
            sessionStore: sessionStore,
            relayClient: relayClient
        )

        #expect(service.isLoadingSnapshot == false)
        #expect(service.terminalSnapshot == nil)
        #expect(service.snapshotError == nil)
    }

    @Test("Snapshot request completes with error when not connected")
    func snapshotRequestFailsWhenNotConnected() async {
        let sessionStore = SessionStore()
        let relayClient = RelayClient()

        let service = SessionDetailService(
            paneId: "%1",
            sessionStore: sessionStore,
            relayClient: relayClient
        )

        // Request snapshot (will fail because not connected)
        await service.requestTerminalSnapshot()

        // Should have error and no snapshot
        #expect(service.snapshotError != nil)
        #expect(service.terminalSnapshot == nil)
        #expect(service.isLoadingSnapshot == false)
    }
}
