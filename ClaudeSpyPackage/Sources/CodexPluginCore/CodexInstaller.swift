#if os(macOS)
    import ClaudeSpyNetworking
    import Dependencies
    import DependenciesMacros
    import Foundation
    import Logging

    /// Installs the `gallager` Codex CLI plugin so Codex forwards every
    /// lifecycle event to the local Gallager HTTP server.
    ///
    /// The plugin and its marketplace ship inside the app bundle at
    /// `Resources/plugin/codex/`. Install points Codex at that path with
    /// `codex plugin marketplace add`, then `codex plugin add` to enable the
    /// plugin. Everything goes through Codex CLI commands; we never touch
    /// Codex's config files directly.
    ///
    /// The first time Codex runs after install it will still surface its own
    /// trust prompt for the hook commands — we register the plugin, the user
    /// trusts the hooks. There is no documented way to bypass that prompt.
    ///
    /// Renamed from `CodexPluginInstaller` (Task 10) to mirror
    /// `ClaudeCodeInstaller`. The internal `Process` helper avoids depending
    /// on `ProcessRunner` (which lives in `ClaudeSpyServerFeature`) so this
    /// type can be linked into the Codex sidecar executable in Task 13.
    @DependencyClient
    public struct CodexInstaller: Sendable {
        /// Installs (or refreshes) the gallager plugin. Pass the path to
        /// the user's `codex` binary so we can invoke `codex plugin add`.
        public var install: @Sendable (_ codexCommand: String) async throws -> Void = { _ in }

        /// Uninstalls the gallager plugin via `codex plugin remove`.
        public var uninstall: @Sendable (_ codexCommand: String) async throws -> Void = { _ in }

        /// Whether `codex plugin list` reports our plugin as installed. Pass
        /// the codex command so this can be queried even when the binary is
        /// outside the app's PATH.
        public var isInstalled: @Sendable (_ codexCommand: String) async -> Bool = { _ in false }
    }

    // MARK: - DependencyKey

    extension CodexInstaller: DependencyKey {
        public static var previewValue: CodexInstaller {
            CodexInstaller(install: { _ in }, uninstall: { _ in }, isInstalled: { _ in false })
        }

        public static var liveValue: CodexInstaller {
            let installer = LiveCodexInstaller()
            return CodexInstaller(
                install: { codexCommand in
                    try await installer.install(codexCommand: codexCommand)
                },
                uninstall: { codexCommand in
                    try await installer.uninstall(codexCommand: codexCommand)
                },
                isInstalled: { codexCommand in
                    await installer.isInstalled(codexCommand: codexCommand)
                }
            )
        }
    }

    // MARK: - Live Implementation

    private actor LiveCodexInstaller {
        private let logger = Logger(label: "com.claudespy.codexinstaller")
        private let fileManager = FileManager.default

        /// Plugin folder name on disk and in the manifest.
        private static let pluginName = "gallager"

        /// Marketplace name we register with Codex. Matches the `name` field
        /// inside `plugin/codex/.agents/plugins/marketplace.json` that ships
        /// in the app bundle.
        private static let marketplaceName = "gallager"

        private static var pluginSelector: String {
            "\(pluginName)@\(marketplaceName)"
        }

        // MARK: - Install

        func install(codexCommand: String) async throws {
            let codexPath = try await resolveCodexExecutable(codexCommand)
            let bundleMarketplaceRoot = try locateBundleMarketplaceRoot()

            // Point Codex at the marketplace shipped inside the .app bundle.
            // Codex copies plugin files into its own cache
            // (~/.codex/plugins/cache/...) on `plugin add`, so we never need
            // to write a shadow copy of the plugin to the user's home — and
            // Sparkle-replacing the .app in place keeps the bundle path
            // stable across updates.
            try await registerMarketplace(codexPath: codexPath, source: bundleMarketplaceRoot.path)

            let addResult = try await Self.runCodex(
                binary: codexPath,
                arguments: ["plugin", "add", Self.pluginSelector],
                timeout: 30
            )
            if !addResult.isSuccess {
                let stderr = addResult.stderr.lowercased()
                let benign = stderr.contains("already") && stderr.contains("install")
                guard benign else {
                    throw CodexPluginInstallError.codexInvocationFailed(
                        command: "plugin add",
                        exitCode: addResult.exitCode,
                        stderr: addResult.stderr
                    )
                }
                logger.info("Codex reports the plugin is already installed; treating as success.")
            }
            logger.info("Installed \(Self.pluginSelector) from \(bundleMarketplaceRoot.path)")
        }

        /// Runs `codex plugin marketplace add <source>`. If Codex reports
        /// that a marketplace by the same name is already registered from a
        /// different source (e.g. the bundle's own Claude marketplace shows
        /// up under the same `gallager` name when discovered at a higher
        /// path), removes that registration and retries the add so the new
        /// source wins.
        private func registerMarketplace(codexPath: String, source: String) async throws {
            let result = try await Self.runCodex(
                binary: codexPath,
                arguments: ["plugin", "marketplace", "add", source],
                timeout: 30
            )
            if result.isSuccess { return }

            let stderr = result.stderr.lowercased()
            if stderr.contains("already added from a different source") {
                logger.info("Codex's existing '\(Self.marketplaceName)' marketplace points elsewhere; replacing it.")
                // Surface — don't swallow — failure of the remove. If remove
                // fails for any reason other than "not present" (permissions,
                // pinned marketplace, codex CLI quirk), the retry below will
                // hit the same "already added from a different source" error
                // and the user gets the same opaque message; logging the
                // stderr here keeps a stuck install diagnosable.
                let removeResult = try await Self.runCodex(
                    binary: codexPath,
                    arguments: ["plugin", "marketplace", "remove", Self.marketplaceName],
                    timeout: 30
                )
                if !removeResult.isSuccess {
                    let removeStderr = removeResult.stderr.lowercased()
                    let benign = removeStderr.contains("not found") || removeStderr.contains("not present")
                    if !benign {
                        logger.warning(
                            "`codex plugin marketplace remove \(Self.marketplaceName)` failed (exit \(removeResult.exitCode)): \(removeResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
                        )
                    }
                }
                let retry = try await Self.runCodex(
                    binary: codexPath,
                    arguments: ["plugin", "marketplace", "add", source],
                    timeout: 30
                )
                guard retry.isSuccess else {
                    throw CodexPluginInstallError.codexInvocationFailed(
                        command: "plugin marketplace add",
                        exitCode: retry.exitCode,
                        stderr: retry.stderr
                    )
                }
                return
            }

            // Any other failure is fatal.
            throw CodexPluginInstallError.codexInvocationFailed(
                command: "plugin marketplace add",
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }

        // MARK: - Uninstall

        func uninstall(codexCommand: String) async throws {
            let codexPath = try await resolveCodexExecutable(codexCommand)
            let result = try await Self.runCodex(
                binary: codexPath,
                arguments: ["plugin", "remove", Self.pluginSelector],
                timeout: 30
            )
            if !result.isSuccess {
                let stderr = result.stderr.lowercased()
                let benign = stderr.contains("not installed") || stderr.contains("not found")
                guard benign else {
                    throw CodexPluginInstallError.codexInvocationFailed(
                        command: "plugin remove",
                        exitCode: result.exitCode,
                        stderr: result.stderr
                    )
                }
            }
            logger.info("Removed \(Self.pluginSelector) from Codex")
        }

        // MARK: - Installed Check

        func isInstalled(codexCommand: String) async -> Bool {
            // Ask Codex directly via `codex plugin list --marketplace
            // claudespy`. Output is a small text table; the row for our
            // plugin starts with the selector and a status word ("installed"
            // or "not installed"). We never read Codex's config files
            // directly so the install/uninstall flow stays the source of
            // truth.
            guard let codexPath = try? await resolveCodexExecutable(codexCommand) else {
                return false
            }
            let result = try? await Self.runCodex(
                binary: codexPath,
                arguments: ["plugin", "list", "--marketplace", Self.marketplaceName],
                timeout: 10
            )
            guard let result, result.isSuccess else { return false }
            return parsePluginRow(result.stdout)
        }

        /// Returns `true` if the `codex plugin list` table contains a row
        /// whose first column is `<plugin>@<marketplace>` and whose status
        /// is `installed` (in any enabled/disabled flavor) rather than
        /// `not installed`.
        private func parsePluginRow(_ output: String) -> Bool {
            for line in output.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix(Self.pluginSelector) else { continue }
                // Strip the leading selector + whitespace and check the
                // status column. Codex prints "not installed" or
                // "installed, enabled" / "installed, disabled" / ...
                let rest = trimmed.dropFirst(Self.pluginSelector.count)
                let statusArea = rest.trimmingCharacters(in: .whitespaces)
                if statusArea.lowercased().hasPrefix("not installed") {
                    return false
                }
                if statusArea.lowercased().hasPrefix("installed") {
                    return true
                }
            }
            return false
        }

        // MARK: - Bundle Layout
        //
        // The Codex marketplace ships in its own subdirectory of the bundle
        // so it doesn't share a root with the Claude marketplace at
        // `plugin/.claude-plugin/marketplace.json`:
        //
        //   Gallager.app/Contents/Resources/plugin/
        //     .claude-plugin/marketplace.json   (Claude marketplace, unchanged)
        //     gallager/                         (Claude plugin)
        //     codex/
        //       .agents/plugins/marketplace.json   (name = "claudespy")
        //       codex-gallager/                    (referenced as ./codex-gallager)
        //         .codex-plugin/plugin.json
        //         hooks/hooks.json
        //         scripts/hook.py
        //
        // Codex resolves a marketplace's "root" by walking up from
        // marketplace.json stripping `.agents/plugins/marketplace.json`, so
        // the root here is `<bundle>/plugin/codex/` and `./codex-gallager`
        // resolves to that directory's `codex-gallager/`. No copying.

        private func locateBundleMarketplaceRoot() throws -> URL {
            guard
                let root = Bundle.main.resourceURL?
                    .appendingPathComponent("plugin", isDirectory: true)
                    .appendingPathComponent("codex", isDirectory: true) else {
                throw CodexPluginInstallError.bundledPluginNotFound
            }
            let manifest = root
                .appendingPathComponent(".agents", isDirectory: true)
                .appendingPathComponent("plugins", isDirectory: true)
                .appendingPathComponent("marketplace.json")
            let pluginDir = root.appendingPathComponent(Self.pluginName, isDirectory: true)
            guard
                fileManager.fileExists(atPath: manifest.path),
                fileManager.fileExists(atPath: pluginDir.path) else {
                throw CodexPluginInstallError.bundledPluginNotFound
            }
            return root
        }

        // MARK: - Executable Resolution

        /// Resolves a possibly-bare `codex` command to an absolute path.
        ///
        /// macOS apps launched from the Finder/Dock inherit a minimal `PATH`
        /// (`/usr/bin:/bin:/usr/sbin:/sbin`) — Homebrew, Volta, nvm, asdf,
        /// mise, cargo, etc. are not in it even though `codex` works fine in
        /// the user's terminal. We try, in order:
        ///   1. Absolute path → use directly.
        ///   2. The app's own `PATH` plus a curated list of common Codex
        ///      install locations.
        ///   3. The user's login shell (`/bin/zsh -ilc 'command -v codex'`)
        ///      which loads their `~/.zprofile`/`~/.zshrc` and resolves
        ///      whatever path manager they actually use.
        private func resolveCodexExecutable(_ command: String) async throws -> String {
            if command.hasPrefix("/") {
                guard fileManager.isExecutableFile(atPath: command) else {
                    throw CodexPluginInstallError.codexNotFound(command)
                }
                return command
            }

            if let curated = curatedLookup(command) {
                return curated
            }

            if let viaShell = try? await loginShellLookup(command), !viaShell.isEmpty {
                if fileManager.isExecutableFile(atPath: viaShell) {
                    return viaShell
                }
            }

            throw CodexPluginInstallError.codexNotFound(command)
        }

        private func curatedLookup(_ command: String) -> String? {
            let home = fileManager.homeDirectoryForCurrentUser.path
            let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":")
                .map(String.init)
            let fallbacks = [
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
                "\(home)/.local/bin",
                "\(home)/.cargo/bin",
                "\(home)/.npm-global/bin",
                "\(home)/.volta/bin",
                "\(home)/.bun/bin",
            ]
            for dir in pathDirs + fallbacks {
                let candidate = (dir as NSString).appendingPathComponent(command)
                if fileManager.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
            return nil
        }

        /// Asks the user's login shell to resolve the command. Captures
        /// version-manager shims (nvm / asdf / volta / mise / fnm) that
        /// don't live at any fixed path.
        private func loginShellLookup(_ command: String) async throws -> String {
            let zsh = "/bin/zsh"
            guard fileManager.isExecutableFile(atPath: zsh) else { return "" }
            let result = try await Self.runCodex(
                binary: zsh,
                arguments: ["-ilc", "command -v \(command) 2>/dev/null"],
                timeout: 5
            )
            guard result.isSuccess else { return "" }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // MARK: - Process helper

        /// Lightweight `Process` runner used in place of the
        /// `ProcessRunner` dependency (which lives in
        /// `ClaudeSpyServerFeature` and would create a circular
        /// dependency). Mirrors the helper inside `ClaudeCodeInstaller`.
        fileprivate struct RunResult: Sendable {
            let exitCode: Int32
            let stdout: String
            let stderr: String

            var isSuccess: Bool { exitCode == 0 }
        }

        fileprivate static func runCodex(
            binary: String,
            arguments: [String],
            timeout: TimeInterval
        ) async throws -> RunResult {
            try await Task.detached(priority: .userInitiated) { () -> RunResult in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binary)
                process.arguments = arguments
                process.environment = ProcessInfo.processInfo.environment

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                try process.run()

                // Watchdog: if the process outlives `timeout`, terminate it
                // (SIGTERM, then SIGKILL) so an interactive login shell that
                // blocks on a slow `~/.zshrc` prompt can't hang the RPC
                // forever. Killing the process closes its pipe write ends,
                // which lets the reads below hit EOF and unblock.
                let watchdog = Task {
                    try? await Task.sleep(for: .seconds(timeout))
                    guard process.isRunning else { return }
                    process.terminate()
                    try? await Task.sleep(for: .seconds(2))
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
                defer { watchdog.cancel() }

                // Drain both pipes *concurrently* before waiting on exit.
                // `readDataToEndOfFile()` returns on pipe EOF (the child
                // closing its write ends on exit); reading them sequentially
                // would still deadlock if the child fills stderr's buffer
                // (~64KB) while we're blocked draining stdout, so run them on
                // separate tasks.
                async let stdoutTask = Task.detached {
                    stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                }.value
                async let stderrTask = Task.detached {
                    stderrPipe.fileHandleForReading.readDataToEndOfFile()
                }.value
                let stdoutData = await stdoutTask
                let stderrData = await stderrTask
                process.waitUntilExit()

                return RunResult(
                    exitCode: process.terminationStatus,
                    stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                    stderr: String(data: stderrData, encoding: .utf8) ?? ""
                )
            }.value
        }
    }

    // MARK: - Errors

    public enum CodexPluginInstallError: Error, LocalizedError {
        case bundledPluginNotFound
        case codexNotFound(String)
        case codexInvocationFailed(command: String, exitCode: Int32, stderr: String)

        public var errorDescription: String? {
            switch self {
            case .bundledPluginNotFound:
                "Could not locate the bundled codex-gallager plugin inside the app."
            case let .codexNotFound(command):
                "Couldn't find the codex executable (\(command)). Check the Codex CLI Command path in Settings."
            case let .codexInvocationFailed(command, exitCode, stderr):
                "`codex \(command)` failed (exit \(exitCode)): \(stderr)"
            }
        }
    }

#endif
