#if os(macOS)
    import ClaudeSpyNetworking
    import Dependencies
    import DependenciesMacros
    import Foundation
    import Logging

    /// Installs the global Codex CLI hook configuration that forwards every
    /// lifecycle event to the local ClaudeSpy HTTP server.
    ///
    /// Codex's per-project hook config (`<repo>/.codex/hooks.json`) requires
    /// the user to explicitly trust the project, which produces one trust
    /// prompt per repository. The global layer (`~/.codex/hooks.json`) needs
    /// approval only once, so that's what we write to.
    @DependencyClient
    public struct CodexHookInstaller: Sendable {
        /// Installs (or refreshes) the Codex hook configuration. Idempotent;
        /// rewrites the config to point at the current ClaudeSpy bridge script.
        public var install: @Sendable () async throws -> Void = { }

        /// Removes the ClaudeSpy-managed hook entries from Codex's config. The
        /// global config file itself is left in place (it may host hooks the
        /// user added manually).
        public var uninstall: @Sendable () async throws -> Void = { }

        /// Whether Codex hooks pointing at the current ClaudeSpy bridge are
        /// currently installed.
        public var isInstalled: @Sendable () async -> Bool = { false }
    }

    // MARK: - DependencyKey

    extension CodexHookInstaller: DependencyKey {
        public static var previewValue: CodexHookInstaller {
            CodexHookInstaller(install: { }, uninstall: { }, isInstalled: { false })
        }

        public static var liveValue: CodexHookInstaller {
            let installer = LiveCodexHookInstaller()
            return CodexHookInstaller(
                install: { try await installer.install() },
                uninstall: { try await installer.uninstall() },
                isInstalled: { await installer.isInstalled() }
            )
        }
    }

    // MARK: - Live Implementation

    private actor LiveCodexHookInstaller {
        private let logger = Logger(label: "com.claudespy.codexinstaller")
        private let fileManager = FileManager.default

        /// The complete set of Codex hook events we register handlers for.
        /// Mirrors the events Codex CLI v0.132+ emits.
        private static let codexEvents: [String] = [
            "SessionStart",
            "UserPromptSubmit",
            "PreToolUse",
            "PostToolUse",
            "PermissionRequest",
            "PreCompact",
            "PostCompact",
            "SubagentStart",
            "SubagentStop",
            "Stop",
        ]

        /// Marker so we can detect (and only modify) our own hook entries when
        /// rewriting `~/.codex/hooks.json` — never touch entries the user
        /// installed themselves.
        private static let managedMarker = "claudespy-bridge"

        func install() async throws {
            let bridgePath = try await ensureBridgeOnDisk()
            try writeHooksFile(bridgePath: bridgePath)
            logger.info("Installed Codex hooks pointing at \(bridgePath.path)")
        }

        func uninstall() async throws {
            let hooksURL = codexHomeURL().appendingPathComponent("hooks.json")
            guard fileManager.fileExists(atPath: hooksURL.path) else { return }
            let data = try Data(contentsOf: hooksURL)
            guard
                let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                var hooks = raw["hooks"] as? [String: [[String: Any]]] else {
                return
            }
            for event in Self.codexEvents {
                guard var entries = hooks[event] else { continue }
                entries.removeAll(where: { isOurEntry($0) })
                if entries.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = entries
                }
            }
            var updated = raw
            if hooks.isEmpty {
                updated.removeValue(forKey: "hooks")
            } else {
                updated["hooks"] = hooks
            }
            try writeJSON(updated, to: hooksURL)
            logger.info("Uninstalled ClaudeSpy entries from Codex hooks.json")
        }

        func isInstalled() async -> Bool {
            let hooksURL = codexHomeURL().appendingPathComponent("hooks.json")
            guard
                fileManager.fileExists(atPath: hooksURL.path),
                let data = try? Data(contentsOf: hooksURL),
                let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let hooks = raw["hooks"] as? [String: [[String: Any]]] else {
                return false
            }
            return hooks.values.flatMap(\.self).contains(where: isOurEntry)
        }

        // MARK: - Hooks JSON

        private func writeHooksFile(bridgePath: URL) throws {
            let hooksURL = codexHomeURL().appendingPathComponent("hooks.json")
            try fileManager.createDirectory(
                at: codexHomeURL(),
                withIntermediateDirectories: true
            )

            var root: [String: Any] = [:]
            if
                let data = try? Data(contentsOf: hooksURL),
                let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                root = existing
            }

            var existingHooks = (root["hooks"] as? [String: [[String: Any]]]) ?? [:]
            let ourEntry = buildHookEntry(bridgePath: bridgePath)

            for event in Self.codexEvents {
                var entries = existingHooks[event] ?? []
                entries.removeAll(where: { isOurEntry($0) })
                entries.append(ourEntry)
                existingHooks[event] = entries
            }
            root["hooks"] = existingHooks

            try writeJSON(root, to: hooksURL)
        }

        private func buildHookEntry(bridgePath: URL) -> [String: Any] {
            let pythonPath = "/usr/bin/env"
            let command = "\(pythonPath) python3 \(shellEscape(bridgePath.path)) --agent codex"
            return [
                "matcher": ".*",
                // The Codex schema nests an array of hook handlers under the
                // matcher entry. We attach our marker on the outer matcher
                // dict so uninstall can find it without inspecting commands.
                Self.managedMarker: true,
                "hooks": [
                    [
                        "type": "command",
                        "command": command,
                        "timeout": 30,
                    ],
                ],
            ]
        }

        private func isOurEntry(_ entry: [String: Any]) -> Bool {
            if entry[Self.managedMarker] as? Bool == true { return true }
            // Fallback: detect our bridge via the command string in case the
            // marker was stripped by an external editor.
            if
                let nested = entry["hooks"] as? [[String: Any]],
                nested.contains(where: { ($0["command"] as? String)?.contains("--agent codex") == true }) {
                return true
            }
            return false
        }

        private func writeJSON(_ object: [String: Any], to url: URL) throws {
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: url, options: .atomic)
        }

        private func shellEscape(_ path: String) -> String {
            "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
        }

        // MARK: - Codex Home

        private func codexHomeURL() -> URL {
            if let override = ProcessInfo.processInfo.environment["CODEX_HOME"], !override.isEmpty {
                return URL(fileURLWithPath: override).standardizedFileURL
            }
            return fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex")
                .standardizedFileURL
        }

        // MARK: - Bridge Script

        /// Copies the bundled `hook.py` to a stable path under
        /// `~/.claudespy/bin/` so Codex's hook config can reference it without
        /// depending on the gallager Claude-plugin install layout. Re-copies
        /// when the bundled version differs from the on-disk copy.
        private func ensureBridgeOnDisk() async throws -> URL {
            let destinationDir = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".claudespy")
                .appendingPathComponent("bin")
            try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)
            let destination = destinationDir.appendingPathComponent("hook.py")

            guard let bundled = bundledHookURL() else {
                throw CodexHookInstallError.bridgeNotFound
            }

            // Copy only when the on-disk copy is missing or stale.
            let bundledData = try Data(contentsOf: bundled)
            let existingData = (try? Data(contentsOf: destination)) ?? Data()
            if bundledData != existingData {
                try bundledData.write(to: destination, options: .atomic)
                try fileManager.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: destination.path
                )
            }
            return destination
        }

        private func bundledHookURL() -> URL? {
            // Resource path in Bundle.main; falls back to walking the bundled
            // plugin directory for development builds where the script lives
            // next to the .app rather than inside Resources.
            if
                let resourceURL = Bundle.main.resourceURL?
                    .appendingPathComponent("plugin")
                    .appendingPathComponent("gallager")
                    .appendingPathComponent("scripts")
                    .appendingPathComponent("hook.py"),
                fileManager.fileExists(atPath: resourceURL.path) {
                return resourceURL
            }
            return nil
        }
    }

    // MARK: - Errors

    public enum CodexHookInstallError: Error, LocalizedError {
        case bridgeNotFound

        public var errorDescription: String? {
            switch self {
            case .bridgeNotFound:
                "Could not locate the bundled ClaudeSpy hook bridge script."
            }
        }
    }

#endif
