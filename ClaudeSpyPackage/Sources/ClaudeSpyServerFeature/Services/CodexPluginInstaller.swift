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
    @DependencyClient
    public struct CodexPluginInstaller: Sendable {
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

    extension CodexPluginInstaller: DependencyKey {
        public static var previewValue: CodexPluginInstaller {
            CodexPluginInstaller(install: { _ in }, uninstall: { _ in }, isInstalled: { _ in false })
        }

        public static var liveValue: CodexPluginInstaller {
            @Dependency(ProcessRunner.self) var processRunner
            let installer = LiveCodexPluginInstaller(processRunner: processRunner)
            return CodexPluginInstaller(
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

    private actor LiveCodexPluginInstaller {
        private let logger = Logger(label: "com.claudespy.codexplugininstaller")
        private let fileManager = FileManager.default
        private let processRunner: ProcessRunner

        /// Plugin folder name on disk and in the manifest.
        private static let pluginName = "gallager"

        /// Marketplace name we register with Codex. Matches the `name` field
        /// inside `plugin/codex/.agents/plugins/marketplace.json` that ships
        /// in the app bundle.
        private static let marketplaceName = "gallager"

        private static var pluginSelector: String {
            "\(pluginName)@\(marketplaceName)"
        }

        init(processRunner: ProcessRunner) {
            self.processRunner = processRunner
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

            let addResult = try await processRunner.run(
                codexPath,
                ["plugin", "add", Self.pluginSelector],
                nil,
                30
            )
            if !addResult.isSuccess {
                let stderr = addResult.stderrString.lowercased()
                let benign = stderr.contains("already") && stderr.contains("install")
                guard benign else {
                    throw CodexPluginInstallError.codexInvocationFailed(
                        command: "plugin add",
                        exitCode: addResult.exitCode,
                        stderr: addResult.stderrString
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
            let result = try await processRunner.run(
                codexPath,
                ["plugin", "marketplace", "add", source],
                nil,
                30
            )
            if result.isSuccess { return }

            let stderr = result.stderrString.lowercased()
            if stderr.contains("already added from a different source") {
                logger.info("Codex's existing '\(Self.marketplaceName)' marketplace points elsewhere; replacing it.")
                _ = try? await processRunner.run(
                    codexPath,
                    ["plugin", "marketplace", "remove", Self.marketplaceName],
                    nil,
                    30
                )
                let retry = try await processRunner.run(
                    codexPath,
                    ["plugin", "marketplace", "add", source],
                    nil,
                    30
                )
                guard retry.isSuccess else {
                    throw CodexPluginInstallError.codexInvocationFailed(
                        command: "plugin marketplace add",
                        exitCode: retry.exitCode,
                        stderr: retry.stderrString
                    )
                }
                return
            }

            // Any other failure is fatal.
            throw CodexPluginInstallError.codexInvocationFailed(
                command: "plugin marketplace add",
                exitCode: result.exitCode,
                stderr: result.stderrString
            )
        }

        // MARK: - Uninstall

        func uninstall(codexCommand: String) async throws {
            let codexPath = try await resolveCodexExecutable(codexCommand)
            let result = try await processRunner.run(
                codexPath,
                ["plugin", "remove", Self.pluginSelector],
                nil,
                30
            )
            if !result.isSuccess {
                let stderr = result.stderrString.lowercased()
                let benign = stderr.contains("not installed") || stderr.contains("not found")
                guard benign else {
                    throw CodexPluginInstallError.codexInvocationFailed(
                        command: "plugin remove",
                        exitCode: result.exitCode,
                        stderr: result.stderrString
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
            let result = try? await processRunner.run(
                codexPath,
                ["plugin", "list", "--marketplace", Self.marketplaceName],
                nil,
                10
            )
            guard let result, result.isSuccess else { return false }
            return parsePluginRow(result.stdoutString)
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
            let result = try await processRunner.run(
                zsh,
                ["-ilc", "command -v \(command) 2>/dev/null"],
                nil,
                5
            )
            guard result.isSuccess else { return "" }
            return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
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
