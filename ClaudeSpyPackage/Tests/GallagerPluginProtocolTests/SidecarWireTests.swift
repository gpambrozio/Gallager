import ClaudeSpyNetworking
import Foundation
import Testing
@testable import GallagerPluginProtocol

@Suite("StdioFramer")
struct StdioFramerTests {
    @Test("encode prepends a Content-Length header + blank line")
    func encodeShape() {
        let framed = StdioFramer.encode(Data("{}".utf8))
        #expect(String(bytes: framed, encoding: .utf8) == "Content-Length: 2\r\n\r\n{}")
    }

    @Test("decoder reassembles a frame split across chunks")
    func splitChunks() throws {
        var dec = FrameDecoder()
        let framed = StdioFramer.encode(Data(#"{"a":1}"#.utf8))
        #expect(try dec.push(framed.prefix(5)).isEmpty) // header start only
        let bodies = try dec.push(framed.suffix(from: framed.index(framed.startIndex, offsetBy: 5)))
        #expect(bodies.count == 1)
        #expect(String(bytes: bodies[0], encoding: .utf8) == #"{"a":1}"#)
    }

    @Test("decoder yields two frames from one chunk, in order")
    func twoFrames() throws {
        var dec = FrameDecoder()
        var buf = StdioFramer.encode(Data(#"{"n":1}"#.utf8))
        buf.append(StdioFramer.encode(Data(#"{"n":2}"#.utf8)))
        let bodies = try dec.push(buf)
        #expect(bodies.map { String(bytes: $0, encoding: .utf8) } == [#"{"n":1}"#, #"{"n":2}"#])
    }

    @Test("header past 16 KiB without terminator throws malformedHeader")
    func headerCap() {
        var dec = FrameDecoder()
        let hostile = Data(repeating: UInt8(ascii: "X"), count: 17 * 1_024)
        #expect(throws: FramingError.malformedHeader) { _ = try dec.push(hostile) }
    }

    @Test("Content-Length above 32 MiB is rejected before allocation")
    func bodyCap() {
        var dec = FrameDecoder()
        let header = Data("Content-Length: \(33 * 1_024 * 1_024)\r\n\r\n".utf8)
        #expect(throws: FramingError.bodyTooLarge(33 * 1_024 * 1_024)) { _ = try dec.push(header) }
    }
}

@Suite("RPCMessage")
struct RPCMessageTests {
    @Test("request round-trips through JSON")
    func requestRoundTrip() throws {
        let msg = RPCMessage.request(
            id: "1",
            method: SidecarRPC.initialize,
            params: .object(["appVersion": .string("2.0")])
        )
        let data = try JSONEncoder().encode(msg)
        let back = try JSONDecoder().decode(RPCMessage.self, from: data)
        #expect(back == msg)
        #expect(back.isRequest)
        #expect(!back.isNotification)
    }

    @Test("a notification has no id")
    func notificationHasNoID() throws {
        let n = RPCMessage.notification(method: HostRPC.emitEvent, params: .object([:]))
        #expect(n.id == nil)
        #expect(n.isNotification)
        let data = try JSONEncoder().encode(n)
        #expect(!(String(bytes: data, encoding: .utf8) ?? "").contains("\"id\""))
    }

    @Test("method-name constants match the spec vocabulary")
    func methodNames() {
        #expect(SidecarRPC.translateEvent == "translate_event")
        #expect(SidecarRPC.commandForLaunch == "command_for_launch")
        #expect(HostRPC.setProjects == "set_projects")
        #expect(HostRPC.agentPanes == "agent_panes")
    }
}

@Suite("PluginEnvWire")
struct PluginEnvWireTests {
    @Test("settings ride as nested JSON, not base64")
    func settingsNested() throws {
        let env = PluginEnv(
            pluginRoot: URL(fileURLWithPath: "/p"), stateDir: URL(fileURLWithPath: "/s"),
            appVersion: "2.0", settings: Data(#"{"auto_run":true}"#.utf8),
            marketplaceSource: URL(fileURLWithPath: "/m"),
            otlpReceiverEndpoint: URL(string: "http://127.0.0.1:4318")
        )
        let wire = try PluginEnvWire(env)
        let json = try JSONEncoder().encode(wire)
        let text = String(bytes: json, encoding: .utf8) ?? ""
        #expect(text.contains(#""auto_run":true"#)) // embedded object, not a quoted blob
        #expect(!text.contains("eyJ")) // no base64
        // Round-trips back to the same settings bytes.
        let decoded = try JSONDecoder().decode(PluginEnvWire.self, from: json)
        #expect(decoded.settingsData() == env.settings)
    }
}
