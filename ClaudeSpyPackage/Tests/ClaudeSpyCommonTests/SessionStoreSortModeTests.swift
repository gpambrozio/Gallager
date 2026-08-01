import ClaudeSpyNetworking
import Foundation
import Testing
@testable import ClaudeSpyCommon

@MainActor
@Suite("SessionStore sidebarSortMode")
struct SessionStoreSortModeTests {
    @Test("The host's pushed sort mode is stored per host and cleared with its sessions")
    func storesAndClears() {
        let store = SessionStore()
        store.handleStateUpdate(SessionStateMessage(
            pairId: "host-1", paneStates: [:], sidebarSortMode: "alphabetical"
        ))
        #expect(store.sidebarSortMode(for: "host-1") == .alphabetical)

        // A push without the field (older host) clears it — callers fall back
        // to the default mode.
        store.handleStateUpdate(SessionStateMessage(pairId: "host-1", paneStates: [:]))
        #expect(store.sidebarSortMode(for: "host-1") == nil)

        // An unknown future mode from a newer host parses to nil too.
        store.handleStateUpdate(SessionStateMessage(
            pairId: "host-1", paneStates: [:], sidebarSortMode: "sort-by-vibes"
        ))
        #expect(store.sidebarSortMode(for: "host-1") == nil)

        store.handleStateUpdate(SessionStateMessage(
            pairId: "host-1", paneStates: [:], sidebarSortMode: "statusPriority"
        ))
        #expect(store.sidebarSortMode(for: "host-1") == .statusPriority)
        store.clearSessions(for: "host-1")
        #expect(store.sidebarSortMode(for: "host-1") == nil)
    }

    @Test("A snapshot from an older host (no sidebarSortMode key) still decodes")
    func decodesWithoutSortModeKey() throws {
        let oldJSON = Data("""
        {"pairId": "host-1", "paneStates": {}, "homeDirectory": "/Users/bob"}
        """.utf8)
        let message = try JSONDecoder().decode(SessionStateMessage.self, from: oldJSON)
        #expect(message.sidebarSortMode == nil)
        #expect(message.homeDirectory == "/Users/bob")
    }
}
