import Foundation
import Testing
@testable import CodexPluginCore

/// Write/read round-trip for the core-internal pane↔session correlation store
/// (spec §12), against a temp directory. Also covers the defensive paths.
@Suite("CodexSessionCorrelation")
struct CodexSessionCorrelationTests {
    private let fileManager = FileManager.default

    private func makeStore() -> (CodexSessionCorrelation, URL) {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("gallager-cx-corr-\(UUID().uuidString)")
        return (CodexSessionCorrelation(root: root), root)
    }

    @Test("record then read round-trips by pane")
    func roundTripByPane() throws {
        let (store, root) = makeStore()
        defer { try? fileManager.removeItem(at: root) }

        let ok = store.record(
            sessionID: "sess-123",
            tmuxPane: "%4",
            cwd: "/Users/test/Proj",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(ok == true)

        let record = try #require(store.record(forPane: "%4"))
        #expect(record.sessionID == "sess-123")
        #expect(record.cwd == "/Users/test/Proj")
        #expect(record.startedAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("pane(forSessionID:) resolves the owning pane")
    func resolvePaneBySession() {
        let (store, root) = makeStore()
        defer { try? fileManager.removeItem(at: root) }

        store.record(sessionID: "sess-A", tmuxPane: "%1", cwd: nil)
        store.record(sessionID: "sess-B", tmuxPane: "%2", cwd: nil)

        #expect(store.pane(forSessionID: "sess-A") == "%1")
        #expect(store.pane(forSessionID: "sess-B") == "%2")
        #expect(store.pane(forSessionID: "sess-missing") == nil)
    }

    @Test("a later record for the same pane overwrites the earlier one")
    func overwritesSamePane() throws {
        let (store, root) = makeStore()
        defer { try? fileManager.removeItem(at: root) }

        store.record(sessionID: "sess-old", tmuxPane: "%9", cwd: nil)
        store.record(sessionID: "sess-new", tmuxPane: "%9", cwd: nil)

        let record = try #require(store.record(forPane: "%9"))
        #expect(record.sessionID == "sess-new")
        #expect(store.pane(forSessionID: "sess-new") == "%9")
    }

    @Test("recording with an empty pane is a no-op")
    func emptyPaneNoOp() {
        let (store, root) = makeStore()
        defer { try? fileManager.removeItem(at: root) }
        #expect(store.record(sessionID: "x", tmuxPane: "", cwd: nil) == false)
    }

    @Test("reading a pane with no file returns nil")
    func missingReturnsNil() {
        let (store, root) = makeStore()
        defer { try? fileManager.removeItem(at: root) }
        #expect(store.record(forPane: "%nope") == nil)
        #expect(store.pane(forSessionID: "whatever") == nil)
    }

    @Test("a malformed correlation file is tolerated without trapping")
    func defensiveMalformed() throws {
        let (store, root) = makeStore()
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: root.appendingPathComponent("%3.json"))

        #expect(store.record(forPane: "%3") == nil)
        // Scanning for a session id must skip the malformed file, not trap.
        #expect(store.pane(forSessionID: "anything") == nil)
    }

    @Test("allPanes lists every recorded pane and is empty when none")
    func allPanesListsRecorded() {
        let (store, root) = makeStore()
        defer { try? fileManager.removeItem(at: root) }

        #expect(store.allPanes().isEmpty)

        store.record(sessionID: "sess-A", tmuxPane: "%1", cwd: nil)
        store.record(sessionID: "sess-B", tmuxPane: "%2", cwd: nil)

        #expect(store.allPanes() == ["%1", "%2"])
    }

    @Test("remove deletes a pane's correlation file")
    func removeDeletesFile() {
        let (store, root) = makeStore()
        defer { try? fileManager.removeItem(at: root) }

        store.record(sessionID: "sess-A", tmuxPane: "%1", cwd: nil)
        store.record(sessionID: "sess-B", tmuxPane: "%2", cwd: nil)

        store.remove(pane: "%1")

        #expect(store.allPanes() == ["%2"])
        #expect(store.record(forPane: "%1") == nil)
        // Removing an absent pane (or empty id) is a harmless no-op.
        store.remove(pane: "%1")
        store.remove(pane: "")
        #expect(store.allPanes() == ["%2"])
    }
}
