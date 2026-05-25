import Foundation
import Testing
@testable import ClaudeSpyPluginRuntime

@Suite("PluginSettingsMigration")
struct SettingsMigrationTests {
    // MARK: - Helpers

    /// Create a fresh temp directory + a `PluginRootLayout` rooted at it.
    /// Per-test cleanup keeps parallel tests from stomping on each other.
    private func withTempLayout<R: Sendable>(
        _ body: (PluginRootLayout, URL) async throws -> R
    ) async throws -> R {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SettingsMigration-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = PluginRootLayout.live(rootOverride: root, bundledOverride: root)
        return try await body(layout, root)
    }

    /// UUID-suffixed UserDefaults suite so each test has its own key
    /// namespace and parallel tests don't observe each other's writes.
    /// Removed in the closure's `defer` block so test artifacts don't
    /// accumulate on the host preferences plist.
    private func withTempUserDefaults<R>(
        _ body: (UserDefaults, String) async throws -> R
    ) async throws -> R {
        let suiteName = "SettingsMigration-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Could not create UserDefaults suite \(suiteName)")
            throw CocoaError(.fileWriteUnknown)
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return try await body(defaults, suiteName)
    }

    private func decodeSettings(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let parsed = try JSONSerialization.jsonObject(with: data)
        guard let dict = parsed as? [String: Any] else {
            Issue.record("Settings file is not a JSON object: \(url.path)")
            throw CocoaError(.fileReadCorruptFile)
        }
        return dict
    }

    // MARK: - Custom path migrates

    @Test("non-default Claude command path migrates to plugin settings.json")
    func customClaudePathMigrates() async throws {
        try await withTempLayout { layout, _ in
            try await withTempUserDefaults { defaults, _ in
                defaults.set(
                    "/opt/claude/bin/claude",
                    forKey: PluginSettingsMigration.claudeCommandPathKey
                )

                let migration = PluginSettingsMigration(
                    layout: layout,
                    userDefaults: defaults
                )

                try await migration.runIfNeeded()

                // Claude settings file exists with the custom path.
                let claudeURL = layout.settingsURL("claude-code")
                #expect(FileManager.default.fileExists(atPath: claudeURL.path))
                let claudeSettings = try decodeSettings(at: claudeURL)
                #expect(claudeSettings["command_path"] as? String == "/opt/claude/bin/claude")

                // Codex defaults; no file written.
                let codexURL = layout.settingsURL("codex")
                #expect(!FileManager.default.fileExists(atPath: codexURL.path))

                // Legacy UserDefaults key cleared.
                #expect(defaults.string(forKey: PluginSettingsMigration.claudeCommandPathKey) == nil)

                // Migration flag set.
                #expect(defaults.bool(forKey: PluginSettingsMigration.migrationFlagKey))
            }
        }
    }

    // MARK: - Default path does NOT migrate

    @Test("default Claude command path is skipped; legacy key still cleared")
    func defaultPathDoesNotMigrate() async throws {
        try await withTempLayout { layout, _ in
            try await withTempUserDefaults { defaults, _ in
                // User had the default value stored — common when an early
                // launch wrote the default through the property setter.
                defaults.set(
                    PluginSettingsMigration.claudeCommandDefault,
                    forKey: PluginSettingsMigration.claudeCommandPathKey
                )

                let migration = PluginSettingsMigration(
                    layout: layout,
                    userDefaults: defaults
                )
                try await migration.runIfNeeded()

                // No settings file — the default is the plugin's own default.
                let claudeURL = layout.settingsURL("claude-code")
                #expect(!FileManager.default.fileExists(atPath: claudeURL.path))

                // Legacy key cleared so a future re-migration doesn't trip.
                #expect(defaults.string(forKey: PluginSettingsMigration.claudeCommandPathKey) == nil)

                // Migration flag set.
                #expect(defaults.bool(forKey: PluginSettingsMigration.migrationFlagKey))
            }
        }
    }

    // MARK: - Both agents migrate

    @Test("both Claude and Codex custom paths migrate independently")
    func bothAgentsMigrate() async throws {
        try await withTempLayout { layout, _ in
            try await withTempUserDefaults { defaults, _ in
                defaults.set(
                    "/opt/claude",
                    forKey: PluginSettingsMigration.claudeCommandPathKey
                )
                defaults.set(
                    "/opt/codex",
                    forKey: PluginSettingsMigration.codexCommandPathKey
                )

                let migration = PluginSettingsMigration(
                    layout: layout,
                    userDefaults: defaults
                )
                try await migration.runIfNeeded()

                let claudeSettings = try decodeSettings(at: layout.settingsURL("claude-code"))
                #expect(claudeSettings["command_path"] as? String == "/opt/claude")

                let codexSettings = try decodeSettings(at: layout.settingsURL("codex"))
                #expect(codexSettings["command_path"] as? String == "/opt/codex")
            }
        }
    }

    // MARK: - Idempotence

    @Test("running the migration twice is a no-op the second time")
    func idempotent() async throws {
        try await withTempLayout { layout, _ in
            try await withTempUserDefaults { defaults, _ in
                defaults.set(
                    "/opt/claude",
                    forKey: PluginSettingsMigration.claudeCommandPathKey
                )

                let migration = PluginSettingsMigration(
                    layout: layout,
                    userDefaults: defaults
                )
                try await migration.runIfNeeded()

                // Mutate the file out-of-band; the second run must NOT
                // overwrite it.
                let claudeURL = layout.settingsURL("claude-code")
                let mutated = """
                {
                  "command_path": "/edited/by/user"
                }
                """
                try mutated.data(using: .utf8)!.write(to: claudeURL)

                // Re-add the legacy key to prove the second pass doesn't
                // re-consume it (the flag should short-circuit the migration).
                defaults.set(
                    "/opt/claude-NEW",
                    forKey: PluginSettingsMigration.claudeCommandPathKey
                )

                try await migration.runIfNeeded()

                // File is whatever the user wrote, not what we'd have written.
                let stillMutated = try String(contentsOf: claudeURL, encoding: .utf8)
                #expect(stillMutated.contains("/edited/by/user"))

                // The re-added legacy key is left alone (flag short-circuit
                // means the migration didn't even read it).
                #expect(
                    defaults.string(forKey: PluginSettingsMigration.claudeCommandPathKey)
                        == "/opt/claude-NEW"
                )
            }
        }
    }

    // MARK: - No-op when nothing is stored

    @Test("running with no UserDefaults state still sets the migration flag")
    func emptyUserDefaultsSetsFlag() async throws {
        try await withTempLayout { layout, _ in
            try await withTempUserDefaults { defaults, _ in
                let migration = PluginSettingsMigration(
                    layout: layout,
                    userDefaults: defaults
                )
                try await migration.runIfNeeded()

                #expect(defaults.bool(forKey: PluginSettingsMigration.migrationFlagKey))
                #expect(!FileManager.default.fileExists(atPath: layout.settingsURL("claude-code").path))
                #expect(!FileManager.default.fileExists(atPath: layout.settingsURL("codex").path))
            }
        }
    }
}
