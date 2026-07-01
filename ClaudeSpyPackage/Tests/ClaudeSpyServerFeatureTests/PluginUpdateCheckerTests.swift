#if os(macOS)
    import Foundation
    import GallagerPluginProtocol
    import Testing
    @testable import ClaudeSpyServerFeature

    // MARK: - Stub session (per-URL responses)

    /// A stub session keyed by URL. Unmapped URLs return an empty body.
    private struct UpdateStubSession: URLSessionProtocol {
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

    private func makeManifestData(
        id: String,
        version: String,
        bundleURLString: String = "https://cdn.example.com/bundle.zip"
    ) -> Data {
        let body = """
        {
          "schema_version": 1,
          "id": "\(id)",
          "display_name": "Test Plugin",
          "short_name": "TP",
          "version": "\(version)",
          "runtime": "sidecar",
          "sidecar": {"executable": "bin/sidecar"},
          "bundle_url": "\(bundleURLString)",
          "bundle_sha256": "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
          "process_names": [],
          "ui": {}
        }
        """
        return Data(body.utf8)
    }

    private func makeEntry(
        id: String,
        version: String,
        manifestURL: URL,
        bundleURL: URL? = URL(string: "https://cdn.example.com/bundle.zip")
    ) -> PluginRegistryEntry {
        PluginRegistryEntry(
            id: id,
            version: version,
            source: .url,
            runtime: .sidecar,
            enabled: true,
            manifestURL: manifestURL,
            bundleURL: bundleURL,
            bundleSHA256: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
        )
    }

    // MARK: - Tests

    @Suite("PluginUpdateChecker")
    struct PluginUpdateCheckerTests {
        // MARK: Newer version detected

        @Test("entry at v1.0.0 whose manifest reports v1.1.0 produces one PluginUpdate")
        func newerVersionDetected() async throws {
            let id = "test-plugin"
            let manifestURL = try #require(URL(string: "https://example.com/\(id)/plugin.json"))
            let entry = makeEntry(id: id, version: "1.0.0", manifestURL: manifestURL)

            let session = UpdateStubSession(responses: [
                manifestURL: makeManifestData(id: id, version: "1.1.0"),
            ])

            let updates = await PluginUpdateChecker.check([entry], session: session)

            #expect(updates.count == 1)
            let update = try #require(updates.first)
            #expect(update.id == id)
            #expect(update.currentVersion == "1.0.0")
            #expect(update.newVersion == "1.1.0")
            #expect(update.sourceChanged == false)
        }

        // MARK: Source host changed

        @Test("fetched bundle_url on a different host sets sourceChanged = true")
        func sourceHostChanged() async throws {
            let id = "host-changed-plugin"
            let manifestURL = try #require(URL(string: "https://example.com/\(id)/plugin.json"))
            // Entry has bundle hosted on cdn-old.example.com.
            let oldBundleURL = try #require(URL(string: "https://cdn-old.example.com/bundle.zip"))
            let entry = makeEntry(id: id, version: "1.0.0", manifestURL: manifestURL, bundleURL: oldBundleURL)

            // Remote manifest reports v1.1.0 on a different host.
            let newBundleURLString = "https://cdn-new.example.com/bundle.zip"
            let session = UpdateStubSession(responses: [
                manifestURL: makeManifestData(id: id, version: "1.1.0", bundleURLString: newBundleURLString),
            ])

            let updates = await PluginUpdateChecker.check([entry], session: session)

            #expect(updates.count == 1)
            let update = try #require(updates.first)
            #expect(update.newVersion == "1.1.0")
            #expect(update.sourceChanged == true)
        }

        // MARK: Up-to-date entry produces no update

        @Test("up-to-date entry (same version) produces no PluginUpdate")
        func upToDateNoUpdate() async throws {
            let id = "current-plugin"
            let manifestURL = try #require(URL(string: "https://example.com/\(id)/plugin.json"))
            let entry = makeEntry(id: id, version: "2.0.0", manifestURL: manifestURL)

            let session = UpdateStubSession(responses: [
                manifestURL: makeManifestData(id: id, version: "2.0.0"),
            ])

            let updates = await PluginUpdateChecker.check([entry], session: session)
            #expect(updates.isEmpty)
        }

        // MARK: Bundled / folder entries are skipped

        @Test("bundled and folder-source entries are skipped")
        func bundledAndFolderSkipped() async throws {
            let manifestURL = try #require(URL(string: "https://example.com/plugin.json"))
            let bundledEntry = PluginRegistryEntry(
                id: "bundled-plugin",
                version: "1.0.0",
                source: .bundled,
                runtime: .inProcess,
                enabled: true,
                manifestURL: manifestURL,
                bundleURL: nil,
                bundleSHA256: nil
            )
            let folderEntry = PluginRegistryEntry(
                id: "folder-plugin",
                version: "1.0.0",
                source: .folder,
                runtime: .sidecar,
                enabled: true,
                manifestURL: manifestURL,
                bundleURL: nil,
                bundleSHA256: nil
            )
            // Session serves a newer version — but these entries must not trigger checks.
            let session = UpdateStubSession(responses: [
                manifestURL: makeManifestData(id: "any", version: "9.9.9"),
            ])

            let updates = await PluginUpdateChecker.check([bundledEntry, folderEntry], session: session)
            #expect(updates.isEmpty)
        }

        // MARK: Entry without manifestURL is skipped

        @Test("url-source entry with nil manifestURL is skipped")
        func urlSourceNoManifestURLSkipped() async {
            let entry = PluginRegistryEntry(
                id: "no-manifest-url",
                version: "1.0.0",
                source: .url,
                runtime: .sidecar,
                enabled: true,
                manifestURL: nil,
                bundleURL: URL(string: "https://cdn.example.com/bundle.zip"),
                bundleSHA256: nil
            )
            let session = UpdateStubSession(responses: [:])
            let updates = await PluginUpdateChecker.check([entry], session: session)
            #expect(updates.isEmpty)
        }

        // MARK: Older fetched version does not report update

        @Test("fetched manifest at an older version does not produce an update")
        func olderVersionNoUpdate() async throws {
            let id = "downgrade-plugin"
            let manifestURL = try #require(URL(string: "https://example.com/\(id)/plugin.json"))
            let entry = makeEntry(id: id, version: "2.0.0", manifestURL: manifestURL)

            let session = UpdateStubSession(responses: [
                manifestURL: makeManifestData(id: id, version: "1.9.9"),
            ])

            let updates = await PluginUpdateChecker.check([entry], session: session)
            #expect(updates.isEmpty)
        }

        // MARK: isNewer unit tests

        @Test("isNewer: 1.1.0 is newer than 1.0.0")
        func isNewerPatch() {
            #expect(PluginUpdateChecker.isNewer("1.1.0", than: "1.0.0"))
        }

        @Test("isNewer: 2.0.0 is newer than 1.9.9")
        func isNewerMajor() {
            #expect(PluginUpdateChecker.isNewer("2.0.0", than: "1.9.9"))
        }

        @Test("isNewer: 1.0.0 is NOT newer than 1.0.0")
        func isNewerEqual() {
            #expect(!PluginUpdateChecker.isNewer("1.0.0", than: "1.0.0"))
        }

        @Test("isNewer: 1.0.0 is NOT newer than 2.0.0")
        func isNewerOlder() {
            #expect(!PluginUpdateChecker.isNewer("1.0.0", than: "2.0.0"))
        }
    }
#endif
