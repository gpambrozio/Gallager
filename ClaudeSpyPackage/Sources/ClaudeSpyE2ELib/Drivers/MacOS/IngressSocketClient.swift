import Darwin
import Foundation
import GallagerPluginProtocol
import Logging

/// Writes one self-identifying, length-prefixed `IngressFrame` to the app's
/// ingress Unix socket (spec §8 / §17.3).
///
/// This replaces the deleted HTTP hook POST path: instead of POSTing a hook body
/// to `HookServerService`, the E2E driver connects to the per-scenario ingress
/// socket (`<gallager-state-root>/ingress.sock`), writes a single
/// `4-byte big-endian length + JSON body` frame carrying `plugin_id`, the
/// harvested `context` env (`TMUX_PANE`, `CLAUDE_PROJECT_DIR`), and the raw
/// host-agent `payload`, then closes — exactly what a real hook bridge does
/// (spec §8.1). The app routes the frame by `plugin_id` to the owning core's
/// `handleIngress`, so existing scenarios that send real Claude/Codex hook JSON
/// exercise the SAME real-translation flow, just over the new transport.
enum IngressSocketClient {
    private static let logger = Logger(label: "e2e.ingress-socket")

    /// Connect to `socketPath`, write one length-prefixed frame built from the
    /// given fields, and close. Returns `true` on a successful full write.
    ///
    /// - Parameters:
    ///   - pluginID: routing id baked into the frame (`"claude-code"` for the
    ///     real Claude core, `"codex"` for Codex, `"echo"` for the reference core).
    ///   - context: env snapshot the bridge would have harvested. `TMUX_PANE`
    ///     gives the frame its pane identity; agent-specific keys (e.g.
    ///     `CLAUDE_PROJECT_DIR`) are read by the owning core.
    ///   - payload: raw host-agent event bytes (the JSON hook body).
    ///   - socketPath: the per-instance ingress socket path.
    @discardableResult
    static func sendFrame(
        pluginID: String,
        context: [String: String],
        payload: Data,
        socketPath: String
    ) async throws -> Bool {
        let frame = IngressFrame(pluginID: pluginID, context: context, payload: payload)
        let frameData = try frame.encodeFrame()

        // The blocking POSIX connect/write runs off the cooperative pool so the
        // orchestrator actor isn't stalled.
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    try writeFrameSynchronously(frameData, to: socketPath)
                    Self.logger.info(
                        "Ingress frame written to \(socketPath) (plugin_id=\(pluginID), \(frameData.count) bytes)"
                    )
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Synchronous POSIX writer

    /// Open an `AF_UNIX`/`SOCK_STREAM` connection to `socketPath`, write all of
    /// `frameData`, and close. Throws `IngressClientError` on any failure so the
    /// step surfaces a clear message (the app not being up yet is the common
    /// case — the socket file won't exist).
    private static func writeFrameSynchronously(_ frameData: Data, to socketPath: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw IngressClientError.socketCreationFailed(errnoString())
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard socketPath.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw IngressClientError.pathTooLong(socketPath)
        }
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
                let raw = UnsafeMutableRawPointer(sunPath)
                raw.copyMemory(from: ptr, byteCount: socketPath.utf8.count + 1)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, addrLen)
            }
        }
        guard connectResult == 0 else {
            throw IngressClientError.connectFailed(path: socketPath, reason: errnoString())
        }

        try frameData.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            let total = buffer.count
            while offset < total {
                let written = Darwin.write(fd, base + offset, total - offset)
                if written > 0 {
                    offset += written
                } else {
                    throw IngressClientError.writeFailed(errnoString())
                }
            }
        }
    }

    private static func errnoString() -> String {
        String(cString: strerror(errno))
    }
}

/// Errors writing an ingress frame from the E2E driver.
enum IngressClientError: Error, LocalizedError {
    case socketCreationFailed(String)
    case pathTooLong(String)
    case connectFailed(path: String, reason: String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case let .socketCreationFailed(reason):
            "Failed to create ingress client socket: \(reason)"
        case let .pathTooLong(path):
            "Ingress socket path exceeds the maximum length: \(path)"
        case let .connectFailed(path, reason):
            "Failed to connect to ingress socket \(path): \(reason) "
                + "(is the app running with --gallager-state-root pointing here?)"
        case let .writeFailed(reason):
            "Failed to write the ingress frame: \(reason)"
        }
    }
}
