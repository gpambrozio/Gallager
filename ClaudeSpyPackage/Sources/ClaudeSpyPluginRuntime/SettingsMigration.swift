import Foundation
import Logging

// MARK: - PluginSettingsMigration

/// One-shot migration from the legacy `AppSettings.claudeCommandPath` /
/// `AppSettings.codexCommandPath` UserDefaults keys to the per-plugin
/// `~/.gallager/state/plugins/<id>/settings.json` files (Spec §17.3,
/// Task 16).
///
/// Idempotent — keyed off `PluginSettingsMigrationV1Complete` in
/// UserDefaults. Subsequent launches see the flag and skip the migration
/// outright, so no UserDefaults reads / no filesystem writes happen on
/// the steady-state path.
///
/// Default-value carve-out: the legacy defaults are `"claude"` and
/// `"codex"`. A user who never edited the field has those exact strings
/// stored (or no key at all, depending on whether the property setter
/// ever ran), and there is no value to migrate — the plugin's own
/// `default` ("claude" / "codex") already resolves to the same launch
/// command. We only migrate non-default strings.
public struct PluginSettingsMigration: Sendable {
    /// Key used to record migration completion in UserDefaults. Reading
    /// the boolean lazily lets the migration self-skip without a separate
    /// state file.
    public static let migrationFlagKey = "PluginSettingsMigrationV1Complete"

    /// Legacy UserDefaults keys consumed by the migration. Public so
    /// tests can seed them deterministically.
    public static let claudeCommandPathKey = "claudeCommandPath"
    public static let codexCommandPathKey = "codexCommandPath"

    /// Defaults that match the legacy `AppSettings.Defaults`. A stored
    /// string equal to one of these is treated as "user accepted the
    /// default" — no migration needed.
    public static let claudeCommandDefault = "claude"
    public static let codexCommandDefault = "codex"

    private let layout: PluginRootLayout
    // `UserDefaults` is documented as thread-safe but not marked
    // `Sendable` in the Foundation overlay. The same `nonisolated(unsafe)`
    // dance `PreferencesService.liveValue` uses applies here — we only
    // touch it through its synchronized accessors.
    private nonisolated(unsafe) let userDefaults: UserDefaults
    private let logger: Logger

    /// - Parameters:
    ///   - layout: Filesystem layout used to resolve each plugin's
    ///     `settings.json` path.
    ///   - userDefaults: UserDefaults store the migration reads from /
    ///     writes to. Defaults to `.standard`; tests pass a
    ///     suite-scoped instance for isolation.
    ///   - logger: Optional logger; defaults to a quiet one.
    public init(
        layout: PluginRootLayout,
        userDefaults: UserDefaults = .standard,
        logger: Logger? = nil
    ) {
        self.layout = layout
        self.userDefaults = userDefaults
        self.logger = logger ?? Logger(label: "gallager.plugin.settings.migration")
    }

    /// Run the migration once. Subsequent calls are no-ops.
    ///
    /// Throws if a settings file can't be persisted; the migration flag
    /// is only set after every successful per-plugin write so a partial
    /// failure leaves the migration re-runnable.
    public func runIfNeeded() async throws {
        guard !userDefaults.bool(forKey: Self.migrationFlagKey) else {
            return
        }

        try migrate(
            pluginID: "claude-code",
            userDefaultsKey: Self.claudeCommandPathKey,
            defaultValue: Self.claudeCommandDefault
        )

        try migrate(
            pluginID: "codex",
            userDefaultsKey: Self.codexCommandPathKey,
            defaultValue: Self.codexCommandDefault
        )

        userDefaults.set(true, forKey: Self.migrationFlagKey)
    }

    // MARK: - Internal

