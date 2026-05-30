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
}
