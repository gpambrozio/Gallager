import ClaudeSpyNetworking
import Foundation
import GallagerPluginProtocol
import Testing
@testable import CodexPluginCore

/// Lifecycle + auto-launch behavior of the core itself (the pieces not covered
/// by the translator / keystroke / scanner / installer / correlation suites).
struct CodexPluginCoreTests {
    private func makeEnv(settings: Data = Data(), otlpEndpoint: URL? = nil) -> PluginEnv {
        PluginEnv(
            pluginRoot: URL(fileURLWithPath: NSTemporaryDirectory()),
            stateDir: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("gallager-cx-core-\(UUID().uuidString)"),
            appVersion: "1.0",
            settings: settings,
            marketplaceSource: URL(fileURLWithPath: "/"),
            otlpReceiverEndpoint: otlpEndpoint
        )
    }

    /// A core whose correlation store points at a throwaway temp dir so tests
    /// never touch the real `~/.claudespy/codex-sessions/`.
    private func makeCore() -> CodexPluginCore {
        let correlationRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("gallager-cx-core-corr-\(UUID().uuidString)")
        return CodexPluginCore(correlation: CodexSessionCorrelation(root: correlationRoot))
    }

    @Test("pluginID is codex")
    func pluginID() {
        #expect(CodexPluginCore.pluginID == "codex")
    }

    @Test("initialize pushes a project list to the host")
    func initializePushesProjects() async throws {
        let host = MockPluginHost()
        let core = makeCore()
        try await core.initialize(makeEnv(), host: host)
        let calls = await host.projectsCalls
        // At least one setProjects call happened during the initial scan.
        #expect(calls.count >= 1)
    }

    @Test("refreshProjects pushes again")
    func refreshPushesProjects() async throws {
        let host = MockPluginHost()
        let core = makeCore()
        try await core.initialize(makeEnv(), host: host)
        let before = await host.projectsCalls.count
        await core.refreshProjects()
        let after = await host.projectsCalls.count
        #expect(after == before + 1)
    }

    @Test("commandForLaunch returns the configured command when autoRun is on")
    func commandForLaunchEnabled() async throws {
        let settings = try JSONEncoder().encode(
            CodexSettings(commandPath: "/opt/codex", autoRun: true)
        )
        let host = MockPluginHost()
        let core = makeCore()
        try await core.initialize(makeEnv(settings: settings), host: host)

        let launch = await core.commandForLaunch(projectPath: "/Users/test/Proj")
        #expect(launch?.command == "/opt/codex")
    }

    @Test("commandForLaunch appends -c otel overrides when a receiver endpoint is present")
    func commandForLaunchInjectsOtel() async throws {
        let settings = try JSONEncoder().encode(CodexSettings(commandPath: "codex", autoRun: true))
        let host = MockPluginHost()
        let core = makeCore()
        try await core.initialize(
            makeEnv(settings: settings, otlpEndpoint: URL(string: "http://127.0.0.1:4318")),
            host: host
        )

        let launch = await core.commandForLaunch(projectPath: "/Users/test/Proj")
        #expect(launch?.command == "codex")
        let args = launch?.args ?? []
        #expect(args.contains("-c"))
        #expect(args.contains(#"otel.exporter.otlp-http.endpoint="http://127.0.0.1:4318/v1/logs""#))
        #expect(args.contains(#"otel.log_user_prompt=false"#))
    }

    @Test("commandForLaunch omits otel overrides when exportTelemetry is off")
    func commandForLaunchRespectsTelemetryOptOut() async throws {
        let settings = try JSONEncoder().encode(
            CodexSettings(commandPath: "codex", autoRun: true, exportTelemetry: false)
        )
        let host = MockPluginHost()
        let core = makeCore()
        try await core.initialize(
            makeEnv(settings: settings, otlpEndpoint: URL(string: "http://127.0.0.1:4318")),
            host: host
        )

        let launch = await core.commandForLaunch(projectPath: "/Users/test/Proj")
        #expect(launch?.command == "codex")
        #expect(launch?.args.isEmpty == true)
    }

    @Test("commandForLaunch omits otel overrides when no receiver endpoint is available")
    func commandForLaunchNoEndpoint() async throws {
        let settings = try JSONEncoder().encode(CodexSettings(commandPath: "codex", autoRun: true))
        let host = MockPluginHost()
        let core = makeCore()
        try await core.initialize(makeEnv(settings: settings), host: host) // no endpoint

        let launch = await core.commandForLaunch(projectPath: "/Users/test/Proj")
        #expect(launch?.args.isEmpty == true)
    }

    @Test("commandForLaunch declines when autoRun is off")
    func commandForLaunchDisabled() async throws {
        let settings = try JSONEncoder().encode(
            CodexSettings(commandPath: "/opt/codex", autoRun: false)
        )
        let host = MockPluginHost()
        let core = makeCore()
        try await core.initialize(makeEnv(settings: settings), host: host)

        let launch = await core.commandForLaunch(projectPath: "/Users/test/Proj")
        #expect(launch == nil)
    }

    @Test("applySettings updates the launch command")
    func applySettingsUpdatesLaunch() async throws {
        let host = MockPluginHost()
        let core = makeCore()
        try await core.initialize(makeEnv(), host: host)

        let newSettings = try JSONEncoder().encode(
            CodexSettings(commandPath: "/new/codex", autoRun: true)
        )
        let result = await core.applySettings(newSettings)
        guard case .applied = result else {
            Issue.record("expected .applied")
            return
        }
        let launch = await core.commandForLaunch(projectPath: "/x")
        #expect(launch?.command == "/new/codex")
    }

    @Test("shutdown is safe to call and stops delivery")
    func shutdownStopsDelivery() async throws {
        let host = MockPluginHost()
        let core = makeCore()
        try await core.initialize(makeEnv(), host: host)
        await core.shutdown()

        // After shutdown the host reference is cleared, so delivery is a no-op.
        await core.deliverResponse(sessionID: "s", requestID: "r", .prompt(text: "hi"))
        let texts = await host.sentText
        #expect(texts.isEmpty)
    }
}
