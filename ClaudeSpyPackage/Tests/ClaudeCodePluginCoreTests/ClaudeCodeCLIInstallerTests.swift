import ClaudeSpyCommon
import Foundation
import GallagerPluginProtocol
import Testing
@testable import ClaudeCodePluginCore

// MARK: - Thread-safe call recorder

/// Thread-safe collector for process invocations made through a test ProcessRunner.
private actor CallRecorder {
    struct Call: Sendable {
        let executable: String
        let arguments: [String]
        let environment: [String: String]?
    }

    private(set) var calls: [Call] = []

    func record(_ call: Call) {
        calls.append(call)
    }

    func reset() {
        calls = []
    }
}

// MARK: - Test helpers

private extension ProcessResult {
    static func success(_ stdout: String = "", stderr: String = "") -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8))
    }

    static func failure(exitCode: Int32, stderr: String = "") -> ProcessResult {
        ProcessResult(exitCode: exitCode, stdout: Data(), stderr: Data(stderr.utf8))
    }
}

// MARK: - ClaudeCodeCLIInstallerTests

@Suite("ClaudeCodeCLIInstaller")
struct ClaudeCodeCLIInstallerTests {
    private let marketplaceSource = URL(fileURLWithPath: "/bundle/plugin")

    // MARK: - install(configRoot:)

    @Test("install runs marketplace add then plugin install, wrapped in /usr/bin/env")
    func installCommandSequence() async throws {
        let recorder = CallRecorder()
        let processRunner = ProcessRunner { exe, args, env, _ in
            await recorder.record(.init(executable: exe, arguments: args, environment: env))
            return .success()
        }
        let installer = ClaudeCodeCLIInstaller(
            processRunner: processRunner,
            command: "claude",
            marketplaceSource: marketplaceSource
        )

        _ = try await installer.install(configRoot: nil)

        let calls = await recorder.calls
        #expect(calls.count == 2)

        // First call: marketplace add
        let marketplaceCall = calls[0]
        #expect(marketplaceCall.executable == "/usr/bin/env")
        #expect(marketplaceCall.arguments == ["claude", "plugin", "marketplace", "add", "/bundle/plugin"])

        // Second call: plugin install
        let installCall = calls[1]
        #expect(installCall.executable == "/usr/bin/env")
        #expect(installCall.arguments == ["claude", "plugin", "install", "gallager", "--scope", "user"])
    }

    @Test("install sets CLAUDE_CONFIG_DIR when configRoot is non-nil")
    func installSetsConfigDirEnv() async throws {
        let recorder = CallRecorder()
        let processRunner = ProcessRunner { exe, args, env, _ in
            await recorder.record(.init(executable: exe, arguments: args, environment: env))
            return .success()
        }
        let installer = ClaudeCodeCLIInstaller(
            processRunner: processRunner,
            command: "claude",
            marketplaceSource: marketplaceSource
        )

        _ = try await installer.install(configRoot: "/custom/config")

        let calls = await recorder.calls
        #expect(calls.count == 2)
        for call in calls {
            #expect(call.environment?["CLAUDE_CONFIG_DIR"] == "/custom/config")
        }
    }

    @Test("install omits CLAUDE_CONFIG_DIR when configRoot is nil")
    func installOmitsConfigDirWhenNil() async throws {
        let recorder = CallRecorder()
        let processRunner = ProcessRunner { exe, args, env, _ in
            await recorder.record(.init(executable: exe, arguments: args, environment: env))
            return .success()
        }
        let installer = ClaudeCodeCLIInstaller(
            processRunner: processRunner,
            command: "claude",
            marketplaceSource: marketplaceSource
        )

        _ = try await installer.install(configRoot: nil)

        let calls = await recorder.calls
        for call in calls {
            #expect(call.environment == nil)
        }
    }

    @Test("install returns .alreadyInstalled when the install step reports already-installed")
    func installAlreadyInstalled() async throws {
        let processRunner = ProcessRunner { _, args, _, _ in
            // marketplace add succeeds; plugin install reports already-installed.
            if args.contains("install") {
                return .failure(exitCode: 1, stderr: "Error: plugin gallager already installed")
            }
            return .success()
        }
        let installer = ClaudeCodeCLIInstaller(
            processRunner: processRunner,
            command: "claude",
            marketplaceSource: marketplaceSource
        )

        let result = try await installer.install(configRoot: nil)
        guard case .alreadyInstalled = result else {
            Issue.record("Expected .alreadyInstalled, got \(result)")
            return
        }
    }

