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
            PluginSettingsMigration.runIfNeeded(
                paths: paths,
                claudeCommandPath: "/custom/claude",
                claudeAutoRun: false,
                codexCommandPath: "/custom/codex",
                codexAutoRun: true,
                preferences: preferences
            )

            let claude = try ClaudeCodeSettings.decode(from: Data(contentsOf: paths.pluginSettingsPath("claude-code")))
            #expect(claude.commandPath == "/custom/claude")
            #expect(claude.autoRun == false)

            let codex = try CodexSettings.decode(from: Data(contentsOf: paths.pluginSettingsPath("codex")))
            #expect(codex.commandPath == "/custom/codex")
            #expect(codex.autoRun == true)

            // Flag is set so a second run is a no-op.
            #expect(preferences.optionalBool(PluginSettingsMigration.flagKey) == true)
        }
    }

    @Test("is a no-op once the flag is set")
    func idempotent() throws {
        let (paths, root) = makePaths()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        try withDependencies {
            $0[PreferencesService.self] = .inMemory()
        } operation: {
            @Dependency(PreferencesService.self) var preferences
            preferences.setBool(true, PluginSettingsMigration.flagKey)

            PluginSettingsMigration.runIfNeeded(
                paths: paths,
                claudeCommandPath: "/custom/claude",
                claudeAutoRun: false,
                codexCommandPath: "/custom/codex",
                codexAutoRun: true,
                preferences: preferences
            )

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

        try withDependencies {
            $0[PreferencesService.self] = .inMemory()
        } operation: {
            @Dependency(PreferencesService.self) var preferences
            PluginSettingsMigration.runIfNeeded(
                paths: paths,
                claudeCommandPath: "/custom/claude",
                claudeAutoRun: false,
                codexCommandPath: "/custom/codex",
                codexAutoRun: true,
                preferences: preferences
            )

            // The user's existing file is preserved.
            let claude = try ClaudeCodeSettings.decode(from: Data(contentsOf: claudePath))
            #expect(claude.commandPath == "/user/edited")
        }
    }
}
