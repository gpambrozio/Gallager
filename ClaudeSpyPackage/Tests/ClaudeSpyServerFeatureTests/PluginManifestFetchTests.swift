#if os(macOS)
    import Foundation
    import GallagerPluginProtocol
    import Testing
    @testable import ClaudeSpyServerFeature

    // MARK: - StubSession

    /// A test double for `URLSessionProtocol` that yields canned `Data` chunks.
    ///
    /// Construct with a body `Data` value; the stub splits it into one or more
    /// chunks and yields them from `openStream`. Use `StubSession.oversized` to
    /// produce a body larger than the 1 MiB manifest cap.
    struct StubSession: URLSessionProtocol {
        let body: Data
        let chunkSize: Int

        init(body: Data, chunkSize: Int = 65_536) {
            self.body = body
            self.chunkSize = chunkSize
        }

        /// A stub that yields an empty body (useful when we expect a pre-network error).
        static let empty = StubSession(body: Data())

        /// A stub whose body exceeds the 1 MiB manifest size cap.
        static let oversized = StubSession(
            body: Data(repeating: 0x41, count: PluginInstaller.manifestSizeCap + 1),
            chunkSize: 65_536
        )

        func openStream(_ request: URLRequest) async throws -> (HTTPURLResponse?, AsyncThrowingStream<Data, any Error>) {
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
            // Return a synthetic 200 response; status code is not checked by fetchManifest.
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

    @Suite("PluginInstaller manifest fetch")
    struct PluginManifestFetchTests {
        // MARK: - HTTPS enforcement

        @Test("rejects non-https URL before touching the network")
        func notHTTPS() async throws {
            await #expect(throws: InstallError.notHTTPS) {
                _ = try await PluginInstaller.fetchManifest(
                    #require(URL(string: "http://example.com/m.json")),
                    session: StubSession.empty
                )
            }
        }

        // MARK: - Size cap

        @Test("throws manifestTooLarge when body exceeds 1 MiB")
        func manifestTooLarge() async throws {
            await #expect(throws: InstallError.manifestTooLarge) {
                _ = try await PluginInstaller.fetchManifest(
                    #require(URL(string: "https://example.com/m.json")),
                    session: StubSession.oversized
                )
            }
        }

        // MARK: - ID sanitization

        @Test("rejects a manifest whose id is a path traversal")
        func invalidID() async throws {
            let body = #"{"schema_version":1,"id":"../evil","display_name":"E","short_name":"E","version":"1","runtime":"sidecar","ui":{}}"#
            await #expect(throws: InstallError.invalidID) {
                _ = try await PluginInstaller.fetchManifest(
                    #require(URL(string: "https://example.com/m.json")),
                    session: StubSession(body: Data(body.utf8))
                )
            }
        }

        // MARK: - Happy path

        @Test("returns manifest and TrustDetails for a valid https manifest")
        func happyPath() async throws {
            let bundleURL = try #require(URL(string: "https://cdn.example.com/opencode-1.2.3.zip"))
            let body = """
            {
              "schema_version": 1,
              "id": "opencode",
              "display_name": "OpenCode",
              "short_name": "OC",
              "version": "1.2.3",
              "runtime": "sidecar",
              "publisher": "OpenCode Inc.",
              "bundle_url": "\(bundleURL.absoluteString)",
              "bundle_sha256": "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
              "ui": {}
            }
            """
            let sourceURL = try #require(URL(string: "https://example.com/opencode/plugin.json"))
            let (manifest, trust) = try await PluginInstaller.fetchManifest(
                sourceURL,
                session: StubSession(body: Data(body.utf8))
            )

            #expect(manifest.id == "opencode")
            #expect(manifest.displayName == "OpenCode")
            #expect(manifest.version == "1.2.3")
            #expect(manifest.publisher == "OpenCode Inc.")

            #expect(trust.id == "opencode")
            #expect(trust.displayName == "OpenCode")
            #expect(trust.version == "1.2.3")
            #expect(trust.publisher == "OpenCode Inc.")
            #expect(trust.sourceURL == sourceURL)
            #expect(trust.bundleURL == bundleURL)
            #expect(trust.bundleSHA256 == "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890")
            #expect(trust.bundleSizeBytes == nil)
        }
    }
#endif