    @Test("install throws executionFailed when install fails for an unrelated reason")
    func installThrowsOnFailure() async throws {
        let processRunner = ProcessRunner { _, args, _, _ in
            if args.contains("install") {
                return .failure(exitCode: 2, stderr: "Error: network unreachable")
            }
            return .success()
        }
        let installer = ClaudeCodeCLIInstaller(
            processRunner: processRunner,
            command: "claude",
            marketplaceSource: marketplaceSource
        )

        await #expect(throws: ProcessRunnerError.self) {
            _ = try await installer.install(configRoot: nil)
        }
    }

    // MARK: - uninstall(configRoot:)

    @Test("uninstall runs plugin uninstall gallager, wrapped in /usr/bin/env")
    func uninstallCommand() async throws {
        let recorder = CallRecorder()
        let processRunner = ProcessRunner { exe, args, env, _ in
            await recorder.record(.init(executable: exe, arguments: args, environment: env))
            return .success()
        }
        let installer = ClaudeCodeCLIInstaller(
            processRunner: processRunner,
            command: "claude",
            marketplaceSource: marketplaceSource
        )

        try await installer.uninstall(configRoot: nil)

        let calls = await recorder.calls
        #expect(calls.count == 1)
        #expect(calls[0].executable == "/usr/bin/env")
        #expect(calls[0].arguments == ["claude", "plugin", "uninstall", "gallager"])
        #expect(calls[0].environment == nil)
    }

    @Test("uninstall threads CLAUDE_CONFIG_DIR when configRoot is non-nil")
    func uninstallThreadsConfigDir() async throws {
        let recorder = CallRecorder()
        let processRunner = ProcessRunner { exe, args, env, _ in
            await recorder.record(.init(executable: exe, arguments: args, environment: env))
            return .success()
        }
        let installer = ClaudeCodeCLIInstaller(
            processRunner: processRunner,
            command: "claude",
            marketplaceSource: marketplaceSource
        )

        try await installer.uninstall(configRoot: "/custom/config")

        let calls = await recorder.calls
        #expect(calls.count == 1)
        #expect(calls[0].environment?["CLAUDE_CONFIG_DIR"] == "/custom/config")
    }

    // MARK: - installStatus(configRoot:)

    @Test("installStatus returns .installed(version:) when gallager line with x.y.z is present")
    func installStatusParsesInstalledVersion() async throws {
        let listing = """
        Available plugins:
          gallager  1.2.3  Gallager monitoring plugin
          other     0.1.0  Some other plugin
        """
        let processRunner = ProcessRunner { _, _, _, _ in
            .success(listing)
        }
        let installer = ClaudeCodeCLIInstaller(
            processRunner: processRunner,
            command: "claude",
            marketplaceSource: marketplaceSource
        )

        let status = await installer.installStatus(configRoot: nil)
        guard case let .installed(version) = status else {
            Issue.record("Expected .installed, got \(status)")
            return
        }
        #expect(version == "1.2.3")
    }

    @Test("installStatus returns .notInstalled when gallager is absent from listing")
    func installStatusNotInstalled() async throws {
        let listing = """
        Available plugins:
          other  0.5.0  Some other plugin
        """
        let processRunner = ProcessRunner { _, _, _, _ in
            .success(listing)
        }
        let installer = ClaudeCodeCLIInstaller(
            processRunner: processRunner,
            command: "claude",
            marketplaceSource: marketplaceSource
        )

        let status = await installer.installStatus(configRoot: nil)
        #expect(status == .notInstalled)
    }

    @Test("installStatus returns .agentUnavailable when process exits 127")
    func installStatusAgentUnavailableOn127() async throws {
        let processRunner = ProcessRunner { _, _, _, _ in
            .failure(exitCode: 127)
        }
        let installer = ClaudeCodeCLIInstaller(
            processRunner: processRunner,
            command: "claude",
            marketplaceSource: marketplaceSource
        )

        let status = await installer.installStatus(configRoot: nil)
        #expect(status == .agentUnavailable)
    }

    @Test("installStatus returns .agentUnavailable when processRunner throws")
    func installStatusAgentUnavailableOnThrow() async throws {
        let processRunner = ProcessRunner { _, _, _, _ in
            throw ProcessRunnerError.executionFailed(exitCode: 127, stderr: "not found")
        }
        let installer = ClaudeCodeCLIInstaller(
            processRunner: processRunner,
            command: "claude",
            marketplaceSource: marketplaceSource
        )

        let status = await installer.installStatus(configRoot: nil)
        #expect(status == .agentUnavailable)
    }

    // MARK: - parseStatus (unit)

    @Test("parseStatus: installed line with version token")
    func parseStatusWithVersion() {
        let listing = "  gallager  2.0.1  A plugin"
        let status = ClaudeCodeCLIInstaller.parseStatus(from: listing)
        guard case let .installed(version) = status else {
            Issue.record("Expected .installed, got \(status)")
            return
        }
        #expect(version == "2.0.1")
    }

    @Test("parseStatus: gallager line without version token → installed(version: nil)")
    func parseStatusNoVersion() {
        let listing = "  gallager"
        let status = ClaudeCodeCLIInstaller.parseStatus(from: listing)
        guard case let .installed(version) = status else {
            Issue.record("Expected .installed, got \(status)")
            return
        }
        #expect(version == nil)
    }

    @Test("parseStatus: absent → .notInstalled")
    func parseStatusAbsent() {
        let listing = "  other  1.0.0  Not our plugin"
        let status = ClaudeCodeCLIInstaller.parseStatus(from: listing)
        #expect(status == .notInstalled)
    }

    @Test("parseStatus: empty listing → .notInstalled")
    func parseStatusEmpty() {
        let status = ClaudeCodeCLIInstaller.parseStatus(from: "")
        #expect(status == .notInstalled)
    }

    // MARK: - configRoot passed to plugin list

    @Test("installStatus passes CLAUDE_CONFIG_DIR when configRoot is non-nil")
    func installStatusPassesConfigDir() async throws {
        let recorder = CallRecorder()
        let processRunner = ProcessRunner { exe, args, env, _ in
            await recorder.record(.init(executable: exe, arguments: args, environment: env))
            return .success()
        }
        let installer = ClaudeCodeCLIInstaller(
            processRunner: processRunner,
            command: "claude",
            marketplaceSource: marketplaceSource
        )

        _ = await installer.installStatus(configRoot: "/some/dir")

        let calls = await recorder.calls
        #expect(calls.count == 1)
        #expect(calls[0].arguments == ["claude", "plugin", "list"])
        #expect(calls[0].environment?["CLAUDE_CONFIG_DIR"] == "/some/dir")
    }
}
