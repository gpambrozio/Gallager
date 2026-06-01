import ClaudeSpyNetworking
import Foundation
import GallagerPluginProtocol
import Testing
@testable import ClaudeCodePluginCore

/// Round-trips the hook-bridge registration against a temp directory:
/// install → isInstalled true → uninstall → isInstalled false. Also verifies the
/// bridge script is written with the plugin id + socket baked in, and that the
/// installer leaves unrelated hook entries alone.
@Suite("ClaudeCodeInstaller")
struct ClaudeCodeInstallerTests {
    private let fileManager = FileManager.default

    private func makeInstaller() throws -> (ClaudeCodeInstaller, URL) {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("gallager-cc-install-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let installer = ClaudeCodeInstaller(
            settingsPath: root.appendingPathComponent("settings.json"),
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
        for event in ClaudeCodeInstaller.hookEvents {
            #expect(hooks[event] != nil)
        }
        // Probe one event's command string.
        let permission = try #require(hooks["PermissionRequest"] as? [[String: Any]])
        let inner = try #require(permission.first?["hooks"] as? [[String: Any]])
        let command = try #require(inner.first?["command"] as? String)
        #expect(command.contains("GALLAGER_PLUGIN_ID=claude-code"))
        #expect(command.contains(installer.socketPath))
        #expect(command.contains(ClaudeCodeInstaller.scriptName))
    }

    @Test("the bridge script is written, executable, and targets the unix socket")
    func bridgeScriptWritten() throws {
        let (installer, root) = try makeInstaller()
        defer { try? fileManager.removeItem(at: root) }

        _ = try installer.install()

        let scriptURL = installer.scriptDir.appendingPathComponent(ClaudeCodeInstaller.scriptName)
        #expect(fileManager.fileExists(atPath: scriptURL.path))

        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        #expect(script.contains("AF_UNIX"))
        #expect(script.contains("\"claude-code\"") || script.contains("PLUGIN_ID = \"claude-code\""))
        #expect(script.contains("GALLAGER_INGRESS_SOCKET"))
        #expect(script.contains("struct.pack(\">I\""))

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
        #expect(!commands.contains { $0.contains(ClaudeCodeInstaller.markerToken) })
    }

    @Test("isInstalled tolerates a malformed settings.json without trapping")
    func defensiveIsInstalled() throws {
        let (installer, root) = try makeInstaller()
        defer { try? fileManager.removeItem(at: root) }
        try Data("{ not json".utf8).write(to: installer.settingsPath)
        #expect(installer.isInstalled() == false)
    }

    @Test("install refuses to overwrite an existing-but-unparseable settings.json")
    func installBailsOnUnparseableSettings() throws {
        let (installer, root) = try makeInstaller()
        defer { try? fileManager.removeItem(at: root) }

        // A real-but-corrupt config the user would be furious to lose.
        let corrupt = "{ this is not valid json"
        try Data(corrupt.utf8).write(to: installer.settingsPath)

        #expect(throws: ClaudeCodeInstallerError.self) {
            _ = try installer.install()
        }
        // The file is left exactly as it was — not overwritten.
        let after = try String(contentsOf: installer.settingsPath, encoding: .utf8)
        #expect(after == corrupt)
    }
}
