import ClaudeSpyCommon
import Foundation
import GallagerPluginProtocol

/// Installs the Gallager Claude Code plugin through Claude's own CLI
/// (`claude plugin …`), scoped to a `CLAUDE_CONFIG_DIR`. The app never edits
/// Claude's settings files directly (spec §1–2). All invocations are wrapped in
/// `/usr/bin/env <command> …` so PATH resolution works and a missing binary
/// surfaces as exit 127 → `.agentUnavailable`.
struct ClaudeCodeCLIInstaller: Sendable {
    let processRunner: ProcessRunner
    /// The configured claude command (full path or bare `claude`).
    let command: String
    /// Bundled marketplace dir (`<app>/Contents/Resources/plugin`).
    let marketplaceSource: URL

    static let pluginName = "gallager"

    private func env(for configRoot: String?) -> [String: String]? {
        configRoot.map { ["CLAUDE_CONFIG_DIR": $0] }
    }

    private func run(_ args: [String], configRoot: String?, timeout: TimeInterval) async throws -> ProcessResult {
        try await processRunner.run("/usr/bin/env", [command] + args, env(for: configRoot), timeout)
    }

    func install(configRoot: String?) async throws -> InstallResult {
        // Marketplace add is idempotent; tolerate "already registered".
        _ = try? await run(["plugin", "marketplace", "add", marketplaceSource.path], configRoot: configRoot, timeout: 60)

        let result = try await run(["plugin", "install", Self.pluginName, "--scope", "user"], configRoot: configRoot, timeout: 120)
        if result.isSuccess {
            return .installed(message: "Installed \(Self.pluginName) via claude plugin install")
        }
        let stderr = result.stderrString.lowercased()
        if stderr.contains("already") && stderr.contains("install") {
            return .alreadyInstalled
        }
        throw ProcessRunnerError.executionFailed(exitCode: result.exitCode, stderr: result.stderrString)
    }

    func uninstall(configRoot: String?) async throws {
        _ = try await run(["plugin", "uninstall", Self.pluginName], configRoot: configRoot, timeout: 60)
    }

    func installStatus(configRoot: String?) async -> PluginInstallStatus {
        guard let result = try? await run(["plugin", "list"], configRoot: configRoot, timeout: 30) else {
            return .agentUnavailable
        }
        if result.exitCode == 127 { return .agentUnavailable }
        guard result.isSuccess else { return .notInstalled }
        return Self.parseStatus(from: result.stdoutString)
    }

    /// Finds a line mentioning our plugin and extracts a `x.y.z` version if present.
    /// Assumes the `claude plugin list` line format `<name> <version> …` (whitespace
    /// -separated columns); the first numeric, dot-bearing token is taken as the version.
    static func parseStatus(from listing: String) -> PluginInstallStatus {
        for line in listing.split(separator: "\n") where line.contains(pluginName) {
            let version = line
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .first(where: { $0.first?.isNumber == true && $0.contains(".") })
                .map(String.init)
            return .installed(version: version)
        }
        return .notInstalled
    }
}
