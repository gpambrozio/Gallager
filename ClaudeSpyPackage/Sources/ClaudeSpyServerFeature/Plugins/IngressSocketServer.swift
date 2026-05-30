#if os(macOS)
    import ClaudeSpyNetworking
    import Darwin
    import Foundation
    import GallagerPluginProtocol
    import Logging

    /// The one app-owned ingress socket (spec §8). A POSIX `AF_UNIX`/`SOCK_STREAM`
    /// accept-loop server (mirrors `APISocketServer`) listening at
    /// `GallagerPaths.ingressSocketPath`.
    ///
    /// Each connection carries one (or more) length-prefixed frames:
    /// `4-byte big-endian UInt32 length + JSON body`. The server reads a frame,
    /// decodes it (`IngressFrame.decode`), routes by `pluginID` to the owning core's
    /// `handleIngress`, and hands any returned `PluginEvent` to the dispatcher.
    ///
    /// Robustness (spec §8.2/§8.3): frames for disabled/unknown plugins and
    /// malformed frames are dropped with a debug log; the connection survives so a
    /// subsequent good frame still lands.
    public actor IngressSocketServer {
        /// Resolve the enabled core for a `pluginID` (the registry's `core(_:)`).
        public typealias CoreLookup = @Sendable (_ pluginID: String) async -> (any PluginCore)?

        private let logger = Logger(label: "com.claudespy.ingress-socket")
        private let socketPath: String
        private let coreLookup: CoreLookup
        private let dispatcher: PluginEventDispatcher

        private var serverFd: Int32 = -1
        private var isRunning = false
        private var acceptTask: Task<Void, Never>?

        /// - Parameters:
        ///   - socketPath: where to bind the ingress socket (typically
        ///     `GallagerPaths.ingressSocketPath.path`).
        ///   - coreLookup: resolves an enabled core by `pluginID`.
        ///   - dispatcher: receives every `PluginEvent` a core returns.
        public init(
            socketPath: String,
            coreLookup: @escaping CoreLookup,
            dispatcher: PluginEventDispatcher
        ) {
            self.socketPath = socketPath
            self.coreLookup = coreLookup
            self.dispatcher = dispatcher
        }

        /// The path this server binds to (as supplied at init). Exposed so callers
        /// and tests can connect without re-deriving it.
        public var boundSocketPath: String {
            socketPath
        }

        // MARK: - Lifecycle

        /// Bind, listen, and start accepting. Idempotent. If another instance
        /// already owns the socket, this is a no-op (matches `APISocketServer`).
        public func start() throws {
            guard !isRunning else { return }

            if isSocketActive(path: socketPath) {
                logger.info("Another instance already owns the ingress socket, skipping")
                return
            }
            // Ensure the parent directory exists before binding.
            let dir = (socketPath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true
            )
            unlink(socketPath)

            serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard serverFd >= 0 else {
                throw IngressSocketError.socketCreationFailed
            }

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            guard socketPath.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
                close(serverFd)
                serverFd = -1
                throw IngressSocketError.pathTooLong
            }
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
                throw IngressSocketError.bindFailed
            }

            guard listen(serverFd, 16) == 0 else {
                close(serverFd)
                serverFd = -1
                throw IngressSocketError.listenFailed
            }

            isRunning = true
            logger.info("Ingress socket server listening at \(socketPath)")

            acceptTask = Task { [weak self] in
                await self?.acceptLoop()
            }
        }

        /// Stop accepting, close the socket, and unlink the path. Idempotent.
        public func stop() {
            guard isRunning else { return }
            isRunning = false
            acceptTask?.cancel()
            acceptTask = nil

            if serverFd >= 0 {
                shutdown(serverFd, SHUT_RDWR)
                close(serverFd)
                serverFd = -1
            }
            unlink(socketPath)
            logger.info("Ingress socket server stopped")
        }

        // MARK: - Accept loop

        private func acceptLoop() async {
            while !Task.isCancelled, isRunning {
                let clientFd = await withCheckedContinuation { continuation in
                    DispatchQueue.global().async { [serverFd] in
                        let fd = accept(serverFd, nil, nil)
                        continuation.resume(returning: fd)
                    }
                }

                guard clientFd >= 0 else {
                    if isRunning {
                        logger.debug("accept() failed, stopping ingress server")
                    }
                    break
                }

                // Each connection is handled in its own task; the bridge writes one
                // (or a few) frames and disconnects.
                let lookup = coreLookup
                let dispatcher = dispatcher
                let logger = logger
                Task {
                    await Self.handleConnection(
                        clientFd,
                        coreLookup: lookup,
                        dispatcher: dispatcher,
                        logger: logger
                    )
                }
            }
        }

        /// Read length-prefixed frames from one client until it disconnects (spec
        /// §8). Malformed frames and frames for unknown/disabled plugins are dropped
        /// with a debug log; the connection survives for the next frame.
        private static func handleConnection(
            _ fd: Int32,
            coreLookup: @escaping CoreLookup,
            dispatcher: PluginEventDispatcher,
            logger: Logger
        ) async {
            defer { close(fd) }

            while true {
                // 1) Read the 4-byte big-endian length prefix.
                guard let lengthData = await readExactly(fd, count: 4), lengthData.count == 4 else {
                    break // clean disconnect or short read → done with this client
                }
                let bodyLength = lengthData.withUnsafeBytes { raw in
                    UInt32(bigEndian: raw.loadUnaligned(as: UInt32.self))
                }

                // Guard against an absurd length (protects against a hostile or
                // corrupt prefix). 16 MB is far beyond any real hook payload.
                guard bodyLength > 0, bodyLength <= 16 * 1_024 * 1_024 else {
                    logger.debug("Ingress frame length \(bodyLength) out of range, dropping connection")
                    break
                }

                // 2) Read exactly `bodyLength` body bytes.
                guard
                    let body = await readExactly(fd, count: Int(bodyLength)),
                    body.count == Int(bodyLength)
                else {
                    break // truncated body → give up on this client
                }

                // 3) Decode + route. Failures drop this frame but keep the socket.
                let frame: IngressFrame
                do {
                    frame = try IngressFrame.decode(body: body)
                } catch {
                    logger.debug("Dropping malformed ingress frame: \(error)")
                    continue
                }

                guard let core = await coreLookup(frame.pluginID) else {
                    logger.debug("Dropping ingress frame for unknown/disabled plugin '\(frame.pluginID)'")
                    continue
                }

                if let event = await core.handleIngress(frame) {
                    await dispatcher.dispatch(event)
                } else {
                    logger.debug("Core '\(frame.pluginID)' dropped ingress frame (returned nil)")
                }
            }
        }

        /// Read exactly `count` bytes from `fd`, or `nil` if the peer closed before
        /// `count` bytes arrived. Runs the blocking reads off the cooperative pool.
        private static func readExactly(_ fd: Int32, count: Int) async -> Data? {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    var buffer = Data()
                    buffer.reserveCapacity(count)
                    var scratch = [UInt8](repeating: 0, count: min(count, 4_096))
                    while buffer.count < count {
                        let remaining = count - buffer.count
                        let toRead = min(remaining, scratch.count)
                        let n = scratch.withUnsafeMutableBytes { ptr in
                            Darwin.read(fd, ptr.baseAddress, toRead)
                        }
                        if n > 0 {
                            buffer.append(contentsOf: scratch[0..<n])
                        } else {
                            // n == 0 → EOF; n < 0 → error. Either way, stop.
                            continuation.resume(returning: buffer.isEmpty ? nil : buffer)
                            return
                        }
                    }
                    continuation.resume(returning: buffer)
                }
            }
        }

        // MARK: - Socket liveness probe

        private func isSocketActive(path: String) -> Bool {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return false }
            defer { close(fd) }

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
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
    }

    // MARK: - Errors

    enum IngressSocketError: Error, LocalizedError {
        case socketCreationFailed
        case bindFailed
        case listenFailed
        case pathTooLong

        var errorDescription: String? {
            switch self {
            case .socketCreationFailed: "Failed to create the ingress Unix domain socket"
            case .bindFailed: "Failed to bind the ingress socket"
            case .listenFailed: "Failed to listen on the ingress socket"
            case .pathTooLong: "Ingress socket path exceeds the maximum length"
            }
        }
    }
#endif
