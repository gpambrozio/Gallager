import ClaudeSpyNetworking
import Foundation
import GallagerPluginProtocol
import Testing

// MARK: - IngressFrame codec

@Suite("IngressFrame codec")
struct IngressFrameCodecTests {
    @Test("round-trips plugin id, context, and payload through the length-prefixed frame")
    func roundTrip() throws {
        let payload = try JSONSerialization.data(withJSONObject: ["hook_event_name": "Stop", "n": 1])
        let frame = IngressFrame(
            pluginID: "claude-code",
            context: ["TMUX_PANE": "%3", "CLAUDE_PROJECT_DIR": "/work/app"],
            payload: payload
        )

        let wire = try frame.encodeFrame()
        // First 4 bytes are the big-endian length of the body.
        #expect(wire.count > 4)
        let length = wire.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        #expect(Int(length) == wire.count - 4)

        let decoded = try IngressFrame.decode(body: wire.dropFirst(4))
        #expect(decoded.pluginID == "claude-code")
        #expect(decoded.tmuxPane == "%3")
        #expect(decoded.context["CLAUDE_PROJECT_DIR"] == "/work/app")

        let decodedPayload = try JSONSerialization.jsonObject(with: decoded.payload) as? [String: Any]
        #expect(decodedPayload?["hook_event_name"] as? String == "Stop")
    }

    @Test("rejects a body without a plugin id")
    func missingPluginID() throws {
        let body = try JSONSerialization.data(withJSONObject: ["context": [:], "payload": [:]])
        #expect(throws: IngressFrameError.missingPluginID) {
            _ = try IngressFrame.decode(body: body)
        }
    }
}

// MARK: - Manifest decode

@Suite("PluginManifest decode")
struct ManifestDecodeTests {
    @Test("decodes the minimal v1 manifest with snake_case keys")
    func minimalManifest() throws {
        let json = Data("""
        {
          "schema_version": 1,
          "id": "claude-code",
          "display_name": "Claude Code",
          "short_name": "Claude",
          "version": "1.0.0",
          "process_names": ["claude"],
          "ui": { "icon": "assets/icon.png", "color": "#cb6f3a" }
        }
        """.utf8)

        let manifest = try JSONDecoder().decode(PluginManifest.self, from: json)
        #expect(manifest.id == "claude-code")
        #expect(manifest.shortName == "Claude")
        #expect(manifest.processNames == ["claude"])
        #expect(manifest.color == "#cb6f3a")
        // runtime absent → inProcess (spec §10)
        #expect(manifest.runtime == .inProcess)
    }

    @Test("falls back to the default color when ui.color is absent")
    func colorFallback() throws {
        let json = Data("""
        { "id": "x", "display_name": "X", "short_name": "X", "ui": {} }
        """.utf8)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: json)
        #expect(manifest.color == PluginManifest.fallbackColor)
    }
}

// MARK: - Wire-model Codable round-trips

@Suite("Plugin wire models")
struct PluginWireModelTests {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    @Test("PluginEvent survives a Codable round-trip")
    func pluginEvent() throws {
        let event = PluginEvent(
            pluginID: "claude-code",
            sessionID: "s1",
            working: true,
            attention: false,
            notification: NotificationSpec(title: "T", body: "B"),
            responseRequest: ResponseRequestPayload(
                requestID: "r1",
                request: .permission(PermissionRequest(
                    title: "Bash",
                    description: "npm install",
                    isAutoApprovable: true,
                    suggestions: [PermissionSuggestionOption(id: "s1", label: "Always allow")],
                    allowsCustomInstructions: true
                ))
            ),
            appActions: [.dismissFileSuggestions(sessionID: "s1")],
            tmuxPane: "%2",
            projectPath: "/work/app"
        )
        #expect(try roundTrip(event) == event)
    }

    @Test("response-request retraction encodes a null request")
    func retraction() throws {
        let payload = ResponseRequestPayload(requestID: "r1", request: nil)
        #expect(try roundTrip(payload) == payload)
    }

