#if os(macOS)
    import ClaudeSpyNetworking
    import Darwin
    import Foundation
    import GallagerPluginProtocol
    import Testing
    @testable import ClaudeSpyServerFeature

    /// Collects every `PluginEvent` that reaches the dispatcher so the round-trip
    /// test can assert the echo core's event arrived.
    private actor EventCollector {
        private(set) var events: [PluginEvent] = []
        func record(_ event: PluginEvent) {
            events.append(event)
        }
    }

    @Suite("IngressSocketServer")
    struct IngressSocketServerTests {
        // MARK: - Helpers

        private func makeSocketPath() -> String {
            // Keep the path short — sockaddr_un.sun_path caps at ~104 bytes.
            "\(NSTemporaryDirectory())gi-\(UUID().uuidString.prefix(8)).sock"
        }

        private func makeDispatcher(_ collector: EventCollector) -> PluginEventDispatcher {
            PluginEventDispatcher(
                onState: { pluginID, sessionID, state, tmuxPane, projectPath, permissionMode in
                    await collector.record(PluginEvent(
                        pluginID: pluginID,
                        sessionID: sessionID,
                        state: state,
                        tmuxPane: tmuxPane,
                        projectPath: projectPath,
                        permissionMode: permissionMode
                    ))
                }
            )
        }

        /// Connect a client `AF_UNIX` socket to `path`, retrying briefly while the
        /// server finishes binding. Returns the connected fd, or `nil` on failure.
        private func connectClient(to path: String, deadline: Date) -> Int32? {
            while Date() < deadline {
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else { return nil }

                var addr = sockaddr_un()
                addr.sun_family = sa_family_t(AF_UNIX)
                path.withCString { ptr in
                    withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
                        UnsafeMutableRawPointer(sunPath).copyMemory(from: ptr, byteCount: path.utf8.count + 1)
                    }
                }
                let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
                let result = withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        connect(fd, sockPtr, addrLen)
                    }
                }
                if result == 0 { return fd }
                close(fd)
                usleep(20_000) // 20ms; server is mid-bind
            }
            return nil
        }

        @discardableResult
        private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
            data.withUnsafeBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return false }
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(fd, base + offset, raw.count - offset)
                    if n <= 0 { return false }
                    offset += n
                }
                return true
            }
        }

        /// Poll `collector` until it has at least `count` events or the deadline
        /// passes. Sanctioned `Task.sleep` poll: the socket read happens on a real
        /// background queue, so there is no virtual clock to advance.
        private func waitForEvents(_ collector: EventCollector, atLeast count: Int) async -> [PluginEvent] {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                let events = await collector.events
                if events.count >= count { return events }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return await collector.events
        }

        private func echoFrameData(directive: EchoDirective, context: [String: String]) throws -> Data {
            let payload = try JSONEncoder().encode(directive)
            let frame = IngressFrame(pluginID: EchoPluginCore.pluginID, context: context, payload: payload)
            return try frame.encodeFrame()
        }

        // MARK: - Tests

        @Test("round-trip: an echo frame produces a PluginEvent that reaches the dispatcher")
        func roundTrip() async throws {
            let collector = EventCollector()
            let dispatcher = makeDispatcher(collector)
            let core = EchoPluginCore()
            let server = IngressSocketServer(
                socketPath: makeSocketPath(),
                coreLookup: { id in id == EchoPluginCore.pluginID ? core : nil },
                dispatcher: dispatcher
            )
            try await server.start()
            defer { Task { await server.stop() } }

            let path = await pathOf(server)
            let fd = try #require(connectClient(to: path, deadline: Date().addingTimeInterval(5)))
            defer { close(fd) }

            let directive = EchoDirective(sessionID: "sess-1", state: .working)
            let frameData = try echoFrameData(directive: directive, context: ["TMUX_PANE": "%1"])
            #expect(writeAll(fd, frameData))

            let events = await waitForEvents(collector, atLeast: 1)
            #expect(events.count == 1)
            let event = try #require(events.first)
            #expect(event.pluginID == EchoPluginCore.pluginID)
            #expect(event.sessionID == "sess-1")
            #expect(event.state == .working)
            // tmuxPane bootstrapped from the frame context (echo falls back to it).
            #expect(event.tmuxPane == "%1")

            await server.stop()
        }

        @Test("a malformed frame is dropped and the socket survives a subsequent good frame")
        func malformedThenGood() async throws {
            let collector = EventCollector()
            let dispatcher = makeDispatcher(collector)
            let core = EchoPluginCore()
            let server = IngressSocketServer(
                socketPath: makeSocketPath(),
                coreLookup: { id in id == EchoPluginCore.pluginID ? core : nil },
                dispatcher: dispatcher
            )
            try await server.start()
            defer { Task { await server.stop() } }

            let path = await pathOf(server)
            let fd = try #require(connectClient(to: path, deadline: Date().addingTimeInterval(5)))
            defer { close(fd) }

            // 1) Malformed: a 4-byte length prefix followed by non-JSON bytes.
            let garbage = Data([0xFF, 0xFE, 0xFD])
            var malformed = Data()
            var len = UInt32(garbage.count).bigEndian
            malformed.append(Data(bytes: &len, count: 4))
            malformed.append(garbage)
            #expect(writeAll(fd, malformed))

            // 2) A good frame on the same connection should still land.
            let directive = EchoDirective(sessionID: "sess-2", state: .doneWorking(summary: nil))
            let good = try echoFrameData(directive: directive, context: ["TMUX_PANE": "%2"])
            #expect(writeAll(fd, good))

            let events = await waitForEvents(collector, atLeast: 1)
            #expect(events.count == 1)
            #expect(events.first?.sessionID == "sess-2")
            #expect(events.first?.state?.needsAttention == true)

            await server.stop()
        }

        @Test("a frame for an unknown plugin id is dropped")
        func unknownPluginDropped() async throws {
            let collector = EventCollector()
            let dispatcher = makeDispatcher(collector)
            let core = EchoPluginCore()
            let server = IngressSocketServer(
                socketPath: makeSocketPath(),
                // Only echo is known; "ghost" resolves to nil.
                coreLookup: { id in id == EchoPluginCore.pluginID ? core : nil },
                dispatcher: dispatcher
            )
            try await server.start()
            defer { Task { await server.stop() } }

            let path = await pathOf(server)
            let fd = try #require(connectClient(to: path, deadline: Date().addingTimeInterval(5)))
            defer { close(fd) }

            // Frame for a plugin the lookup doesn't know.
            let payload = try JSONEncoder().encode(EchoDirective(sessionID: "x", state: .working))
            let ghost = IngressFrame(pluginID: "ghost", context: [:], payload: payload)
            #expect(try writeAll(fd, ghost.encodeFrame()))

            // Follow with a known-good echo frame to prove the socket is still alive
            // and to give the collector something to wait on deterministically.
            let good = try echoFrameData(
                directive: EchoDirective(sessionID: "sess-known", state: .working),
                context: [:]
            )
            #expect(writeAll(fd, good))

            let events = await waitForEvents(collector, atLeast: 1)
            // Only the known plugin's event arrives; the ghost frame was dropped.
            #expect(events.count == 1)
            #expect(events.first?.sessionID == "sess-known")

            await server.stop()
        }

        @Test("frames from separate connections dispatch in arrival order, not processing-completion order")
        func serializedDispatchOrder() async throws {
            let collector = EventCollector()
            let dispatcher = makeDispatcher(collector)
            let core = EchoPluginCore()
            let server = IngressSocketServer(
                socketPath: makeSocketPath(),
                coreLookup: { id in id == EchoPluginCore.pluginID ? core : nil },
                dispatcher: dispatcher
            )
            try await server.start()
            defer { Task { await server.stop() } }
            let path = await pathOf(server)

            // Connection A: a frame that is slow to process (400ms artificial delay).
            let fdA = try #require(connectClient(to: path, deadline: Date().addingTimeInterval(5)))
            defer { close(fdA) }
            let frameA = try echoFrameData(
                directive: EchoDirective(sessionID: "A", state: .working, tmuxPane: "%1", delayMs: 400),
                context: [:]
            )
            #expect(writeAll(fdA, frameA))

            // Let A be accepted and enter processing before B arrives.
            try await Task.sleep(for: .milliseconds(150))

            // Connection B: processes instantly. With one racing task per connection,
            // B's event would reach the dispatcher ~250ms *before* A's; a serialized
            // ingress must still dispatch A first because it arrived first.
            let fdB = try #require(connectClient(to: path, deadline: Date().addingTimeInterval(5)))
            defer { close(fdB) }
            let frameB = try echoFrameData(
                directive: EchoDirective(sessionID: "B", state: .working, tmuxPane: "%2", delayMs: 0),
                context: [:]
            )
            #expect(writeAll(fdB, frameB))

            let events = await waitForEvents(collector, atLeast: 2)
            #expect(events.count == 2)
            #expect(events.map(\.sessionID) == ["A", "B"])

            await server.stop()
        }

        /// Read the bound path back off the actor (the server holds it privately for
        /// liveness, but the test supplied it; this just keeps the read on-actor).
        private func pathOf(_ server: IngressSocketServer) async -> String {
            await server.boundSocketPath
        }
    }
#endif
