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
    static let marketplaceName = "gallager"

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
        // `-m gallager` scopes the listing to our marketplace, so the only
        // `gallager@gallager` row is ours.
        guard
            let result = try? await run(
                ["plugin", "list", "-m", Self.marketplaceName], configRoot: configRoot, timeout: 30
            ) else {
            return .agentUnavailable
        }
        if result.exitCode == 127 { return .agentUnavailable }
        guard result.isSuccess else { return .notInstalled }
        return Self.parseStatus(from: result.stdoutString)
    }

    /// Parses `codex plugin list -m gallager` output. Only the `gallager@gallager`
    /// row's STATUS column is authoritative — `"not installed"` ⇒ `.notInstalled`,
    /// `"installed"` ⇒ `.installed`. The marketplace header line (`` Marketplace
    /// `gallager` ``) and the on-disk plugin path must NOT be mistaken for an
    /// install. Version is the first dot-bearing numeric token on the row, if any.
    static func parseStatus(from listing: String) -> PluginInstallStatus {
        for line in listing.split(separator: "\n") where line.contains(pluginRef) {
            let lower = line.lowercased()
            if lower.contains("not installed") { return .notInstalled }
            guard lower.contains("installed") else { continue }
            let version = line
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .first(where: { $0.first?.isNumber == true && $0.contains(".") })
                .map(String.init)
            return .installed(version: version)
        }
        return .notInstalled
    }
}
