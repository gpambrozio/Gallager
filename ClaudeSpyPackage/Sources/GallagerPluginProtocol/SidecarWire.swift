import Foundation

public enum FramingError: Error, Equatable {
    case malformedHeader
    case bodyTooLarge(Int)
    case missingContentLength
}

public enum StdioFramer {
    static let maxHeaderBytes = 16 * 1_024
    static let maxBodyBytes = 32 * 1_024 * 1_024

    public static func encode(_ body: Data) -> Data {
        var out = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        out.append(body)
        return out
    }
}

/// Incremental, allocation-bounded decoder for `Content-Length`-framed JSON.
/// Not thread-safe; the transport actor owns one and feeds it inline.
public struct FrameDecoder {
    private var buffer = Data()
    private var expectedBody: Int? // set once a header is parsed; nil while reading a header
    private static let headerTerminator = Data("\r\n\r\n".utf8)

    public init() { }

    /// Append `chunk`; return every complete body it completes, in order.
    public mutating func push(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var bodies: [Data] = []
        while true {
            if let need = expectedBody {
                guard buffer.count >= need else { break }
                bodies.append(buffer.prefix(need))
                buffer.removeFirst(need)
                expectedBody = nil
                continue
            }
            guard let range = buffer.range(of: Self.headerTerminator) else {
                if buffer.count > StdioFramer.maxHeaderBytes { throw FramingError.malformedHeader }
                break
            }
            let header = buffer[buffer.startIndex..<range.lowerBound]
            if header.count > StdioFramer.maxHeaderBytes { throw FramingError.malformedHeader }
            guard let length = Self.contentLength(header) else { throw FramingError.missingContentLength }
            if length > StdioFramer.maxBodyBytes { throw FramingError.bodyTooLarge(length) }
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            expectedBody = length
        }
        return bodies
    }

    private static func contentLength(_ header: Data) -> Int? {
        guard let text = String(data: header, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard
                parts.count == 2,
                parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length"
            else { continue }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}
