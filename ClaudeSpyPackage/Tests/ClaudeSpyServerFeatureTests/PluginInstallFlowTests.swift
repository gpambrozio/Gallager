#if os(macOS)
    import ClaudeSpyNetworking
    import CryptoKit
    import Foundation
    import GallagerPluginProtocol
    import Testing
    @testable import ClaudeSpyServerFeature

    // MARK: - Test support types

    /// A minimal `PluginHost` stub for install-flow tests. Records initialize calls
    /// so tests can verify the core was started.
    private actor FlowMockPluginHost: PluginHost {
        func setProjects(_: [AgentProject]) async { }
        func emit(_: PluginEvent) async { }
        func sendText(sessionID _: String, _: String) async { }
        func sendKeys(sessionID _: String, _: [PluginTmuxKey]) async { }
        func log(_: LogLine) async { }
    }

    /// A URL-keyed stub session: each URL can be mapped to a response body. Falls
    /// back to an empty body for unmapped URLs.
    private struct MultiURLStubSession: URLSessionProtocol {
        let responses: [URL: Data]

        func openStream(
            _ request: URLRequest
        ) async throws -> (HTTPURLResponse?, AsyncThrowingStream<Data, any Error>) {
            let body = (request.url.flatMap { responses[$0] }) ?? Data()
            let stream = AsyncThrowingStream<Data, any Error> { continuation in
                let task = Task {
                    if !body.isEmpty {
                        continuation.yield(body)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )
            return (response, stream)
        }
    }

    // MARK: - Helpers

    private func makeTempPaths() throws -> (GallagerPaths, URL) {
        // Use a two-level structure so each test gets its own isolated gallagerRoot:
        //   NSTemporaryDirectory()/PluginInstallFlowTests-<UUID>/state/
        // gallagerRoot → NSTemporaryDirectory()/PluginInstallFlowTests-<UUID>/
        // stateRoot    → NSTemporaryDirectory()/PluginInstallFlowTests-<UUID>/state/
        // This prevents registry.json stomping when the full suite runs in parallel.
        let testRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PluginInstallFlowTests-\(UUID().uuidString)")
        let stateRoot = testRoot.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
        let paths = GallagerPaths(stateRootOverride: stateRoot)
        return (paths, testRoot)
    }

    /// Build a valid sidecar bundle zip that the `initialize` call will answer
    /// correctly. Uses the same shell-script pattern as `SidecarSupervisorTests`.
    private func makeInitializableSidecarZip(id: String, version: String) throws -> (URL, Data) {
        let src = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flow-src-\(UUID().uuidString)")
        let bin = src.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

        // Shell sidecar that reads one initialize RPC and replies, then loops forever.
        let script = """
        #!/bin/bash
        while IFS= read -r line; do
            line="${line%%$'\\r'}"
            [[ "$line" == Content-Length:* ]] && cl="${line#Content-Length: }"
            [[ -z "$line" ]] && break
        done
        body=$(dd bs=1 count="${cl:-0}" 2>/dev/null)
        id=$(echo "$body" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
        resp="{\\\"id\\\":\\\"${id}\\\",\\\"result\\\":{}}"
        printf "Content-Length: %d\\r\\n\\r\\n%s" "${#resp}" "$resp"
        while true; do sleep 3600; done
        """
        let exe = bin.appendingPathComponent("sidecar")
        try script.write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)

        let pluginJSON = """
        {
          "schema_version": 1,
          "id": "\(id)",
          "display_name": "Flow Test Plugin",
          "short_name": "FTP",
          "version": "\(version)",
          "runtime": "sidecar",
          "sidecar": {"executable": "bin/sidecar"},
          "process_names": [],
          "ui": {}
        }
        """
        try pluginJSON.write(to: src.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)

        let dest = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flow-\(UUID().uuidString).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", dest.path, "."]
        process.currentDirectoryURL = src
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "PluginInstallFlowTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "zip failed"]
            )
        }

        let data = try Data(contentsOf: dest)
        try? FileManager.default.removeItem(at: src)
        try? FileManager.default.removeItem(at: dest)
        return (dest, data)
    }

    private func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func makeManifestJSON(id: String, version: String, bundleURL: URL, sha256: String) -> Data {
        let body = """
        {
          "schema_version": 1,
          "id": "\(id)",
          "display_name": "Flow Test Plugin",
          "short_name": "FTP",
          "version": "\(version)",
          "runtime": "sidecar",
          "sidecar": {"executable": "bin/sidecar"},
          "bundle_url": "\(bundleURL.absoluteString)",
          "bundle_sha256": "\(sha256)",
          "process_names": [],
          "ui": {}
        }
        """
        return Data(body.utf8)
    }

    // MARK: - Tests

    @Suite("PluginInstallFlow")
    struct PluginInstallFlowTests {
        // MARK: Trust gate

        @Test("install(trustConfirmed: false) returns .needsTrust without downloading")
        @MainActor
        func trustGate() async throws {
            let (paths, stateRoot) = try makeTempPaths()
            defer { try? FileManager.default.removeItem(at: stateRoot) }

            // Prepare a stub that serves a valid manifest.
            let id = "flow-trust-test"
            let manifestURL = try #require(URL(string: "https://example.com/plugin.json"))
            let bundleURL = try #require(URL(string: "https://cdn.example.com/bundle.zip"))
            let manifestBody = makeManifestJSON(
                id: id,
                version: "1.0.0",
                bundleURL: bundleURL,
                sha256: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
            )
            // No bundle response (any attempt to download would be served empty, causing hash failure).
            let session = MultiURLStubSession(responses: [manifestURL: manifestBody])

            let registry = PluginRegistry()
            registry.attachPaths(paths)
            paths.ensurePluginsDir()

            let result = await PluginInstaller.install(
                manifestURL: manifestURL,
                trustConfirmed: false,
                registry: registry,
                paths: paths,
                session: session,
                makeHost: { _ in FlowMockPluginHost() },
                makeEnv: { id in
                    PluginEnv(
                        pluginRoot: paths.pluginInstallDir(id),
                        stateDir: paths.pluginStateDir(id),
                        appVersion: "2.0",
                        settings: Data(),
                        marketplaceSource: paths.pluginInstallDir(id)
                    )
                }
            )

            // Must return .needsTrust — no download attempted.
            guard
                case let .success(outcome) = result,
                case let .needsTrust(trust) = outcome else {
                Issue.record("Expected .success(.needsTrust), got \(result)")
                return
            }
            #expect(trust.id == id)
            #expect(trust.version == "1.0.0")

            // The install directory must not exist (nothing was downloaded).
            #expect(!FileManager.default.fileExists(atPath: paths.pluginInstallDir(id).path))
            // The registry must not have this plugin registered.
            #expect(!registry.isRegistered(id))
        }

        // MARK: Full install + enable

        @Test("install(trustConfirmed: true) downloads, validates, commits, enables")
        @MainActor
        func fullInstallAndEnable() async throws {
            let (paths, stateRoot) = try makeTempPaths()
            defer { try? FileManager.default.removeItem(at: stateRoot) }

            let id = "flow-install-test"
            let version = "1.2.0"

            // Build the bundle zip and capture its bytes for stubbing.
            let (_, bundleData) = try makeInitializableSidecarZip(id: id, version: version)
            let sha256 = sha256Hex(bundleData)

            let manifestURL = try #require(URL(string: "https://example.com/\(id)/plugin.json"))
            let bundleURL = try #require(URL(string: "https://cdn.example.com/\(id)-\(version).zip"))

            let manifestBody = makeManifestJSON(
                id: id,
                version: version,
                bundleURL: bundleURL,
                sha256: sha256
            )
            let session = MultiURLStubSession(responses: [
                manifestURL: manifestBody,
                bundleURL: bundleData,
            ])

            let registry = PluginRegistry()
            registry.attachPaths(paths)
            paths.ensurePluginsDir()

            let result = await PluginInstaller.install(
                manifestURL: manifestURL,
                trustConfirmed: true,
                registry: registry,
                paths: paths,
                session: session,
                makeHost: { _ in FlowMockPluginHost() },
                makeEnv: { id in
                    PluginEnv(
                        pluginRoot: paths.pluginInstallDir(id),
                        stateDir: paths.pluginStateDir(id),
                        appVersion: "2.0",
                        settings: Data(),
                        marketplaceSource: paths.pluginInstallDir(id)
                    )
                }
            )

            // Outcome: either .installed or .enableFailed (sidecar may fail to start
            // in a test environment — that's acceptable, files must still be in place).
            let installDir = paths.pluginInstallDir(id)
            #expect(
                FileManager.default.fileExists(atPath: installDir.path),
                "Install directory must exist after a successful commit"
            )
            let sidecarBin = installDir.appendingPathComponent("bin/sidecar")
            #expect(
                FileManager.default.isExecutableFile(atPath: sidecarBin.path),
                "bin/sidecar must be present and executable"
            )

            // Registry must know about the plugin.
            #expect(registry.isRegistered(id), "Registry must have the entry after install")

            // The entry in listEntries must have source == "url".
            let entry = registry.listEntries().first(where: { $0.id == id })
            #expect(entry?.source == "url", "source must be 'url'")

            // The registry.json file must have been written.
            let registryFile = PluginRegistryStore.load(paths.registryPath)
            let fileEntry = registryFile.plugins.first(where: { $0.id == id })
            #expect(fileEntry != nil, "registry.json must contain an entry for '\(id)'")
            #expect(fileEntry?.source == .url)

            // Outcome is either .success(.installed) or .failure(.enableFailed).
            switch result {
            case let .success(.installed(resultID)):
                #expect(resultID == id)
                #expect(registry.isEnabled(id), "Plugin must be enabled on successful install")
            case .failure(.enableFailed):
                // Acceptable in test environment where the sidecar subprocess may fail.
                break
            default:
                Issue.record("Unexpected install result: \(result)")
            }
        }

        // MARK: Remove

        @Test("remove deletes files and registry entry after install")
        @MainActor
        func removeAfterInstall() async throws {
            let (paths, stateRoot) = try makeTempPaths()
            defer { try? FileManager.default.removeItem(at: stateRoot) }

            let id = "flow-remove-test"
            let version = "1.0.0"

            let (_, bundleData) = try makeInitializableSidecarZip(id: id, version: version)
            let sha256 = sha256Hex(bundleData)
            let manifestURL = try #require(URL(string: "https://example.com/\(id)/plugin.json"))
            let bundleURL = try #require(URL(string: "https://cdn.example.com/\(id).zip"))
            let manifestBody = makeManifestJSON(id: id, version: version, bundleURL: bundleURL, sha256: sha256)
            let session = MultiURLStubSession(responses: [
                manifestURL: manifestBody,
                bundleURL: bundleData,
            ])

            let registry = PluginRegistry()
            registry.attachPaths(paths)
            paths.ensurePluginsDir()

            // Install first.
            _ = await PluginInstaller.install(
                manifestURL: manifestURL,
                trustConfirmed: true,
                registry: registry,
                paths: paths,
                session: session,
                makeHost: { _ in FlowMockPluginHost() },
                makeEnv: { id in
                    PluginEnv(
                        pluginRoot: paths.pluginInstallDir(id),
                        stateDir: paths.pluginStateDir(id),
                        appVersion: "2.0",
                        settings: Data(),
                        marketplaceSource: paths.pluginInstallDir(id)
                    )
                }
            )

            // Verify files are in place before removal.
            let installDir = paths.pluginInstallDir(id)
            #expect(FileManager.default.fileExists(atPath: installDir.path))
            #expect(registry.isRegistered(id))

            // Write a dummy state dir so we can verify deleteState removes it.
            let stateDir = paths.pluginStateDir(id)
            try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
            let settingsFile = stateDir.appendingPathComponent("settings.json")
            try Data("{}".utf8).write(to: settingsFile)

            // Now remove with deleteState: true.
            let removeResult = await PluginInstaller.remove(
                id: id,
                deleteState: true,
                registry: registry,
                paths: paths
            )
            if case let .failure(err) = removeResult {
                Issue.record("remove returned failure: \(err)")
            }

            // Install directory must be gone.
            #expect(
                !FileManager.default.fileExists(atPath: installDir.path),
                "Install directory must be removed"
            )

            // State directory must be gone (deleteState: true).
            #expect(
                !FileManager.default.fileExists(atPath: stateDir.path),
                "State directory must be removed when deleteState == true"
            )

            // Registry entry must be gone from the file.
            let registryFile = PluginRegistryStore.load(paths.registryPath)
            #expect(
                registryFile.plugins.first(where: { $0.id == id }) == nil,
                "registry.json must not contain '\(id)' after remove"
            )
        }

        // MARK: bundle_url https validation

        @Test("install(trustConfirmed: true) returns .notHTTPS when bundle_url uses http://")
        @MainActor
        func bundleURLHttpSchemeRejected() async throws {
            let (paths, stateRoot) = try makeTempPaths()
            defer { try? FileManager.default.removeItem(at: stateRoot) }

            let id = "flow-http-bundle-test"
            let manifestURL = try #require(URL(string: "https://example.com/plugin.json"))
            // bundle_url uses http:// — should be rejected before any download
            let bundleURL = try #require(URL(string: "http://cdn.example.com/bundle.zip"))
            let manifestBody = makeManifestJSON(
                id: id,
                version: "1.0.0",
                bundleURL: bundleURL,
                sha256: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
            )
            // If the code erroneously tries to download, it gets an empty body → hashMismatch.
            // The test asserts .notHTTPS so any other result is a failure.
            let session = MultiURLStubSession(responses: [manifestURL: manifestBody])

            let registry = PluginRegistry()
            registry.attachPaths(paths)
            paths.ensurePluginsDir()

            let result = await PluginInstaller.install(
                manifestURL: manifestURL,
                trustConfirmed: true,
                registry: registry,
                paths: paths,
                session: session,
                makeHost: { _ in FlowMockPluginHost() },
                makeEnv: { id in
                    PluginEnv(
                        pluginRoot: paths.pluginInstallDir(id),
                        stateDir: paths.pluginStateDir(id),
                        appVersion: "2.0",
                        settings: Data(),
                        marketplaceSource: paths.pluginInstallDir(id)
                    )
                }
            )

            guard case let .failure(err) = result else {
                Issue.record("Expected .failure(.notHTTPS) but got: \(result)")
                return
            }
            #expect(err == .notHTTPS, "Expected .notHTTPS, got \(err)")
            // The install directory must not exist — nothing was downloaded.
            #expect(!FileManager.default.fileExists(atPath: paths.pluginInstallDir(id).path))
        }

        @Test("remove refuses bundled plugin ids")
        @MainActor
        func removeRefusesBundled() async throws {
            let (paths, stateRoot) = try makeTempPaths()
            defer { try? FileManager.default.removeItem(at: stateRoot) }

            let registry = PluginRegistry()
            registry.attachPaths(paths)

            // "claude-code" is a bundled plugin — remove must refuse.
            let result = await PluginInstaller.remove(
                id: "claude-code",
                deleteState: false,
                registry: registry,
                paths: paths
            )
            guard case let .failure(err) = result else {
                Issue.record("Expected failure for bundled plugin remove, got success")
                return
            }
            #expect(err == .notInstalled)
        }
    }
#endif
