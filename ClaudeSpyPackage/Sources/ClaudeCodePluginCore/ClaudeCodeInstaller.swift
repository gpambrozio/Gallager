import Foundation
import GallagerPluginProtocol

// MARK: - ClaudeCodeInstaller

/// Registers (and removes) the Claude Code hook bridge in the agent's own hook
/// config so it fires for ANY Claude session (spec §8.1).
///
/// Unlike the legacy HTTP bridge (`plugin/gallager/scripts/hook.py`), the new
/// bridge writes ONE self-identifying length-prefixed frame to the well-known
/// UNIX socket `~/.gallager/state/ingress.sock`, baking in `plugin_id =
/// "claude-code"`. The frame format is the one documented on `IngressFrame`:
/// 4-byte big-endian length + JSON `{plugin_id, context, payload}`.
///
/// Registration is written into `<claudeRoot>/.claude/settings.json`'s `hooks`
/// map (the user-level hook config Claude reads for every session). We tag each
/// entry with a stable marker command so `isInstalled` / `uninstall` can find
/// exactly our entries without disturbing the user's other hooks.
///
/// Trap-free per spec §13: all reads/decodes tolerate missing or malformed
/// files. Paths are injected so the install↔uninstall round-trip is unit-testable
/// against a temp directory.
struct ClaudeCodeInstaller {
    /// `<claudeRoot>/settings.json` — where the hook registration is written.
    /// Defaults to `~/.claude/settings.json`.
    let settingsPath: URL
    /// Directory the bridge script is written into (the plugin state dir).
    let scriptDir: URL
    /// Absolute path of the ingress socket the bridge connects to.
    let socketPath: String

    /// A stable marker baked into our hook command so we can identify our own
    /// entries on read. Includes the plugin id per spec §8.1.
    static let markerToken = "GALLAGER_PLUGIN_ID=claude-code"

    /// Filename of the bridge script written into `scriptDir`.
    static let scriptName = "claude-hook-bridge.py"

    /// The Claude hook events the bridge registers for. Mirrors the existing
    /// `plugin/gallager/hooks/hooks.json` event list.
    static let hookEvents: [String] = [
        "SessionStart", "Setup", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
        "PermissionDenied", "PostToolUse", "PostToolUseFailure", "SubagentStart",
        "SubagentStop", "Stop", "PreCompact", "SessionEnd", "Notification",
        "TeammateIdle", "TaskCompleted", "PostCompact", "InstructionsLoaded",
        "StopFailure", "ConfigChange", "CwdChanged", "FileChanged", "Elicitation",
        "ElicitationResult", "WorktreeCreate", "WorktreeRemove", "TaskCreated",
        "UserPromptExpansion", "PostToolBatch",
    ]

    /// Default installer rooted at the real `~/.claude` + plugin state dir.
    static func live(stateDir: URL) -> ClaudeCodeInstaller {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ClaudeCodeInstaller(
            settingsPath: home.appendingPathComponent(".claude").appendingPathComponent("settings.json"),
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
        return .installed(message: "Claude Code hook bridge registered in \(settingsPath.path)")
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

    /// One Claude hook matcher object running our bridge. The marker env-var is
    /// embedded in the command so it survives a JSON round-trip and is easy to
    /// detect, while still passing the socket path + plugin id to the script.
    private func ourMatcher() -> [String: Any] {
        let scriptPath = scriptDir.appendingPathComponent(Self.scriptName).path
        let command = "\(Self.markerToken) "
            + "GALLAGER_INGRESS_SOCKET=\(shellQuote(socketPath)) "
            + "python3 \(shellQuote(scriptPath))"
        return [
            "hooks": [
                [
                    "type": "command",
                    "command": command,
                    "async": true,
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
        // Best-effort chmod +x so Claude can run it directly if it ever drops the
        // `python3` prefix; the registration invokes `python3 <script>` regardless.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
    }

    /// Minimal shell quoting for embedding a path in the hook command string.
    private func shellQuote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The language-agnostic bridge: reads stdin + `TMUX_PANE` /
    /// `CLAUDE_PROJECT_DIR`, connects to `GALLAGER_INGRESS_SOCKET`, and writes ONE
    /// frame (4-byte BE length prefix + JSON `{plugin_id, context, payload}`) with
    /// `plugin_id = "claude-code"` baked in, then exits. Silent on any failure so
    /// it never blocks the agent.
    static let bridgeScript = #"""
    #!/usr/bin/env python3
    import json
    import os
    import socket
    import struct
    import sys

    PLUGIN_ID = "claude-code"


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
        project_dir = os.environ.get("CLAUDE_PROJECT_DIR", "")
        if project_dir:
            context["CLAUDE_PROJECT_DIR"] = project_dir

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
            # ClaudeSpy not running / socket gone — drop silently.
            return


    if __name__ == "__main__":
        main()
    """#
}
