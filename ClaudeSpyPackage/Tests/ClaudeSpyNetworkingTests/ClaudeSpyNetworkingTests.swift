import Foundation
import Testing
@testable import ClaudeSpyEncryption
@testable import ClaudeSpyNetworking

@Suite("Push Models Tests")
struct PushModelsTests {
    // MARK: - NotificationContent Tests

    @Test("NotificationContent encodes to JSON correctly")
    func notificationContentEncodes() throws {
        let timestamp = Date(timeIntervalSince1970: 1_704_067_200) // 2024-01-01 00:00:00 UTC
        let content = NotificationContent(
            title: "Test Title",
            body: "Test Body",
            eventType: "sessionStart",
            pairId: "test-pair-123",
            timestamp: timestamp
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(content)
        let jsonString = try #require(String(data: jsonData, encoding: .utf8))

        #expect(jsonString.contains("Test Title"))
        #expect(jsonString.contains("Test Body"))
        #expect(jsonString.contains("sessionStart"))
        #expect(jsonString.contains("test-pair-123"))
    }

    @Test("NotificationContent decodes from JSON correctly")
    func notificationContentDecodes() throws {
        let json = """
        {
            "title": "Claude Code",
            "body": "Session started",
            "eventType": "sessionStart",
            "pairId": "pair-abc",
            "timestamp": "2024-01-01T00:00:00Z"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let content = try decoder.decode(NotificationContent.self, from: Data(json.utf8))

        #expect(content.title == "Claude Code")
        #expect(content.body == "Session started")
        #expect(content.eventType == "sessionStart")
        #expect(content.pairId == "pair-abc")
    }

    @Test("NotificationContent round-trip encoding")
    func notificationContentRoundTrip() throws {
        let original = NotificationContent(
            title: "Permission Required",
            body: "Claude Code needs permission",
            eventType: "permissionRequest",
            pairId: "uuid-123",
            timestamp: Date()
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(NotificationContent.self, from: jsonData)

        #expect(decoded.title == original.title)
        #expect(decoded.body == original.body)
        #expect(decoded.eventType == original.eventType)
        #expect(decoded.pairId == original.pairId)
    }

    @Test("NotificationContent with paneId round-trip encoding")
    func notificationContentWithPaneIdRoundTrip() throws {
        let original = NotificationContent(
            title: "Session Event",
            body: "Something happened",
            eventType: "sessionStart",
            pairId: "uuid-456",
            paneId: "%123",
            timestamp: Date()
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(NotificationContent.self, from: jsonData)

        #expect(decoded.title == original.title)
        #expect(decoded.body == original.body)
        #expect(decoded.eventType == original.eventType)
        #expect(decoded.pairId == original.pairId)
        #expect(decoded.paneId == original.paneId)
        #expect(decoded.paneId == "%123")
    }

    @Test("NotificationContent decodes with missing paneId")
    func notificationContentDecodesWithoutPaneId() throws {
        let json = """
        {
            "title": "Claude Code",
            "body": "Session started",
            "eventType": "sessionStart",
            "pairId": "pair-abc",
            "timestamp": "2024-01-01T00:00:00Z"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let content = try decoder.decode(NotificationContent.self, from: Data(json.utf8))

        #expect(content.paneId == nil)
    }

    // MARK: - EncryptedPushPayload Tests

    @Test("EncryptedPushPayload encodes correctly")
    func encryptedPushPayloadEncodes() throws {
        let ciphertext = Data([0x01, 0x02, 0x03, 0x04])
        let encryptedContent = EncryptedPayload(
            ciphertext: ciphertext,
            senderKeyId: "key-123"
        )
        let payload = EncryptedPushPayload(
            encryptedContent: encryptedContent,
            pairId: "test-pair"
        )

        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(payload)
        let jsonString = try #require(String(data: jsonData, encoding: .utf8))

        #expect(jsonString.contains("test-pair"))
        #expect(jsonString.contains("key-123"))
        // Base64 encoded ciphertext
        #expect(jsonString.contains("AQIDBA=="))
    }

    @Test("EncryptedPushPayload decodes correctly")
    func encryptedPushPayloadDecodes() throws {
        let json = """
        {
            "encryptedContent": {
                "ciphertext": "AQIDBA==",
                "senderKeyId": "sender-key",
                "version": 1
            },
            "pairId": "pair-xyz",
            "silent": false
        }
        """

        let decoder = JSONDecoder()
        let payload = try decoder.decode(EncryptedPushPayload.self, from: Data(json.utf8))

        #expect(payload.pairId == "pair-xyz")
        #expect(payload.encryptedContent.senderKeyId == "sender-key")
        #expect(payload.encryptedContent.version == 1)
        #expect(payload.encryptedContent.ciphertext == Data([0x01, 0x02, 0x03, 0x04]))
    }

    @Test("EncryptedPushPayload equality")
    func encryptedPushPayloadEquality() {
        let ciphertext = Data([0xAA, 0xBB])
        let encrypted = EncryptedPayload(ciphertext: ciphertext, senderKeyId: "key")

        let payload1 = EncryptedPushPayload(encryptedContent: encrypted, pairId: "pair")
        let payload2 = EncryptedPushPayload(encryptedContent: encrypted, pairId: "pair")
        let payload3 = EncryptedPushPayload(encryptedContent: encrypted, pairId: "different")

        #expect(payload1 == payload2)
        #expect(payload1 != payload3)
    }
}

// MARK: - TmuxKey CSI Parsing Tests

@Suite("TmuxKey CSI Parsing")
struct TmuxKeyCsiParsingTests {
    // MARK: - Legacy CSI sequences (unchanged behavior)

    @Test("Parses simple arrow keys")
    func parsesSimpleArrowKeys() {
        let right = Data([0x1B, 0x5B, 0x43]) // ESC [ C
        #expect(TmuxKey.from(bytes: right) == [.right])

        let left = Data([0x1B, 0x5B, 0x44]) // ESC [ D
        #expect(TmuxKey.from(bytes: left) == [.left])

        let up = Data([0x1B, 0x5B, 0x41]) // ESC [ A
        #expect(TmuxKey.from(bytes: up) == [.up])

        let down = Data([0x1B, 0x5B, 0x42]) // ESC [ B
        #expect(TmuxKey.from(bytes: down) == [.down])
    }

    @Test("Parses home and end keys")
    func parsesHomeEnd() {
        let home = Data([0x1B, 0x5B, 0x48]) // ESC [ H
        #expect(TmuxKey.from(bytes: home) == [.home])

        let end = Data([0x1B, 0x5B, 0x46]) // ESC [ F
        #expect(TmuxKey.from(bytes: end) == [.end])
    }

    @Test("Parses backtab")
    func parsesBacktab() {
        let backtab = Data([0x1B, 0x5B, 0x5A]) // ESC [ Z
        #expect(TmuxKey.from(bytes: backtab) == [.backtab])
    }

    @Test("Parses extended key sequences")
    func parsesExtendedKeys() {
        let delete = Data([0x1B, 0x5B, 0x33, 0x7E]) // ESC [ 3 ~
        #expect(TmuxKey.from(bytes: delete) == [.delete])

        let pageUp = Data([0x1B, 0x5B, 0x35, 0x7E]) // ESC [ 5 ~
        #expect(TmuxKey.from(bytes: pageUp) == [.pageUp])

        let pageDown = Data([0x1B, 0x5B, 0x36, 0x7E]) // ESC [ 6 ~
        #expect(TmuxKey.from(bytes: pageDown) == [.pageDown])
    }

    // MARK: - Modified arrow keys (parameterized CSI)

    @Test("Parses modified arrow keys CSI 1;mod X")
    func parsesModifiedArrowKeys() {
        // ESC [ 1 ; 5 C — Ctrl+Right (modifier 5)
        let ctrlRight = Data([0x1B, 0x5B, 0x31, 0x3B, 0x35, 0x43])
        #expect(TmuxKey.from(bytes: ctrlRight) == [.right])

        // ESC [ 1 ; 2 A — Shift+Up (modifier 2)
        let shiftUp = Data([0x1B, 0x5B, 0x31, 0x3B, 0x32, 0x41])
        #expect(TmuxKey.from(bytes: shiftUp) == [.up])
    }

    // MARK: - CSI u (kitty keyboard protocol)

    @Test("Parses CSI u for regular character")
    func parsesCsiURegularChar() {
        // ESC [ 97 u — 'a' (codepoint 97)
        let data = Data([0x1B, 0x5B, 0x39, 0x37, 0x75])
        let keys = TmuxKey.from(bytes: data)
        #expect(keys == [.text("a")])
    }

    @Test("Parses CSI u for Ctrl+A")
    func parsesCsiUCtrlA() {
        // ESC [ 97 ; 5 u — Ctrl+A (codepoint 97, modifier 5 = 1 + ctrl)
        let data = Data([0x1B, 0x5B, 0x39, 0x37, 0x3B, 0x35, 0x75])
        let keys = TmuxKey.from(bytes: data)
        #expect(keys == [.ctrl("a")])
    }

    @Test("Parses CSI u for Alt+B")
    func parsesCsiUAltB() {
        // ESC [ 98 ; 3 u — Alt+B (codepoint 98, modifier 3 = 1 + alt)
        let data = Data([0x1B, 0x5B, 0x39, 0x38, 0x3B, 0x33, 0x75])
        let keys = TmuxKey.from(bytes: data)
        #expect(keys == [.alt("b")])
    }

    @Test("Parses CSI u for special keys")
    func parsesCsiUSpecialKeys() {
        // ESC [ 13 u — Enter
        let enter = Data([0x1B, 0x5B, 0x31, 0x33, 0x75])
        #expect(TmuxKey.from(bytes: enter) == [.enter])

        // ESC [ 27 u — Escape
        let escape = Data([0x1B, 0x5B, 0x32, 0x37, 0x75])
        #expect(TmuxKey.from(bytes: escape) == [.escape])

        // ESC [ 9 u — Tab
        let tab = Data([0x1B, 0x5B, 0x39, 0x75])
        #expect(TmuxKey.from(bytes: tab) == [.tab])

        // ESC [ 127 u — Backspace
        let backspace = Data([0x1B, 0x5B, 0x31, 0x32, 0x37, 0x75])
        #expect(TmuxKey.from(bytes: backspace) == [.backspace])

        // ESC [ 32 u — Space
        let space = Data([0x1B, 0x5B, 0x33, 0x32, 0x75])
        #expect(TmuxKey.from(bytes: space) == [.space])
    }

    @Test("Parses CSI u for Ctrl+Alt+C")
    func parsesCsiUCtrlAltC() {
        // ESC [ 99 ; 7 u — Ctrl+Alt+C (codepoint 99, modifier 7 = 1 + alt + ctrl)
        let data = Data([0x1B, 0x5B, 0x39, 0x39, 0x3B, 0x37, 0x75])
        let keys = TmuxKey.from(bytes: data)
        #expect(keys == [.ctrlAlt("c")])
    }

    @Test("Parses CSI u for Shift+Tab as backtab")
    func parsesCsiUShiftTab() {
        // ESC [ 9 ; 2 u — Shift+Tab (codepoint 9, modifier 2 = 1 + shift)
        let data = Data([0x1B, 0x5B, 0x39, 0x3B, 0x32, 0x75])
        #expect(TmuxKey.from(bytes: data) == [.backtab])
    }

    @Test("Parses CSI u for Shift+Enter as shiftEnter")
    func parsesCsiUShiftEnter() {
        // ESC [ 13 ; 2 u — Shift+Enter (codepoint 13, modifier 2 = 1 + shift)
        let data = Data([0x1B, 0x5B, 0x31, 0x33, 0x3B, 0x32, 0x75])
        #expect(TmuxKey.from(bytes: data) == [.shiftEnter])
    }

    @Test("Unknown CSI sequence produces no garbage output")
    func unknownCsiProducesNoGarbage() {
        // ESC [ 200 ~ — bracketed paste start (unknown extended key)
        let data = Data([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E])
        let keys = TmuxKey.from(bytes: data)
        #expect(keys.isEmpty)
    }

    @Test("Unrecognized CSI final byte produces no garbage")
    func unrecognizedCsiFinalByteNoGarbage() {
        // ESC [ 1 P — unknown final byte 'P'
        let data = Data([0x1B, 0x5B, 0x31, 0x50])
        let keys = TmuxKey.from(bytes: data)
        #expect(keys.isEmpty)
    }

    @Test("CSI u with surrounding text")
    func csiUWithSurroundingText() {
        // "abc" + ESC [ 13 u (Enter) + "def"
        var data = Data("abc".utf8)
        data.append(contentsOf: [0x1B, 0x5B, 0x31, 0x33, 0x75]) // ESC [ 13 u
        data.append(Data("def".utf8))

        let keys = TmuxKey.from(bytes: data)
        #expect(keys == [.text("abc"), .enter, .text("def")])
    }
}

@Suite("WebSocket Message Tests")
struct WebSocketMessageTests {
    @Test("encryptedPush message encodes correctly")
    func encryptedPushMessageEncodes() throws {
        let ciphertext = Data([0x01, 0x02, 0x03])
        let encrypted = EncryptedPayload(ciphertext: ciphertext, senderKeyId: "key-1")
        let payload = EncryptedPushPayload(encryptedContent: encrypted, pairId: "pair-id")
        let message = WebSocketMessage.encryptedPush(payload)

        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(message)
        let jsonString = try #require(String(data: jsonData, encoding: .utf8))

        #expect(jsonString.contains("encryptedPush"))
        #expect(jsonString.contains("pair-id"))
    }

    @Test("encryptedPush message decodes correctly")
    func encryptedPushMessageDecodes() throws {
        let json = """
        {
            "type": "encryptedPush",
            "payload": {
                "encryptedContent": {
                    "ciphertext": "AQID",
                    "senderKeyId": "sender",
                    "version": 1
                },
                "pairId": "test-pair",
                "silent": false
            }
        }
        """

        let decoder = JSONDecoder()
        let message = try decoder.decode(WebSocketMessage.self, from: Data(json.utf8))

        if case let .encryptedPush(payload) = message {
            #expect(payload.pairId == "test-pair")
            #expect(payload.encryptedContent.senderKeyId == "sender")
        } else {
            Issue.record("Expected encryptedPush message type")
        }
    }

    @Test("encryptedPush message round-trip")
    func encryptedPushMessageRoundTrip() throws {
        let ciphertext = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let encrypted = EncryptedPayload(ciphertext: ciphertext, senderKeyId: "test-key")
        let originalPayload = EncryptedPushPayload(encryptedContent: encrypted, pairId: "round-trip-pair")
        let originalMessage = WebSocketMessage.encryptedPush(originalPayload)

        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(originalMessage)

        let decoder = JSONDecoder()
        let decodedMessage = try decoder.decode(WebSocketMessage.self, from: jsonData)

        if case let .encryptedPush(decodedPayload) = decodedMessage {
            #expect(decodedPayload == originalPayload)
        } else {
            Issue.record("Message type changed during round-trip")
        }
    }

    @Test("messageType returns correct type for encryptedPush")
    func encryptedPushMessageType() {
        let encrypted = EncryptedPayload(ciphertext: Data(), senderKeyId: "k")
        let payload = EncryptedPushPayload(encryptedContent: encrypted, pairId: "p")
        let message = WebSocketMessage.encryptedPush(payload)

        #expect(message.messageType == "encryptedPush")
    }
}

@Suite("TerminalStreamMessage Tests")
struct TerminalStreamMessageTests {
    @Test("Notification message round-trip encoding")
    func notificationRoundTrip() throws {
        let original = TerminalStreamMessage.notification(
            paneId: "%1",
            title: "Claude Code",
            body: "Task completed"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TerminalStreamMessage.self, from: jsonData)

        #expect(decoded.paneId == "%1")
        if case let .notification(notification) = decoded.updateType {
            #expect(notification.title == "Claude Code")
            #expect(notification.body == "Task completed")
        } else {
            Issue.record("Expected notification update type")
        }
    }

    @Test("Notification message without title round-trip encoding")
    func notificationWithoutTitleRoundTrip() throws {
        let original = TerminalStreamMessage.notification(
            paneId: "%2",
            body: "Simple notification"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TerminalStreamMessage.self, from: jsonData)

        if case let .notification(notification) = decoded.updateType {
            #expect(notification.title == nil)
            #expect(notification.body == "Simple notification")
        } else {
            Issue.record("Expected notification update type")
        }
    }

    @Test("TerminalNotification equality")
    func terminalNotificationEquality() {
        let n1 = TerminalStreamMessage.TerminalNotification(title: "A", body: "B")
        let n2 = TerminalStreamMessage.TerminalNotification(title: "A", body: "B")
        let n3 = TerminalStreamMessage.TerminalNotification(title: "X", body: "B")

        #expect(n1 == n2)
        #expect(n1 != n3)
    }
}

@Suite("AgentProject Tests")
struct AgentProjectTests {
    @Test("Round-trip preserves claudeConfigDir")
    func roundTripPreservesConfigDir() throws {
        let original = AgentProject(
            name: "MyProject",
            path: "/Users/test/MyProject",
            lastUsed: Date(timeIntervalSince1970: 1_704_067_200),
            claudeConfigDir: "/Users/test/work-claude"
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(AgentProject.self, from: data)

        #expect(decoded == original)
        #expect(decoded.claudeConfigDir == "/Users/test/work-claude")
    }

    @Test("Decodes JSON without claudeConfigDir as nil")
    func decodesJSONWithoutConfigDir() throws {
        let json = """
        {
            "name": "PlainProject",
            "path": "/Users/test/PlainProject",
            "lastUsed": null,
            "plugin_id": "claude-code"
        }
        """

        let decoded = try JSONDecoder().decode(AgentProject.self, from: Data(json.utf8))

        #expect(decoded.name == "PlainProject")
        #expect(decoded.path == "/Users/test/PlainProject")
        #expect(decoded.claudeConfigDir == nil)
        #expect(decoded.pluginID == "claude-code")
    }

    @Test("Decodes modern Codex project JSON via plugin_id")
    func decodesCodexProject() throws {
        let json = """
        {
            "name": "CodexProject",
            "path": "/Users/test/CodexProject",
            "lastUsed": null,
            "plugin_id": "codex"
        }
        """

        let decoded = try JSONDecoder().decode(AgentProject.self, from: Data(json.utf8))

        #expect(decoded.pluginID == "codex")
    }

    @Test("Decodes legacy payload that uses the old `agent` raw value")
    func decodesLegacyAgentField() throws {
        // Cross-host fallback: a peer on the pre-plugin-system build
        // emits `agent: "codex"` instead of `plugin_id: "codex"`. The new
        // build accepts it and lifts the raw value to `pluginID`. Per
        // `feedback_no-backward-compat`, this fallback is permanent.
        let json = """
        {
            "name": "LegacyCodex",
            "path": "/Users/test/LegacyCodex",
            "lastUsed": null,
            "agent": "codex"
        }
        """

        let decoded = try JSONDecoder().decode(AgentProject.self, from: Data(json.utf8))

        #expect(decoded.pluginID == "codex")
        #expect(decoded.claudeConfigDir == nil)
    }

    @Test("Decodes payload with neither key as claude-code")
    func decodesLegacyPayloadWithoutAgent() throws {
        // Mirrors what a `main`-version host emits before the agent split —
        // no `agent`, no `plugin_id`. The new build must tolerate it and
        // default to Claude Code (the only agent those versions knew about).
        let json = """
        {
            "name": "LegacyProject",
            "path": "/Users/test/LegacyProject",
            "lastUsed": null
        }
        """

        let decoded = try JSONDecoder().decode(AgentProject.self, from: Data(json.utf8))

        #expect(decoded.pluginID == "claude-code")
        #expect(decoded.claudeConfigDir == nil)
    }

    @Test("Encoded payload uses plugin_id, not agent")
    func encodesModernKey() throws {
        let project = AgentProject(
            name: "MyProject",
            path: "/Users/test/MyProject",
            pluginID: "codex"
        )
        let data = try JSONEncoder().encode(project)
        let raw = try #require(String(data: data, encoding: .utf8))

        #expect(raw.contains("\"plugin_id\":\"codex\""))
        // Legacy key must NOT be emitted by the new encoder; cross-host
        // peers parse the modern shape.
        #expect(!raw.contains("\"agent\""))
    }
}

@Suite("AgentSession Cross-Version Decoding")
struct AgentSessionCrossVersionTests {
    @Test("Decodes legacy payload that used the `agent` raw value as plugin id")
    func decodesLegacyAgentField() throws {
        // Cross-host fallback: a pre-plugin-system peer emits `agent: "codex"`
        // instead of `plugin_id: "codex"`. The new build accepts it verbatim
        // and lifts the raw value onto `pluginID`. Per
        // `feedback_no-backward-compat`, this fallback is permanent.
        let json = """
        {
            "id": "session-1",
            "agent": "codex"
        }
        """

        let decoded = try JSONDecoder().decode(AgentSession.self, from: Data(json.utf8))

        #expect(decoded.id == "session-1")
        #expect(decoded.pluginID == "codex")
        #expect(decoded.working == false)
        #expect(decoded.attention == false)
    }

    @Test("Decodes payload with neither key as claude-code")
    func decodesPayloadWithoutAgent() throws {
        // Mirrors what a `main`-version host emits before the agent split —
        // no `agent`, no `plugin_id`. The new build must default to Claude
        // Code, the only agent older builds knew about.
        let json = """
        {
            "id": "abc"
        }
        """

        let decoded = try JSONDecoder().decode(AgentSession.self, from: Data(json.utf8))

        #expect(decoded.pluginID == "claude-code")
    }

    @Test("Round-trips the modern plugin_id payload through snake_case JSON")
    func roundTripsModernPayload() throws {
        let original = AgentSession(
            id: "session-42",
            pluginID: "claude-code",
            tmuxPane: "%2",
            projectPath: "/Users/test/Proj",
            working: true,
            attention: false,
            lastEventTimestamp: Date(timeIntervalSince1970: 1_716_575_531)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let raw = try #require(String(data: data, encoding: .utf8))
        // Modern encoder must emit snake_case keys per the wire convention.
        // JSONEncoder escapes forward slashes by default, so match the escaped form.
        #expect(raw.contains("\"plugin_id\":\"claude-code\""))
        #expect(raw.contains("\"tmux_pane\":\"%2\""))
        #expect(raw.contains("\"project_path\":"))
        #expect(raw.contains("\"last_event_timestamp\""))
        // Legacy `agent` key must NOT appear in the new wire format.
        #expect(!raw.contains("\"agent\""))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AgentSession.self, from: data)
        #expect(decoded == original)
    }
}

@Suite("CreateTmuxSession Tests")
struct CreateTmuxSessionTests {
    @Test("Round-trip preserves claudeConfigDir")
    func roundTripPreservesConfigDir() throws {
        let original = CreateTmuxSession(
            sessionName: "work",
            width: 120,
            height: 40,
            workingDirectory: "/Users/test/work",
            claudeConfigDir: "/Users/test/work-claude"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CreateTmuxSession.self, from: data)

        #expect(decoded == original)
        #expect(decoded.claudeConfigDir == "/Users/test/work-claude")
    }

    @Test("Decodes legacy JSON without claudeConfigDir as nil")
    func decodesLegacyJSON() throws {
        let json = """
        {
            "sessionName": "legacy",
            "width": 80,
            "height": 24
        }
        """

        let decoded = try JSONDecoder().decode(CreateTmuxSession.self, from: Data(json.utf8))

        #expect(decoded.sessionName == "legacy")
        #expect(decoded.width == 80)
        #expect(decoded.height == 24)
        #expect(decoded.workingDirectory == nil)
        #expect(decoded.claudeConfigDir == nil)
        #expect(decoded.pluginID == "claude-code")
    }

    @Test("Round-trip preserves Codex plugin id")
    func roundTripPreservesCodexPluginID() throws {
        let original = CreateTmuxSession(
            sessionName: "codex-work",
            width: 120,
            height: 40,
            workingDirectory: "/Users/test/codex-work",
            pluginID: "codex"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CreateTmuxSession.self, from: data)

        #expect(decoded == original)
        #expect(decoded.pluginID == "codex")
    }

    @Test("Defaults plugin id to Claude Code when omitted on init")
    func defaultsPluginIDToClaude() {
        let session = CreateTmuxSession(
            sessionName: "work",
            width: 80,
            height: 24,
            workingDirectory: "/Users/test/work"
        )

        #expect(session.pluginID == "claude-code")
    }

    @Test("Decodes legacy `agent` field into pluginID")
    func decodesLegacyAgentField() throws {
        let json = """
        {
            "sessionName": "old-host",
            "width": 80,
            "height": 24,
            "agent": "codex"
        }
        """

        let decoded = try JSONDecoder().decode(CreateTmuxSession.self, from: Data(json.utf8))

        #expect(decoded.pluginID == "codex")
    }
}
