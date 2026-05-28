import Foundation

// MARK: - JSONRPCFramer

/// LSP-style framing for JSON-RPC messages.
///
/// The sidecar protocol (Spec §6) uses `Content-Length:` header + blank
/// line + JSON body framing, identical to LSP. This namespace handles both
/// directions of the wire:
///
/// - `encode(_:)` builds a complete framed message from a JSON body.
/// - `read(from:)` consumes a framed message off an `AsyncSequence<UInt8>`
///   and returns the JSON body bytes only.
public enum JSONRPCFramer {
    /// Build a single LSP-framed JSON-RPC message:
    /// `Content-Length: <N>\r\n\r\n<body>`.
    public static func encode(_ body: Data) -> Data {
        var out = Data()
        let header = "Content-Length: \(body.count)\r\n\r\n"
        out.append(contentsOf: header.utf8)
        out.append(body)
        return out
    }

    /// Upper bound on the header block. LSP-style headers are short
    /// (`Content-Length: <N>\r\n\r\n`); 16 KiB is generous and ensures a peer
    /// that never sends `\r\n\r\n` can't grow `headerBuffer` until OOM.
    public static let maxHeaderBytes = 16 * 1_024

    /// Read one framed message from `bytes` and return the JSON body.
    ///
    /// Parses headers byte-by-byte until the blank `\r\n\r\n` separator, then
    /// reads exactly `Content-Length` more bytes. Throws on malformed headers,
    /// missing `Content-Length`, or truncated bodies.
    public static func read<S: AsyncSequence>(from bytes: S) async throws -> Data
        where S.Element == UInt8 {
        // Headers are terminated by an empty line: "\r\n\r\n". We accumulate
        // bytes until we see that exact 4-byte trailer, parse the text once,
        // then move on to the body.
        var headerBuffer: [UInt8] = []
        var contentLength: Int?
        var iterator = bytes.makeAsyncIterator()

        while true {
            guard let byte = try await iterator.next() else {
                // Stream ended before we saw the blank line.
                throw JSONRPCFramingError.malformedHeader("stream ended before header terminator")
            }
            headerBuffer.append(byte)
            if headerBuffer.count > maxHeaderBytes {
                throw JSONRPCFramingError.malformedHeader(
                    "header exceeded \(maxHeaderBytes) bytes without CRLFCRLF"
                )
            }

            // Cheap end-of-headers detector: last 4 bytes equal CRLFCRLF.
            if
                headerBuffer.count >= 4,
                headerBuffer[headerBuffer.count - 4] == 0x0D,
                headerBuffer[headerBuffer.count - 3] == 0x0A,
                headerBuffer[headerBuffer.count - 2] == 0x0D,
                headerBuffer[headerBuffer.count - 1] == 0x0A {
                // Strip the trailing CRLFCRLF before parsing.
                let headerBytes = headerBuffer.prefix(headerBuffer.count - 4)
                contentLength = try parseHeaders(Array(headerBytes))
                break
            }
        }

        guard let length = contentLength else {
            // Defensive: parseHeaders is the only path that sets this; if it
            // returned without throwing, length is non-nil. Keeping the guard
            // makes the contract explicit.
            throw JSONRPCFramingError.contentLengthMissing
        }

        // Read exactly `length` more body bytes.
        var body = Data()
        body.reserveCapacity(length)
        for _ in 0..<length {
            guard let byte = try await iterator.next() else {
                throw JSONRPCFramingError.truncated
            }
            body.append(byte)
        }
        return body
    }

    // MARK: - Internal

    private static func parseHeaders(_ bytes: [UInt8]) throws -> Int {
        guard let headerString = String(bytes: bytes, encoding: .utf8) else {
            throw JSONRPCFramingError.malformedHeader("non-utf8 header bytes")
        }

        // Header block can have multiple `Key: Value\r\n` lines. We only need
        // `Content-Length`, but reject lines that don't fit the form so
        // garbage doesn't decode as an empty header set.
        let lines = headerString.components(separatedBy: "\r\n")
            .filter { !$0.isEmpty }

        var contentLength: Int?
        for line in lines {
            guard let colonIndex = line.firstIndex(of: ":") else {
                throw JSONRPCFramingError.malformedHeader("missing colon in header line: \(line)")
            }
            let key = line[..<colonIndex].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colonIndex)...]
                .trimmingCharacters(in: .whitespaces)

            if key.lowercased() == "content-length" {
                guard let parsed = Int(value), parsed >= 0 else {
                    throw JSONRPCFramingError.malformedHeader("invalid Content-Length value: \(value)")
                }
                contentLength = parsed
            }
        }

        guard let length = contentLength else {
            throw JSONRPCFramingError.contentLengthMissing
        }
        return length
    }
}

// MARK: - JSONRPCFramingError

/// Errors emitted by `JSONRPCFramer.read(from:)`.
public enum JSONRPCFramingError: Error, Equatable, Sendable {
    /// Header block was structurally invalid (no colon, non-utf8, etc.).
    case malformedHeader(String)

    /// Header block parsed but did not contain a `Content-Length` field.
    case contentLengthMissing

    /// Stream ended before the body finished. Header said the body would be
    /// N bytes; we got fewer.
    case truncated
}
