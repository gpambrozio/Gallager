import Foundation
import GallagerPluginProtocol

/// Errors raised while registering the Codex hook bridge.
enum CodexInstallerError: LocalizedError {
    /// The settings file exists but isn't valid top-level JSON, so overwriting
    /// it would destroy the user's config — we refuse instead.
    case settingsUnparseable(path: String)

    var errorDescription: String? {
        switch self {
        case let .settingsUnparseable(path):
            "Refusing to overwrite \(path): it exists but isn't valid JSON. Fix or remove it, then retry."
        }
    }
}

// MARK: - CodexInstaller

/// Registers (and removes) the Codex hook bridge in the agent's own hook config
/// so it fires for ANY Codex session (spec §8.1).
///
/// Mirrors the Claude core's installer model rather than the legacy
/// `codex plugin marketplace add` flow: it writes ONE self-identifying
/// length-prefixed frame to the well-known UNIX socket
/// `~/.gallager/state/ingress.sock`, baking in `plugin_id = "codex"`. The frame
/// format is the one documented on `IngressFrame`: 4-byte big-endian length +
/// JSON `{plugin_id, context, payload}`.
///
/// Registration is written into `<codexRoot>/hooks.json`'s `hooks` map (the same
/// `{matcher, hooks:[{type, command}]}` shape Codex's own
/// `plugin/codex/gallager/hooks/hooks.json` uses). We tag each entry with a
/// stable marker command so `isInstalled` / `uninstall` can find exactly our
/// entries without disturbing the user's other hooks.
///
/// Codex doesn't expose a project-dir env var the way Claude does, so the bridge
/// harvests the working directory from the payload's `cwd` field into the frame
/// context instead.
///
/// Trap-free per spec §13: all reads/decodes tolerate missing or malformed
/// files. Paths are injected so the install↔uninstall round-trip is unit-testable
/// against a temp directory.
struct CodexInstaller {
    /// `<codexRoot>/hooks.json` — where the hook registration is written.
    /// Defaults to `~/.codex/hooks.json`.
    let settingsPath: URL
    /// Directory the bridge script is written into (the plugin state dir).
    let scriptDir: URL
    /// Absolute path of the ingress socket the bridge connects to.
    let socketPath: String

    /// A stable marker baked into our hook command so we can identify our own
    /// entries on read. Includes the plugin id per spec §8.1.
    static let markerToken = "GALLAGER_PLUGIN_ID=codex"

    /// Filename of the bridge script written into `scriptDir`.
    static let scriptName = "codex-hook-bridge.py"

