#if os(macOS)
    import ClaudeSpyNetworking
    import Foundation
    import GallagerPluginProtocol
    import Testing
    @testable import ClaudeSpyServerFeature

    @Suite("SidecarSpawnEnvTests")
    struct SidecarSpawnEnvTests {
        // MARK: - Helpers

        private func makeLayout(
            pluginRoot: URL,
            suffix: String = UUID().uuidString
        ) throws -> (manifest: PluginManifest, layout: PluginRootLayout) {
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("spawn-env-\(suffix)")
            let stateDir = tmp.appendingPathComponent("state")
            let logDir = stateDir.appendingPathComponent("logs")
            try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

            let ingressSockPath = tmp.appendingPathComponent("ingress.sock").path

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
                pluginRoot: pluginRoot,
                stateDir: stateDir,
                logDir: logDir,
                ingressSocketPath: ingressSockPath,
                appVersion: "2.0"
            )
            return (manifest, layout)
        }

        // MARK: - Tests

        /// Proves the supervisor injects GALLAGER_INGRESS_SOCK + GALLAGER_PLUGIN_ID into the
        /// child env, and that EchoPluginSidecar.install() templates both into
        /// <pluginRoot>/generated/hook.sh.
        @Test("install writes hook.sh containing ingress socket path and plugin id")
        func installTemplatesHookScript() async throws {
            // Copy the binary into a writable temp root so install can write under it.
            let binaryURL = try locateEchoSidecarBinary()
            let (pluginRoot, _) = try makeWritablePluginRoot(binaryURL: binaryURL)

            let (manifest, layout) = try makeLayout(pluginRoot: pluginRoot)
            let supervisor = SidecarSupervisor(manifest: manifest, layout: layout)
            let transport = try await supervisor.startTransport(delegate: SharedNoopSidecarDelegate())

            do {
                // Step 1: initialize.
                _ = try await transport.request(SidecarRPC.initialize, .object([:]), timeout: .seconds(10))

                // Step 2: install.
                _ = try await transport.request(
                    SidecarRPC.install,
                    .object(["configRoot": .null]),
                    timeout: .seconds(10)
                )
            } catch {
                await supervisor.stop()
                throw error
            }
            await supervisor.stop()

            // Assert hook.sh was created.
            let hookURL = pluginRoot.appendingPathComponent("generated/hook.sh")
            let hookExists = FileManager.default.fileExists(atPath: hookURL.path)
            #expect(hookExists, "generated/hook.sh should exist at \(hookURL.path)")

            // Assert it contains the baked-in socket path and plugin id.
            let hookContents = try String(contentsOf: hookURL, encoding: .utf8)
            #expect(
                hookContents.contains(layout.ingressSocketPath),
                "hook.sh should contain ingressSocketPath '\(layout.ingressSocketPath)'"
            )
            #expect(
                hookContents.contains(manifest.id),
                "hook.sh should contain plugin id '\(manifest.id)'"
            )

            // Regression guard: must use 4-byte big-endian length-prefix framing (ingress socket),
            // never LSP-style Content-Length headers (STDIO transport).
            #expect(
                !hookContents.contains("Content-Length"),
                "hook.sh must NOT use Content-Length framing (that is for STDIO, not ingress socket)"
            )
            #expect(
                hookContents.contains("nc -U"),
                "hook.sh should write to the Unix domain socket via nc -U"
            )
            #expect(
                hookContents.contains("%03o"),
                "hook.sh should use printf octal escapes to build the 4-byte big-endian length prefix"
            )
            #expect(
                hookContents.contains("wc -c"),
                "hook.sh should compute byte length with wc -c for the 4-byte prefix"
            )
        }
    }
#endif
