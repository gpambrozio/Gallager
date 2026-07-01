#if os(macOS)
    import ClaudeSpyNetworking
    import Foundation
    import GallagerPluginProtocol
    import Testing
    @testable import ClaudeSpyServerFeature

    // MARK: - Test support

    /// Minimal `PluginHost` stub for zip-install tests.
    private actor ZipMockPluginHost: PluginHost {
        func setProjects(_: [AgentProject]) async { }
        func emit(_: PluginEvent) async { }
        func sendText(sessionID _: String, _: String) async { }
        func sendKeys(sessionID _: String, _: [PluginTmuxKey]) async { }
        func log(_: LogLine) async { }
    }

    private func makeTempPaths() throws -> (GallagerPaths, URL) {
        let testRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PluginZipInstallTests-\(UUID().uuidString)")
        let stateRoot = testRoot.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
        return (GallagerPaths(stateRootOverride: stateRoot), testRoot)
    }

    /// Build a valid sidecar bundle `.zip` (plugin.json at the archive root) and
    /// leave it on disk, returning the file URL. The caller owns cleanup.
    private func makeLocalSidecarZip(
        id: String,
        version: String = "1.0.0",
        includePluginJSON: Bool = true
    ) throws -> URL {
        let src = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("zip-src-\(UUID().uuidString)")
        let bin = src.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

        let exe = bin.appendingPathComponent("sidecar")
        try "#!/bin/sh\necho hello\n".write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)

        if includePluginJSON {
            let pluginJSON = """
            {
              "schema_version": 1,
              "id": "\(id)",
              "display_name": "Zip Test Plugin",
              "short_name": "ZTP",
              "version": "\(version)",
              "publisher": "Test Co",
              "runtime": "sidecar",
              "sidecar": {"executable": "bin/sidecar"},
              "process_names": [],
              "ui": {}
            }
            """
            try pluginJSON.write(
                to: src.appendingPathComponent("plugin.json"),
                atomically: true,
                encoding: .utf8
            )
        }

        let dest = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("zip-\(UUID().uuidString).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", dest.path, "."]
        process.currentDirectoryURL = src
        try process.run()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: src)
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "PluginZipInstallTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "zip failed"]
            )
        }
        return dest
    }

    // MARK: - Tests

    @Suite("PluginInstaller local-zip install")
    struct PluginZipInstallTests {
        // MARK: peekZipManifest

        @Test("peekZipManifest reads the manifest + builds trust details from a local zip")
        func peekValidZip() throws {
            let id = "zip-peek-test"
            let zip = try makeLocalSidecarZip(id: id, version: "2.1.0")
            defer { try? FileManager.default.removeItem(at: zip) }

            let (manifest, trust) = try PluginInstaller.peekZipManifest(zip: zip)
            #expect(manifest.id == id)
            #expect(manifest.version == "2.1.0")
            #expect(trust.id == id)
            #expect(trust.version == "2.1.0")
            #expect(trust.publisher == "Test Co")
            // Source + bundle are the chosen file; no remote integrity pin.
            #expect(trust.sourceURL == zip)
            #expect(trust.bundleURL == zip)
            #expect(trust.bundleSHA256 == nil)
            // On-disk size is reported.
            #expect((trust.bundleSizeBytes ?? 0) > 0)
        }

        @Test("peekZipManifest throws when plugin.json is missing from the archive root")
        func peekZipMissingManifest() throws {
            let zip = try makeLocalSidecarZip(id: "unused", includePluginJSON: false)
            defer { try? FileManager.default.removeItem(at: zip) }

            #expect(throws: InstallError.self) {
                _ = try PluginInstaller.peekZipManifest(zip: zip)
            }
        }

        // MARK: installFromZip trust gate

        @Test("installFromZip(trustConfirmed: false) returns .needsTrust and writes nothing")
        @MainActor
        func zipTrustGate() async throws {
            let (paths, testRoot) = try makeTempPaths()
            defer { try? FileManager.default.removeItem(at: testRoot) }

            let id = "zip-trust-gate"
            let zip = try makeLocalSidecarZip(id: id)
            defer { try? FileManager.default.removeItem(at: zip) }

            let registry = PluginRegistry()
            registry.attachPaths(paths)
            paths.ensurePluginsDir()

            let result = await PluginInstaller.installFromZip(
                zip: zip,
                trustConfirmed: false,
                registry: registry,
                paths: paths,
                makeHost: { _ in ZipMockPluginHost() },
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

            guard
                case let .success(outcome) = result,
                case let .needsTrust(trust) = outcome else {
                Issue.record("Expected .success(.needsTrust), got \(result)")
                return
            }
            #expect(trust.id == id)
            #expect(!FileManager.default.fileExists(atPath: paths.pluginInstallDir(id).path))
            #expect(!registry.isRegistered(id))
        }

        // MARK: installFromZip full install

        @Test("installFromZip(trustConfirmed: true) extracts, commits, registers as folder, enables")
        @MainActor
        func zipFullInstall() async throws {
            let (paths, testRoot) = try makeTempPaths()
            defer { try? FileManager.default.removeItem(at: testRoot) }

            let id = "zip-install-test"
            let version = "1.4.2"
            let zip = try makeLocalSidecarZip(id: id, version: version)
            defer { try? FileManager.default.removeItem(at: zip) }

            let registry = PluginRegistry()
            registry.attachPaths(paths)
            paths.ensurePluginsDir()

            let result = await PluginInstaller.installFromZip(
                zip: zip,
                trustConfirmed: true,
                registry: registry,
                paths: paths,
                makeHost: { _ in ZipMockPluginHost() },
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

            // Files committed regardless of whether the test-env sidecar starts.
            let installDir = paths.pluginInstallDir(id)
            #expect(FileManager.default.fileExists(atPath: installDir.path))
            let sidecarBin = installDir.appendingPathComponent("bin/sidecar")
            #expect(FileManager.default.isExecutableFile(atPath: sidecarBin.path))

            // Registered as a folder-source sidecar (what relaunch discovery assigns).
            #expect(registry.isRegistered(id))
            let entry = registry.listEntries().first(where: { $0.id == id })
            #expect(entry?.source == "folder")

            // Persisted to registry.json with source folder.
            let registryFile = PluginRegistryStore.load(paths.registryPath)
            #expect(registryFile.plugins.first(where: { $0.id == id })?.source == .folder)

            // Outcome is .installed or .enableFailed (sidecar may not start in tests).
            switch result {
            case let .success(.installed(resultID)):
                #expect(resultID == id)
            case .failure(.enableFailed):
                break
            default:
                Issue.record("Unexpected outcome: \(result)")
            }
        }

        @Test("installFromZip rejects a zip whose manifest id is unsafe")
        @MainActor
        func zipInvalidID() async throws {
            let (paths, testRoot) = try makeTempPaths()
            defer { try? FileManager.default.removeItem(at: testRoot) }

            // An id with path-traversal characters is rejected by sanitize(id:).
            let zip = try makeLocalSidecarZip(id: "../evil")
            defer { try? FileManager.default.removeItem(at: zip) }

            let registry = PluginRegistry()
            registry.attachPaths(paths)
            paths.ensurePluginsDir()

            let result = await PluginInstaller.installFromZip(
                zip: zip,
                trustConfirmed: true,
                registry: registry,
                paths: paths,
                makeHost: { _ in ZipMockPluginHost() },
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

            guard case .failure(.invalidID) = result else {
                Issue.record("Expected .failure(.invalidID), got \(result)")
                return
            }
        }
    }
#endif
