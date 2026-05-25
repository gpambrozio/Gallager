import ClaudeSpyNetworking
import Foundation
import Testing
@testable import GallagerPluginProtocol

@Suite("IngressFrame")
struct IngressFrameTests {
    @Test("round-trips through length-prefixed Codable encoding")
    func roundTrip() throws {
        let original = IngressFrame(
            context: ["FOO": "bar"],
            payload: .object(["tool": .string("Read")])
        )

        let encoded = try original.encodedForSocket()

        // Strip the 4-byte length prefix, decode the body.
        #expect(encoded.count > 4)
        let lengthBytes = encoded.prefix(4)
        let bodyBytes = encoded.suffix(from: 4)

        // Length prefix is big-endian UInt32 equal to body length.
        let bodyLen = UInt32(bigEndian: lengthBytes.withUnsafeBytes { $0.load(as: UInt32.self) })
        #expect(Int(bodyLen) == bodyBytes.count)

        let decoded = try IngressFrame.decode(from: Data(bodyBytes))
        #expect(decoded == original)
    }

    @Test("encodeLengthPrefix returns 4 big-endian bytes")
    func lengthPrefixBigEndian() throws {
        // 258 = 0x00 0x00 0x01 0x02 in big-endian
        let data = IngressFrame.encodeLengthPrefix(258)
        #expect(data.count == 4)
        #expect(Array(data) == [0x00, 0x00, 0x01, 0x02])
    }

    @Test("encodeLengthPrefix handles zero")
    func lengthPrefixZero() throws {
        let data = IngressFrame.encodeLengthPrefix(0)
        #expect(Array(data) == [0x00, 0x00, 0x00, 0x00])
    }

    @Test("encodeLengthPrefix handles UInt32.max")
    func lengthPrefixMax() throws {
        let data = IngressFrame.encodeLengthPrefix(UInt32.max)
        #expect(Array(data) == [0xFF, 0xFF, 0xFF, 0xFF])
    }

    @Test("encoded frame's first 4 bytes are body length big-endian")
    func encodedFirstFourBytesAreLength() throws {
        let frame = IngressFrame(
            context: ["A": "B"],
            payload: .object(["x": .int(1)])
        )

        let encoded = try frame.encodedForSocket()

        // First 4 bytes are big-endian UInt32 of the JSON-body length.
        let lenBytes = Array(encoded.prefix(4))
        let bodyLen = Int(encoded.count - 4)

        let high = (bodyLen >> 24) & 0xFF
        let midHigh = (bodyLen >> 16) & 0xFF
        let midLow = (bodyLen >> 8) & 0xFF
        let low = bodyLen & 0xFF
        #expect(lenBytes == [UInt8(high), UInt8(midHigh), UInt8(midLow), UInt8(low)])
    }

    @Test("decode rejects body that isn't valid JSON")
    func decodeRejectsInvalidBody() throws {
        let garbage = Data([0x00, 0x01, 0x02])
        #expect(throws: (any Error).self) {
            _ = try IngressFrame.decode(from: garbage)
        }
    }
}
