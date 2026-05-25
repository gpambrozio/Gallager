#if os(macOS)
    import Foundation
    import GallagerPluginProtocol
    import Testing

    // `ClaudeSpyNetworking` and `GallagerPluginProtocol` both declare
    // `JSONRPCRequest`/`JSONRPCResponse`/`JSONRPCError`. Narrow the
    // import so the sidecar-protocol shapes win in this file.
    import enum ClaudeSpyNetworking.JSONValue

    // MARK: - ClaudeCodeSidecarTests

    /// Integration tests for the `ClaudeCodePluginSidecar` executable.
    /// Each test spawns the SPM-built binary as a child process and drives
    /// it via JSON-RPC over Pipes + the per-state-dir ingress Unix socket.
    ///
    /// `.serialized` because every test spawns a real subprocess and the
    /// runner sees scheduler pressure when several executables boot in
    /// parallel.
    @Suite("ClaudeCodePluginSidecar", .serialized)
    struct ClaudeCodeSidecarTests {
        // MARK: - Binary resolution

        /// Resolve the SPM-built sidecar binary. Walks `.build/<config>/`
        /// looking for the first one that has `ClaudeCodePluginSidecar` —
        /// matches the approach `SidecarSupervisorTests` uses for the
        /// EchoSidecar fixture.
        private func sidecarURL() -> URL? {
            let buildDir = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // ClaudeCodePluginSidecarTests
                .deletingLastPathComponent() // Tests
                .deletingLastPathComponent() // ClaudeSpyPackage
                .appendingPathComponent(".build")

            let fm = FileManager.default
            guard let configs = try? fm.contentsOfDirectory(atPath: buildDir.path) else {
                return nil
            }
            for config in configs {
                let candidate = buildDir
                    .appendingPathComponent(config)
                    .appendingPathComponent("ClaudeCodePluginSidecar")
                if fm.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
            return nil
        }

        private func makeTempDir(label: String) throws -> URL {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }

        // MARK: - Test 1: initialize + translate_event round trip
        //
        // Exercises the bulk of the sidecar protocol: initialize handshake,
        // capability advertisement, then a `translate_event` RPC against
        // the bundled `ClaudeCodeEventTranslator` to confirm a
        // `UserPromptSubmit` payload comes back as a `working:true`
        // PluginEvent. The ingress socket itself is covered by
        // `IngressSocketServerTests`; we deliberately avoid driving it
        // from a sibling process here because `NWListener`'s Unix socket
        // files aren't always visible across the test bundle's sandbox
        // (the child process binds successfully but the test runner can't
        // see the path).

        @Test("sidecar translates a hook payload into a PluginEvent via translate_event")
        func sidecarTranslateEventReturnsPluginEvent() async throws {
            guard let binary = sidecarURL() else {
                Issue.record("ClaudeCodePluginSidecar binary missing — run `swift build` first")
                return
            }

            // Set up a plugin root with the bundled settings schema so
            // `get_settings_schema` (and the sidecar's own assertions on
            // disk layout) don't trip during init.
            let pluginRoot = try makeTempDir(label: "claude-plugin-root")
            try FileManager.default.createDirectory(
                at: pluginRoot.appendingPathComponent("ui"),
                withIntermediateDirectories: true
            )
            let settingsJSON = #"""
            {
              "schema_version": 1,
              "sections": []
            }
            """#
            try Data(settingsJSON.utf8).write(
                to: pluginRoot.appendingPathComponent("ui/settings.json")
            )

            let stateDir = try makeTempDir(label: "claude-plugin-state")
            defer {
                try? FileManager.default.removeItem(at: pluginRoot)
                try? FileManager.default.removeItem(at: stateDir)
            }

            // Spawn the sidecar with stdin/stdout/stderr piped.
            let proc = Process()
            proc.executableURL = binary
            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            proc.standardInput = stdinPipe
            proc.standardOutput = stdoutPipe
            proc.standardError = stderrPipe
            try proc.run()
            defer {
                proc.terminate()
            }

            // Long-lived byte stream from the sidecar's stdout. Critical:
            // a fresh `makeAsyncByteStream()` per read would re-arm the
            // readabilityHandler and miss bytes — keep one stream and one
            // iterator open for the whole test.
            let outBytes = stdoutPipe.fileHandleForReading.makeAsyncByteStream()
            var iterator = outBytes.makeAsyncIterator()

            // 1. Send `initialize`.
            let initRequest = JSONRPCRequest(
                jsonrpc: "2.0",
                id: .number(1),
                method: PluginRPCMethod.AppToSidecar.initialize.rawValue,
                params: .object([
                    "plugin_root": .string(pluginRoot.path),
                    "state_dir": .string(stateDir.path),
                    "app_version": .string("1.33"),
                ])
            )
            try writeMessage(.request(initRequest), to: stdinPipe.fileHandleForWriting)

            // 2. Read messages until we see the response with id == 1.
            // Any `set_projects` notifications that arrive first are
            // skipped by `readUntilResponse`.
            let initResponse = try await readUntilResponse(
                id: .number(1),
                iterator: &iterator
            )
            #expect(initResponse.error == nil)

            // 3. Send a `translate_event` RPC. The Claude translator
            // maps a `UserPromptSubmit` payload onto `working: true`.
            let translateRequest = JSONRPCRequest(
                jsonrpc: "2.0",
                id: .number(2),
                method: PluginRPCMethod.AppToSidecar.translateEvent.rawValue,
                params: .object([
                    "context": .object([
                        "TMUX_PANE": .string("%0"),
                        "CLAUDE_PROJECT_DIR": .string("/tmp/proj"),
                        "CLAUDE_SESSION_ID": .string("session-1"),
                    ]),
                    "payload": .object([
                        "session_id": .string("session-1"),
                        "hook_event_name": .string("UserPromptSubmit"),
                        "prompt": .string("hello"),
                    ]),
                ])
            )
            try writeMessage(
                .request(translateRequest),
                to: stdinPipe.fileHandleForWriting
            )

            let translateResponse = try await readUntilResponse(
                id: .number(2),
                iterator: &iterator
            )
            #expect(translateResponse.error == nil)

            // Decode the result blob as a typed `PluginEvent`.
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let resultData = try encoder.encode(translateResponse.result ?? .null)
            let event = try decoder.decode(PluginEvent.self, from: resultData)
            #expect(event.sessionID == "session-1")
            #expect(event.working == true)
            #expect(event.pluginID == "claude-code")
        }

        // MARK: - Test 2: shutdown RPC

        @Test("sidecar exits cleanly on shutdown RPC")
        func sidecarShutdownExitsCleanly() async throws {
            guard let binary = sidecarURL() else {
                Issue.record("ClaudeCodePluginSidecar binary missing — run `swift build` first")
                return
            }

            let pluginRoot = try makeTempDir(label: "claude-plugin-root")
            try FileManager.default.createDirectory(
                at: pluginRoot.appendingPathComponent("ui"),
                withIntermediateDirectories: true
            )
            try Data(#"{"schema_version":1,"sections":[]}"#.utf8).write(
                to: pluginRoot.appendingPathComponent("ui/settings.json")
            )
            let stateDir = try makeTempDir(label: "claude-plugin-state")
            defer {
                try? FileManager.default.removeItem(at: pluginRoot)
                try? FileManager.default.removeItem(at: stateDir)
            }

            let proc = Process()
            proc.executableURL = binary
            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            proc.standardInput = stdinPipe
            proc.standardOutput = stdoutPipe
            proc.standardError = stderrPipe
            try proc.run()

            let outBytes = stdoutPipe.fileHandleForReading.makeAsyncByteStream()
            var iterator = outBytes.makeAsyncIterator()

            // Initialize
            try writeMessage(
                .request(JSONRPCRequest(
                    jsonrpc: "2.0",
                    id: .number(1),
                    method: PluginRPCMethod.AppToSidecar.initialize.rawValue,
                    params: .object([
                        "plugin_root": .string(pluginRoot.path),
                        "state_dir": .string(stateDir.path),
                        "app_version": .string("1.33"),
                    ])
                )),
                to: stdinPipe.fileHandleForWriting
            )
            _ = try await readUntilResponse(id: .number(1), iterator: &iterator)

            // Shutdown
            try writeMessage(
                .request(JSONRPCRequest(
                    jsonrpc: "2.0",
                    id: .number(2),
                    method: PluginRPCMethod.AppToSidecar.shutdown.rawValue,
                    params: .object([:])
                )),
                to: stdinPipe.fileHandleForWriting
            )
            _ = try await readUntilResponse(id: .number(2), iterator: &iterator)

            // Close stdin so the read loop sees EOF and exits the run loop.
            try? stdinPipe.fileHandleForWriting.close()

            // Wait for the child to exit. Foundation doesn't expose an
            // async `waitUntilExit`, so we poll briefly.
            for _ in 0..<200 {
                if !proc.isRunning { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(!proc.isRunning)
            if proc.isRunning {
                proc.terminate()
            }
        }

        // MARK: - Test 3: health RPC

        @Test("sidecar replies to health with ok:true")
        func sidecarHealthReply() async throws {
            guard let binary = sidecarURL() else {
                Issue.record("ClaudeCodePluginSidecar binary missing — run `swift build` first")
                return
            }

            let pluginRoot = try makeTempDir(label: "claude-plugin-root")
            try FileManager.default.createDirectory(
                at: pluginRoot.appendingPathComponent("ui"),
                withIntermediateDirectories: true
            )
            try Data(#"{"schema_version":1,"sections":[]}"#.utf8).write(
                to: pluginRoot.appendingPathComponent("ui/settings.json")
            )
            let stateDir = try makeTempDir(label: "claude-plugin-state")
            defer {
                try? FileManager.default.removeItem(at: pluginRoot)
                try? FileManager.default.removeItem(at: stateDir)
            }

            let proc = Process()
            proc.executableURL = binary
            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            proc.standardInput = stdinPipe
            proc.standardOutput = stdoutPipe
            proc.standardError = stderrPipe
            try proc.run()
            defer { proc.terminate() }

            let outBytes = stdoutPipe.fileHandleForReading.makeAsyncByteStream()
            var iterator = outBytes.makeAsyncIterator()

            try writeMessage(
                .request(JSONRPCRequest(
                    jsonrpc: "2.0",
                    id: .number(1),
                    method: PluginRPCMethod.AppToSidecar.initialize.rawValue,
                    params: .object([
                        "plugin_root": .string(pluginRoot.path),
                        "state_dir": .string(stateDir.path),
                        "app_version": .string("1.33"),
                    ])
                )),
                to: stdinPipe.fileHandleForWriting
            )
            _ = try await readUntilResponse(id: .number(1), iterator: &iterator)

            try writeMessage(
                .request(JSONRPCRequest(
                    jsonrpc: "2.0",
                    id: .number(2),
                    method: PluginRPCMethod.AppToSidecar.health.rawValue,
                    params: .object([:])
                )),
                to: stdinPipe.fileHandleForWriting
            )
            let response = try await readUntilResponse(
                id: .number(2),
                iterator: &iterator
            )
            #expect(response.error == nil)
            if case let .object(obj) = response.result, case let .bool(ok) = obj["ok"] {
                #expect(ok)
            } else {
                Issue.record("health result was not { ok: true } — got: \(String(describing: response.result))")
            }
        }

        // MARK: - Helpers

        private func writeMessage(_ message: JSONRPCMessage, to handle: FileHandle) throws {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let body = try encoder.encode(message)
            let frame = JSONRPCFramer.encode(body)
            try handle.write(contentsOf: frame)
        }

        /// Drain framed JSON-RPC messages off `iterator` until a response
        /// with `id` arrives. Ignores intervening notifications (typical:
        /// the `set_projects` push that follows `initialize`).
        private func readUntilResponse(
            id: JSONRPCID,
            iterator: inout AsyncStream<UInt8>.AsyncIterator
        ) async throws -> JSONRPCResponse {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            // 10s deadline so a hung sidecar surfaces as a test failure
            // instead of a permanently-spinning runner.
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                let bytes = IteratorAsyncSequence(iterator: iterator)
                let body = try await JSONRPCFramer.read(from: bytes)
                iterator = bytes.iterator
                let message = try decoder.decode(JSONRPCMessage.self, from: body)
                if case let .response(response) = message, response.id == id {
                    return response
                }
            }
            throw TestTimeout.responseTimeout
        }
    }

    // MARK: - IteratorAsyncSequence

    /// Wraps an existing `AsyncStream.AsyncIterator` so a fresh call to
    /// `JSONRPCFramer.read` can iterate the *remainder* of the stream
    /// without losing bytes between reads. The underlying iterator is a
    /// value type — we keep it by reference and let callers swap their
    /// local copy back out via `iterator`.
    final private class IteratorAsyncSequence: AsyncSequence {
        typealias Element = UInt8

        private(set) var iterator: AsyncStream<UInt8>.AsyncIterator

        init(iterator: AsyncStream<UInt8>.AsyncIterator) {
            self.iterator = iterator
        }

        struct AsyncIteratorImpl: AsyncIteratorProtocol {
            let owner: IteratorAsyncSequence

            mutating func next() async throws -> UInt8? {
                await owner.iterator.next()
            }
        }

        func makeAsyncIterator() -> AsyncIteratorImpl {
            AsyncIteratorImpl(owner: self)
        }
    }

    // MARK: - TestTimeout

    private enum TestTimeout: Error {
        case responseTimeout
    }
#endif
