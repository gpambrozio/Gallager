import ClaudeCodePluginCore
import ClaudeSpyCommon
import CodexPluginCore
import Dependencies
import Foundation
import Testing
@testable import ClaudeSpyServerFeature

@MainActor
@Suite("PluginSettingsMigration")
struct PluginSettingsMigrationTests {
    /// A fresh temp state root + `GallagerPaths` override, auto-cleaned.
    private func makePaths() -> (GallagerPaths, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gallager-migration-test-\(UUID().uuidString)")
            .appendingPathComponent("state")
        return (GallagerPaths(stateRootOverride: root), root)
    }

    @Test("writes legacy command paths + auto-run into each plugin's settings.json")
    func migratesLegacyValues() throws {
        let (paths, root) = makePaths()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        try withDependencies {
            $0[PreferencesService.self] = .inMemory()
        } operation: {
            @Dependency(PreferencesService.self) var preferences

            // Seed legacy UserDefaults keys directly (as AppSettings used to write them).
            preferences.setString("/custom/claude", "claudeCommandPath")
            preferences.setBool(false, "autoRunClaudeInProjects")
            preferences.setString("/custom/codex", "codexCommandPath")
            preferences.setBool(true, "autoRunCodexInProjects")
            preferences.setBool(true, "closePaneOnSessionEnd")
            // additionalClaudeFolders stored as JSON-encoded [String]
            let foldersData = try JSONEncoder().encode(["/extra/folder1", "/extra/folder2"])
            preferences.setData(foldersData, "additionalClaudeFolders")

            PluginSettingsMigration.runIfNeeded(paths: paths, preferences: preferences)

            let claude = ClaudeCodeSettings.decode(from: (try? Data(contentsOf: paths.pluginSettingsPath("claude-code"))) ?? Data())
            #expect(claude.commandPath == "/custom/claude")
            #expect(claude.autoRun == false)
            #expect(claude.closePaneOnSessionEnd == true)
            #expect(claude.additionalConfigFolders == ["/extra/folder1", "/extra/folder2"])

            let codex = CodexSettings.decode(from: (try? Data(contentsOf: paths.pluginSettingsPath("codex"))) ?? Data())
            #expect(codex.commandPath == "/custom/codex")
            #expect(codex.autoRun == true)
            #expect(codex.closePaneOnSessionEnd == true)
            // Codex has no legacy additional-folders source
            #expect(codex.additionalConfigFolders == [])

            // Flag is set so a second run is a no-op.
            #expect(preferences.optionalBool(PluginSettingsMigration.flagKey) == true)
        }
    }

    @Test("falls back to defaults when legacy keys are absent")
    func migratesWithDefaults() {
        let (paths, root) = makePaths()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        withDependencies {
            $0[PreferencesService.self] = .inMemory()
        } operation: {
            @Dependency(PreferencesService.self) var preferences
            // No legacy keys set — all values should be defaults.
            PluginSettingsMigration.runIfNeeded(paths: paths, preferences: preferences)

            let claude = ClaudeCodeSettings.decode(from: (try? Data(contentsOf: paths.pluginSettingsPath("claude-code"))) ?? Data())
            #expect(claude.commandPath == "claude")
            #expect(claude.autoRun == true)
            #expect(claude.closePaneOnSessionEnd == false)
            #expect(claude.additionalConfigFolders == [])

            let codex = CodexSettings.decode(from: (try? Data(contentsOf: paths.pluginSettingsPath("codex"))) ?? Data())
            #expect(codex.commandPath == "codex")
            #expect(codex.autoRun == true)
            #expect(codex.closePaneOnSessionEnd == false)
        }
    }

    @Test("is a no-op once the flag is set")
    func idempotent() {
        let (paths, root) = makePaths()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        withDependencies {
            $0[PreferencesService.self] = .inMemory()
        } operation: {
            @Dependency(PreferencesService.self) var preferences
            preferences.setBool(true, PluginSettingsMigration.flagKey)

            // Seed some legacy keys to confirm they aren't read when flag is set.
            preferences.setString("/custom/claude", "claudeCommandPath")

            PluginSettingsMigration.runIfNeeded(paths: paths, preferences: preferences)

            // Nothing written because the flag was already set.
            #expect(!FileManager.default.fileExists(atPath: paths.pluginSettingsPath("claude-code").path))
        }
    }

    @Test("does not clobber an existing settings.json")
    func doesNotClobber() throws {
        let (paths, root) = makePaths()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        // Pre-existing user file.
        let claudePath = paths.pluginSettingsPath("claude-code")
        try FileManager.default.createDirectory(
            at: claudePath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(ClaudeCodeSettings(commandPath: "/user/edited", autoRun: true))
            .write(to: claudePath)

        withDependencies {
            $0[PreferencesService.self] = .inMemory()
        } operation: {
            @Dependency(PreferencesService.self) var preferences
            preferences.setString("/custom/claude", "claudeCommandPath")

            PluginSettingsMigration.runIfNeeded(paths: paths, preferences: preferences)

            // The user's existing file is preserved.
            let claude = ClaudeCodeSettings.decode(from: (try? Data(contentsOf: claudePath)) ?? Data())
            #expect(claude.commandPath == "/user/edited")
        }
    }
}
