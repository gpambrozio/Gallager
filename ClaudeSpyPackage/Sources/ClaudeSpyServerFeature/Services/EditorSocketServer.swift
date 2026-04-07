#if os(macOS)
    import Foundation
    import Logging

    /// Represents an active editor request from a CLI invocation.
    public struct EditorRequest: Sendable {
        /// The tmux pane ID that triggered the edit (from $TMUX_PANE)
        public let paneId: String
        /// Path to the temp file containing the prompt
        public let filePath: String
        /// Unique identifier for this editor session
        public let sessionId: UUID
    }

    /// Unix domain socket server that receives edit requests from the GallagerEditor CLI.
    ///
    /// When Claude Code's Ctrl-G is pressed, it invokes the CLI via `$VISUAL`. The CLI
    /// connects to this socket, sends the pane ID and file path, then blocks until signaled.
    /// The server notifies the app, which shows an editor UI. When the user finishes editing,
    /// the app calls `completeSession(_:)` to signal the CLI to exit.
    actor EditorSocketServer {
        static let socketPath = "/tmp/gallager-editor.sock"

        private let logger = Logger(label: "com.claudespy.editorsocket")
        private var serverFd: Int32 = -1
        private var isRunning = false
        private var acceptTask: Task<Void, Never>?

        /// Active sessions keyed by session ID, holding the client file descriptor
        private var activeSessions: [UUID: Int32] = [:]

        /// Callback when a new edit request arrives
        private var onEditRequest: (@MainActor @Sendable (EditorRequest) -> Void)?

        /// Sets the callback for when new edit requests arrive.
        func setOnEditRequest(_ handler: @escaping @MainActor @Sendable (EditorRequest) -> Void) {
            onEditRequest = handler
        }

        // MARK: - Lifecycle

        /// Starts listening for CLI connections on the Unix domain socket.
        func start() throws {
            guard !isRunning else { return }

            // Only remove the socket file if it's stale (no active listener).
            // If another instance already owns the socket, leave it alone and skip starting.
            if Self.isSocketActive() {
                logger.info("Another instance already owns the editor socket, skipping")
                return
            }
            unlink(Self.socketPath)

            serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard serverFd >= 0 else {
                throw EditorSocketError.socketCreationFailed
            }

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            Self.socketPath.withCString { ptr in
                withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
                    let raw = UnsafeMutableRawPointer(sunPath)
                    raw.copyMemory(from: ptr, byteCount: Self.socketPath.utf8.count + 1)
                }
            }

            let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let bindResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    bind(serverFd, sockPtr, addrLen)
                }
            }
            guard bindResult == 0 else {
                close(serverFd)
                serverFd = -1
                throw EditorSocketError.bindFailed
            }

            guard listen(serverFd, 5) == 0 else {
                close(serverFd)
                serverFd = -1
                throw EditorSocketError.listenFailed
            }

            isRunning = true
            logger.info("Editor socket server listening at \(Self.socketPath)")

            // Accept connections in a background task
            acceptTask = Task {
                await self.acceptLoop()
            }
        }

        /// Stops the server and cleans up.
        func stop() {
            guard isRunning else { return }
            isRunning = false
            acceptTask?.cancel()
            acceptTask = nil

            // Close all active client connections
            for (_, clientFd) in activeSessions {
                close(clientFd)
            }
            activeSessions.removeAll()

            // Close server socket and remove socket file
            if serverFd >= 0 {
                close(serverFd)
                serverFd = -1
            }
            unlink(Self.socketPath)
            logger.info("Editor socket server stopped")
        }

        // MARK: - Session Management

        /// Signals a CLI that editing is complete, causing it to exit.
        /// Claude Code will then read the (possibly modified) temp file.
        func completeSession(_ sessionId: UUID) {
            guard let clientFd = activeSessions.removeValue(forKey: sessionId) else {
                logger.warning("No active session found for \(sessionId)")
                return
            }

            let msg = "done\n"
            msg.withCString { ptr in
                _ = Darwin.write(clientFd, ptr, msg.utf8.count)
            }
            close(clientFd)
            logger.info("Completed editor session \(sessionId)")
        }

        // MARK: - Private

        /// Checks whether an active listener exists on the socket path.
        /// Attempts a connect — if it succeeds, another instance owns the socket.
        private static func isSocketActive() -> Bool {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return false }
            defer { close(fd) }

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            socketPath.withCString { ptr in
                withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
                    let raw = UnsafeMutableRawPointer(sunPath)
                    raw.copyMemory(from: ptr, byteCount: socketPath.utf8.count + 1)
                }
            }

            let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let connected = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    connect(fd, sockPtr, addrLen)
                }
            }
            return connected == 0
        }

        private func acceptLoop() async {
            while !Task.isCancelled && isRunning {
                // Use a background thread for the blocking accept() call
                let clientFd = await withCheckedContinuation { continuation in
                    DispatchQueue.global().async { [serverFd] in
                        let fd = accept(serverFd, nil, nil)
                        continuation.resume(returning: fd)
                    }
                }

                guard clientFd >= 0 else {
                    if isRunning {
                        logger.error("accept() failed, stopping server")
                    }
                    break
                }

                await handleConnection(clientFd)
            }
        }

        private func handleConnection(_ fd: Int32) async {
            // Read the message (paneId\tfilePath\n) on a background thread
            // to avoid blocking the cooperative thread pool
            let data = await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    var data = Data()
                    var byte: UInt8 = 0
                    while Darwin.read(fd, &byte, 1) == 1 {
                        if byte == UInt8(ascii: "\n") { break }
                        data.append(byte)
                    }
                    continuation.resume(returning: data)
                }
            }

            guard let message = String(data: data, encoding: .utf8) else {
                logger.error("Failed to decode message from CLI")
                close(fd)
                return
            }

            let parts = message.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else {
                logger.error("Invalid message format: expected 'paneId\\tfilePath'")
                close(fd)
                return
            }

            let paneId = String(parts[0])
            let filePath = String(parts[1])
            let sessionId = UUID()

            // Store the connection for later signaling
            activeSessions[sessionId] = fd

            let request = EditorRequest(paneId: paneId, filePath: filePath, sessionId: sessionId)
            logger.info("Editor request from pane \(paneId): \(filePath)")

            // Notify the app on the main actor
            if let handler = onEditRequest {
                await handler(request)
            }
        }
    }

    // MARK: - Errors

    enum EditorSocketError: Error, LocalizedError {
        case socketCreationFailed
        case bindFailed
        case listenFailed

        var errorDescription: String? {
            switch self {
            case .socketCreationFailed: "Failed to create Unix domain socket"
            case .bindFailed: "Failed to bind socket to \(EditorSocketServer.socketPath)"
            case .listenFailed: "Failed to listen on socket"
            }
        }
    }
#endif
