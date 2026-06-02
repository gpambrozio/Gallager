import ClaudeSpyCommon
import Foundation
import GallagerPluginProtocol

/// Installs the Gallager Codex plugin through Codex's own CLI
/// (`codex plugin …`), scoped to a `CODEX_HOME`. Mirrors `ClaudeCodeCLIInstaller`.
struct CodexCLIInstaller: Sendable {
    let processRunner: ProcessRunner
    let command: String
    let marketplaceSource: URL

    static let pluginRef = "gallager@gallager"

    private func env(for configRoot: String?) -> [String: String]? {
        configRoot.map { ["CODEX_HOME": $0] }
    }

    private func run(_ args: [String], configRoot: String?, timeout: TimeInterval) async throws -> ProcessResult {
        try await processRunner.run("/usr/bin/env", [command] + args, env(for: configRoot), timeout)
    }

    func install(configRoot: String?) async throws -> InstallResult {
        _ = try? await run(["plugin", "marketplace", "add", marketplaceSource.path], configRoot: configRoot, timeout: 60)
        let result = try await run(["plugin", "add", Self.pluginRef], configRoot: configRoot, timeout: 120)
        if result.isSuccess {
            return .installed(message: "Installed \(Self.pluginRef) via codex plugin add")
        }
        let stderr = result.stderrString.lowercased()
        if stderr.contains("already") && stderr.contains("add") {
            return .alreadyInstalled
        }
        throw ProcessRunnerError.executionFailed(exitCode: result.exitCode, stderr: result.stderrString)
    }

    func uninstall(configRoot: String?) async throws {
        _ = try await run(["plugin", "remove", Self.pluginRef], configRoot: configRoot, timeout: 60)
    }

    func installStatus(configRoot: String?) async -> PluginInstallStatus {
        guard let result = try? await run(["plugin", "list"], configRoot: configRoot, timeout: 30) else {
            return .agentUnavailable
        }
        if result.exitCode == 127 { return .agentUnavailable }
        guard result.isSuccess else { return .notInstalled }
        // Assumes a `codex plugin list` line format `<name> <version> …`; the first
        // numeric, dot-bearing token on a line mentioning gallager is the version.
        for line in result.stdoutString.split(separator: "\n") where line.contains("gallager") {
            let version = line
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .first(where: { $0.first?.isNumber == true && $0.contains(".") })
                .map(String.init)
            return .installed(version: version)
        }
        return .notInstalled
    }
}
