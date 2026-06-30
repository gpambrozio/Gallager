#if os(macOS)
    import ClaudeSpyNetworking
    import Foundation
    import GallagerPluginProtocol
    import Testing
    @testable import ClaudeSpyServerFeature

    private actor NoopDelegate: SidecarTransportDelegate {
        func handleNotification(_: String, _: JSONValue?) async { }
        func handleInboundRequest(_ m: String, _: JSONValue?) async -> Result<JSONValue, RPCError> {
            .failure(.methodNotFound(m))
        }
    }

    /// Thread-safe container for the auto-disabled stderr lines callback result.
    private actor StderrCapture {
        var lines: [String] = []
        func set(_ l: [String]) {
            lines = l
        }
    }

    @Suite("SidecarSupervisor")
    struct SidecarSupervisorTests {
        /// Writes a minimal shell-script "sidecar" into a temp plugin root and
        /// returns its layout. `behavior == .echoInitialize` answers one
        /// `initialize` frame with `Content-Length: 2\r\n\r\n{}` then loops on stdin;
        /// `behavior == .abort` prints a marker to stderr and `exit 1`s immediately.
        private enum Behavior { case echoInitialize, abort }
        private func makeScriptLayout(_ behavior: Behavior) throws -> PluginRootLayout {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("sup-\(UUID().uuidString)")
            let bin = root.appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let script: String
            switch behavior {
            case .echoInitialize:
                // Read the first JSON-RPC request from stdin, extract its id, and reply with
                // {"id":"<id>","result":{}}. The framing is Content-Length:<n>\r\n\r\n<body>.
                // We skip the header lines until the blank line, then read exactly the body
                // bytes indicated by Content-Length, parse the id, and echo a response.
                script = """
                #!/bin/bash
                # Read Content-Length header
                while IFS= read -r line; do
                    line="${line%%$'\\r'}"
                    [[ "$line" == Content-Length:* ]] && cl="${line#Content-Length: }"
                    [[ -z "$line" ]] && break
                done
                # Read body bytes
                body=$(dd bs=1 count="${cl:-0}" 2>/dev/null)
                # Extract id value (simple grep, works for "id":"rpc-N")
                id=$(echo "$body" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
                # Send response
                resp="{\\\"id\\\":\\\"${id}\\\",\\\"result\\\":{}}"
                printf "Content-Length: %d\\r\\n\\r\\n%s" "${#resp}" "$resp"
                # Loop forever to keep the process alive
                while true; do sleep 3600; done
                """
            case .abort:
                script = "#!/bin/bash\necho 'echo-sidecar boom' 1>&2\nexit 1\n"
            }
            let exe = bin.appendingPathComponent("sidecar")
            try script.write(to: exe, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
            let state = root.appendingPathComponent("state")
            let logs = state.appendingPathComponent("logs")
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            return PluginRootLayout(
                pluginRoot: root,
                stateDir: state,
                logDir: logs,
                ingressSocketPath: state.appendingPathComponent("ingress.sock").path,
                appVersion: "2.0"
            )
        }

        @Test("spawns, completes an initialize RPC, and stops cleanly")
        func happyPath() async throws {
            let layout = try makeScriptLayout(.echoInitialize)
            let manifest = PluginManifest.fixtureSidecar(executable: "bin/sidecar")
            let sup = SidecarSupervisor(manifest: manifest, layout: layout)
            let transport = try await sup.startTransport(delegate: NoopDelegate())
            let result = try await transport.request(SidecarRPC.initialize, .object([:]), timeout: .seconds(5))
            #expect(result == .object([:]))
            await sup.stop()
            #expect(await sup.state() == .stopped)
        }

        // I1: after stop(), the transport is closed (private, so verified via observable
        // consequence: a second startTransport succeeds and an initialize RPC round-trips,
        // which would hang/fail if a stale open transport were interfering with the pipes).
        @Test("stop() cleans up transport; second startTransport round-trips initialize")
        func stopCleansUpTransport() async throws {
            let layout = try makeScriptLayout(.echoInitialize)
            let manifest = PluginManifest.fixtureSidecar(executable: "bin/sidecar")
            let sup = SidecarSupervisor(manifest: manifest, layout: layout)

            // First launch + RPC.
            let t1 = try await sup.startTransport(delegate: NoopDelegate())
            let r1 = try await t1.request(SidecarRPC.initialize, .object([:]), timeout: .seconds(5))
            #expect(r1 == .object([:]))

            // Clean stop — must close and nil the transport.
            await sup.stop()
            #expect(await sup.state() == .stopped)

            // Second launch on the SAME supervisor: must not be blocked by a stale transport.
            let t2 = try await sup.startTransport(delegate: NoopDelegate())
            let r2 = try await t2.request(SidecarRPC.initialize, .object([:]), timeout: .seconds(5))
            #expect(r2 == .object([:]))

            await sup.stop()
            #expect(await sup.state() == .stopped)
        }

        @Test("4 crashes in the window auto-disables and surfaces stderr")
        func crashLoopDisables() async throws {
            let layout = try makeScriptLayout(.abort) // prints to stderr then exits 1
            let manifest = PluginManifest.fixtureSidecar(executable: "bin/sidecar")
            // Use a tiny backoff schedule so 4 crashes + auto-disable complete quickly
            let sup = SidecarSupervisor(
                manifest: manifest,
                layout: layout,
                backoffSchedule: [.milliseconds(20), .milliseconds(20), .milliseconds(20)]
            )
            let capture = StderrCapture()
            await sup.setOnAutoDisabled { lines in Task { await capture.set(lines) } }
            _ = try? await sup.startTransport(delegate: NoopDelegate())
            // Poll until the crash loop exhausts its window and auto-disables.
            // The four crashes are real fork/exec subprocesses, which can be
            // starved under heavy parallel test load, so the deadline is generous
            // rather than a fixed sleep; the loop exits the instant the state
            // flips, so it costs nothing on the happy path.
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline, await sup.state() != .disabled {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(await sup.state() == .disabled)
            // The onAutoDisabled callback hops through a Task to fill the capture,
            // so it may land a beat after the state flips — poll for it too.
            while Date() < deadline, await capture.lines.isEmpty {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(await !capture.lines.isEmpty)
        }
    }
#endif
