import Dependencies
import DependenciesMacros
import Foundation

// MARK: - ClaudeCodeInstaller

/// Installs / uninstalls / detects the `gallager` plugin inside the Claude
/// Code CLI's plugin marketplace.
///
/// Lives in `ClaudeCodePluginCore` rather than `ClaudeSpyServerFeature` so
/// the Task 12 sidecar executable can reuse the exact same install flow
/// the Mac app uses today (`PluginService.installPlugin()` will eventually
/// route through this dependency once Task 15 wires the new path).
///
/// The shape mirrors `PluginService`'s steps:
///   1. `claude plugin marketplace add <plugin-root>`
///   2. `claude plugin install gallager --scope user`
///   3. parse `~/.claude/plugins/installed_plugins.json` to confirm.
///
/// Each closure runs `claude` via `Process` with an optional
/// `CLAUDE_CONFIG_DIR` env override so users with a non-default `.claude`
/// folder still install correctly.
@DependencyClient
public struct ClaudeCodeInstaller: Sendable {
    /// Install the gallager plugin from `pluginRoot` (the directory
    /// containing the marketplace manifest) via the `claude` CLI at
    /// `claudeBin`. Returns `.ok` on success or `.failed(reason)`.
    public var install: @Sendable (
        _ pluginRoot: URL,
        _ claudeBin: URL,
        _ claudeConfigDir: URL?
    ) async throws -> InstallStatus = { _, _, _ in
        reportIssue("install")
        return .failed("unimplemented")
    }

    /// Uninstall the gallager plugin via `claude plugin uninstall gallager`.
    public var uninstall: @Sendable (
        _ claudeBin: URL,
        _ claudeConfigDir: URL?
    ) async throws -> InstallStatus = { _, _ in
        reportIssue("uninstall")
        return .failed("unimplemented")
    }

    /// Check `installed_plugins.json` under the resolved Claude config dir
    /// to see whether the gallager plugin is registered.
    public var isInstalled: @Sendable (
        _ claudeConfigDir: URL?
    ) async -> Bool = { _ in
        reportIssue("isInstalled")
        return false
    }

    public enum InstallStatus: Sendable, Equatable {
        case ok
        case failed(String)
    }
}

// MARK: - DependencyKey

extension ClaudeCodeInstaller: DependencyKey {
    public static let liveValue: Self = .live
    public static let testValue: Self = ClaudeCodeInstaller()

    public static let live: Self = ClaudeCodeInstaller(
        install: { pluginRoot, claudeBin, claudeConfigDir in
            do {
                // Step 1: register the marketplace (idempotent in
                // Claude CLI 1.x — adding the same path twice is a
                // no-op).
                let addResult = try await runClaude(
                    binary: claudeBin,
                    configDir: claudeConfigDir,
                    arguments: ["plugin", "marketplace", "add", pluginRoot.path]
                )
                guard addResult.isSuccess else {
                    return .failed(addResult.failureMessage(step: "add marketplace"))
                }

                // Step 2: install at user scope so it survives across
                // workspaces.
                let installResult = try await runClaude(
                    binary: claudeBin,
                    configDir: claudeConfigDir,
                    arguments: ["plugin", "install", "gallager", "--scope", "user"]
                )
                guard installResult.isSuccess else {
                    return .failed(installResult.failureMessage(step: "install plugin"))
                }

                return .ok
            } catch {
                return .failed("install failed: \(error)")
            }
        },
        uninstall: { claudeBin, claudeConfigDir in
            do {
                let result = try await runClaude(
                    binary: claudeBin,
                    configDir: claudeConfigDir,
                    arguments: ["plugin", "uninstall", "gallager"]
                )
                return result.isSuccess
                    ? .ok
                    : .failed(result.failureMessage(step: "uninstall plugin"))
            } catch {
                return .failed("uninstall failed: \(error)")
            }
        },
        isInstalled: { claudeConfigDir in
            let installedPath = resolveInstalledPluginsPath(
                claudeConfigDir: claudeConfigDir
            )
            return await Task.detached { () -> Bool in
                guard FileManager.default.fileExists(atPath: installedPath.path) else {
                    return false
                }
                guard
                    let data = try? Data(contentsOf: installedPath),
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let plugins = json["plugins"] as? [String: Any]
                else {
                    return false
                }
                // Plugin keys look like "gallager@Gallager" — only the
                // prefix is stable, the suffix is the marketplace name.
                return plugins.keys.contains { $0.hasPrefix("gallager@") }
            }.value
        }
    )
}

// MARK: - Helpers

private extension ClaudeCodeInstaller {
    /// Result of a `claude` invocation in a shape simpler than
    /// `ProcessResult` (we don't pull in `ClaudeSpyCommon` here so the
    /// installer can be lifted into the sidecar executable in Task 12
    /// without that dependency).
    struct RunResult: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String

        var isSuccess: Bool { exitCode == 0 }

        func failureMessage(step: String) -> String {
            let trimmedStderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedStderr.isEmpty {
                return "\(step) failed (exit \(exitCode)): \(trimmedStderr)"
            }
            return "\(step) failed (exit \(exitCode))"
        }
    }

    static func runClaude(
        binary: URL,
        configDir: URL?,
        arguments: [String]
    ) async throws -> RunResult {
        try await Task.detached(priority: .userInitiated) { () -> RunResult in
            let process = Process()
            process.executableURL = binary
            process.arguments = arguments

            var environment = ProcessInfo.processInfo.environment
            if let configDir {
                environment["CLAUDE_CONFIG_DIR"] = configDir.path
            }
            process.environment = environment

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            try process.run()
            process.waitUntilExit()

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

            return RunResult(
                exitCode: process.terminationStatus,
                stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                stderr: String(data: stderrData, encoding: .utf8) ?? ""
            )
        }.value
    }

    /// Resolves the path to `installed_plugins.json` under the chosen
    /// Claude config dir (or `~/.claude` when `configDir` is nil).
    static func resolveInstalledPluginsPath(
        claudeConfigDir: URL?
    ) -> URL {
        let root = claudeConfigDir ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        return root
            .appendingPathComponent("plugins")
            .appendingPathComponent("installed_plugins.json")
    }
}
