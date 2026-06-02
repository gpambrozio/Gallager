import ClaudeCodePluginCore
import ClaudeSpyCommon
import CodexPluginCore
import Foundation

/// One-shot migration (spec §11): copies the legacy per-agent command path /
/// auto-run values from UserDefaults (previously owned by `AppSettings`) into
/// each plugin's typed `settings.json`, so the cores read the user's existing
/// configuration on the first launch of the plugin-system build.
///
/// Reads legacy values by raw UserDefaults key so the `AppSettings` per-agent
/// properties can be deleted without breaking seeding.
///
/// Idempotent — guarded by a UserDefaults flag; never clobbers an existing
/// settings file (so a user edit or a prior migration wins).
///
/// Note: users who already ran the V1 migration (commandPath + autoRun only)
/// have an existing settings.json, so `writeIfAbsent` will NOT overwrite it.
/// Their `closePaneOnSessionEnd`/`additionalConfigFolders` will stay at the
/// decoder defaults (false/[]). This is acceptable: those fields default off/
/// empty and users set them via the Agents tab.
@MainActor
enum PluginSettingsMigration {
    static let flagKey = "pluginSettingsMigrationV1Done"

    // Raw UserDefaults keys for the legacy AppSettings per-agent fields.
    private enum LegacyKeys {
        static let claudeCommandPath = "claudeCommandPath"
        static let autoRunClaudeInProjects = "autoRunClaudeInProjects"
        static let codexCommandPath = "codexCommandPath"
        static let autoRunCodexInProjects = "autoRunCodexInProjects"
        static let closePaneOnSessionEnd = "closePaneOnSessionEnd"
        static let additionalClaudeFolders = "additionalClaudeFolders"
    }

    static func runIfNeeded(paths: GallagerPaths, preferences: PreferencesService) {
        guard preferences.optionalBool(flagKey) != true else { return }

        let claudeCommandPath = preferences.string(LegacyKeys.claudeCommandPath) ?? "claude"
        let claudeAutoRun = preferences.optionalBool(LegacyKeys.autoRunClaudeInProjects) ?? true
        let codexCommandPath = preferences.string(LegacyKeys.codexCommandPath) ?? "codex"
        let codexAutoRun = preferences.optionalBool(LegacyKeys.autoRunCodexInProjects) ?? true
        let closePaneOnSessionEnd = preferences.optionalBool(LegacyKeys.closePaneOnSessionEnd) ?? false

        // additionalClaudeFolders was stored as JSONEncoder().encode([String]) data.
        let additionalConfigFolders: [String]
        if
            let data = preferences.data(LegacyKeys.additionalClaudeFolders),
            let decoded = try? JSONDecoder().decode([String].self, from: data) {
            additionalConfigFolders = decoded
        } else {
            additionalConfigFolders = []
        }

        writeIfAbsent(
            ClaudeCodeSettings(
                commandPath: claudeCommandPath,
                autoRun: claudeAutoRun,
                additionalConfigFolders: additionalConfigFolders,
                closePaneOnSessionEnd: closePaneOnSessionEnd
            ),
            to: paths.pluginSettingsPath("claude-code")
        )
        writeIfAbsent(
            CodexSettings(
                commandPath: codexCommandPath,
                autoRun: codexAutoRun,
                closePaneOnSessionEnd: closePaneOnSessionEnd
                // Codex has no legacy additional-folders source → keeps default []
            ),
            to: paths.pluginSettingsPath("codex")
        )

        preferences.setBool(true, flagKey)
    }

    private static func writeIfAbsent(_ value: some Encodable, to url: URL) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            // Best-effort: cores fall back to typed defaults when the file is absent.
        }
    }
}
