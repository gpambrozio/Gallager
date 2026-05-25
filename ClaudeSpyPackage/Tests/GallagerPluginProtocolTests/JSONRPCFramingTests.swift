import Foundation
import Testing
@testable import GallagerPluginProtocol

@Suite("JSONRPCFramer")
struct JSONRPCFramingTests {
    // MARK: - Helpers

    /// Wraps a `Data` as an async byte sequence for `JSONRPCFramer.read(from:)`.
    private struct ByteStream: AsyncSequence {
        typealias Element = UInt8
        let bytes: [UInt8]

        struct AsyncIterator: AsyncIteratorProtocol {
            var iterator: Array<UInt8>.Iterator

            mutating func next() async -> UInt8? {
                iterator.next()
            }
        }

        func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(iterator: bytes.makeIterator())
        }
    }

    // MARK: - encode

    @Test("encode prepends Content-Length header with CRLF blank line")
    func encodeProducesCorrectHeader() throws {
        let payload = Data(repeating: 0x41, count: 100) // 100 'A' bytes
        let framed = JSONRPCFramer.encode(payload)
        let asString = String(data: framed, encoding: .utf8)
        let expected = "Content-Length: 100\r\n\r\n" + String(repeating: "A", count: 100)
        #expect(asString == expected)
    }

    @Test("encode reports correct byte count for utf-8 payload")
    func encodeReportsByteCount() throws {
        let payload = Data("hello, world".utf8)
        let framed = JSONRPCFramer.encode(payload)
        let asString = try #require(String(data: framed, encoding: .utf8))
        #expect(asString == "Content-Length: 12\r\n\r\nhello, world")
    }

    // MARK: - read

    @Test("read returns the body when framed correctly")
    func readReturnsBody() async throws {
        let payload = Data("{\"jsonrpc\":\"2.0\",\"method\":\"x\"}".utf8)
        let framed = JSONRPCFramer.encode(payload)
        let stream = ByteStream(bytes: Array(framed))

        let body = try await JSONRPCFramer.read(from: stream)
        #expect(body == payload)
    }

    @Test("read can decode a 100-byte body identically")
    func readDecodesLongBody() async throws {
        let payload = Data(repeating: 0x42, count: 100)
        let framed = JSONRPCFramer.encode(payload)
        let stream = ByteStream(bytes: Array(framed))

        let body = try await JSONRPCFramer.read(from: stream)
        #expect(body == payload)
    }

    // MARK: - error paths

    @Test("read throws .malformedHeader when no Content-Length present")
    func readThrowsOnMissingContentLength() async throws {
        let raw = Data("Foo: bar\r\n\r\nbody".utf8)
        let stream = ByteStream(bytes: Array(raw))

        await #expect(throws: JSONRPCFramingError.contentLengthMissing) {
            _ = try await JSONRPCFramer.read(from: stream)
        }
    }

    @Test("read throws .malformedHeader when header is not key: value form")
    func readThrowsOnMalformedHeaderLine() async throws {
        let raw = Data("not-a-header-line\r\n\r\nbody".utf8)
        let stream = ByteStream(bytes: Array(raw))

        await #expect(throws: (any Error).self) {
            _ = try await JSONRPCFramer.read(from: stream)
        }
    }

    @Test("read throws .malformedHeader when stream ends before blank line")
    func readThrowsWhenBlankLineMissing() async throws {
        // No final \r\n\r\n separator: stream just ends.
        let raw = Data("Content-Length: 4\r\n".utf8)
        let stream = ByteStream(bytes: Array(raw))

        await #expect(throws: (any Error).self) {
            _ = try await JSONRPCFramer.read(from: stream)
        }
    }

    @Test("read throws .truncated when body shorter than Content-Length")
    func readThrowsOnTruncatedBody() async throws {
        let raw = Data("Content-Length: 100\r\n\r\nABC".utf8) // only 3 body bytes
        let stream = ByteStream(bytes: Array(raw))

        await #expect(throws: JSONRPCFramingError.truncated) {
            _ = try await JSONRPCFramer.read(from: stream)
        }
    }

    @Test("read header parsing is case-insensitive for Content-Length")
    func readHeaderCaseInsensitive() async throws {
        let payload = Data("ok".utf8)
        // Use lowercase header.
        let raw = Data("content-length: 2\r\n\r\nok".utf8)
        let stream = ByteStream(bytes: Array(raw))

        let body = try await JSONRPCFramer.read(from: stream)
        #expect(body == payload)
    }
}
