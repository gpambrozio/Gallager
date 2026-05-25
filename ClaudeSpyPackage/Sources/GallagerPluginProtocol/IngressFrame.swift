import ClaudeSpyNetworking
import Foundation

// MARK: - IngressFrame

/// A single frame on the plugin's ingress socket
/// (`~/.gallager/state/plugins/<id>/ingress.sock`).
///
/// Per Spec §8, the socket wire format is:
///
///     4-byte big-endian UInt32 length + JSON body
///
/// where the JSON body is `{ "context": { ... }, "payload": <raw> }`.
/// `context` holds environment variables relevant at the time the hook fired
/// (e.g. tmux pane id); `payload` is whatever raw event shape the host agent
/// produced — the sidecar decodes it downstream.
public struct IngressFrame: Codable, Sendable, Equatable {
    public let context: [String: String]
    public let payload: JSONValue

    public init(context: [String: String], payload: JSONValue) {
        self.context = context
        self.payload = payload
    }

    // MARK: - Wire encoding

    /// Encode the frame for the socket: `UInt32` big-endian length prefix +
    /// JSON body. The receiver reads 4 bytes, parses the length, then reads
    /// exactly that many body bytes.
    public func encodedForSocket() throws -> Data {
        let body = try JSONEncoder().encode(self)
        let length = UInt32(body.count)
        var out = Data()
        out.append(IngressFrame.encodeLengthPrefix(length))
        out.append(body)
        return out
    }

    /// Decode a JSON body (caller has already stripped the 4-byte length
    /// prefix).
    public static func decode(from data: Data) throws -> IngressFrame {
        try JSONDecoder().decode(IngressFrame.self, from: data)
    }

    // MARK: - Length-prefix helpers

    /// Return the 4-byte big-endian representation of `length`.
    /// Exposed so the socket-write helpers in `ClaudeSpyPluginRuntime` can
    /// be unit-tested without forging a full `IngressFrame`.
    public static func encodeLengthPrefix(_ length: UInt32) -> Data {
        var bigEndian = length.bigEndian
        return Data(bytes: &bigEndian, count: MemoryLayout<UInt32>.size)
    }
}
