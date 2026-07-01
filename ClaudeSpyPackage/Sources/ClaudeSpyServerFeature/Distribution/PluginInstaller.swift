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
        /// The manifest parsed but declares no downloadable bundle — it lacks
        /// `bundle_url` and/or `bundle_sha256`, so it can't be installed from a
        /// URL. Typically a bundle-internal `plugin.json` served directly instead
        /// of a distribution manifest.
        case missingBundleReference
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

        /// Resolve the registry entry for a folder-discovered plugin, preserving
        /// url-source metadata when the loaded registry already has a `.url` entry
        /// for the same id.
        ///
        /// - Parameters:
        ///   - discoveredID: The id of the folder-discovered plugin.
        ///   - manifest: The manifest loaded from disk for this plugin.
        ///   - loaded: The existing persisted registry (loaded before discovery).
        /// - Returns: A `PluginRegistryEntry.Source` and the urls to carry forward.
        ///   When the loaded registry has a `.url` entry for `discoveredID`, returns
        ///   `(.url, manifestURL, bundleURL, bundleSHA256)` from that entry.
        ///   Otherwise returns `(.folder, nil, nil, nil)`.
        public static func resolveRegistryEntry(
            discoveredID: String,
            manifest: PluginManifest,
            loaded: PluginRegistryFile
        ) -> (source: PluginRegistryEntry.Source, manifestURL: URL?, bundleURL: URL?, bundleSHA256: String?) {
            if
                let prior = loaded.plugins.first(where: { $0.id == discoveredID }),
                prior.source == .url {
                return (.url, prior.manifestURL, prior.bundleURL, prior.bundleSHA256)
            }
            return (.folder, nil, nil, nil)
        }

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

            // Always fetch the currently-published manifest. A manifest host may
            // omit `Cache-Control`/`ETag` (sending only `Last-Modified`), in which
            // case URLSession applies *heuristic* freshness and would serve a stale
            // cached body after the author re-publishes — so an install could keep
            // seeing an old manifest (e.g. one still missing `bundle_url`). Bypass
            // the local cache so the fetch reflects the server, not a prior install.
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
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
            guard url.scheme == "https" else {
                throw InstallError.notHTTPS
            }
            // Bypass the local cache (same reasoning as the manifest fetch): a
            // re-published bundle at a stable URL must not be shadowed by a
            // heuristically-cached copy. The SHA-256 pin would catch a stale body,
            // but fetching fresh avoids a spurious hash-mismatch failure.
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            let (_, bodyStream) = try await session.openStream(request)

            let fm = FileManager.default
            // Create the output file so we can open a FileHandle for writing.
            fm.createFile(atPath: temp.path, contents: nil)
            guard let handle = FileHandle(forWritingAtPath: temp.path) else {
                // Don't leave the just-created empty file orphaned in pluginsDir.
                try? fm.removeItem(at: temp)
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
                    // Throwing variant: a write failure (e.g. disk-full) routes
                    // through the catch cleanup below instead of trapping the way
                    // the deprecated `FileHandle.write(_:)` does.
                    try handle.write(contentsOf: chunk)
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
            // --- Step 0: pre-extraction preflight -------------------------------
            // Enumerate the archive's central directory BEFORE extracting and
            // reject any traversal/symlink member. This closes the detect-after-
            // damage window: without it, `unzip` could create a symlink and then
            // write a later entry *through* it to a path outside `stagingDir`
            // before the post-extraction enumeration (Step 2) ever runs.
            try preflightArchive(zip: zip)

            // --- Step 1: unzip --------------------------------------------------
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzip.arguments = ["-o", "-q", zip.path, "-d", stagingDir.path]
            // stderr is unused (the preflight + enumeration are the real guards);
            // route it to /dev/null so a chatty archive can't fill an unread pipe
            // buffer and deadlock `waitUntilExit()`.
            unzip.standardError = FileHandle.nullDevice
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

        /// Inspect a zip archive's listing without extracting it and reject any
        /// member that could escape the extraction root: an absolute path, a `..`
        /// path component, or a symlink. A plugin bundle must not contain symlinks
        /// (rejecting them up front prevents `unzip` from writing a later entry
        /// through an extracted symlink).
        static func preflightArchive(zip: URL) throws {
            // Pass 1: names only (`unzip -Z -1` → one member name per line).
            let names = try runUnzipList(zip: zip, args: ["-Z", "-1", zip.path])
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
            for name in names {
                guard !name.hasPrefix("/") else {
                    throw InstallError.zipSlip(name)
                }
                // Reject any `..` component (covers `../x`, `a/../../x`, etc.).
                if name.split(separator: "/", omittingEmptySubsequences: false).contains("..") {
                    throw InstallError.zipSlip(name)
                }
            }

            // Pass 2: long listing (`unzip -Z`) so we can spot symlink members by
            // their unix mode. zipinfo entry lines begin with a 10-char permission
            // string (e.g. "lrwxr-xr-x"); a leading `l` marks a symlink. The
            // "Archive:" header and the "N files," trailer don't match that shape.
            // The long listing enumerates entries in the same archive order as the
            // `-Z -1` names above, so we pair them by index to name the offender.
            let entryLines = try runUnzipList(zip: zip, args: ["-Z", zip.path])
                .split(separator: "\n", omittingEmptySubsequences: true)
                .filter { line in
                    guard
                        let perms = line.split(separator: " ", omittingEmptySubsequences: true).first,
                        perms.count == 10,
                        let kind = perms.first else { return false }
                    return kind == "-" || kind == "d" || kind == "l"
                }
            for (index, line) in entryLines.enumerated() where line.hasPrefix("l") {
                let offender = index < names.count ? names[index] : "symlink member in bundle"
                throw InstallError.zipSlip(offender)
            }
        }

        /// Run `/usr/bin/unzip` with the given listing args and return its stdout.
        /// stderr is routed to `/dev/null` (it's unused and would otherwise risk a
        /// full-pipe deadlock on a chatty archive).
        private static func runUnzipList(zip: URL, args: [String]) throws -> String {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            proc.arguments = args
            let outPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
            } catch {
                throw InstallError.treeValidationFailed("could not list zip: \(error)")
            }
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return String(bytes: data, encoding: .utf8) ?? ""
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

        // MARK: - Install orchestration (Task 14)

        /// The outcome of a successful `install(...)` call.
        public enum InstallOutcome: Sendable, Equatable {
            /// Trust confirmation is required before downloading. The caller should
            /// present `TrustDetails` to the user and call `install` again with
            /// `trustConfirmed: true`.
            case needsTrust(TrustDetails)
            /// The plugin was downloaded, validated, committed, and enabled.
            case installed(id: String)
        }

        /// Full URL-install orchestration flow (spec §12–14).
        ///
        /// **Steps (when `trustConfirmed == true`):**
        /// 1. `fetchManifest` — validates HTTPS, schema version, and id.
        /// 2. Requires `manifest.runtime == .sidecar`, a `bundleURL`, and a
        ///    `bundleSHA256`. This runs *before* the trust gate, so a bundle-less
        ///    manifest short-circuits with `.failure(.missingBundleReference)`
        ///    (or `.invalidSchema` for a non-sidecar runtime) at the fetch stage —
        ///    the caller never reaches a trust prompt it can't complete.
        /// 3. `downloadBundle` into a temp file inside `paths.pluginsDir`.
        /// 4. `unpackAndValidate` into `paths.pluginStagingDir(id)`.
        /// 5. `commitInstall` → `paths.pluginInstallDir(id)`.
        /// 6. `registry.registerSidecar(manifest:root:source:.url)`.
        /// 7. Persist `registry.json` to `paths.registryPath` (best-effort).
        /// 8. `registry.enable(id, host:env:)`.
        /// 9. If `registry.failedInit[id]` is set → return `.failure(.enableFailed)`,
        ///    leaving the installed files in place for a future retry.
        ///
        /// When `trustConfirmed == false`, `fetchManifest` and the step-2 bundle
        /// validation run (no download). Returns `.success(.needsTrust(TrustDetails))`
        /// for an installable manifest so the caller can present a confirmation
        /// sheet, or `.failure(.missingBundleReference)` up front when the manifest
        /// has no bundle to install.
        ///
        /// Heavy work (download, unpack, commit) runs on whatever executor the
        /// caller is on — these helpers are non-`@MainActor`. Only the registry
        /// mutation and `enable` are `@MainActor`.
        public static func install(
            manifestURL: URL,
            trustConfirmed: Bool,
            registry: PluginRegistry,
            paths: GallagerPaths,
            session: any URLSessionProtocol,
            makeHost: @MainActor (String) -> any PluginHost,
            makeEnv: @MainActor (String) -> PluginEnv
        ) async -> Result<InstallOutcome, InstallError> {
            // Step 1: fetch manifest (validates HTTPS / schema / id).
            let manifest: PluginManifest
            let trust: TrustDetails
            do {
                (manifest, trust) = try await fetchManifest(manifestURL, session: session)
            } catch let err as InstallError {
                return .failure(err)
            } catch {
                return .failure(.invalidSchema)
            }

            // Step 2: a URL install requires a downloadable, integrity-pinned
            // bundle. Validate this BEFORE the trust gate so a bundle-less manifest
            // (e.g. a bundle-internal `plugin.json` served directly) fails on the
            // entry screen instead of after the user clicks "Trust and Install".
            guard manifest.runtime == .sidecar else {
                return .failure(.invalidSchema)
            }
            guard let bundleURL = manifest.bundleURL, let expectedSHA256 = manifest.bundleSHA256 else {
                return .failure(.missingBundleReference)
            }
            guard bundleURL.scheme == "https" else {
                return .failure(.notHTTPS)
            }

            // Trust gate: no download until the user confirms.
            guard trustConfirmed else {
                return .success(.needsTrust(trust))
            }

            let id = manifest.id

            // Ensure the plugins dir exists before we try to write into it.
            paths.ensurePluginsDir()

            // Step 3: download the bundle into a temp file.
            let tempFile = paths.pluginsDir
                .appendingPathComponent("\(id)-\(UUID().uuidString).zip")
            do {
                try await downloadBundle(
                    bundleURL,
                    expectedSHA256: expectedSHA256,
                    session: session,
                    into: tempFile
                )
            } catch let err as InstallError {
                try? FileManager.default.removeItem(at: tempFile)
                return .failure(err)
            } catch {
                try? FileManager.default.removeItem(at: tempFile)
                return .failure(.bundleMissing)
            }

            // Step 4: unpack + validate into the staging directory.
            let stagingDir = paths.pluginStagingDir(id)
            // Clean up any leftover staging dir from a previous attempt.
            try? FileManager.default.removeItem(at: stagingDir)
            do {
                try FileManager.default.createDirectory(
                    at: stagingDir,
                    withIntermediateDirectories: true
                )
                try unpackAndValidate(zip: tempFile, stagingDir: stagingDir, manifest: manifest)
            } catch let err as InstallError {
                try? FileManager.default.removeItem(at: tempFile)
                try? FileManager.default.removeItem(at: stagingDir)
                return .failure(err)
            } catch {
                try? FileManager.default.removeItem(at: tempFile)
                try? FileManager.default.removeItem(at: stagingDir)
                return .failure(.treeValidationFailed(String(describing: error)))
            }

            // Clean up temp zip.
            try? FileManager.default.removeItem(at: tempFile)

            // Step 5: atomic commit staging → final.
            let finalDir = paths.pluginInstallDir(id)
            do {
                try commitInstall(stagingDir: stagingDir, finalDir: finalDir)
            } catch {
                try? FileManager.default.removeItem(at: stagingDir)
                return .failure(.treeValidationFailed("commit failed: \(error)"))
            }

            // Steps 6–9: register, persist, and enable (all @MainActor).
            // Step 6: register the sidecar.
            await MainActor.run {
                registry.registerSidecar(manifest: manifest, root: finalDir, source: .url)
                // Step 7: persist registry.json (best-effort).
                persistRegistry(registry: registry, paths: paths)
            }

            // Step 8: enable the plugin (registry.enable is @MainActor async).
            let host = await makeHost(id)
            let env = await makeEnv(id)
            await registry.enable(id, host: host, env: env)

            // Step 9: if init failed, report failure but leave files for retry.
            if let failure = await MainActor.run(body: { registry.failedInit[id] }) {
                return .failure(.enableFailed(failure))
            }
            return .success(.installed(id: id))
        }

        // MARK: - Local zip install

        /// Read just the `plugin.json` member at the archive root of a local zip
        /// bundle (without extracting it), decode it, and build `TrustDetails`.
        ///
        /// Used by the "Install from Zip…" flow to populate the trust prompt before
        /// anything is written to disk. The manifest must live at the archive root
        /// (same convention as a URL-distributed bundle).
        ///
        /// - Throws:
        ///   - `InstallError.treeValidationFailed` if `plugin.json` is missing from
        ///     the archive root or the archive can't be read.
        ///   - `InstallError.manifestTooLarge` if the manifest exceeds 1 MiB.
        ///   - `InstallError.invalidSchema` if it can't be decoded or
        ///     `schema_version != 1`.
        ///   - `InstallError.invalidID` if `sanitize(id:)` rejects the id.
        public static func peekZipManifest(zip: URL) throws -> (PluginManifest, TrustDetails) {
            // Stream `plugin.json` to stdout without extracting the whole archive.
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzip.arguments = ["-p", zip.path, "plugin.json"]
            let outPipe = Pipe()
            unzip.standardOutput = outPipe
            // stderr is unused; route it to /dev/null so a chatty archive can't
            // fill an unread pipe buffer and deadlock `waitUntilExit()`.
            unzip.standardError = FileHandle.nullDevice

            do {
                try unzip.run()
            } catch {
                throw InstallError.treeValidationFailed("could not read zip: \(error)")
            }
            // Read the manifest in bounded 64 KiB chunks, enforcing the same 1 MiB
            // cap as the remote fetch *mid-stream* so a crafted archive can't balloon
            // memory before the cap check (matches the streaming guarantee).
            let readHandle = outPipe.fileHandleForReading
            var data = Data()
            do {
                while let chunk = try readHandle.read(upToCount: 65_536), !chunk.isEmpty {
                    data.append(chunk)
                    if data.count > manifestSizeCap {
                        unzip.terminate()
                        unzip.waitUntilExit()
                        throw InstallError.manifestTooLarge
                    }
                }
            } catch let error as InstallError {
                throw error
            } catch {
                unzip.waitUntilExit()
                throw InstallError.treeValidationFailed("could not read plugin.json: \(error)")
            }
            unzip.waitUntilExit()

            guard !data.isEmpty else {
                throw InstallError.treeValidationFailed("plugin.json missing from bundle root")
            }

            let manifest: PluginManifest
            do {
                manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
            } catch {
                throw InstallError.invalidSchema
            }
            guard manifest.schemaVersion == 1 else {
                throw InstallError.invalidSchema
            }
            guard sanitize(id: manifest.id) != nil else {
                throw InstallError.invalidID
            }

            // For a local file there's no remote source/integrity pin: surface the
            // file URL as both the source and "bundle", the on-disk size, and no
            // SHA-256 (integrity pinning is moot for a local file the user chose).
            let sizeBytes = (try? FileManager.default
                .attributesOfItem(atPath: zip.path)[.size] as? Int) ?? nil
            let trust = TrustDetails(
                id: manifest.id,
                displayName: manifest.displayName,
                version: manifest.version,
                publisher: manifest.publisher,
                sourceURL: zip,
                bundleURL: zip,
                bundleSHA256: nil,
                bundleSizeBytes: sizeBytes
            )
            return (manifest, trust)
        }

        /// Install a plugin from a local `.zip` bundle the user selected.
        ///
        /// This is the URL flow (§12–14) minus the network steps: there is no HTTPS
        /// fetch and no SHA-256 download verification — the archive is already on
        /// disk. The zip is unpacked (zip-slip-hardened), tree-validated, atomically
        /// committed, registered (as `.folder`, matching what folder-drop discovery
        /// would assign on the next launch), and enabled.
        ///
        /// When `trustConfirmed == false`, only the manifest is peeked and
        /// `.success(.needsTrust)` is returned so the caller can present the trust
        /// prompt — nothing is written to disk.
        public static func installFromZip(
            zip: URL,
            trustConfirmed: Bool,
            registry: PluginRegistry,
            paths: GallagerPaths,
            makeHost: @MainActor (String) -> any PluginHost,
            makeEnv: @MainActor (String) -> PluginEnv
        ) async -> Result<InstallOutcome, InstallError> {
            // Step 1: peek the manifest (validates schema / id) for the trust gate.
            let manifest: PluginManifest
            let trust: TrustDetails
            do {
                (manifest, trust) = try peekZipManifest(zip: zip)
            } catch let err as InstallError {
                return .failure(err)
            } catch {
                return .failure(.invalidSchema)
            }

            // Trust gate: nothing is written to disk until the user confirms.
            guard trustConfirmed else {
                return .success(.needsTrust(trust))
            }

            // Only sidecar plugins can be installed from a zip.
            guard manifest.runtime == .sidecar else {
                return .failure(.invalidSchema)
            }

            let id = manifest.id
            paths.ensurePluginsDir()

            // Step 2: unpack + validate into the staging directory.
            let stagingDir = paths.pluginStagingDir(id)
            try? FileManager.default.removeItem(at: stagingDir)
            do {
                try FileManager.default.createDirectory(
                    at: stagingDir,
                    withIntermediateDirectories: true
                )
                try unpackAndValidate(zip: zip, stagingDir: stagingDir, manifest: manifest)
            } catch let err as InstallError {
                try? FileManager.default.removeItem(at: stagingDir)
                return .failure(err)
            } catch {
                try? FileManager.default.removeItem(at: stagingDir)
                return .failure(.treeValidationFailed(String(describing: error)))
            }

            // Step 3: atomic commit staging → final.
            let finalDir = paths.pluginInstallDir(id)
            do {
                try commitInstall(stagingDir: stagingDir, finalDir: finalDir)
            } catch {
                try? FileManager.default.removeItem(at: stagingDir)
                return .failure(.treeValidationFailed("commit failed: \(error)"))
            }

            // Steps 4–6: register (as .folder), persist, enable (all @MainActor).
            await MainActor.run {
                registry.registerSidecar(manifest: manifest, root: finalDir, source: .folder)
                persistRegistry(registry: registry, paths: paths)
            }

            let host = await makeHost(id)
            let env = await makeEnv(id)
            await registry.enable(id, host: host, env: env)

            if let failure = await MainActor.run(body: { registry.failedInit[id] }) {
                return .failure(.enableFailed(failure))
            }
            return .success(.installed(id: id))
        }

        /// Remove an installed (non-bundled) plugin.
        ///
        /// - Calls `core.uninstall(configRoot: nil)` best-effort (e.g. removes the
        ///   hook file from `~/.claude/`).
        /// - `registry.disable(id)` — shuts down the core.
        /// - Deletes `paths.pluginInstallDir(id)`.
        /// - If `deleteState`, also deletes `paths.pluginStateDir(id)`.
        /// - Rewrites `registry.json` without the entry.
        ///
        /// Refuses to remove bundled plugins (returns `.failure`).
        public static func remove(
            id: String,
            deleteState: Bool,
            registry: PluginRegistry,
            paths: GallagerPaths
        ) async -> Result<Void, InstallError> {
            // Check registration and source on the MainActor.
            let checkResult: Result<Void, InstallError> = await MainActor.run {
                // Not registered at all → refuse.
                guard registry.isRegistered(id) else {
                    return .failure(.notInstalled)
                }
                // Bundled plugins (source == "bundled" or in factory table but not sidecar) → refuse.
                let sourceStr = registry.listEntries().first(where: { $0.id == id })?.source
                if sourceStr == "bundled" {
                    return .failure(.notInstalled)
                }
                // Not in listEntries at all (unknown id that somehow passed isRegistered) → refuse.
                if sourceStr == nil {
                    return .failure(.notInstalled)
                }
                return .success(())
            }
            if case .failure = checkResult { return checkResult }

            // Best-effort uninstall via the core (removes hook files etc.)
            if let core = await MainActor.run(body: { registry.core(id) }) {
                try? await core.uninstall(configRoot: nil)
            }

            // Disable (shuts down the core).
            await registry.disable(id)

            // Fully unregister so it disappears from registeredIDs (the Agents
            // picker) immediately — disable() only stops the core, it leaves the
            // manifest/source registration in place until the next launch.
            await registry.unregisterSidecar(id)

            // Delete the install directory.
            let installDir = paths.pluginInstallDir(id)
            try? FileManager.default.removeItem(at: installDir)

            // Optionally delete the state directory.
            if deleteState {
                let stateDir = paths.pluginStateDir(id)
                try? FileManager.default.removeItem(at: stateDir)
            }

            // Rewrite registry.json without this entry.
            await MainActor.run {
                persistRegistryExcluding(id: id, registry: registry, paths: paths)
            }

            return .success(())
        }

        // MARK: - Registry persistence helpers

        /// Persist the current registry state to disk. Best-effort; never traps.
        @MainActor
        static func persistRegistry(registry: PluginRegistry, paths: GallagerPaths) {
            let cliEntries = registry.listEntries()
            let entries = cliEntries.compactMap { cliEntry -> PluginRegistryEntry? in
                guard let manifest = registry.manifest(cliEntry.id) else { return nil }
                let source = PluginRegistryEntry.Source(rawValue: cliEntry.source) ?? .bundled
                return PluginRegistryEntry(
                    id: cliEntry.id,
                    version: cliEntry.version,
                    source: source,
                    runtime: manifest.runtime,
                    enabled: cliEntry.enabled,
                    manifestURL: manifest.manifestURL,
                    bundleURL: manifest.bundleURL,
                    bundleSHA256: manifest.bundleSHA256
                )
            }
            let registryFile = PluginRegistryFile(schemaVersion: 1, plugins: entries)
            try? PluginRegistryStore.save(registryFile, to: paths.registryPath)
        }

        /// Persist the registry to disk, omitting the entry for `id`. Best-effort.
        @MainActor
        static func persistRegistryExcluding(id: String, registry: PluginRegistry, paths: GallagerPaths) {
            let cliEntries = registry.listEntries().filter { $0.id != id }
            let entries = cliEntries.compactMap { cliEntry -> PluginRegistryEntry? in
                guard let manifest = registry.manifest(cliEntry.id) else { return nil }
                let source = PluginRegistryEntry.Source(rawValue: cliEntry.source) ?? .bundled
                return PluginRegistryEntry(
                    id: cliEntry.id,
                    version: cliEntry.version,
                    source: source,
                    runtime: manifest.runtime,
                    enabled: cliEntry.enabled,
                    manifestURL: manifest.manifestURL,
                    bundleURL: manifest.bundleURL,
                    bundleSHA256: manifest.bundleSHA256
                )
            }
            let registryFile = PluginRegistryFile(schemaVersion: 1, plugins: entries)
            try? PluginRegistryStore.save(registryFile, to: paths.registryPath)
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