    /// Migrate one (UserDefaults key, plugin id) pair.
    ///
    /// Writes `{"command_path": "<value>"}` to the plugin's settings.json
    /// when the stored value is present AND differs from `defaultValue`.
    /// Always clears the legacy key on success so a subsequent run never
    /// re-reads stale data.
    private func migrate(
        pluginID: String,
        userDefaultsKey: String,
        defaultValue: String
    ) throws {
        guard let storedValue = userDefaults.string(forKey: userDefaultsKey) else {
            // Nothing to migrate. Don't touch the plugin's settings file.
            return
        }

        // Clear the legacy key regardless of whether we write a file —
        // the next launch shouldn't keep re-reading it. We do this
        // BEFORE the write so a write failure leaves us in the
        // "value cleared from defaults, settings file untouched" state,
        // which the migration can recover from (the flag isn't set yet
        // so we'll re-run — but the cleared key means the second run
        // is a no-op for this plugin, which is acceptable because the
        // user's customisation is at worst lost back to the plugin
        // default; the alternative is repeatedly migrating the same
        // value, which is uglier).
        //
        // Actually — order matters. If the write succeeds and the
        // clear-key fails, we'd re-migrate next launch. If we clear
        // first and the write fails, we lose the customisation. Write
        // first, then clear, then set the flag at the top level.
        // Failure between write and clear is benign: a partial state
        // gets the value into the plugin file AND leaves it in
        // UserDefaults, but the next run will simply rewrite the
        // same value (settings.json overwrite is idempotent) before
        // clearing the key.

        guard storedValue != defaultValue else {
            // User accepted the default; nothing to migrate. Clear the
            // legacy key so the next launch's migration doesn't even
            // bother reading it.
            userDefaults.removeObject(forKey: userDefaultsKey)
            return
        }

        try writeSettings(
            pluginID: pluginID,
            commandPath: storedValue
        )
        userDefaults.removeObject(forKey: userDefaultsKey)

        logger.info(
            "Migrated \(userDefaultsKey) -> \(pluginID)/settings.json",
            metadata: ["value": "\(storedValue)"]
        )
    }

    /// Persist `{"command_path": "<commandPath>"}` to the plugin's
    /// settings.json. Creates the state directory if necessary; the file
    /// is written atomically.
    ///
    /// If the file already contains a `command_path` value, this
    /// overwrites it — the legacy UserDefaults value wins on the very
    /// first migration. Subsequent runs are guarded by the flag, so this
    /// only happens once.
    private func writeSettings(pluginID: String, commandPath: String) throws {
        let settingsURL = layout.settingsURL(pluginID)
        let stateDir = settingsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: stateDir,
            withIntermediateDirectories: true
        )

        // Merge with any existing settings so a user who already saved a
        // form value through the UI keeps the rest of their settings.
        // First migration almost always sees a missing file; this guard
        // is defensive.
        var existing: [String: AnyEncodable] = [:]
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            let data = try Data(contentsOf: settingsURL)
            if let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (key, value) in decoded {
                    existing[key] = AnyEncodable(value)
                }
            }
        }
        existing["command_path"] = AnyEncodable(commandPath)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(existing)
        try data.write(to: settingsURL, options: .atomic)
    }
}

// MARK: - AnyEncodable

/// Tiny `Encodable` wrapper for round-tripping a heterogeneous
/// `[String: Any]` decoded out of `JSONSerialization` and back into a
/// `JSONEncoder`-friendly shape.
///
/// We use `JSONSerialization` to read the existing file (so we don't
/// need to know its schema), then re-encode through `JSONEncoder` so
/// the migration's output uses the same pretty-printed key-sorted
/// shape as every other Gallager JSON file.
private struct AnyEncodable: Encodable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let string as String:
            try container.encode(string)
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case is NSNull:
            try container.encodeNil()
        case let array as [Any]:
            try container.encode(array.map(AnyEncodable.init))
        case let dict as [String: Any]:
            try container.encode(dict.mapValues(AnyEncodable.init))
        default:
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "AnyEncodable cannot encode \(type(of: value))"
                )
            )
        }
    }
}