    /// The Codex hook events the bridge registers for. Mirrors the existing
    /// `plugin/codex/gallager/hooks/hooks.json` event list.
    static let hookEvents: [String] = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PermissionRequest", "PreCompact", "PostCompact", "SubagentStart",
        "SubagentStop", "Stop",
    ]

    /// Default installer rooted at the real `~/.codex` + plugin state dir.
    static func live(stateDir: URL) -> CodexInstaller {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return CodexInstaller(
            settingsPath: home.appendingPathComponent(".codex").appendingPathComponent("hooks.json"),
            scriptDir: stateDir,
            socketPath: home
                .appendingPathComponent(".gallager")
                .appendingPathComponent("state")
                .appendingPathComponent("ingress.sock")
                .path
        )
    }

    // MARK: - Install

    func install() throws -> InstallResult {
        if isInstalled() {
            return .alreadyInstalled
        }
        try writeBridgeScript()
        try writeHookRegistration()
        return .installed(message: "Codex hook bridge registered in \(settingsPath.path)")
    }

    // MARK: - Uninstall

    func uninstall() throws {
        guard var settings = readSettings() else { return }
        guard var hooks = settings["hooks"] as? [String: Any] else { return }

        for event in Self.hookEvents {
            guard var matchers = hooks[event] as? [[String: Any]] else { continue }
            matchers = matchers.filter { !Self.matcherIsOurs($0) }
            if matchers.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = matchers
            }
        }

        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
        try writeSettings(settings)

        // Remove the bridge script too (best-effort; ignore if absent).
        let scriptURL = scriptDir.appendingPathComponent(Self.scriptName)
        try? FileManager.default.removeItem(at: scriptURL)
    }

    // MARK: - Query

    /// True when our marked hook entry is present for at least one event.
    func isInstalled() -> Bool {
        guard
            let settings = readSettings(),
            let hooks = settings["hooks"] as? [String: Any]
        else { return false }

        for event in Self.hookEvents {
            guard let matchers = hooks[event] as? [[String: Any]] else { continue }
            if matchers.contains(where: Self.matcherIsOurs) {
                return true
            }
        }
        return false
    }

    // MARK: - Registration writing

    private func writeHookRegistration() throws {
        // Never clobber a real-but-unparseable settings file: if it exists on
        // disk but `readSettings()` can't decode it, bail rather than starting
        // from `[:]` — `writeSettings` would atomically overwrite it, wiping the
        // user's real config.
        if FileManager.default.fileExists(atPath: settingsPath.path), readSettings() == nil {
            throw CodexInstallerError.settingsUnparseable(path: settingsPath.path)
        }
        var settings = readSettings() ?? [:]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        let matcher = ourMatcher()
        for event in Self.hookEvents {
            var matchers = hooks[event] as? [[String: Any]] ?? []
            // Drop any stale entry of ours before appending the fresh one.
            matchers = matchers.filter { !Self.matcherIsOurs($0) }
            matchers.append(matcher)
            hooks[event] = matchers
        }
        settings["hooks"] = hooks
        try writeSettings(settings)
    }

    /// One Codex hook matcher object running our bridge. The marker env-var is
    /// embedded in the command so it survives a JSON round-trip and is easy to
    /// detect, while still passing the socket path + plugin id to the script.
    private func ourMatcher() -> [String: Any] {
        let scriptPath = scriptDir.appendingPathComponent(Self.scriptName).path
        let command = "\(Self.markerToken) "
            + "GALLAGER_INGRESS_SOCKET=\(shellQuote(socketPath)) "
            + "python3 \(shellQuote(scriptPath))"
        return [
            "matcher": ".*",
            "hooks": [
                [
                    "type": "command",
                    "command": command,
                    "timeout": 30,
                ] as [String: Any],
            ],
        ]
    }

    /// A matcher is ours if any of its inner command hooks carries our marker.
    private static func matcherIsOurs(_ matcher: [String: Any]) -> Bool {
        guard let inner = matcher["hooks"] as? [[String: Any]] else { return false }
        return inner.contains { hook in
            (hook["command"] as? String)?.contains(markerToken) ?? false
        }
    }

    // MARK: - Settings file IO (defensive)

    private func readSettings() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: settingsPath.path) else { return nil }
        guard
            let data = try? Data(contentsOf: settingsPath),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    private func writeSettings(_ settings: [String: Any]) throws {
        try FileManager.default.createDirectory(
            at: settingsPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: settingsPath, options: .atomic)
    }

    // MARK: - Bridge script

    private func writeBridgeScript() throws {
        try FileManager.default.createDirectory(
            at: scriptDir,
            withIntermediateDirectories: true
        )
        let scriptURL = scriptDir.appendingPathComponent(Self.scriptName)
        try Self.bridgeScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        // Best-effort chmod +x so Codex can run it directly; the registration
        // invokes `python3 <script>` regardless.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
    }

    /// Shell quoting for embedding a path in the hook command string. Single
    /// quotes (with the `'\''` escape) suppress all expansion — inside double
    /// quotes the shell would still expand `$`, backtick, and `\`.
    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The language-agnostic bridge: reads stdin + `TMUX_PANE`, harvests `cwd`
    /// from the payload (Codex has no project-dir env var), connects to
    /// `GALLAGER_INGRESS_SOCKET`, and writes ONE frame (4-byte BE length prefix +
    /// JSON `{plugin_id, context, payload}`) with `plugin_id = "codex"` baked in,
    /// then exits. Silent on any failure so it never blocks the agent.
    static let bridgeScript = #"""
    #!/usr/bin/env python3
    import json
    import os
    import socket
    import struct
    import sys

    PLUGIN_ID = "codex"


    def main():
        tmux_pane = os.environ.get("TMUX_PANE", "")
        if not tmux_pane:
            # Not inside tmux — nothing to mirror.
            return

        socket_path = os.environ.get("GALLAGER_INGRESS_SOCKET", "")
        if not socket_path:
            return

        raw = sys.stdin.read()
        try:
            payload = json.loads(raw) if raw.strip() else {}
        except Exception:
            return

        context = {"TMUX_PANE": tmux_pane}
        # Codex doesn't expose a project-dir env var; harvest cwd from the
        # payload so the core can resolve the project path. The context key
        # must match what CodexPluginCore reads (CODEX_PROJECT_DIR), mirroring
        # the Claude bridge's CLAUDE_PROJECT_DIR convention.
        if isinstance(payload, dict):
            cwd = payload.get("cwd")
            if isinstance(cwd, str) and cwd:
                context["CODEX_PROJECT_DIR"] = cwd

        body = json.dumps(
            {"plugin_id": PLUGIN_ID, "context": context, "payload": payload}
        ).encode("utf-8")
        frame = struct.pack(">I", len(body)) + body

        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(5)
            sock.connect(socket_path)
            sock.sendall(frame)
            sock.close()
        except Exception:
            # Gallager not running / socket gone — drop silently.
            return


    if __name__ == "__main__":
        main()
    """#
}
