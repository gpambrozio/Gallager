import ClaudeSpyNetworking
import Foundation
import GallagerPluginProtocol

/// Minimal JSON-RPC echo sidecar used by `SidecarSupervisorTests` and
/// `PluginManagerTests`.
///
/// Behaviour:
///  - Replies to every request with `{ "echo": <params>, "method": <name> }`.
///  - `crash` request → `abort()` so the supervisor sees an unexpected exit.
///  - `stall` request → sleep 60 s without replying, lets tests exercise the
///    `JSONRPCConnection` timeout path.
///  - Logs every received request's method to stderr in the form
///    `[echo-rpc] <method>\n`. `PluginManagerTests` reads the sidecar's
///    log file to verify which RPCs the manager dispatched.
///  - `_test_push_set_projects` request → emit a `set_projects` notification
///    with two AgentProjects before replying. Used by the PluginManager
///    "projects update" test.
///
/// Reads framed JSON-RPC from stdin, writes framed responses (and the
/// occasional notification) to stdout. Built by SPM as a regular
/// `.executableTarget`; tests resolve the resulting binary in
/// `.build/<config>/EchoSidecar`.
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

                    // Trace every RPC so PluginManagerTests can verify the
                    // method the manager dispatched landed on the right
                    // sidecar.
                    _ = try? stderr.write(contentsOf: Data(
                        "[echo-rpc] \(req.method)\n".utf8
                    ))

                    // Special test-only path: emit a `set_projects`
                    // notification before responding. Lets the manager test
                    // verify that sidecar-pushed callbacks update the
                    // manager's project mirror.
                    if req.method == "_test_push_set_projects" {
                        let projects = JSONValue.array([
                            JSONValue.object([
                                "name": .string("alpha"),
                                "path": .string("/tmp/alpha"),
                                "last_used": .null,
                                "claude_config_dir": .null,
                                "agent": .string("claude-code"),
                            ]),
                            JSONValue.object([
                                "name": .string("beta"),
                                "path": .string("/tmp/beta"),
                                "last_used": .null,
                                "claude_config_dir": .null,
                                "agent": .string("claude-code"),
                            ]),
                        ])
                        let notif = JSONRPCNotification(
                            jsonrpc: "2.0",
                            method: "set_projects",
                            params: JSONValue.object(["projects": projects])
                        )
                        let notifBody = try encoder.encode(JSONRPCMessage.notification(notif))
                        try output.write(contentsOf: JSONRPCFramer.encode(notifBody))
                    }

                    // Build an "echoed" result: `{"echo": <params>, "method": <name>}`
                    // so tests can assert the round-trip.
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
