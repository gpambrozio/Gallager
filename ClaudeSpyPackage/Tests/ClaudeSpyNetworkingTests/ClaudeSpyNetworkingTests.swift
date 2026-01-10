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
        let jsonString = String(data: jsonData, encoding: .utf8)!

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
        let jsonString = String(data: jsonData, encoding: .utf8)!

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
            "pairId": "pair-xyz"
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
        let jsonString = String(data: jsonData, encoding: .utf8)!

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
                "pairId": "test-pair"
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
