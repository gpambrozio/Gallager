import ClaudeSpyNetworking
import Foundation
import GallagerPluginProtocol
import Testing
@testable import ClaudeSpyE2ELib

@Suite("MacAppPluginIngressClient")
struct MacAppPluginIngressClientTests {
    /// Smoke test: standing up an `IngressSocketServer` at a tmp path, the
    /// client should connect and deliver a single framed JSON body that the
    /// server then yields as the equivalent ``IngressFrame``.
    @Test("client writes framed JSON over Unix socket")
    func clientWritesFramedJSONOverUnixSocket() async throws {
        let socketURL = Self.makeTempSocketURL()
        defer { try? FileManager.default.removeItem(at: socketURL) }

        let server = IngressSocketServer(socketURL: socketURL)
        let frames = try await server.start()

        // Drive the client.
        let client = MacAppPluginIngressClient(socketURL: socketURL)
        let payload: JSONValue = .object([
            "event": .string("test"),
            "n": .int(42),
        ])
        let env = [
            "TMUX_PANE": "%7",
            "CLAUDE_PROJECT_DIR": "/tmp/proj",
            "CLAUDE_SESSION_ID": "S1",
        ]
        try await client.send(payload: payload, env: env)

        // Receive on the server side.
        var iter = frames.makeAsyncIterator()
        let received = try #require(await iter.next())
        #expect(received.context == env)
        #expect(received.payload == payload)

        await server.stop()
    }

    // MARK: - Helpers

    /// Returns a temp directory `.sock` URL with a UUID suffix so concurrent
    /// runs don't collide. Patterned after `IngressSocketServerTests`.
    private static func makeTempSocketURL() -> URL {
        // macOS sockaddr_un caps the path at 104 bytes; "/tmp/<uuid>.sock"
        // is comfortably under the limit.
        URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("e2e-ingress-client-\(UUID().uuidString).sock")
    }
}
