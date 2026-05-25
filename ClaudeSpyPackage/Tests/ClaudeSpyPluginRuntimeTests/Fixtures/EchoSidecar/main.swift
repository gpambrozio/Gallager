import ClaudeSpyNetworking
import Foundation
import GallagerPluginProtocol

/// Minimal JSON-RPC echo sidecar used by `SidecarSupervisorTests`.
///
/// Behaviour:
///  - Replies to every request with `{ "echo": <params> }`.
///  - `crash` request → `abort()` so the supervisor sees an unexpected exit.
///  - `stall` request → sleep 60 s without replying, lets tests exercise the
///    `JSONRPCConnection` timeout path.
///  - Notifications and unsolicited responses are logged to stderr.
///
/// Reads framed JSON-RPC from stdin, writes framed responses to stdout. Built
/// by SPM as a regular `.executableTarget`; tests resolve the resulting
/// binary in `.build/<config>/EchoSidecar`.
@main
struct EchoSidecar {
    static func main() async throws {
        let input = FileHandle.standardInput
        let output = FileHandle.standardOutput
        let stderr = FileHandle.standardError

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        // NB: Don't use `input.bytes` — `FileHandle.AsyncBytes` doesn't
        // deliver pipe bytes until the writer closes its end, so a real
        // sidecar reading from stdin via that iterator would never see a
        // request frame. `makeAsyncByteStream()` uses readabilityHandler so
        // each flushed frame lands immediately.
        let bytes = input.makeAsyncByteStream()

        while true {
            do {
                let body = try await JSONRPCFramer.read(from: bytes)
                guard let message = try? decoder.decode(JSONRPCMessage.self, from: body) else {
                    _ = try? stderr.write(contentsOf: Data("[echo] malformed JSON\n".utf8))
                    continue
                }
                switch message {
                case let .request(req):
                    if req.method == "crash" {
                        abort()
                    }
                    if req.method == "stall" {
                        try? await Task.sleep(for: .seconds(60))
                        continue
                    }
                    // Build an "echoed" result: `{"echo": <params>}` so
                    // tests can assert the round-trip.
                    let result = JSONValue.object([
                        "echo": req.params ?? .null,
                        "method": .string(req.method),
                    ])
                    let response = JSONRPCResponse(
                        jsonrpc: "2.0",
                        id: req.id,
                        result: result,
                        error: nil
                    )
                    let respBody = try encoder.encode(JSONRPCMessage.response(response))
                    try output.write(contentsOf: JSONRPCFramer.encode(respBody))

                case let .notification(notification):
                    _ = try? stderr.write(contentsOf: Data(
                        "[echo] notification \(notification.method)\n".utf8
                    ))

                case .response:
                    _ = try? stderr.write(contentsOf: Data(
                        "[echo] unsolicited response\n".utf8
                    ))
                }
            } catch {
                // EOF or unrecoverable error — exit cleanly.
                break
            }
        }
    }
}
