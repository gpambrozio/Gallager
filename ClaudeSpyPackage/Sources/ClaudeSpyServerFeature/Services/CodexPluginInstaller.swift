#if os(macOS)
    import ClaudeSpyNetworking
    import Dependencies
    import DependenciesMacros
    import Foundation
    import Logging

    /// Installs the `codex-gallager` Codex CLI plugin so Codex forwards every
    /// lifecycle event to the local Gallager HTTP server.
    ///
    /// The plugin ships inside the app bundle at
    /// `Resources/plugin/codex-gallager/`. Install copies it to
    /// `~/.agents/plugins/codex-gallager/`, registers it in the personal
    /// marketplace at `~/.agents/plugins/marketplace.json`, then invokes
    /// `codex plugin add codex-gallager@personal` so Codex picks it up.
    ///
    /// The first time Codex runs after install it will still surface its own
    /// trust prompt for the hook commands — we register the plugin, the user
    /// trusts the hooks. There is no documented way to bypass that prompt.
    @DependencyClient
    public struct CodexPluginInstaller: Sendable {
        /// Installs (or refreshes) the codex-gallager plugin. Pass the path to
        /// the user's `codex` binary so we can invoke `codex plugin add`.
        public var install: @Sendable (_ codexCommand: String) async throws -> Void = { _ in }

        /// Uninstalls the codex-gallager plugin via `codex plugin remove`.
        /// Leaves the marketplace entry and copied plugin folder in place so
        /// reinstall is a one-click operation.
        public var uninstall: @Sendable (_ codexCommand: String) async throws -> Void = { _ in }

        /// Whether the plugin folder and marketplace entry exist. This is a
        /// best-effort proxy for "Codex knows about us"; the source of truth
        /// (enabled vs. disabled per-plugin) lives in `~/.codex/config.toml`
        /// as TOML which Swift can't parse without an extra dep.
        public var isInstalled: @Sendable () async -> Bool = { false }
    }

    // MARK: - DependencyKey

    extension CodexPluginInstaller: DependencyKey {
        public static var previewValue: CodexPluginInstaller {
            CodexPluginInstaller(install: { _ in }, uninstall: { _ in }, isInstalled: { false })
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
                isInstalled: { await installer.isInstalled() }
            )
        }
    }

    // MARK: - Live Implementation

    private actor LiveCodexPluginInstaller {
        private let logger = Logger(label: "com.claudespy.codexplugininstaller")
        private let fileManager = FileManager.default
        private let processRunner: ProcessRunner

        /// Plugin folder name on disk and in the marketplace entry.
        private static let pluginName = "codex-gallager"

        /// Personal marketplace name used by Codex's auto-discovered
        /// `~/.agents/plugins/marketplace.json`.
        private static let marketplaceName = "personal"

        init(processRunner: ProcessRunner) {
            self.processRunner = processRunner
        }

        // MARK: - Install

        func install(codexCommand: String) async throws {
            // Resolve the codex binary BEFORE touching the filesystem so a
            // PATH miss doesn't leave half-installed state on disk that
            // makes `isInstalled` lie afterwards.
            let codexPath = try await resolveCodexExecutable(codexCommand)

            let bundled = try locateBundledPlugin()
            let destination = pluginDestinationURL()

            try copyPluginFolder(from: bundled, to: destination)
            try updateMarketplaceJSON()

            // `codex plugin add` returns an error if the plugin is already
            // added. We swallow the "already installed" failure so reinstall
            // is a one-click operation.
            let result = try await processRunner.run(
                codexPath,
                ["plugin", "add", "\(Self.pluginName)@\(Self.marketplaceName)"],
                nil,
                30
            )
            if !result.isSuccess {
                let stderr = result.stderrString.lowercased()
                let benign = stderr.contains("already") && stderr.contains("install")
                guard benign else {
                    throw CodexPluginInstallError.codexInvocationFailed(
                        exitCode: result.exitCode,
                        stderr: result.stderrString
                    )
                }
                logger.info("Codex reports the plugin is already installed; treating as success.")
            }
            logger.info("Installed \(Self.pluginName) at \(destination.path)")
        }

        // MARK: - Uninstall

        func uninstall(codexCommand: String) async throws {
            let codexPath = try await resolveCodexExecutable(codexCommand)
            let result = try await processRunner.run(
                codexPath,
                ["plugin", "remove", "\(Self.pluginName)@\(Self.marketplaceName)"],
                nil,
                30
            )
            if !result.isSuccess {
                let stderr = result.stderrString.lowercased()
                let benign = stderr.contains("not installed") || stderr.contains("not found")
                guard benign else {
                    throw CodexPluginInstallError.codexInvocationFailed(
                        exitCode: result.exitCode,
                        stderr: result.stderrString
                    )
                }
            }
            logger.info("Removed \(Self.pluginName) from Codex")
        }

        // MARK: - Installed Check

        func isInstalled() async -> Bool {
            // Source of truth is what Codex itself records. `codex plugin
            // add` writes a `[plugins."<name>@<marketplace>"]` table to
            // `~/.codex/config.toml`; `codex plugin remove` deletes it. Our
            // on-disk plugin folder and marketplace.json can persist past a
            // failed add, so checking those alone gives false positives.
            let configURL = codexConfigURL()
            guard
                fileManager.fileExists(atPath: configURL.path),
                let data = try? Data(contentsOf: configURL),
                let toml = String(data: data, encoding: .utf8) else {
                return false
            }
            return toml.contains("\(Self.pluginName)@\(Self.marketplaceName)")
        }

        private func codexConfigURL() -> URL {
            if let override = ProcessInfo.processInfo.environment["CODEX_HOME"], !override.isEmpty {
                return URL(fileURLWithPath: override).appendingPathComponent("config.toml")
            }
            return fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex")
                .appendingPathComponent("config.toml")
        }

        // MARK: - File Layout

        private func pluginDestinationURL() -> URL {
            agentsPluginsRoot().appendingPathComponent(Self.pluginName, isDirectory: true)
        }

        private func marketplaceJSONURL() -> URL {
            agentsPluginsRoot().appendingPathComponent("marketplace.json")
        }

        private func agentsPluginsRoot() -> URL {
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".agents", isDirectory: true)
                .appendingPathComponent("plugins", isDirectory: true)
        }

        private func locateBundledPlugin() throws -> URL {
            guard
                let candidate = Bundle.main.resourceURL?
                    .appendingPathComponent("plugin", isDirectory: true)
                    .appendingPathComponent(Self.pluginName, isDirectory: true),
                fileManager.fileExists(atPath: candidate.path) else {
                throw CodexPluginInstallError.bundledPluginNotFound
            }
            return candidate
        }

        // MARK: - Copy

        private func copyPluginFolder(from source: URL, to destination: URL) throws {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            // Codex inspects the plugin folder lazily; replacing it atomically
            // would require a sibling-rename dance. Doing a remove-then-copy is
            // good enough because install is user-initiated and a half-state
            // is recoverable by re-running install.
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: source, to: destination)
        }

        // MARK: - Marketplace JSON

        private func updateMarketplaceJSON() throws {
            try fileManager.createDirectory(
                at: agentsPluginsRoot(),
                withIntermediateDirectories: true
            )

            let url = marketplaceJSONURL()
            var root = readExistingMarketplace(at: url)

            // Seed top-level fields if this is a brand-new marketplace.
            if root["name"] == nil {
                root["name"] = Self.marketplaceName
            }
            if root["interface"] == nil {
                root["interface"] = ["displayName": "Personal"]
            }

            var plugins = (root["plugins"] as? [[String: Any]]) ?? []
            plugins.removeAll { ($0["name"] as? String) == Self.pluginName }
            plugins.append(buildPluginEntry())
            root["plugins"] = plugins

            let data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: url, options: .atomic)
        }

        private func readExistingMarketplace(at url: URL) -> [String: Any] {
            guard
                fileManager.fileExists(atPath: url.path),
                let data = try? Data(contentsOf: url),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return [:]
            }
            return json
        }

        private func buildPluginEntry() -> [String: Any] {
            [
                "name": Self.pluginName,
                "source": [
                    "source": "local",
                    "path": "./plugins/\(Self.pluginName)",
                ],
                "policy": [
                    "installation": "AVAILABLE",
                    "authentication": "ON_INSTALL",
                ],
                "category": "Productivity",
            ]
        }

        private func marketplaceContainsOurPlugin() -> Bool {
            let json = readExistingMarketplace(at: marketplaceJSONURL())
            let plugins = (json["plugins"] as? [[String: Any]]) ?? []
            return plugins.contains { ($0["name"] as? String) == Self.pluginName }
        }

        // MARK: - Executable Resolution

        /// Resolves a possibly-bare `codex` command to an absolute path.
        ///
        /// macOS apps launched from the Finder/Dock inherit a minimal `PATH`
        /// (`/usr/bin:/bin:/usr/sbin:/sbin`) — Homebrew, Volta, nvm, asdf,
        /// cargo, etc. are not in it even though `codex` works fine in the
        /// user's terminal. We try, in order:
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
        case codexInvocationFailed(exitCode: Int32, stderr: String)

        public var errorDescription: String? {
            switch self {
            case .bundledPluginNotFound:
                "Could not locate the bundled codex-gallager plugin inside the app."
            case let .codexNotFound(command):
                "Couldn't find the codex executable (\(command)). Check the Codex CLI Command path in Settings."
            case let .codexInvocationFailed(exitCode, stderr):
                "`codex plugin` failed (exit \(exitCode)): \(stderr)"
            }
        }
    }

#endif
