#if os(macOS)
    import Foundation
    import GallagerPluginProtocol

    // MARK: - InstallError

    /// Errors that can be thrown throughout the plugin install flow (Tasks 12–14).
    public enum InstallError: Error, Equatable {
        /// The manifest URL uses a non-`https` scheme.
        case notHTTPS
        /// The manifest body exceeded the 1 MiB streaming cap.
        case manifestTooLarge
        /// The manifest's `schema_version` is not 1.
        case invalidSchema
        /// The manifest's `id` failed `PluginInstaller.sanitize(id:)`.
        case invalidID
        /// The downloaded bundle exceeded the size cap.
        case bundleTooLarge
        /// The SHA-256 digest of the downloaded bundle does not match the manifest.
        case hashMismatch
        /// A path inside the bundle archive escapes the extraction root (zip-slip).
        case zipSlip(String)
        /// The bundle archive is missing the expected plugin bundle directory.
        case bundleMissing
        /// The plugin is not installed in the plugins directory.
        case notInstalled
        /// Enabling the plugin failed with the given reason.
        case enableFailed(String)
    }

    // MARK: - URLSessionProtocol

    /// A thin, stubbable seam over URLSession that returns a streaming body so
    /// callers can enforce a byte-count cap mid-stream without buffering the full
    /// response first.
    ///
    /// Conformers must be `Sendable` so the protocol can be used across actor
    /// boundaries in Swift 6 strict-concurrency mode.
    ///
    /// Task 13 reuses this protocol for bundle downloads.
    public protocol URLSessionProtocol: Sendable {
        /// Open an HTTP(S) request and return the response head plus a chunked body
        /// stream. Callers accumulate chunks and may abort early (by cancelling the
        /// enclosing `Task`) when a size limit is reached.
        func openStream(_ request: URLRequest) async throws -> (HTTPURLResponse?, AsyncThrowingStream<Data, any Error>)
    }

    // MARK: - Live URLSession conformance

    extension URLSession: URLSessionProtocol {
        public func openStream(_ request: URLRequest) async throws -> (HTTPURLResponse?, AsyncThrowingStream<Data, any Error>) {
            // `URLSession.bytes(for:)` is available on macOS 12+; this project targets macOS 15+.
            let (byteStream, response) = try await bytes(for: request)
            let httpResponse = response as? HTTPURLResponse
            let stream = AsyncThrowingStream<Data, any Error> { continuation in
                let task = Task {
                    var buffer = Data()
                    buffer.reserveCapacity(4_096)
                    for try await byte in byteStream {
                        buffer.append(byte)
                        // Flush in ~4 KiB chunks for low latency on the cap check.
                        if buffer.count >= 4_096 {
                            continuation.yield(buffer)
                            buffer = Data()
                            buffer.reserveCapacity(4_096)
                        }
                    }
                    if !buffer.isEmpty {
                        continuation.yield(buffer)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
            return (httpResponse, stream)
        }
    }

    // MARK: - PluginInstaller

    /// Namespace for plugin distribution helpers: id sanitization, folder-drop
    /// discovery, and (from Task 12 onward) HTTPS manifest fetching.
    public enum PluginInstaller {
        // MARK: - ID sanitization

        /// Return `id` iff it matches `^[a-z0-9][a-z0-9._-]*$`, contains no `..`,
        /// and is ≤ 128 characters; otherwise return `nil`.
        ///
        /// These checks guarantee that using the id as a filesystem path component
        /// can never escape the plugins directory via traversal sequences or
        /// absolute paths.
        public static func sanitize(id: String) -> String? {
            guard !id.isEmpty, id.count <= 128 else { return nil }
            guard !id.contains("..") else { return nil }
            // First character: lowercase letter or digit only.
            guard
                let first = id.unicodeScalars.first,
                isLower(first) || isDigit(first) else { return nil }
            // Remaining characters: lowercase letter, digit, dot, underscore, or hyphen.
            for scalar in id.unicodeScalars.dropFirst() {
                guard isLower(scalar) || isDigit(scalar) || scalar == "." || scalar == "_" || scalar == "-" else {
                    return nil
                }
            }
            return id
        }

        // MARK: - Folder-drop discovery

        /// Enumerate the immediate subdirectories of `pluginsDir`, load `plugin.json`
        /// from each, and return the valid sidecar plugins.
        ///
        /// A folder is kept only when all of these hold:
        /// 1. The manifest decodes successfully.
        /// 2. `manifest.runtime == .sidecar`.
        /// 3. `sanitize(id: manifest.id) != nil` AND the sanitized id equals the
        ///    directory name (so an id cannot point outside its own folder).
        /// 4. The executable declared in the manifest (or `bin/sidecar` when absent)
        ///    exists under the plugin root and has the executable bit set.
        ///
        /// Any folder that fails any check is silently skipped — discovery never crashes.
        /// Results are returned in directory-enumeration order (locale-sorted by the OS).
        public static func discoverFolderDropped(pluginsDir: URL) -> [(manifest: PluginManifest, root: URL)] {
            let fm = FileManager.default
            guard
                let contents = try? fm.contentsOfDirectory(
                    at: pluginsDir,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else {
                return []
            }

            var results: [(manifest: PluginManifest, root: URL)] = []

            for entry in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                // Must be a directory.
                guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                    continue
                }

                let dirName = entry.lastPathComponent

                // Load and decode the manifest; skip on any failure.
                guard let manifest = try? PluginManifest.load(fromPluginRoot: entry) else {
                    continue
                }

                // Must be a sidecar plugin.
                guard manifest.runtime == .sidecar else { continue }

                // Sanitize the manifest's id and verify it matches the directory name.
                guard let sanitizedID = sanitize(id: manifest.id), sanitizedID == dirName else {
                    continue
                }

                // Resolve the executable path: use the manifest's declared executable,
                // falling back to `bin/sidecar`.
                let executableRelativePath = manifest.sidecar?.executable ?? "bin/sidecar"
                let executableURL = entry.appendingPathComponent(executableRelativePath)

                // Executable must exist and have the executable bit set.
                guard fm.isExecutableFile(atPath: executableURL.path) else { continue }

                results.append((manifest: manifest, root: entry))
            }

            return results
        }

        // MARK: - Manifest fetch

        /// Maximum allowed manifest body size (1 MiB). Enforced mid-stream so the
        /// process never buffers more than this even against a slow or adversarial
        /// server.
        static let manifestSizeCap = 1 * 1_024 * 1_024

        /// Fetch a remote plugin manifest over HTTPS.
        ///
        /// - Parameters:
        ///   - url: The manifest URL. Must use the `https` scheme.
        ///   - session: The HTTP session to use. Defaults to `URLSession.shared`
        ///     in production; supply a stub in tests.
        /// - Returns: The decoded manifest and a `TrustDetails` value populated
        ///   from the manifest fields and the source URL.
        /// - Throws:
        ///   - `InstallError.notHTTPS` if `url.scheme != "https"` (checked before
        ///     any network activity).
        ///   - `InstallError.manifestTooLarge` if the streamed body exceeds 1 MiB.
        ///   - `InstallError.invalidSchema` if `manifest.schemaVersion != 1`.
        ///   - `InstallError.invalidID` if `sanitize(id: manifest.id)` returns `nil`.
        public static func fetchManifest(
            _ url: URL,
            session: any URLSessionProtocol
        ) async throws -> (PluginManifest, TrustDetails) {
            // HTTPS check happens before any network I/O.
            guard url.scheme == "https" else {
                throw InstallError.notHTTPS
            }

            let request = URLRequest(url: url)
            let (_, bodyStream) = try await session.openStream(request)

            // Stream the body with a running byte count; abort if the cap is exceeded.
            var accumulated = Data()
            accumulated.reserveCapacity(min(manifestSizeCap, 65_536))
            for try await chunk in bodyStream {
                accumulated.append(chunk)
                if accumulated.count > manifestSizeCap {
                    throw InstallError.manifestTooLarge
                }
            }

            // Decode the manifest.
            let manifest: PluginManifest
            do {
                manifest = try JSONDecoder().decode(PluginManifest.self, from: accumulated)
            } catch {
                throw InstallError.invalidSchema
            }

            // Validate schema version.
            guard manifest.schemaVersion == 1 else {
                throw InstallError.invalidSchema
            }

            // Validate the id using the existing sanitizer (no reimplementation).
            guard sanitize(id: manifest.id) != nil else {
                throw InstallError.invalidID
            }

            let trust = TrustDetails(
                id: manifest.id,
                displayName: manifest.displayName,
                version: manifest.version,
                publisher: manifest.publisher,
                sourceURL: url,
                bundleURL: manifest.bundleURL,
                bundleSHA256: manifest.bundleSHA256,
                bundleSizeBytes: nil // known only after Task-13 bundle download
            )

            return (manifest, trust)
        }

        // MARK: - Private helpers

        private static func isLower(_ scalar: Unicode.Scalar) -> Bool {
            scalar.value >= 97 && scalar.value <= 122 // 'a'...'z'
        }

        private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
            scalar.value >= 48 && scalar.value <= 57 // '0'...'9'
        }
    }
#endif
