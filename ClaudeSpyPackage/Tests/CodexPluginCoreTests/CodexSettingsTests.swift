import CodexPluginCore
import Foundation
import GallagerPluginProtocol
import Testing

@Suite("CodexSettings")
struct CodexSettingsTests {
    @Test("defaults match the spec")
    func defaults() {
        let settings = CodexSettings()
        #expect(settings.commandPath == "codex")
        #expect(settings.autoRun == true)
        #expect(settings.logLevel == .info)
    }

    @Test("decodes snake_case settings.json")
    func decodeSnakeCase() throws {
        let json = Data("""
        { "command_path": "/opt/homebrew/bin/codex", "auto_run": false, "log_level": "error" }
        """.utf8)
        let settings = try JSONDecoder().decode(CodexSettings.self, from: json)
        #expect(settings.commandPath == "/opt/homebrew/bin/codex")
        #expect(settings.autoRun == false)
        #expect(settings.logLevel == .error)
    }

    @Test("decode(from:) falls back to defaults on empty or malformed data")
    func defensiveDecode() {
        #expect(CodexSettings.decode(from: Data()) == CodexSettings())
        #expect(CodexSettings.decode(from: Data("nope".utf8)) == CodexSettings())
    }

    @Test("closePaneOnSessionEnd defaults to false")
    func closePaneOnSessionEndDefault() {
        let settings = CodexSettings()
        #expect(settings.closePaneOnSessionEnd == false)
    }

    @Test("decodes close_pane_on_session_end from JSON")
    func decodesClosePaneOnSessionEnd() throws {
        let json = Data("""
        { "close_pane_on_session_end": true }
        """.utf8)
        let settings = try JSONDecoder().decode(CodexSettings.self, from: json)
        #expect(settings.closePaneOnSessionEnd == true)
    }

    @Test("additionalConfigFolders defaults to empty array")
    func additionalConfigFoldersDefault() {
        let settings = CodexSettings()
        #expect(settings.additionalConfigFolders == [])
    }

    @Test("decodes additional_config_folders from JSON")
    func decodesAdditionalConfigFolders() throws {
        let json = Data("""
        { "additional_config_folders": ["/home/user/.codex", "/opt/codex"] }
        """.utf8)
        let settings = try JSONDecoder().decode(CodexSettings.self, from: json)
        #expect(settings.additionalConfigFolders == ["/home/user/.codex", "/opt/codex"])
    }

    @Test("new fields round-trip through JSON")
    func newFieldsRoundTrip() throws {
        let original = CodexSettings(closePaneOnSessionEnd: true, additionalConfigFolders: ["/custom/path"])
        let data = try JSONEncoder().encode(original)
        #expect(CodexSettings.decode(from: data) == original)
    }
}
