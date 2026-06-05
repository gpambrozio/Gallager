import ClaudeSpyNetworking
import Foundation
import GallagerPluginProtocol
import Testing
@testable import ClaudeCodePluginCore

/// Lifecycle + auto-launch behavior of the core itself (the pieces not covered
/// by the translator / keystroke / scanner / installer suites).
@Suite("ClaudeCodePluginCore")
struct ClaudeCodePluginCoreTests {
    private func makeEnv(settings: Data = Data()) -> PluginEnv {
        PluginEnv(
            pluginRoot: URL(fileURLWithPath: NSTemporaryDirectory()),
            stateDir: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("gallager-cc-core-\(UUID().uuidString)"),
            appVersion: "1.0",
            settings: settings,
            marketplaceSource: URL(fileURLWithPath: "/")
        )
    }

    @Test("pluginID is claude-code")
    func pluginID() {
        #expect(ClaudeCodePluginCore.pluginID == "claude-code")
    }

    @Test("initialize pushes a project list to the host")
    func initializePushesProjects() async throws {
        let host = MockPluginHost()
        let core = ClaudeCodePluginCore()
        try await core.initialize(makeEnv(), host: host)
        let calls = await host.projectsCalls
        // At least one setProjects call happened during the initial scan.
        #expect(calls.count >= 1)
    }

    @Test("refreshProjects pushes again")
    func refreshPushesProjects() async throws {
        let host = MockPluginHost()
        let core = ClaudeCodePluginCore()
        try await core.initialize(makeEnv(), host: host)
        let before = await host.projectsCalls.count
        await core.refreshProjects()
        let after = await host.projectsCalls.count
        #expect(after == before + 1)
    }

    @Test("commandForLaunch returns the configured command when autoRun is on")
    func commandForLaunchEnabled() async throws {
        let settings = try JSONEncoder().encode(
            ClaudeCodeSettings(commandPath: "/opt/claude", autoRun: true)
        )
        let host = MockPluginHost()
        let core = ClaudeCodePluginCore()
        try await core.initialize(makeEnv(settings: settings), host: host)

        let launch = await core.commandForLaunch(projectPath: "/Users/test/Proj")
        #expect(launch?.command == "/opt/claude")
    }

    @Test("commandForLaunch declines when autoRun is off")
    func commandForLaunchDisabled() async throws {
        let settings = try JSONEncoder().encode(
            ClaudeCodeSettings(commandPath: "/opt/claude", autoRun: false)
        )
        let host = MockPluginHost()
        let core = ClaudeCodePluginCore()
        try await core.initialize(makeEnv(settings: settings), host: host)

        let launch = await core.commandForLaunch(projectPath: "/Users/test/Proj")
        #expect(launch == nil)
    }

    @Test("applySettings updates the launch command")
    func applySettingsUpdatesLaunch() async throws {
        let host = MockPluginHost()
        let core = ClaudeCodePluginCore()
        try await core.initialize(makeEnv(), host: host)

        let newSettings = try JSONEncoder().encode(
            ClaudeCodeSettings(commandPath: "/new/claude", autoRun: true)
        )
        let result = await core.applySettings(newSettings)
        guard case .applied = result else {
            Issue.record("expected .applied")
            return
        }
        let launch = await core.commandForLaunch(projectPath: "/x")
        #expect(launch?.command == "/new/claude")
    }

    @Test("shutdown is safe to call and stops delivery")
    func shutdownStopsDelivery() async throws {
        let host = MockPluginHost()
        let core = ClaudeCodePluginCore()
        try await core.initialize(makeEnv(), host: host)
        await core.shutdown()

        // After shutdown the host reference is cleared, so delivery is a no-op.
        await core.deliverResponse(sessionID: "s", requestID: "r", .prompt(text: "hi"))
        let texts = await host.sentText
        #expect(texts.isEmpty)
    }
}
