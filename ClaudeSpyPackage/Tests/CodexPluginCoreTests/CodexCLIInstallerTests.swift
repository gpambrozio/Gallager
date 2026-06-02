import ClaudeSpyCommon
import Foundation
import GallagerPluginProtocol
import Testing
@testable import CodexPluginCore

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

// MARK: - CodexCLIInstallerTests

@Suite("CodexCLIInstaller")
struct CodexCLIInstallerTests {
    private let marketplaceSource = URL(fileURLWithPath: "/bundle/codex-plugin")

    // MARK: - install(configRoot:)

    @Test("install runs marketplace add then plugin add, wrapped in /usr/bin/env")
    func installCommandSequence() async throws {
        let recorder = CallRecorder()
        let processRunner = ProcessRunner { exe, args, env, _ in
            await recorder.record(.init(executable: exe, arguments: args, environment: env))
            return .success()
        }
        let installer = CodexCLIInstaller(
            processRunner: processRunner,
            command: "codex",
            marketplaceSource: marketplaceSource
        )

        _ = try await installer.install(configRoot: nil)

        let calls = await recorder.calls
        #expect(calls.count == 2)

        // First call: marketplace add
        let marketplaceCall = calls[0]
        #expect(marketplaceCall.executable == "/usr/bin/env")
        #expect(marketplaceCall.arguments == ["codex", "plugin", "marketplace", "add", "/bundle/codex-plugin"])

        // Second call: plugin add
        let addCall = calls[1]
        #expect(addCall.executable == "/usr/bin/env")
        #expect(addCall.arguments == ["codex", "plugin", "add", "gallager@gallager"])
    }

    @Test("install sets CODEX_HOME when configRoot is non-nil")
    func installSetsCodexHomeEnv() async throws {
        let recorder = CallRecorder()
        let processRunner = ProcessRunner { exe, args, env, _ in
            await recorder.record(.init(executable: exe, arguments: args, environment: env))
            return .success()
        }
        let installer = CodexCLIInstaller(
            processRunner: processRunner,
            command: "codex",
            marketplaceSource: marketplaceSource
        )

        _ = try await installer.install(configRoot: "/custom/codex-home")

        let calls = await recorder.calls
        #expect(calls.count == 2)
        for call in calls {
            #expect(call.environment?["CODEX_HOME"] == "/custom/codex-home")
        }
    }

    @Test("install omits CODEX_HOME when configRoot is nil")
    func installOmitsCodexHomeWhenNil() async throws {
        let recorder = CallRecorder()
        let processRunner = ProcessRunner { exe, args, env, _ in
            await recorder.record(.init(executable: exe, arguments: args, environment: env))
            return .success()
        }
        let installer = CodexCLIInstaller(
            processRunner: processRunner,
            command: "codex",
            marketplaceSource: marketplaceSource
        )

        _ = try await installer.install(configRoot: nil)

        let calls = await recorder.calls
        for call in calls {
            #expect(call.environment == nil)
        }
    }

    @Test("install returns .alreadyInstalled when plugin add stderr reports already-added")
    func installAlreadyInstalled() async throws {
        let processRunner = ProcessRunner { _, args, _, _ in
            // marketplace add (tolerated); plugin add reports already-added. The
            // stderr must carry both "already" AND "add" to satisfy the tightened
            // heuristic (so unrelated "already running" messages don't match).
            if args.contains("add") && args.contains("gallager@gallager") {
                return .failure(exitCode: 1, stderr: "Error: plugin gallager@gallager already added")
            }
            return .success()
        }
        let installer = CodexCLIInstaller(
            processRunner: processRunner,
            command: "codex",
            marketplaceSource: marketplaceSource
        )

        let result = try await installer.install(configRoot: nil)
        guard case .alreadyInstalled = result else {
            Issue.record("Expected .alreadyInstalled, got \(result)")
            return
        }
    }