    @Test("each AgentResponse case survives a round-trip")
    func responses() throws {
        let cases: [AgentResponse] = [
            .prompt(text: "hi"),
            .replyAfterStop(text: ""),
            .permission(decision: .allow, appliedSuggestionID: "s1"),
            .permission(decision: .denyWithFeedback("do X"), appliedSuggestionID: nil),
            .askUserQuestion(answers: [QuestionAnswer(questionID: "q1", selectedOptionIDs: ["a"], freeText: nil)]),
            .approvePlan(decision: .approve, editedPlan: "edited"),
        ]
        for value in cases {
            #expect(try roundTrip(value) == value)
        }
    }
}

// MARK: - EchoPluginCore contract behavior

@Suite("EchoPluginCore drives the contract")
struct EchoPluginCoreTests {
    @Test("handleIngress returns the PluginEvent the directive describes, stamped with frame identity")
    func handleIngress() async throws {
        let host = MockPluginHost()
        let core = EchoPluginCore()
        try await core.initialize(
            PluginEnv(pluginRoot: URL(fileURLWithPath: "/"), stateDir: URL(fileURLWithPath: "/"), appVersion: "2.0", settings: Data()),
            host: host
        )

        let directive = EchoDirective(
            sessionID: "sess-1",
            working: false,
            attention: true,
            notification: NotificationSpec(title: "Done", body: "waiting"),
            responseRequest: ResponseRequestPayload(
                requestID: "req-1",
                request: .prompt(PromptRequest(title: "Reply"))
            )
        )
        let frame = try IngressFrame(
            pluginID: EchoPluginCore.pluginID,
            context: ["TMUX_PANE": "%9"],
            payload: JSONEncoder().encode(directive)
        )

        let event = await core.handleIngress(frame)
        #expect(event?.pluginID == "echo")
        #expect(event?.sessionID == "sess-1")
        #expect(event?.working == false)
        #expect(event?.attention == true)
        #expect(event?.notification?.title == "Done")
        #expect(event?.tmuxPane == "%9")
        #expect(event?.responseRequest?.requestID == "req-1")
    }

    @Test("deliverResponse drives sendText for a prompt reply")
    func deliverPrompt() async throws {
        let host = MockPluginHost()
        let core = EchoPluginCore()
        try await core.initialize(
            PluginEnv(pluginRoot: URL(fileURLWithPath: "/"), stateDir: URL(fileURLWithPath: "/"), appVersion: "2.0", settings: Data()),
            host: host
        )

        await core.deliverResponse(sessionID: "s1", requestID: "r1", .prompt(text: "hello agent"))

        let sent = await host.sentText
        #expect(sent.count == 1)
        #expect(sent.first?.sessionID == "s1")
        #expect(sent.first?.text == "hello agent")
    }

    @Test("deliverResponse drives the allow keystroke for a permission allow")
    func deliverPermission() async throws {
        let host = MockPluginHost()
        let core = EchoPluginCore()
        try await core.initialize(
            PluginEnv(pluginRoot: URL(fileURLWithPath: "/"), stateDir: URL(fileURLWithPath: "/"), appVersion: "2.0", settings: Data()),
            host: host
        )

        await core.deliverResponse(sessionID: "s1", requestID: "r1", .permission(decision: .allow, appliedSuggestionID: nil))

        let keys = await host.sentKeys
        #expect(keys.count == 1)
        #expect(keys.first?.keys == [.text("1")])
    }

    @Test("refreshProjects pushes a project list to the host")
    func refreshProjects() async throws {
        let host = MockPluginHost()
        let core = EchoPluginCore()
        try await core.initialize(
            PluginEnv(pluginRoot: URL(fileURLWithPath: "/"), stateDir: URL(fileURLWithPath: "/"), appVersion: "2.0", settings: Data()),
            host: host
        )

        await core.refreshProjects()

        let calls = await host.projectsCalls
        #expect(calls.count == 1)
        #expect(calls.first?.first?.pluginID == "echo")
    }
}
