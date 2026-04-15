#if os(macOS)
    import ClaudeSpyNetworking
    import Dependencies
    import DependenciesMacros
    import Foundation
    import Logging

    /// Handler type for incoming JSON-RPC requests.
    /// Returns a response for normal requests.
    /// For editor.open, the handler should block until editing completes, then return.
    public typealias APIRequestHandler = @Sendable (JSONRPCRequest) async -> JSONRPCResponse

    @DependencyClient
    public struct APISocketServer: Sendable {
        public var start: @Sendable (_ socketPath: String) async throws -> Void
        public var stop: @Sendable () async -> Void
        public var setRequestHandler: @Sendable (_ handler: @escaping APIRequestHandler) async -> Void
        /// The socket path the server is listening on (set after start()).
        public var getSocketPath: @Sendable () async -> String? = { nil }
    }

    extension APISocketServer: DependencyKey {
        public static var previewValue: APISocketServer {
            APISocketServer()
        }

        public static var liveValue: APISocketServer {
            let server = LiveAPISocketServer()
            return APISocketServer(
                start: { socketPath in
                    try await server.start(socketPath: socketPath)
                },
                stop: {
                    await server.stop()
                },
                setRequestHandler: { handler in
                    await server.setRequestHandler(handler)
                },
                getSocketPath: {
                    await server.socketPath
                }
            )
        }
    }

    /// Actor-based live implementation of the API socket server.
    actor LiveAPISocketServer {
        private let logger = Logger(label: "com.claudespy.apisocket")
        private(set) var socketPath: String?
        private var serverFd: Int32 = -1
        private var isRunning = false
        private var acceptTask: Task<Void, Never>?
        private var requestHandler: APIRequestHandler?

        func setRequestHandler(_ handler: @escaping APIRequestHandler) {
            requestHandler = handler
        }

        func start(socketPath: String) throws {
            guard !isRunning else { return }

            if isSocketActive(path: socketPath) {
                logger.info("Another instance already owns the API socket, skipping")
                return
            }
            unlink(socketPath)

            serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard serverFd >= 0 else {
                throw APISocketError.socketCreationFailed
            }

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            socketPath.withCString { ptr in
                withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
                    let raw = UnsafeMutableRawPointer(sunPath)
                    raw.copyMemory(from: ptr, byteCount: socketPath.utf8.count + 1)
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
                throw APISocketError.bindFailed
            }

            guard listen(serverFd, 5) == 0 else {
                close(serverFd)
                serverFd = -1
                throw APISocketError.listenFailed
            }

            self.socketPath = socketPath
            isRunning = true
            logger.info("API socket server listening at \(socketPath)")

            acceptTask = Task {
                await acceptLoop()
            }
        }

        func stop() {
            guard isRunning else { return }
            isRunning = false
            acceptTask?.cancel()
            acceptTask = nil

            if serverFd >= 0 {
                close(serverFd)
                serverFd = -1
            }
            if let path = socketPath {
                unlink(path)
            }
            logger.info("API socket server stopped")
        }

        // MARK: - Private

        private func isSocketActive(path: String) -> Bool {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return false }
            defer { close(fd) }

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            path.withCString { ptr in
                withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
                    let raw = UnsafeMutableRawPointer(sunPath)
                    raw.copyMemory(from: ptr, byteCount: path.utf8.count + 1)
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

                // Handle each connection in its own task so multiple clients
                // can be served concurrently (important for editor.open which blocks)
                let handler = requestHandler
                let logger = logger
                Task {
                    await Self.handleConnection(clientFd, handler: handler, logger: logger)
                }
            }
        }

        /// Handles a single client connection. Reads newline-delimited JSON-RPC
        /// requests and sends responses until the client disconnects.
        private static func handleConnection(
            _ fd: Int32,
            handler: APIRequestHandler?,
            logger: Logger
        ) async {
            defer { close(fd) }

            // Read messages in a loop (persistent connection)
            while true {
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

                guard !data.isEmpty else {
                    // Client disconnected
                    break
                }

                // Decode JSON-RPC request
                let response: JSONRPCResponse
                do {
                    let request = try JSONDecoder().decode(JSONRPCRequest.self, from: data)
                    if let handler {
                        response = await handler(request)
                    } else {
                        response = .internalError(id: request.id, "No request handler configured")
                    }
                } catch {
                    // Can't decode request — send error with empty ID
                    response = .internalError(id: "", "Invalid JSON-RPC request: \(error.localizedDescription)")
                }

                // Send response
                do {
                    var responseData = try JSONEncoder().encode(response)
                    responseData.append(UInt8(ascii: "\n"))
                    let written = responseData.withUnsafeBytes { ptr in
                        Darwin.write(fd, ptr.baseAddress!, ptr.count)
                    }
                    if written < 0 {
                        logger.error("Failed to write response")
                        break
                    }
                } catch {
                    logger.error("Failed to encode response: \(error)")
                    break
                }
            }
        }
    }

    enum APISocketError: Error, LocalizedError {
        case socketCreationFailed
        case bindFailed
        case listenFailed

        var errorDescription: String? {
            switch self {
            case .socketCreationFailed: "Failed to create Unix domain socket"
            case .bindFailed: "Failed to bind API socket"
            case .listenFailed: "Failed to listen on socket"
            }
        }
    }
#endif
