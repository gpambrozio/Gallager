import Foundation
import Testing
@testable import ClaudeSpyNetworking

@Suite("PluginPresentation Codable round-trip")
struct PluginPresentationTests {
    private static let samplePNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAen63NgAAAAASUVORK5CYII="

    private func samplePNGData() -> Data {
        guard let data = Data(base64Encoded: PluginPresentationTests.samplePNGBase64) else {
            return Data([0x89, 0x50, 0x4E, 0x47])
        }
        return data
    }

    @Test("PluginPresentation round-trips through snake_case encoder/decoder")
    func roundTrip() throws {
        let original = PluginPresentation(
            id: "claude-code",
            version: "1.0.0",
            displayName: "Claude Code",
            shortName: "Claude",
            color: "#cb6f3a",
            iconPNGData: samplePNGData()
        )

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(PluginPresentation.self, from: data)

        #expect(decoded == original)
        #expect(decoded.iconPNGData == samplePNGData())
    }

    @Test("PluginPresentation encodes icon as icon_b64 base64 string")
    func encodesIconB64() throws {
        let pngData = samplePNGData()
        let original = PluginPresentation(
            id: "claude-code",
            version: "1.0.0",
            displayName: "Claude Code",
            shortName: "Claude",
            color: "#cb6f3a",
            iconPNGData: pngData
        )

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(original)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"icon_b64\":\"\(pngData.base64EncodedString())\""))
        #expect(json.contains("\"display_name\":\"Claude Code\""))
        #expect(json.contains("\"short_name\":\"Claude\""))
    }

    @Test("PluginPresentation decodes from spec JSON snippet")
    func decodesSpecJSON() throws {
        let pngData = samplePNGData()
        let json = """
        {
            "id": "claude-code",
            "version": "1.0.0",
            "display_name": "Claude Code",
            "short_name": "Claude",
            "color": "#cb6f3a",
            "icon_b64": "\(pngData.base64EncodedString())"
        }
        """

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(PluginPresentation.self, from: Data(json.utf8))

        #expect(decoded.id == "claude-code")
        #expect(decoded.version == "1.0.0")
        #expect(decoded.displayName == "Claude Code")
        #expect(decoded.shortName == "Claude")
        #expect(decoded.color == "#cb6f3a")
        #expect(decoded.iconPNGData == pngData)
    }

    @Test("PluginPresentationsMessage round-trip preserves type discriminator")
    func presentationsMessageRoundTrip() throws {
        let presentations = [
            PluginPresentation(
                id: "claude-code",
                version: "1.0.0",
                displayName: "Claude Code",
                shortName: "Claude",
                color: "#cb6f3a",
                iconPNGData: samplePNGData()
            ),
            PluginPresentation(
                id: "codex",
                version: "2.1.0",
                displayName: "Codex",
                shortName: "Codex",
                color: "#4287f5",
                iconPNGData: samplePNGData()
            ),
        ]
        let original = PluginPresentationsMessage(presentations: presentations)

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(PluginPresentationsMessage.self, from: data)

        #expect(decoded == original)
        #expect(decoded.presentations.count == 2)
    }

    @Test("PluginPresentationsMessage encodes type as plugin_presentations")
    func presentationsMessageTypeDiscriminator() throws {
        let original = PluginPresentationsMessage(presentations: [
            PluginPresentation(
                id: "claude-code",
                version: "1.0.0",
                displayName: "Claude Code",
                shortName: "Claude",
                color: "#cb6f3a",
                iconPNGData: samplePNGData()
            ),
        ])

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(original)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"type\":\"plugin_presentations\""))
        #expect(json.contains("\"presentations\""))
    }

    @Test("PluginPresentationsMessage decodes spec JSON")
    func presentationsMessageDecodesSpecJSON() throws {
        let pngData = samplePNGData()
        let b64 = pngData.base64EncodedString()
        let json = """
        {
            "type": "plugin_presentations",
            "presentations": [
                {
                    "id": "claude-code",
                    "version": "1.0.0",
                    "display_name": "Claude Code",
                    "short_name": "Claude",
                    "color": "#cb6f3a",
                    "icon_b64": "\(b64)"
                }
            ]
        }
        """

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let message = try decoder.decode(PluginPresentationsMessage.self, from: Data(json.utf8))

        #expect(message.presentations.count == 1)
        let presentation = try #require(message.presentations.first)
        #expect(presentation.id == "claude-code")
        #expect(presentation.displayName == "Claude Code")
        #expect(presentation.shortName == "Claude")
        #expect(presentation.iconPNGData == pngData)
    }
}
