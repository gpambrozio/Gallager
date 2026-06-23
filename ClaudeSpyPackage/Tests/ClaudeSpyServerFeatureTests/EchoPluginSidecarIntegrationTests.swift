#if os(macOS)
    import ClaudeSpyNetworking
    import Foundation
    import GallagerPluginProtocol
    import Testing
    @testable import ClaudeSpyServerFeature

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
            let transport = try await supervisor.startTransport(delegate: SharedNoopSidecarDelegate())

            do {
                let result = try await transport.request(SidecarRPC.initialize, .object([:]), timeout: .seconds(10))
                #expect(result == .object([:]))
            } catch {
                await supervisor.stop()
                throw error
            }
            await supervisor.stop()
        }

        @Test("translate_event round-trip: EchoDirective → PluginEvent with correct fields")
        func translateEventRoundTrip() async throws {
            let binaryURL = try locateEchoSidecarBinary()
            let (manifest, layout) = try makeLayout(binaryURL: binaryURL)
            let supervisor = SidecarSupervisor(manifest: manifest, layout: layout)
            let transport = try await supervisor.startTransport(delegate: SharedNoopSidecarDelegate())

            do {
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
            } catch {
                await supervisor.stop()
                throw error
            }
            await supervisor.stop()
        }
    }
#endif
