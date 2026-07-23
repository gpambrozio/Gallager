#if os(macOS)
    import CryptoKit
    import Foundation
    import GallagerPluginProtocol
    import Testing
    @testable import ClaudeSpyServerFeature

    // MARK: - Test helpers

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PluginInstallerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Build a zip archive containing a SYMLINK entry whose target is outside the
    /// extraction root. macOS `unzip` materializes symlinks (unlike `../` path
    /// entries, which it silently strips), so this drives the enumerator's
    /// `resolvingSymlinksInPath()` containment branch end-to-end.
    ///
    /// The resulting zip contains a single entry named `evil` with
    /// `external_attr = S_IFLNK | 0o777` and contents `/tmp` (the link target).
    private func makeSymlinkEscapeZip() throws -> URL {
        let dest = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("symlink-evil-\(UUID().uuidString).zip")
        let script = """
        import sys, zipfile
        zi = zipfile.ZipInfo('evil')
        zi.external_attr = (0o120777 << 16)
        z = zipfile.ZipFile('\(dest.path)', 'w')
        z.writestr(zi, '/tmp')
        z.close()
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script]
        // Explicit env: posix_spawn must not read the live `environ`, which other
        // parallel tests mutate (a concurrent realloc EFAULTs the spawn).
        process.environment = [:]
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errMsg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(
                domain: "PluginInstallerTests",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "python3 symlink-zip creation failed: \(errMsg)"]
            )
        }
        return dest
    }

    /// Build a zip archive at a temp location containing one entry at the given
    /// in-archive path with the supplied contents. Uses python3 so that `../`
    /// traversal entries are not silently sanitised (which `/usr/bin/zip` does).
    private func makeZipWithEntry(path: String, contents: String) throws -> URL {
        let dest = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("evil-\(UUID().uuidString).zip")
        let script = """
        import zipfile
        z = zipfile.ZipFile('\(dest.path)', 'w')
        z.writestr('\(path)', '\(contents)')
        z.close()
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script]
        process.environment = [:]
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errMsg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(
                domain: "PluginInstallerTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "python3 zip creation failed: \(errMsg)"]
            )
        }
        return dest
    }

    /// Build a valid sidecar zip: `bin/sidecar` (chmod 0o755 shell script) +
    /// `plugin.json` at the archive root, using `/usr/bin/ditto` (preferred) or
    /// falling back to `/usr/bin/zip`.
    private func makeValidSidecarZip(id: String, version: String = "1.0.0") throws -> URL {
        // Build the source tree in a temp dir.
        let src = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sidecar-src-\(UUID().uuidString)")
        let binDir = src.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        let sidecar = binDir.appendingPathComponent("sidecar")
        try "#!/bin/sh\necho hello\n".write(to: sidecar, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sidecar.path)

        let pluginJSON = """
        {
          "schema_version": 1,
          "id": "\(id)",
          "display_name": "Test Plugin",
          "short_name": "TP",
          "version": "\(version)",
          "runtime": "sidecar",
          "sidecar": {"executable": "bin/sidecar"},
          "process_names": [],
          "ui": {}
        }
        """
        try pluginJSON.write(to: src.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)

        let dest = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("valid-\(UUID().uuidString).zip")

        // Use ditto --rsrc --keepParent to produce a zip, then strip the outer dir.
        // Simpler: zip with the contents of src directly.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", dest.path, "."]
        process.currentDirectoryURL = src
        process.environment = [:]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "PluginInstallerTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "zip creation failed"]
            )
        }
        return dest
    }

    /// Compute the hex SHA-256 of `data`.
    private func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - StubSessionForBundle

    /// A stub that yields `body` in chunks, independent of `StubSession` from
    /// PluginManifestFetchTests (same file, separate type to avoid redeclaration).
    private struct BundleStubSession: URLSessionProtocol {
        let body: Data
        let chunkSize: Int

        init(body: Data, chunkSize: Int = 65_536) {
            self.body = body
            self.chunkSize = chunkSize
        }

        func openStream(
            _ request: URLRequest
        ) async throws -> (HTTPURLResponse?, AsyncThrowingStream<Data, any Error>) {
            let capturedBody = body
            let capturedChunkSize = chunkSize
            let stream = AsyncThrowingStream<Data, any Error> { continuation in
                let task = Task {
                    var offset = capturedBody.startIndex
                    while offset < capturedBody.endIndex {
                        let end = capturedBody.index(
                            offset,
                            offsetBy: capturedChunkSize,
                            limitedBy: capturedBody.endIndex
                        ) ?? capturedBody.endIndex
                        continuation.yield(capturedBody[offset..<end])
                        offset = end
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

    // MARK: - Tests

    @Suite("PluginInstaller bundle download + unpack + commit")
    struct PluginInstallerTests {
        // MARK: - downloadBundle: hash mismatch

        @Test("hashMismatch: wrong expectedSHA256 throws .hashMismatch")
        func hashMismatch() async throws {
            let body = Data("hello bundle".utf8)
            // Compute the *correct* digest and then corrupt it.
            let correctHex = sha256Hex(body)
            // Flip the first nibble to produce a guaranteed mismatch.
            let wrongHex = (correctHex.first == "0" ? "1" : "0") + correctHex.dropFirst()

            let tempDir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }
            let tempFile = tempDir.appendingPathComponent("bundle.zip")

            let url = try #require(URL(string: "https://cdn.example.com/bundle.zip"))
            await #expect(throws: InstallError.hashMismatch) {
                try await PluginInstaller.downloadBundle(
                    url,
                    expectedSHA256: wrongHex,
                    session: BundleStubSession(body: body),
                    into: tempFile
                )
            }
            // Temp file must be cleaned up on hash failure.
            #expect(!FileManager.default.fileExists(atPath: tempFile.path))
        }

        // MARK: - downloadBundle: bundle too large

        @Test("bundleTooLarge: stream exceeds sizeCap throws .bundleTooLarge")
        func bundleTooLarge() async throws {
            // 2048 bytes of body, cap of 1024 — exceeds by exactly 1024.
            let body = Data(repeating: 0x41, count: 2_048)
            let smallCap = 1_024

            let tempDir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }
            let tempFile = tempDir.appendingPathComponent("bundle.zip")

            let url = try #require(URL(string: "https://cdn.example.com/bundle.zip"))
            await #expect(throws: InstallError.bundleTooLarge) {
                try await PluginInstaller.downloadBundle(
                    url,
                    expectedSHA256: sha256Hex(body), // correct hash — error must fire first
                    session: BundleStubSession(body: body, chunkSize: 512),
                    into: tempFile,
                    sizeCap: smallCap
                )
            }
            // Temp file must be cleaned up on size-cap failure.
            #expect(!FileManager.default.fileExists(atPath: tempFile.path))
        }

        // MARK: - unpackAndValidate: zip-slip entry rejected

        @Test("zipSlip: traversal entry ../escape.txt is rejected")
        func zipSlip() throws {
            let staging = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: staging) }

            // Build a zip with a traversal path entry via python3.
            // /usr/bin/zip sanitises ../ entries, so we must use python3 here.
            let evilZip = try makeZipWithEntry(path: "../escape.txt", contents: "x")
            defer { try? FileManager.default.removeItem(at: evilZip) }

            let manifest = PluginManifest.fixtureSidecar(executable: "bin/sidecar")

            // Belt-and-suspenders: the call must always throw — either because our
            // enumerator caught an escaping entry (.zipSlip) or because unzip silently
            // stripped the `../` and the now-empty tree fails validation.
            // The CRITICAL guarantee: unpackAndValidate must NEVER return cleanly.
            var threw = false
            do {
                try PluginInstaller.unpackAndValidate(
                    zip: evilZip,
                    stagingDir: staging,
                    manifest: manifest
                )
            } catch let InstallError.zipSlip(path) {
                // Best case: our enumerator caught the escaping path.
                threw = true
                #expect(path.contains("escape.txt") || !path.isEmpty)
            } catch {
                // Also acceptable: unzip refused / tree validation failed because
                // the traversal entry was skipped and the tree is incomplete.
                threw = true
            }
            #expect(threw, "unpackAndValidate must throw for a zip containing ../escape.txt")
        }

        // MARK: - unpackAndValidate: symlink-escape throws .zipSlip specifically

        /// This test drives the enumerator's `resolvingSymlinksInPath()` containment
        /// branch end-to-end. macOS `unzip` materializes symlinks (unlike `../` path
        /// entries, which it silently strips), so `<staging>/evil -> /tmp` is created
        /// on disk, the enumerator resolves it to `/private/tmp`, containment fails,
        /// and `InstallError.zipSlip` must be thrown.
        @Test("zipSlip: symlink entry pointing outside staging throws .zipSlip specifically")
        func zipSlipSymlinkEscape() throws {
            let staging = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: staging) }

            let evilZip = try makeSymlinkEscapeZip()
            defer { try? FileManager.default.removeItem(at: evilZip) }

            let manifest = PluginManifest.fixtureSidecar(executable: "bin/sidecar")

            // Verify unzip actually materialized the symlink before we invoke the
            // containment check. This proves the enumerator branch will be exercised.
            // (We call unzip here explicitly to inspect the staging dir before the
            // full unpackAndValidate run.)
            let verifyStaging = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: verifyStaging) }
            let verifyUnzip = Process()
            verifyUnzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            verifyUnzip.arguments = ["-o", "-q", evilZip.path, "-d", verifyStaging.path]
            verifyUnzip.environment = [:]
            try verifyUnzip.run()
            verifyUnzip.waitUntilExit()
            let symlinkURL = verifyStaging.appendingPathComponent("evil")
            #expect(
                (try? symlinkURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true,
                "pre-condition: unzip must have materialized 'evil' as a symlink in staging"
            )

            // Now assert that unpackAndValidate throws .zipSlip specifically.
            // A catch-all or a different error case would not count.
            var caughtZipSlip = false
            do {
                try PluginInstaller.unpackAndValidate(
                    zip: evilZip,
                    stagingDir: staging,
                    manifest: manifest
                )
                Issue.record("unpackAndValidate must throw for a symlink-escape zip; returned cleanly instead")
            } catch let InstallError.zipSlip(path) {
                caughtZipSlip = true
                // The reported path should name the offending 'evil' entry.
                #expect(path.contains("evil"), "zipSlip payload should name the offending entry; got: \(path)")
            } catch {
                Issue.record("Expected InstallError.zipSlip but got: \(error)")
            }
            #expect(caughtZipSlip, "unpackAndValidate must throw .zipSlip for a symlink-escape zip")
        }

        // MARK: - Happy path: valid bundle installs atomically and is executable

        @Test("happyInstall: valid sidecar zip unpacks, validates, and commits atomically")
        func happyInstall() throws {
            let staging = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: staging) }

            let finalDir = try makeTempDir()
                .appendingPathComponent("opencode")
            defer { try? FileManager.default.removeItem(at: finalDir.deletingLastPathComponent()) }

            let goodZip = try makeValidSidecarZip(id: "opencode")
            defer { try? FileManager.default.removeItem(at: goodZip) }

            let manifest = PluginManifest(
                schemaVersion: 1,
                id: "opencode",
                displayName: "OpenCode",
                shortName: "OC",
                version: "1.0.0",
                processNames: [],
                ui: PluginManifest.UI(icon: nil, color: nil),
                runtime: .sidecar,
                sidecar: PluginManifest.Sidecar(executable: "bin/sidecar")
            )

            try PluginInstaller.unpackAndValidate(zip: goodZip, stagingDir: staging, manifest: manifest)
            try PluginInstaller.commitInstall(stagingDir: staging, finalDir: finalDir)

            // bin/sidecar must be present and executable at the final location.
            let sidecarURL = finalDir.appendingPathComponent("bin/sidecar")
            #expect(FileManager.default.isExecutableFile(atPath: sidecarURL.path))

            // --- Test atomic overwrite: commit a second time over the existing dir ---
            let staging2 = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: staging2) }
            let goodZip2 = try makeValidSidecarZip(id: "opencode")
            defer { try? FileManager.default.removeItem(at: goodZip2) }
            try PluginInstaller.unpackAndValidate(zip: goodZip2, stagingDir: staging2, manifest: manifest)
            // This must not throw even though finalDir already exists.
            try PluginInstaller.commitInstall(stagingDir: staging2, finalDir: finalDir)
            #expect(FileManager.default.isExecutableFile(atPath: sidecarURL.path))
        }

        // MARK: - downloadBundle: happy path (correct hash → file written)

        @Test("downloadBundle: correct SHA-256 writes the temp file")
        func downloadBundleHappyPath() async throws {
            let body = Data("correct bundle contents".utf8)
            let correctHex = sha256Hex(body)

            let tempDir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }
            let tempFile = tempDir.appendingPathComponent("bundle.zip")

            let url = try #require(URL(string: "https://cdn.example.com/bundle.zip"))
            try await PluginInstaller.downloadBundle(
                url,
                expectedSHA256: correctHex,
                session: BundleStubSession(body: body),
                into: tempFile
            )
            let written = try Data(contentsOf: tempFile)
            #expect(written == body)
        }
    }

    @Suite("PluginInstaller.resolveRegistryEntry")
    struct PluginInstallerResolveRegistryEntryTests {
        @Test("url-entry in loaded registry is preserved over folder discovery")
        func preservesURLSourceFromLoadedRegistry() throws {
            // A PluginRegistryFile containing a .url entry for "opencode".
            let manifestURL = try #require(URL(string: "https://example.com/opencode/plugin.json"))
            let bundleURL = try #require(URL(string: "https://cdn.example.com/opencode-1.0.0.zip"))
            let sha = "abc123def456abc123def456abc123def456abc123def456abc123def456abc1"

            let loadedEntry = PluginRegistryEntry(
                id: "opencode",
                version: "1.0.0",
                source: .url,
                runtime: .sidecar,
                enabled: true,
                manifestURL: manifestURL,
                bundleURL: bundleURL,
                bundleSHA256: sha
            )
            let loaded = PluginRegistryFile(schemaVersion: 1, plugins: [loadedEntry])

            // Simulate a discovered manifest (from disk scan — no url fields).
            let discoveredManifest = PluginManifest(
                schemaVersion: 1,
                id: "opencode",
                displayName: "OpenCode",
                shortName: "OC",
                version: "1.0.0",
                processNames: [],
                ui: PluginManifest.UI(icon: nil, color: nil),
                runtime: .sidecar,
                sidecar: PluginManifest.Sidecar(executable: "bin/sidecar")
            )

            let result = PluginInstaller.resolveRegistryEntry(
                discoveredID: "opencode",
                manifest: discoveredManifest,
                loaded: loaded
            )

            // Must preserve .url source and all url fields.
            #expect(result.source == .url, "source must be .url, got \(result.source)")
            #expect(result.manifestURL == manifestURL, "manifestURL must be preserved")
            #expect(result.bundleURL == bundleURL, "bundleURL must be preserved")
            #expect(result.bundleSHA256 == sha, "bundleSHA256 must be preserved")
        }

        @Test("folder discovery without prior url entry returns .folder with nil urls")
        func folderDiscoveryWithoutPriorURLEntry() {
            // Empty loaded registry (no prior entry).
            let loaded = PluginRegistryFile(schemaVersion: 1, plugins: [])

            let manifest = PluginManifest(
                schemaVersion: 1,
                id: "myplugin",
                displayName: "My Plugin",
                shortName: "MP",
                version: "0.1.0",
                processNames: [],
                ui: PluginManifest.UI(icon: nil, color: nil),
                runtime: .sidecar,
                sidecar: PluginManifest.Sidecar(executable: "bin/sidecar")
            )

            let result = PluginInstaller.resolveRegistryEntry(
                discoveredID: "myplugin",
                manifest: manifest,
                loaded: loaded
            )

            #expect(result.source == .folder, "source must be .folder, got \(result.source)")
            #expect(result.manifestURL == nil)
            #expect(result.bundleURL == nil)
            #expect(result.bundleSHA256 == nil)
        }
    }
#endif
