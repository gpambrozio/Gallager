#if os(macOS)
    import ClaudeSpyNetworking
    import Foundation
    import GallagerPluginProtocol
    import Testing
    @testable import ClaudeSpyServerFeature

    // MARK: - Helpers

    private actor NoopSidecarDelegate: SidecarTransportDelegate {
        func handleNotification(_: String, _: JSONValue?) async { }
        func handleInboundRequest(_ m: String, _: JSONValue?) async -> Result<JSONValue, RPCError> {
            .failure(.methodNotFound(m))
        }
    }

    /// Locate the `EchoPluginSidecar` binary within the SPM build-products tree.
    ///
    /// SPM creates a stable symlink `.build/debug` → `.build/<arch>/debug/` so we
    /// don't have to hard-code the architecture string. The package root is found
    /// by walking upward from `#file` until we find a directory that contains
    /// `Package.swift` — this is resilient to SPM's `-file-prefix-map` rewriting
    /// that can omit the package subdirectory from `#file` paths.
    private func locateEchoSidecarBinary(sourceFile: String = #file) throws -> URL {
        // Walk upward from the source file's directory until Package.swift is found.
        var dir = URL(fileURLWithPath: sourceFile).deletingLastPathComponent()
        var packageRoot: URL?
        let fm = FileManager.default
        for _ in 0..<10 {
            if fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                packageRoot = dir
                break
            }
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break } // hit filesystem root
            dir = parent
        }

        var searched: [String] = []

        if let root = packageRoot {
            // Primary: .build/debug (SPM's arch-neutral symlink, always present locally).
            let primary = root.appendingPathComponent(".build/debug/EchoPluginSidecar")
            searched.append(primary.path)
            if fm.isExecutableFile(atPath: primary.path) {
                return primary
            }
            // Fallback: .build/release.
            let release = root.appendingPathComponent(".build/release/EchoPluginSidecar")
            searched.append(release.path)
            if fm.isExecutableFile(atPath: release.path) {
                return release
            }
        }

        throw BinaryNotFoundError(searched: searched, sourceFile: sourceFile)
    }

    private struct BinaryNotFoundError: Error, CustomStringConvertible {
        let searched: [String]
        let sourceFile: String
        var description: String {
            "EchoPluginSidecar binary not found. Searched: \(searched). " +
                "sourceFile=\(sourceFile). " +
                "Run `swift build` in ClaudeSpyPackage before running this test."
        }
    }

    // MARK: - Integration test suite

    @Suite("EchoPluginSidecarIntegration")
    struct EchoPluginSidecarIntegrationTests {
        /// Builds the plugin layout pointing to the real built binary.
        private func makeLayout(binaryURL: URL) throws -> (manifest: PluginManifest, layout: PluginRootLayout) {
            let buildProductsDir = binaryURL.deletingLastPathComponent()
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("echo-sidecar-it-\(UUID().uuidString)")
            let stateDir = tmp.appendingPathComponent("state")
            let logDir = stateDir.appendingPathComponent("logs")
            try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

            // The sidecar config uses a relative path from `pluginRoot`.
            // We point `pluginRoot` at the build-products dir so the supervisor
            // resolves `<pluginRoot>/EchoPluginSidecar` → the real binary.
            let manifest = PluginManifest(
                schemaVersion: 1,
                id: "echo-sidecar",
                displayName: "Echo Sidecar",
                shortName: "Echo",
                version: "1.0.0",
                processNames: [],
                ui: .init(icon: nil, color: nil),
                runtime: .sidecar,
                sidecar: .init(executable: "EchoPluginSidecar")
            )
            let layout = PluginRootLayout(
                pluginRoot: buildProductsDir,
                stateDir: stateDir,
                logDir: logDir,
                ingressSocketPath: stateDir.appendingPathComponent("ingress.sock").path,
                appVersion: "2.0"
            )
            return (manifest, layout)
        }

        // MARK: - Tests

        @Test("spawns real EchoPluginSidecar, initialize RPC returns empty object")
        func spawnAndInitialize() async throws {
            let binaryURL = try locateEchoSidecarBinary()
            let (manifest, layout) = try makeLayout(binaryURL: binaryURL)
            let supervisor = SidecarSupervisor(manifest: manifest, layout: layout)
            let transport = try await supervisor.startTransport(delegate: NoopSidecarDelegate())
            defer { Task { await supervisor.stop() } }

            let result = try await transport.request(SidecarRPC.initialize, .object([:]), timeout: .seconds(10))
            #expect(result == .object([:]))
        }

        @Test("translate_event round-trip: EchoDirective → PluginEvent with correct fields")
        func translateEventRoundTrip() async throws {
            let binaryURL = try locateEchoSidecarBinary()
            let (manifest, layout) = try makeLayout(binaryURL: binaryURL)
            let supervisor = SidecarSupervisor(manifest: manifest, layout: layout)
            let transport = try await supervisor.startTransport(delegate: NoopSidecarDelegate())
            defer { Task { await supervisor.stop() } }

            // Initialize first.
            _ = try await transport.request(SidecarRPC.initialize, .object([:]), timeout: .seconds(10))

            // Build an IngressFrameWire with an EchoDirective payload.
            let directive = EchoDirective(
                sessionID: "s1",
                state: .doneWorking(summary: nil)
            )
            let wire = IngressFrameWire(
                IngressFrame(
                    pluginID: "echo-sidecar",
                    context: ["TMUX_PANE": "%5"],
                    payload: (try? JSONEncoder().encode(directive)) ?? Data()
                )
            )
            let params = try JSONValue(encoding: wire)
            let result = try await transport.request(SidecarRPC.translateEvent, params, timeout: .seconds(10))

            let event = try result.decode(PluginEvent.self)
            #expect(event.pluginID == "echo-sidecar")
            #expect(event.sessionID == "s1")
            #expect(event.state?.needsAttention == true)
            #expect(event.tmuxPane == "%5")

            await supervisor.stop()
        }
    }
#endif
