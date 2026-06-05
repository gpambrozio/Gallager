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
    /// Fully-qualified plugin id (`<name>@<marketplace>`) as it appears in
    /// `claude plugin list --json`. Matching this — not a bare "gallager"
    /// substring — scopes status detection to our plugin.
    static let pluginRef = "gallager@gallager"

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
        // `--json` yields a machine-readable array of installed plugins, so we can
        // match our exact id instead of grepping for a "gallager" substring (which
        // a marketplace header or another plugin could spuriously satisfy).
        guard let result = try? await run(["plugin", "list", "--json"], configRoot: configRoot, timeout: 30) else {
            return .agentUnavailable
        }
        if result.exitCode == 127 { return .agentUnavailable }
        guard result.isSuccess else { return .notInstalled }
        return Self.parseStatus(from: result.stdoutString)
    }

    /// Parses `claude plugin list --json` output (an array of installed-plugin
    /// objects). Our plugin is the entry whose `id` equals `gallager@gallager`;
    /// its `version` field is authoritative. `claude plugin list` lists only
    /// *installed* plugins, so a present entry ⇒ installed. Absent id, malformed
    /// JSON, or an empty array ⇒ `.notInstalled`.
    static func parseStatus(from listing: String) -> PluginInstallStatus {
        guard
            let entries = try? JSONDecoder().decode([PluginListEntry].self, from: Data(listing.utf8)),
            let entry = entries.first(where: { $0.id == pluginRef })
        else {
            return .notInstalled
        }
        return .installed(version: entry.version)
    }

    /// Minimal projection of a `claude plugin list --json` entry; unknown keys
    /// (scope, enabled, installPath, …) are ignored by the decoder.
    private struct PluginListEntry: Decodable {
        let id: String
        let version: String?
    }
}