    @Test("install throws executionFailed when plugin add fails for an unrelated reason")
    func installThrowsOnFailure() async throws {
        let processRunner = ProcessRunner { _, args, _, _ in
            if args.contains("add") && args.contains("gallager@gallager") {
                return .failure(exitCode: 2, stderr: "Error: network unreachable")
            }
            return .success()
        }
        let installer = CodexCLIInstaller(
            processRunner: processRunner,
            command: "codex",
            marketplaceSource: marketplaceSource
        )

        await #expect(throws: ProcessRunnerError.self) {
            _ = try await installer.install(configRoot: nil)
        }
    }

    @Test("install does NOT treat an unrelated 'already' message as alreadyInstalled")
    func installAlreadyMessageWithoutAddThrows() async throws {
        // "already running" carries "already" but not "add"; the tightened
        // heuristic must reject it and surface the failure instead.
        let processRunner = ProcessRunner { _, args, _, _ in
            if args.contains("add") && args.contains("gallager@gallager") {
                return .failure(exitCode: 1, stderr: "Error: codex is already running")
            }
            return .success()
        }
        let installer = CodexCLIInstaller(
            processRunner: processRunner,
            command: "codex",
            marketplaceSource: marketplaceSource
        )

        await #expect(throws: ProcessRunnerError.self) {
            _ = try await installer.install(configRoot: nil)
        }
    }

    // MARK: - uninstall(configRoot:)

    @Test("uninstall runs plugin remove gallager@gallager, wrapped in /usr/bin/env")
    func uninstallCommand() async throws {
        let recorder = CallRecorder()
        let processRunner = ProcessRunner { exe, args, env, _ in
            await recorder.record(.init(executable: exe, arguments: args, environment: env))
            return .success()
        }
        let installer = CodexCLIInstaller(
            processRunner: processRunner,
            command: "codex",
            marketplaceSource: marketplaceSource
        )

        try await installer.uninstall(configRoot: nil)

        let calls = await recorder.calls
        #expect(calls.count == 1)
        #expect(calls[0].executable == "/usr/bin/env")
        #expect(calls[0].arguments == ["codex", "plugin", "remove", "gallager@gallager"])
        #expect(calls[0].environment == nil)
    }

    @Test("uninstall threads CODEX_HOME when configRoot is non-nil")
    func uninstallThreadsCodexHome() async throws {
        let recorder = CallRecorder()
        let processRunner = ProcessRunner { exe, args, env, _ in
            await recorder.record(.init(executable: exe, arguments: args, environment: env))
            return .success()
        }
        let installer = CodexCLIInstaller(
            processRunner: processRunner,
            command: "codex",
            marketplaceSource: marketplaceSource
        )

        try await installer.uninstall(configRoot: "/custom/codex-home")

        let calls = await recorder.calls
        #expect(calls.count == 1)
        #expect(calls[0].environment?["CODEX_HOME"] == "/custom/codex-home")
    }

    // MARK: - installStatus(configRoot:)

    @Test("installStatus returns .installed(version:) when gallager line with x.y.z is present")
    func installStatusParsesInstalledVersion() async throws {
        let listing = """
        Marketplace `gallager`
        /Applications/Gallager.app/Contents/Resources/plugin/codex/.agents/plugins/marketplace.json

        PLUGIN             STATUS     VERSION  PATH
        gallager@gallager  installed  1.3.0    /Applications/Gallager.app/Contents/Resources/plugin/codex/gallager
        """
        let processRunner = ProcessRunner { _, _, _, _ in
            .success(listing)
        }
        let installer = CodexCLIInstaller(
            processRunner: processRunner,
            command: "codex",
            marketplaceSource: marketplaceSource
        )

        let status = await installer.installStatus(configRoot: nil)
        guard case let .installed(version) = status else {
            Issue.record("Expected .installed, got \(status)")
            return
        }
        #expect(version == "1.3.0")
    }

    @Test("installStatus returns .installed(version: nil) when gallager line has no x.y.z token")
    func installStatusInstalledWithoutVersion() async throws {
        // An installed gallager row with no dot-bearing numeric token → version is
        // nil but the plugin is still reported installed.
        let listing = """
        PLUGIN             STATUS     VERSION  PATH
        gallager@gallager  installed           /Applications/Gallager.app/Contents/Resources/plugin/codex/gallager
        """
        let processRunner = ProcessRunner { _, _, _, _ in
            .success(listing)
        }
        let installer = CodexCLIInstaller(
            processRunner: processRunner,
            command: "codex",
            marketplaceSource: marketplaceSource
        )

        let status = await installer.installStatus(configRoot: nil)
        guard case let .installed(version) = status else {
            Issue.record("Expected .installed, got \(status)")
            return
        }
        #expect(version == nil)
    }

    @Test("installStatus is .notInstalled when the row STATUS says 'not installed' (marketplace header present)")
    func installStatusNotInstalledFromStatusColumn() async throws {
        // Real `codex plugin list -m gallager` output: the marketplace IS registered
        // (header + path lines mention `gallager`) but the plugin row's STATUS is
        // "not installed". The marketplace header must NOT be read as installed.
        let listing = """
        Marketplace `gallager`
        /Applications/Gallager.app/Contents/Resources/plugin/codex/.agents/plugins/marketplace.json

        PLUGIN             STATUS         VERSION  PATH
        gallager@gallager  not installed           /Applications/Gallager.app/Contents/Resources/plugin/codex/gallager
        """
        let processRunner = ProcessRunner { _, _, _, _ in
            .success(listing)
        }
        let installer = CodexCLIInstaller(
            processRunner: processRunner,
            command: "codex",
            marketplaceSource: marketplaceSource
        )

        let status = await installer.installStatus(configRoot: nil)
        #expect(status == .notInstalled)
    }

    @Test("installStatus returns .notInstalled when gallager is absent from listing")
    func installStatusNotInstalled() async throws {
        let listing = """
        PLUGIN        STATUS     VERSION  PATH
        other@other   installed  0.5.0    /some/path
        """
        let processRunner = ProcessRunner { _, _, _, _ in
            .success(listing)
        }
        let installer = CodexCLIInstaller(
            processRunner: processRunner,
            command: "codex",
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
        let installer = CodexCLIInstaller(
            processRunner: processRunner,
            command: "codex",
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
        let installer = CodexCLIInstaller(
            processRunner: processRunner,
            command: "codex",
            marketplaceSource: marketplaceSource
        )

        let status = await installer.installStatus(configRoot: nil)
        #expect(status == .agentUnavailable)
    }

    @Test("installStatus passes CODEX_HOME when configRoot is non-nil")
    func installStatusPassesCodexHome() async throws {
        let recorder = CallRecorder()
        let processRunner = ProcessRunner { exe, args, env, _ in
            await recorder.record(.init(executable: exe, arguments: args, environment: env))
            return .success()
        }
        let installer = CodexCLIInstaller(
            processRunner: processRunner,
            command: "codex",
            marketplaceSource: marketplaceSource
        )

        _ = await installer.installStatus(configRoot: "/some/dir")

        let calls = await recorder.calls
        #expect(calls.count == 1)
        #expect(calls[0].arguments == ["codex", "plugin", "list", "-m", "gallager"])
        #expect(calls[0].environment?["CODEX_HOME"] == "/some/dir")
    }

    @Test("installStatus returns .notInstalled when listing fails with non-127 exit")
    func installStatusNotInstalledOnNon127Failure() async throws {
        let processRunner = ProcessRunner { _, _, _, _ in
            .failure(exitCode: 1, stderr: "internal error")
        }
        let installer = CodexCLIInstaller(
            processRunner: processRunner,
            command: "codex",
            marketplaceSource: marketplaceSource
        )

        let status = await installer.installStatus(configRoot: nil)
        #expect(status == .notInstalled)
    }
}
