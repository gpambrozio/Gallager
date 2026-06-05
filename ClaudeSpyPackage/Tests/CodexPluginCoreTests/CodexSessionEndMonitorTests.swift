import ClaudeSpyNetworking
import Foundation
import GallagerPluginProtocol
import Testing
@testable import CodexPluginCore

/// Drives the Codex session-end monitor (`pollSessionEnds`) directly. Codex CLI
/// emits no `SessionEnd` hook, so the core polls `host.agentPanes()` and
/// synthesizes a `.sessionEnded` when a recorded session's `codex` process exits
/// — reusing the app's existing yolo-reset + pane-close handling.
@Suite("CodexSessionEndMonitor")
struct CodexSessionEndMonitorTests {
    private let fileManager = FileManager.default

    /// Builds an initialized core sharing a correlation store with the test (same
    /// root) so the test can record sessions and observe the core's removals.
    private func makeCore(
        closePaneOnSessionEnd: Bool = false
    ) async throws -> (CodexPluginCore, MockPluginHost, CodexSessionCorrelation, URL) {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("gallager-cx-mon-\(UUID().uuidString)")
        let store = CodexSessionCorrelation(root: root)
        let core = CodexPluginCore(correlation: store)
        let host = MockPluginHost()
        let settingsData = try JSONEncoder().encode(
            CodexSettings(closePaneOnSessionEnd: closePaneOnSessionEnd)
        )
        let env = PluginEnv(
            pluginRoot: URL(fileURLWithPath: NSTemporaryDirectory()),
            stateDir: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("gallager-cx-mon-state-\(UUID().uuidString)"),
            appVersion: "1.0",
            settings: settingsData,
            marketplaceSource: URL(fileURLWithPath: "/")
        )
        try await core.initialize(env, host: host)
        return (core, host, store, root)
    }

    @Test("process exit on a recorded pane synthesizes .sessionEnded and clears correlation")
    func processExitSynthesizesEnd() async throws {
        let (core, host, store, root) = try await makeCore()
        defer { try? fileManager.removeItem(at: root) }

        store.record(sessionID: "sess-1", tmuxPane: "%1", cwd: "/Users/test/Proj")

        // Tick 1: codex is alive in %1 → recorded as live, nothing ends.
        await host.setAgentPanes(["%1"])
        await core.pollSessionEnds()
        #expect(await host.emittedEvents.isEmpty)

        // Tick 2: codex has exited %1 → synthesize a session end + drop correlation.
        await host.setAgentPanes([])
        await core.pollSessionEnds()

        let events = await host.emittedEvents
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.pluginID == "codex")
        #expect(event.tmuxPane == "%1")
        #expect(event.appActions == [.sessionEnded(sessionID: "%1", closePaneEligible: false)])
        #expect(store.allPanes().isEmpty)

        await core.shutdown()
    }

    @Test("closePaneEligible follows the closePaneOnSessionEnd pref")
    func closePaneEligibleFollowsPref() async throws {
        let (core, host, store, root) = try await makeCore(closePaneOnSessionEnd: true)
        defer { try? fileManager.removeItem(at: root) }

        store.record(sessionID: "sess-1", tmuxPane: "%7", cwd: nil)
        await host.setAgentPanes(["%7"])
        await core.pollSessionEnds() // tick 1: live
        await host.setAgentPanes([])
        await core.pollSessionEnds() // tick 2: exited

        let event = try #require(await host.emittedEvents.first)
        #expect(event.appActions == [.sessionEnded(sessionID: "%7", closePaneEligible: true)])

        await core.shutdown()
    }

    @Test("first-tick orphan (process already gone) is reconciled silently")
    func firstTickOrphanReconciledSilently() async throws {
        let (core, host, store, root) = try await makeCore()
        defer { try? fileManager.removeItem(at: root) }

        // A correlation file from a previous app run whose codex is already gone.
        store.record(sessionID: "sess-old", tmuxPane: "%2", cwd: nil)
        await host.setAgentPanes([])

        await core.pollSessionEnds() // first tick → orphan reconcile

        #expect(await host.emittedEvents.isEmpty)
        #expect(store.allPanes().isEmpty)

        await core.shutdown()
    }

    @Test("a still-running session is not ended across ticks")
    func liveSessionNotEnded() async throws {
        let (core, host, store, root) = try await makeCore()
        defer { try? fileManager.removeItem(at: root) }

        store.record(sessionID: "sess-1", tmuxPane: "%1", cwd: nil)
        await host.setAgentPanes(["%1"])
        await core.pollSessionEnds() // tick 1
        await core.pollSessionEnds() // tick 2: still alive

        #expect(await host.emittedEvents.isEmpty)
        #expect(store.allPanes() == ["%1"])

        await core.shutdown()
    }
}

/// A `PluginHost` that implements only the required methods, to verify the
/// `agentPanes()` protocol-extension default.
private struct BarePluginHost: PluginHost {
    func setProjects(_: [AgentProject]) async { }
    func emit(_: PluginEvent) async { }
    func sendText(sessionID _: String, _: String) async { }
    func sendKeys(sessionID _: String, _: [PluginTmuxKey]) async { }
    func log(_: LogLine) async { }
}

@Suite("PluginHost default")
struct PluginHostDefaultTests {
    @Test("agentPanes defaults to empty when a host doesn't override it")
    func agentPanesDefaultsEmpty() async {
        let host = BarePluginHost()
        #expect(await host.agentPanes().isEmpty)
    }
}
