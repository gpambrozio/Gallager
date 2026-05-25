import Foundation
import Testing
@testable import GallagerPluginProtocol

@Suite("Bundled settings.json schemas")
struct BundledSettingsSchemaTests {
    // MARK: - Fixtures

    /// The exact Claude Code settings JSON from Spec §17.3, shipped at
    /// `PluginBundles/claude-code/ui/settings.json`.
    private static let claudeCodeSettingsJSON = #"""
    {
      "schema_version": 1,
      "sections": [
        {
          "title": "Command",
          "fields": [
            {
              "id": "command_path",
              "type": "string",
              "label": "Claude CLI command",
              "default": "claude",
              "placeholder": "claude",
              "help": "Absolute path or $PATH-discoverable name."
            }
          ]
        },
        {
          "title": "Behavior",
          "fields": [
            {
              "id": "auto_run",
              "type": "boolean",
              "label": "Auto-launch Claude when opening a project",
              "default": true
            },
            {
              "id": "log_level",
              "type": "picker",
              "label": "Sidecar log level",
              "default": "info",
              "options": [
                { "value": "debug", "label": "Debug" },
                { "value": "info",  "label": "Info" },
                { "value": "warn",  "label": "Warning" },
                { "value": "error", "label": "Error" }
              ]
            }
          ]
        }
      ]
    }
    """#

    /// The same shape with Codex-specific labels (`PluginBundles/codex/ui/settings.json`).
    private static let codexSettingsJSON = #"""
    {
      "schema_version": 1,
      "sections": [
        {
          "title": "Command",
          "fields": [
            {
              "id": "command_path",
              "type": "string",
              "label": "Codex CLI command",
              "default": "codex",
              "placeholder": "codex",
              "help": "Absolute path or $PATH-discoverable name."
            }
          ]
        },
        {
          "title": "Behavior",
          "fields": [
            {
              "id": "auto_run",
              "type": "boolean",
              "label": "Auto-launch Codex when opening a project",
              "default": true
            },
            {
              "id": "log_level",
              "type": "picker",
              "label": "Sidecar log level",
              "default": "info",
              "options": [
                { "value": "debug", "label": "Debug" },
                { "value": "info",  "label": "Info" },
                { "value": "warn",  "label": "Warning" },
                { "value": "error", "label": "Error" }
              ]
            }
          ]
        }
      ]
    }
    """#

    private static func snakeCaseDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    // MARK: - Claude Code

    @Test("Bundled Claude Code settings.json decodes to PluginSettingsSchema")
    func bundledClaudeSettingsSchemaDecodes() throws {
        let data = Data(Self.claudeCodeSettingsJSON.utf8)
        let schema = try Self.snakeCaseDecoder().decode(PluginSettingsSchema.self, from: data)

        #expect(schema.schemaVersion == 1)
        #expect(schema.sections.count == 2)

        // First section: Command — one string field.
        let command = schema.sections[0]
        #expect(command.title == "Command")
        #expect(command.fields.count == 1)
        guard case let .string(commandPath) = command.fields[0] else {
            Issue.record("Expected command_path to be a string field, got \(command.fields[0])")
            return
        }
        #expect(commandPath.id == "command_path")
        #expect(commandPath.label == "Claude CLI command")
        #expect(commandPath.default == "claude")
        #expect(commandPath.placeholder == "claude")
        #expect(commandPath.help == "Absolute path or $PATH-discoverable name.")

        // Second section: Behavior — boolean + picker.
        let behavior = schema.sections[1]
        #expect(behavior.title == "Behavior")
        #expect(behavior.fields.count == 2)

        guard case let .boolean(autoRun) = behavior.fields[0] else {
            Issue.record("Expected auto_run to be a boolean field, got \(behavior.fields[0])")
            return
        }
        #expect(autoRun.id == "auto_run")
        #expect(autoRun.label == "Auto-launch Claude when opening a project")
        #expect(autoRun.default == true)

        guard case let .picker(logLevel) = behavior.fields[1] else {
            Issue.record("Expected log_level to be a picker field, got \(behavior.fields[1])")
            return
        }
        #expect(logLevel.id == "log_level")
        #expect(logLevel.label == "Sidecar log level")
        #expect(logLevel.default == "info")
        #expect(logLevel.options.map(\.value) == ["debug", "info", "warn", "error"])
        #expect(logLevel.options.map(\.label) == ["Debug", "Info", "Warning", "Error"])
    }

    // MARK: - Codex

    @Test("Bundled Codex settings.json decodes to PluginSettingsSchema")
    func bundledCodexSettingsSchemaDecodes() throws {
        let data = Data(Self.codexSettingsJSON.utf8)
        let schema = try Self.snakeCaseDecoder().decode(PluginSettingsSchema.self, from: data)

        #expect(schema.schemaVersion == 1)
        #expect(schema.sections.count == 2)

        guard case let .string(commandPath) = schema.sections[0].fields[0] else {
            Issue.record("Expected command_path to be a string field")
            return
        }
        #expect(commandPath.label == "Codex CLI command")
        #expect(commandPath.default == "codex")

        guard case let .boolean(autoRun) = schema.sections[1].fields[0] else {
            Issue.record("Expected auto_run to be a boolean field")
            return
        }
        #expect(autoRun.label == "Auto-launch Codex when opening a project")
    }

    // MARK: - Disk JSON locks

    /// Belt-and-braces: load the on-disk file relative to the package root.
    /// This catches the case where someone hand-edits the bundled JSON in
    /// a way that diverges from the inline Spec §17.3 copy above.
    @Test("On-disk PluginBundles/claude-code/ui/settings.json matches the inline spec copy")
    func diskClaudeMatchesInline() throws {
        let url = Self.packageRoot()
            .appendingPathComponent("PluginBundles")
            .appendingPathComponent("claude-code")
            .appendingPathComponent("ui")
            .appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("Missing bundled file at \(url.path)")
            return
        }
        let onDisk = try Self.snakeCaseDecoder().decode(PluginSettingsSchema.self, from: Data(contentsOf: url))
        let inline = try Self.snakeCaseDecoder().decode(
            PluginSettingsSchema.self,
            from: Data(Self.claudeCodeSettingsJSON.utf8)
        )
        #expect(onDisk == inline)
    }

    @Test("On-disk PluginBundles/codex/ui/settings.json matches the inline spec copy")
    func diskCodexMatchesInline() throws {
        let url = Self.packageRoot()
            .appendingPathComponent("PluginBundles")
            .appendingPathComponent("codex")
            .appendingPathComponent("ui")
            .appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("Missing bundled file at \(url.path)")
            return
        }
        let onDisk = try Self.snakeCaseDecoder().decode(PluginSettingsSchema.self, from: Data(contentsOf: url))
        let inline = try Self.snakeCaseDecoder().decode(
            PluginSettingsSchema.self,
            from: Data(Self.codexSettingsJSON.utf8)
        )
        #expect(onDisk == inline)
    }

    // MARK: - Helpers

    /// Walks up from this file's location to the package root (the
    /// directory containing `Package.swift`). Lets the on-disk tests find
    /// the bundled `PluginBundles/<id>/ui/settings.json` without any test
    /// resources configuration.
    private static func packageRoot() -> URL {
        var current = URL(fileURLWithPath: #filePath, isDirectory: false)
            .deletingLastPathComponent()
        while current.path != "/" {
            let candidate = current.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return current
            }
            current = current.deletingLastPathComponent()
        }
        fatalError("Could not locate ClaudeSpyPackage root")
    }
}
