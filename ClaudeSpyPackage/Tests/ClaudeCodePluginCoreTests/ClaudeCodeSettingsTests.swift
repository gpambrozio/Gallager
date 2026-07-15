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

    @Test("closePaneOnSessionEnd defaults to false")
    func closePaneOnSessionEndDefault() {
        let settings = ClaudeCodeSettings()
        #expect(settings.closePaneOnSessionEnd == false)
    }

    @Test("decodes close_pane_on_session_end from JSON")
    func decodesClosePaneOnSessionEnd() throws {
        let json = Data("""
        { "close_pane_on_session_end": true }
        """.utf8)
        let settings = try JSONDecoder().decode(ClaudeCodeSettings.self, from: json)
        #expect(settings.closePaneOnSessionEnd == true)
    }

    @Test("closePaneOnSessionEnd round-trips through JSON")
    func closePaneOnSessionEndRoundTrip() throws {
        let original = ClaudeCodeSettings(closePaneOnSessionEnd: true)
        let data = try JSONEncoder().encode(original)
        #expect(ClaudeCodeSettings.decode(from: data) == original)
    }

    @Test("detectFalseStops defaults to true (also when the key is absent)")
    func detectFalseStopsDefault() throws {
        #expect(ClaudeCodeSettings().detectFalseStops == true)
        let json = Data(#"{ "command_path": "claude" }"#.utf8)
        #expect(try JSONDecoder().decode(ClaudeCodeSettings.self, from: json).detectFalseStops == true)
    }

    @Test("decodes detect_false_stops from JSON and round-trips")
    func detectFalseStopsRoundTrip() throws {
        let json = Data(#"{ "detect_false_stops": false }"#.utf8)
        #expect(try JSONDecoder().decode(ClaudeCodeSettings.self, from: json).detectFalseStops == false)

        let original = ClaudeCodeSettings(detectFalseStops: false)
        let data = try JSONEncoder().encode(original)
        #expect(ClaudeCodeSettings.decode(from: data) == original)
    }
}
