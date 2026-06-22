#if os(macOS)
    import ClaudeSpyNetworking
    import Foundation
    import GallagerPluginProtocol
    import Testing
    @testable import ClaudeSpyServerFeature

    /// Sentinel error thrown by the 2 s deadline task in sendFailureFastFails.
    private struct TimeoutSentinel: Error { }

    /// A delegate that answers a fixed inbound request and records notifications.
    private actor RecordingDelegate: SidecarTransportDelegate {
        var notifications: [(String, JSONValue?)] = []
        func handleNotification(_ method: String, _ params: JSONValue?) async {
            notifications.append((method, params))
        }

        func handleInboundRequest(_ method: String, _ params: JSONValue?) async -> Result<JSONValue, RPCError> {
            if method == HostRPC.agentPanes { return .success(.array([.string("%1"), .string("%2")])) }
            return .failure(.methodNotFound(method))
        }
    }

    @Suite("SidecarTransport")
    struct SidecarTransportTests {
        /// Bridge a FileHandle's readability into an AsyncStream<Data> (the supervisor does this for real).
        private func byteStream(_ handle: FileHandle) -> AsyncStream<Data> {
            AsyncStream { continuation in
                handle.readabilityHandler = { h in
                    let d = h.availableData
                    if d.isEmpty { continuation.finish() } else { continuation.yield(d) }
                }
                continuation.onTermination = { _ in handle.readabilityHandler = nil }
            }
        }

        @Test("request gets its matching response across a real pipe")
        func requestResponse() async throws {
            // app <-> peer, two pipes.
            let appToPeer = Pipe(), peerToApp = Pipe()
            let appDelegate = RecordingDelegate(), peerDelegate = RecordingDelegate()
            let app = SidecarTransport(writeHandle: appToPeer.fileHandleForWriting, delegate: appDelegate)
            let peer = SidecarTransport(writeHandle: peerToApp.fileHandleForWriting, delegate: peerDelegate)
            await app.start(reading: byteStream(peerToApp.fileHandleForReading))
            await peer.start(reading: byteStream(appToPeer.fileHandleForReading))

            // The "peer" answers any request with an echo of its params.
            // (For this test the peer auto-responds via a tiny responder task.)
            Task {
                // Peer loop is internal; simulate a server by having peerDelegate route
                // an inbound request — but requests App->Peer must be answered by Peer.
                // We instead exercise the inbound REQUEST direction below.
            }

            // App asks the peer for agent_panes (peer's delegate answers it).
            let result = try await app.request(HostRPC.agentPanes, nil)
            #expect(result == .array([.string("%1"), .string("%2")]))
        }

        @Test("a request with no responder times out")
        func timeout() async throws {
            let appToPeer = Pipe(), peerToApp = Pipe()
            let app = SidecarTransport(writeHandle: appToPeer.fileHandleForWriting, delegate: RecordingDelegate())
            // No peer reading appToPeer / writing peerToApp → no response ever arrives.
            await app.start(reading: byteStream(peerToApp.fileHandleForReading))
            await #expect(throws: TransportError.timeout(SidecarRPC.initialize)) {
                _ = try await app.request(SidecarRPC.initialize, nil, timeout: .milliseconds(200))
            }
        }

        @Test("send failure fast-fails the caller instead of waiting for timeout")
        func sendFailureFastFails() async throws {
            // Use a closed write pipe so any handle.write(...) throws immediately.
            let writePipe = Pipe()
            try writePipe.fileHandleForWriting.close() // Closed before any write attempt.

            // The read side never produces a response, so without the fix the caller would
            // hang until the 30 s default timeout.
            let readPipe = Pipe()
            let transport = SidecarTransport(
                writeHandle: writePipe.fileHandleForWriting,
                delegate: RecordingDelegate()
            )
            await transport.start(reading: byteStream(readPipe.fileHandleForReading))

            // Race: request (generous 30 s timeout) vs a 2 s hard deadline.
            // Fast-fail path: the write error propagates before the sleep wins → throws a
            // non-TimeoutSentinel error, which the test swallows as the expected outcome.
            // Regression path: the sleep wins → TimeoutSentinel propagates → test fails.
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        // Should throw promptly (closed write handle).
                        _ = try await transport.request(SidecarRPC.initialize, nil, timeout: .seconds(30))
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(2))
                        throw TimeoutSentinel()
                    }
                    // next()! throws whichever task errors first; cancel the remaining task.
                    do { try await group.next()! } catch { group.cancelAll()
                        throw error
                    }
                }
            } catch is TimeoutSentinel {
                Issue.record("request did not fast-fail within 2 s — I1 regression")
            } catch {
                // Any non-sentinel error is the expected fast-fail from the closed write handle.
            }
        }

        @Test("notifications arrive in wire order")
        func orderedNotifications() async throws {
            let appToPeer = Pipe(), peerToApp = Pipe()
            let peerDelegate = RecordingDelegate()
            let app = SidecarTransport(writeHandle: appToPeer.fileHandleForWriting, delegate: RecordingDelegate())
            let peer = SidecarTransport(writeHandle: peerToApp.fileHandleForWriting, delegate: peerDelegate)
            await peer.start(reading: byteStream(appToPeer.fileHandleForReading))
            await app.start(reading: byteStream(peerToApp.fileHandleForReading))
            for i in 1...5 {
                try await app.notify(HostRPC.log, .object(["n": .int(i)]))
            }
            try await Task.sleep(for: .milliseconds(300))
            let got = await peerDelegate.notifications
            #expect(got.count == 5)
            #expect(got.map { ($0.1?.objectValue?["n"])?.intValue } == [1, 2, 3, 4, 5])
        }
    }
#endif
