import Foundation
import Testing
@testable import GallagerPluginProtocol

@Suite("StdioFramer")
struct StdioFramerTests {
    @Test("encode prepends a Content-Length header + blank line")
    func encodeShape() {
        let framed = StdioFramer.encode(Data("{}".utf8))
        #expect(String(decoding: framed, as: UTF8.self) == "Content-Length: 2\r\n\r\n{}")
    }

    @Test("decoder reassembles a frame split across chunks")
    func splitChunks() throws {
        var dec = FrameDecoder()
        let framed = StdioFramer.encode(Data(#"{"a":1}"#.utf8))
        #expect(try dec.push(framed.prefix(5)).isEmpty) // header start only
        let bodies = try dec.push(framed.suffix(from: framed.index(framed.startIndex, offsetBy: 5)))
        #expect(bodies.count == 1)
        #expect(String(decoding: bodies[0], as: UTF8.self) == #"{"a":1}"#)
    }

    @Test("decoder yields two frames from one chunk, in order")
    func twoFrames() throws {
        var dec = FrameDecoder()
        var buf = StdioFramer.encode(Data(#"{"n":1}"#.utf8))
        buf.append(StdioFramer.encode(Data(#"{"n":2}"#.utf8)))
        let bodies = try dec.push(buf)
        #expect(bodies.map { String(decoding: $0, as: UTF8.self) } == [#"{"n":1}"#, #"{"n":2}"#])
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
