#if os(macOS)
    import ClaudeSpyNetworking
    import Darwin
    import Foundation
    import Testing
    @testable import ClaudeSpyServerFeature

    /// Records every telemetry snapshot the receiver pushes, so the ordering test
    /// can inspect the final `recentTurns` sequence.
    private actor SnapshotCollector {
        private(set) var snapshots: [SessionTelemetry] = []
        func record(_ telemetry: SessionTelemetry) { snapshots.append(telemetry) }
    }

    @Suite("OTLPReceiver")
    struct OTLPReceiverTests {
        // MARK: - Helpers

        /// Ask the OS for a free loopback port (bind to 0, read it back, release).
        /// The receiver rebinds it immediately and `allowLocalEndpointReuse` makes
        /// that race-free in practice — far more reliable than a guessed port.
        private func freeLoopbackPort() -> UInt16? {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0 // let the OS assign
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    bind(fd, sa, addrLen)
                }
            }
            guard bound == 0 else { return nil }

            var assigned = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &assigned) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    getsockname(fd, sa, &len)
                }
            }
            guard named == 0 else { return nil }
            return UInt16(bigEndian: assigned.sin_port)
        }

        /// Connect a client `AF_INET` socket to `127.0.0.1:port`, retrying briefly
        /// while the listener finishes binding. Returns the connected fd or `nil`.
        private func connectTCP(port: UInt16, deadline: Date) -> Int32? {
            while Date() < deadline {
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                guard fd >= 0 else { return nil }

                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = port.bigEndian
                addr.sin_addr.s_addr = inet_addr("127.0.0.1")
                let addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let result = withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        connect(fd, sa, addrLen)
                    }
                }
                if result == 0 { return fd }
                close(fd)
                usleep(20_000) // 20ms; listener is mid-bind
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

        /// A complete `POST /v1/logs` request carrying one `api_request` log whose
        /// `duration_ms` tags the turn, so processing order is observable in the
        /// accumulated `recentTurns`.
        private func apiRequestRequest(sessionID: String, durationMs: Int) -> Data {
            let body = #"""
            {"resourceLogs":[{"scopeLogs":[{"logRecords":[{"body":{"stringValue":"claude_code.api_request"},"attributes":[{"key":"event.name","value":{"stringValue":"api_request"}},{"key":"session.id","value":{"stringValue":"\#(sessionID)"}},{"key":"duration_ms","value":{"intValue":"\#(durationMs)"}},{"key":"cost_usd","value":{"doubleValue":0.01}}]}]}]}]}
            """#
            let bodyData = Data(body.utf8)
            let header = "POST /v1/logs HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: \(bodyData.count)\r\n\r\n"
            return Data(header.utf8) + bodyData
        }

        /// Poll until a snapshot carrying at least `count` turns lands, or the
        /// deadline passes. Real network queues drive the receiver, so there's no
        /// virtual clock to advance — a sanctioned `Task.sleep` poll. The deadline
        /// is generous because the full suite runs in parallel — under CPU
        /// saturation the network queue can be starved for several seconds; the
        /// loop still returns the instant the snapshot lands, so a long deadline
        /// costs nothing on the happy path and only buys patience under load.
        private func waitForTurns(_ collector: SnapshotCollector, atLeast count: Int) async -> SessionTelemetry? {
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                let snaps = await collector.snapshots
                if let snap = snaps.last(where: { $0.recentTurns.count >= count }) { return snap }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return await collector.snapshots.last
        }

        private func makeReceiver(port: UInt16, collector: SnapshotCollector) -> OTLPReceiver {
            OTLPReceiver(
                port: port,
                onTelemetry: { _, telemetry in await collector.record(telemetry) },
                onMilestone: { _ in },
                onModeChange: { _ in }
            )
        }

        // MARK: - Tests

        @Test("pipelined requests on one connection are processed in arrival order")
        func pipelinedRequestsProcessedInOrder() async throws {
            let collector = SnapshotCollector()
            let port = try #require(freeLoopbackPort())
            let receiver = makeReceiver(port: port, collector: collector)
            try await receiver.start()
            defer { Task { await receiver.stop() } }

            let fd = try #require(connectTCP(port: port, deadline: Date().addingTimeInterval(5)))
            defer { close(fd) }

            // Twelve api_request logs (< maxRecentTurns, so none are trimmed) with
            // strictly increasing duration_ms, all written in a SINGLE socket send
            // so they arrive pipelined in one buffer. The FIFO consumer must keep
            // them in order; an unstructured-Task-per-request design could not.
            let sessionID = "order-test"
            let turnCount = 12
            var pipelined = Data()
            for i in 1...turnCount {
                pipelined.append(apiRequestRequest(sessionID: sessionID, durationMs: i))
            }
            #expect(writeAll(fd, pipelined))

            let snapshot = try #require(await waitForTurns(collector, atLeast: turnCount))
            let latencies = snapshot.recentTurns.map(\.latencyMs)
            // In-order processing yields exactly [1, 2, …, 12]; any reordering
            // would permute this sequence.
            #expect(latencies == (1...turnCount).map { $0 as Int? })

            await receiver.stop()
        }
    }
#endif
