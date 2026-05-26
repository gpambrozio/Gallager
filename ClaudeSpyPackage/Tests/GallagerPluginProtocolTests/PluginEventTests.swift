import ClaudeSpyNetworking
import Foundation
import Testing
@testable import GallagerPluginProtocol

@Suite("PluginEvent Codable")
struct PluginEventTests {
    // The wire-format requirement (Spec §6.3, PluginEvent docs) says
    // serialization uses a snake_case key strategy. Reuse the same encoder /
    // decoder configuration the runtime uses so the round-trip mirrors
    // production behavior.
    private func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    @Test("round-trips with tmuxPane set")
    func roundTripWithTmuxPane() throws {
        let original = PluginEvent(
            pluginID: "echo",
            sessionID: "echo-session-1",
            working: true,
            attention: false,
            notification: nil,
            responseRequest: nil,
            appActions: [],
            tmuxPane: "%42"
        )
        let data = try encoder().encode(original)
        let decoded = try decoder().decode(PluginEvent.self, from: data)
        #expect(decoded == original)
        #expect(decoded.tmuxPane == "%42")
    }

    @Test("round-trips without tmuxPane (defaults to nil)")
    func roundTripWithoutTmuxPane() throws {
        let original = PluginEvent(
            pluginID: "claude-code",
            sessionID: "abc-123",
            working: nil,
            attention: true,
            notification: PluginEvent.NotificationSpec(title: "T", body: "B"),
            responseRequest: nil,
            appActions: []
        )
        let data = try encoder().encode(original)
        let decoded = try decoder().decode(PluginEvent.self, from: data)
        #expect(decoded == original)
        #expect(decoded.tmuxPane == nil)
    }

    @Test("decoder accepts payloads omitting the tmux_pane field (cross-version)")
    func decoderAcceptsOmittedTmuxPane() throws {
        // Hand-built JSON omitting the `tmux_pane` key — simulates an older
        // peer that doesn't yet emit the new field.
        let json = """
        {
          "plugin_id": "claude-code",
          "session_id": "abc",
          "working": false,
          "attention": false,
          "app_actions": []
        }
        """
        let decoded = try decoder().decode(PluginEvent.self, from: Data(json.utf8))
        #expect(decoded.pluginID == "claude-code")
        #expect(decoded.sessionID == "abc")
        #expect(decoded.tmuxPane == nil)
    }

    @Test("encoded JSON uses snake_case 'tmux_pane' key")
    func encodedKeyIsSnakeCase() throws {
        let event = PluginEvent(
            pluginID: "echo",
            sessionID: "s1",
            working: nil,
            attention: false,
            notification: nil,
            responseRequest: nil,
            appActions: [],
            tmuxPane: "%9"
        )
        let data = try encoder().encode(event)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"tmux_pane\""))
        #expect(json.contains("\"%9\""))
    }
}
