import ClaudeSpyNetworking
import Foundation
import GallagerPluginProtocol
import Testing
@testable import CodexPluginCore

/// Round-trips the hook-bridge registration against a temp directory:
/// install → isInstalled true → uninstall → isInstalled false. Also verifies the
/// bridge script is written with the plugin id + socket baked in, and that the
/// installer leaves unrelated hook entries alone.
@Suite("CodexInstaller")
struct CodexInstallerTests {
    private let fileManager = FileManager.default

    private func makeInstaller() throws -> (CodexInstaller, URL) {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("gallager-cx-install-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let installer = CodexInstaller(
            settingsPath: root.appendingPathComponent("hooks.json"),
            scriptDir: root.appendingPathComponent("state"),
            socketPath: root.appendingPathComponent("ingress.sock").path
        )
        return (installer, root)
    }

    @Test("install → isInstalled → uninstall round-trips")
    func roundTrip() throws {
        let (installer, root) = try makeInstaller()
        defer { try? fileManager.removeItem(at: root) }

        #expect(installer.isInstalled() == false)

        let result = try installer.install()
        if case .alreadyInstalled = result {
            Issue.record("expected .installed on first install")
        }
        #expect(installer.isInstalled() == true)

        try installer.uninstall()
        #expect(installer.isInstalled() == false)
    }

    @Test("installing twice reports alreadyInstalled")
    func idempotentInstall() throws {
        let (installer, root) = try makeInstaller()
        defer { try? fileManager.removeItem(at: root) }

        _ = try installer.install()
        let second = try installer.install()
        guard case .alreadyInstalled = second else {
            Issue.record("expected .alreadyInstalled on the second install")
            return
        }
    }

    @Test("registration bakes the plugin id + socket into the hook command")
    func registrationContents() throws {
        let (installer, root) = try makeInstaller()
        defer { try? fileManager.removeItem(at: root) }

        _ = try installer.install()

        let settingsData = try Data(contentsOf: installer.settingsPath)
        let settings = try #require(
            try JSONSerialization.jsonObject(with: settingsData) as? [String: Any]
        )
        let hooks = try #require(settings["hooks"] as? [String: Any])
        // Every configured event is registered.
        for event in CodexInstaller.hookEvents {
            #expect(hooks[event] != nil)
        }
        // Probe one event's command string.
        let permission = try #require(hooks["PermissionRequest"] as? [[String: Any]])
        #expect(permission.first?["matcher"] as? String == ".*")
        let inner = try #require(permission.first?["hooks"] as? [[String: Any]])
        let command = try #require(inner.first?["command"] as? String)
        #expect(command.contains("GALLAGER_PLUGIN_ID=codex"))
        #expect(command.contains(installer.socketPath))
        #expect(command.contains(CodexInstaller.scriptName))
    }

    @Test("the bridge script is written, executable, and targets the unix socket")
    func bridgeScriptWritten() throws {
        let (installer, root) = try makeInstaller()
        defer { try? fileManager.removeItem(at: root) }

        _ = try installer.install()

        let scriptURL = installer.scriptDir.appendingPathComponent(CodexInstaller.scriptName)
        #expect(fileManager.fileExists(atPath: scriptURL.path))

        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        #expect(script.contains("AF_UNIX"))
        #expect(script.contains("PLUGIN_ID = \"codex\""))
        #expect(script.contains("GALLAGER_INGRESS_SOCKET"))
        #expect(script.contains("struct.pack(\">I\""))
        // Codex bridge harvests cwd from the payload (no project-dir env var).
        #expect(script.contains("payload.get(\"cwd\")"))

        let attrs = try fileManager.attributesOfItem(atPath: scriptURL.path)
        let perms = try #require(attrs[.posixPermissions] as? NSNumber)
        #expect(perms.int16Value & 0o111 != 0) // some execute bit set
    }

    @Test("uninstall preserves unrelated user hook entries")
    func preservesUserHooks() throws {
        let (installer, root) = try makeInstaller()
        defer { try? fileManager.removeItem(at: root) }

        // Seed a pre-existing user hook the installer must not clobber.
        let userHook: [String: Any] = [
            "matcher": ".*",
            "hooks": [
                ["type": "command", "command": "echo user-owned"] as [String: Any],
            ],
        ]
        let seeded: [String: Any] = ["hooks": ["PreToolUse": [userHook]]]
        let data = try JSONSerialization.data(withJSONObject: seeded)
        try data.write(to: installer.settingsPath)

        _ = try installer.install()
        try installer.uninstall()

        let after = try Data(contentsOf: installer.settingsPath)
        let settings = try #require(try JSONSerialization.jsonObject(with: after) as? [String: Any])
        let hooks = try #require(settings["hooks"] as? [String: Any])
        let preTool = try #require(hooks["PreToolUse"] as? [[String: Any]])
        // The user's hook survives; ours is gone.
        let commands = preTool
            .compactMap { $0["hooks"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["command"] as? String }
        #expect(commands.contains("echo user-owned"))
        #expect(!commands.contains { $0.contains(CodexInstaller.markerToken) })
    }

    @Test("isInstalled tolerates a malformed hooks.json without trapping")
    func defensiveIsInstalled() throws {
        let (installer, root) = try makeInstaller()
        defer { try? fileManager.removeItem(at: root) }
        try Data("{ not json".utf8).write(to: installer.settingsPath)
        #expect(installer.isInstalled() == false)
    }

    @Test("install refuses to overwrite an existing-but-unparseable settings file")
    func installBailsOnUnparseableSettings() throws {
        let (installer, root) = try makeInstaller()
        defer { try? fileManager.removeItem(at: root) }

        let corrupt = "{ this is not valid json"
        try Data(corrupt.utf8).write(to: installer.settingsPath)

        #expect(throws: CodexInstallerError.self) {
            _ = try installer.install()
        }
        let after = try String(contentsOf: installer.settingsPath, encoding: .utf8)
        #expect(after == corrupt)
    }
}
