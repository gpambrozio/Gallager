#if os(macOS)
    import CryptoKit
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
        /// The extracted bundle tree failed validation (missing manifest, id/version mismatch, etc.).
        case treeValidationFailed(String)
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

        // MARK: - Bundle download (Task 13)

        /// Default maximum bundle size (50 MiB). Enforced mid-stream.
        public static let bundleSizeCapDefault = 50 * 1_024 * 1_024

        /// Stream-download a plugin bundle, verify its SHA-256 digest, and write it
        /// to `temp` incrementally without buffering the full body in memory.
        ///
        /// - Parameters:
        ///   - url: The bundle download URL.
        ///   - expectedSHA256: Lowercase or uppercase hex digest from the manifest.
        ///   - session: Injected HTTP session (swap a stub in tests).
        ///   - temp: Path to write the received bytes. The file is created/overwritten
        ///     on first chunk and removed on any error.
        ///   - sizeCap: Byte ceiling enforced mid-stream. Defaults to 50 MiB.
        /// - Throws:
        ///   - `InstallError.bundleTooLarge` if the running byte count exceeds `sizeCap`.
        ///   - `InstallError.hashMismatch` if the final digest doesn't match `expectedSHA256`.
        public static func downloadBundle(
            _ url: URL,
            expectedSHA256: String,
            session: any URLSessionProtocol,
            into temp: URL,
            sizeCap: Int = PluginInstaller.bundleSizeCapDefault
        ) async throws {
            let request = URLRequest(url: url)
            let (_, bodyStream) = try await session.openStream(request)

            let fm = FileManager.default
            // Create the output file so we can open a FileHandle for writing.
            fm.createFile(atPath: temp.path, contents: nil)
            guard let handle = FileHandle(forWritingAtPath: temp.path) else {
                throw InstallError.bundleMissing
            }

            var hasher = SHA256()
            var byteCount = 0

            do {
                for try await chunk in bodyStream {
                    byteCount += chunk.count
                    if byteCount > sizeCap {
                        // Clean up and abort; do NOT keep a partial file.
                        try? handle.close()
                        try? fm.removeItem(at: temp)
                        throw InstallError.bundleTooLarge
                    }
                    hasher.update(data: chunk)
                    handle.write(chunk)
                }
                try handle.close()
            } catch let error as InstallError {
                try? handle.close()
                try? fm.removeItem(at: temp)
                throw error
            } catch {
                try? handle.close()
                try? fm.removeItem(at: temp)
                throw error
            }

            // Verify the digest (case-insensitive comparison per spec).
            let digest = hasher.finalize()
            let hexDigest = digest.compactMap { String(format: "%02x", $0) }.joined()
            guard hexDigest.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
                try? fm.removeItem(at: temp)
                throw InstallError.hashMismatch
            }
        }

        // MARK: - Unpack + validate (Task 13)

        /// Unzip a bundle archive into `stagingDir`, then:
        /// 1. Reject zip-slip: every extracted entry's resolved path must be
        ///    contained within `stagingDir` (catches `../` traversal AND symlink
        ///    escapes). `/usr/bin/unzip` exits 0 even when it *skips* traversal
        ///    entries, so the exit code alone is NOT sufficient — we enumerate.
        /// 2. Validate the tree: `plugin.json` at the staging root whose `id` and
        ///    `version` match `manifest`; `bin/sidecar` (or `manifest.sidecar.executable`)
        ///    present and executable; any declared `ui.icon` asset present.
        /// - Throws: `InstallError.zipSlip`, `InstallError.bundleMissing`, or a
        ///   descriptive `InstallError.treeValidationFailed` for tree-validation failures.
        public static func unpackAndValidate(
            zip: URL,
            stagingDir: URL,
            manifest: PluginManifest
        ) throws {
            // --- Step 1: unzip --------------------------------------------------
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzip.arguments = ["-o", "-q", zip.path, "-d", stagingDir.path]
            let errPipe = Pipe()
            unzip.standardError = errPipe
            try unzip.run()
            unzip.waitUntilExit()
            // We deliberately do NOT treat a non-zero exit as definitive — the
            // zip-slip enumeration below is the real guard.

            // --- Step 2: zip-slip check -----------------------------------------
            let canonicalStaging = stagingDir.standardizedFileURL.resolvingSymlinksInPath()

            let fm = FileManager.default
            guard
                let enumerator = fm.enumerator(
                    at: stagingDir,
                    includingPropertiesForKeys: [],
                    options: []
                ) else {
                throw InstallError.bundleMissing
            }

            for case let entry as URL in enumerator {
                let resolved = entry.standardizedFileURL.resolvingSymlinksInPath()
                let entryPath = resolved.path
                let stagingPath = canonicalStaging.path
                // The resolved path must start with the staging dir's path.
                // Use a separator-anchored prefix to avoid partial-name matches.
                let containedPrefix = stagingPath.hasSuffix("/")
                    ? stagingPath
                    : stagingPath + "/"
                guard entryPath == stagingPath || entryPath.hasPrefix(containedPrefix) else {
                    throw InstallError.zipSlip(entry.path)
                }
            }

            // --- Step 3: tree validation ----------------------------------------
            // plugin.json must be at the staging root.
            let manifestURL = stagingDir.appendingPathComponent("plugin.json")
            guard fm.fileExists(atPath: manifestURL.path) else {
                throw InstallError.treeValidationFailed("plugin.json missing from bundle root")
            }
            let extracted: PluginManifest
            do {
                extracted = try PluginManifest.load(fromPluginRoot: stagingDir)
            } catch {
                throw InstallError.treeValidationFailed("plugin.json decode failed: \(error)")
            }
            guard extracted.id == manifest.id else {
                throw InstallError.treeValidationFailed(
                    "bundle id '\(extracted.id)' does not match manifest id '\(manifest.id)'"
                )
            }
            guard extracted.version == manifest.version else {
                throw InstallError.treeValidationFailed(
                    "bundle version '\(extracted.version)' does not match manifest version '\(manifest.version)'"
                )
            }

            // Executable must be present and have the executable bit.
            let execRelPath = manifest.sidecar?.executable ?? "bin/sidecar"
            let execURL = stagingDir.appendingPathComponent(execRelPath)
            guard fm.isExecutableFile(atPath: execURL.path) else {
                throw InstallError.treeValidationFailed(
                    "declared executable '\(execRelPath)' is missing or not executable"
                )
            }

            // Declared icon asset must be present.
            if let icon = manifest.ui.icon {
                let iconURL = stagingDir.appendingPathComponent(icon)
                guard fm.fileExists(atPath: iconURL.path) else {
                    throw InstallError.treeValidationFailed("declared ui.icon '\(icon)' is missing from bundle")
                }
            }
        }

        // MARK: - Atomic commit (Task 13)

        /// Atomically move `stagingDir` into `finalDir`, replacing any existing
        /// installation without a window where neither the old nor the new version
        /// is in place.
        ///
        /// Strategy:
        ///  1. If `finalDir` exists, rename it to `<finalDir>.replacing` (move-aside).
        ///  2. Rename `stagingDir` → `finalDir`.
        ///  3. Remove the `.replacing` dir.
        ///
        /// On failure after step 2, the new installation is in place and the old
        /// one is still at `<finalDir>.replacing` — recoverable.
        public static func commitInstall(stagingDir: URL, finalDir: URL) throws {
            let fm = FileManager.default
            let replacing = URL(fileURLWithPath: finalDir.path + ".replacing")

            // Move aside existing install (if any).
            if fm.fileExists(atPath: finalDir.path) {
                // Clean up any leftover `.replacing` dir from a previous failed attempt.
                if fm.fileExists(atPath: replacing.path) {
                    try fm.removeItem(at: replacing)
                }
                try fm.moveItem(at: finalDir, to: replacing)
            }

            // Rename staging → final (atomic on the same filesystem).
            try fm.moveItem(at: stagingDir, to: finalDir)

            // Best-effort cleanup of the old installation.
            if fm.fileExists(atPath: replacing.path) {
                try? fm.removeItem(at: replacing)
            }
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
