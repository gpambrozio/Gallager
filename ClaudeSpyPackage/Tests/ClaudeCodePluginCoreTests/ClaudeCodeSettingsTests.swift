import ClaudeCodePluginCore
import Foundation
import GallagerPluginProtocol
import Testing

@Suite("ClaudeCodeSettings")
struct ClaudeCodeSettingsTests {
    @Test("defaults match the spec")
    func defaults() {
        let settings = ClaudeCodeSettings()
        #expect(settings.commandPath == "claude")
        #expect(settings.autoRun == true)
        #expect(settings.logLevel == .info)
    }

    @Test("decodes snake_case settings.json")
    func decodeSnakeCase() throws {
        let json = Data("""
        { "command_path": "/usr/local/bin/claude", "auto_run": false, "log_level": "debug" }
        """.utf8)
        let settings = try JSONDecoder().decode(ClaudeCodeSettings.self, from: json)
        #expect(settings.commandPath == "/usr/local/bin/claude")
        #expect(settings.autoRun == false)
        #expect(settings.logLevel == .debug)
    }

    @Test("decode(from:) falls back to defaults on empty or malformed data")
    func defensiveDecode() {
        #expect(ClaudeCodeSettings.decode(from: Data()) == ClaudeCodeSettings())
        #expect(ClaudeCodeSettings.decode(from: Data("not json".utf8)) == ClaudeCodeSettings())
    }

    @Test("round-trips through JSON")
    func roundTrip() throws {
        let original = ClaudeCodeSettings(commandPath: "claude", autoRun: true, logLevel: .warn)
        let data = try JSONEncoder().encode(original)
        #expect(ClaudeCodeSettings.decode(from: data) == original)
    }
}
