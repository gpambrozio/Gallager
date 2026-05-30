import ClaudeCodePluginCore
import ClaudeSpyCommon
import CodexPluginCore
import Foundation

/// One-shot migration (spec §11): copies the legacy per-agent command path /
/// auto-run values from `AppSettings` (UserDefaults) into each plugin's typed
/// `settings.json`, so the cores read the user's existing configuration on the
/// first launch of the plugin-system build.
///
/// Idempotent — guarded by a UserDefaults flag; never clobbers an existing
/// settings file (so a user edit or a prior migration wins). The legacy
/// UserDefaults keys are intentionally left in place for now; they are removed
/// in the flag-day flip when `AppSettings`' agent fields are deleted and the
/// old hook path goes away (so the still-live legacy path keeps working).
@MainActor
enum PluginSettingsMigration {
    static let flagKey = "pluginSettingsMigrationV1Done"

    static func runIfNeeded(
        paths: GallagerPaths,
        claudeCommandPath: String,
        claudeAutoRun: Bool,
        codexCommandPath: String,
        codexAutoRun: Bool,
        preferences: PreferencesService
    ) {
        guard preferences.optionalBool(flagKey) != true else { return }

        writeIfAbsent(
            ClaudeCodeSettings(commandPath: claudeCommandPath, autoRun: claudeAutoRun),
            to: paths.pluginSettingsPath("claude-code")
        )
        writeIfAbsent(
            CodexSettings(commandPath: codexCommandPath, autoRun: codexAutoRun),
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
