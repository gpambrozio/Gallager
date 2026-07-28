#if os(macOS)
    import Foundation
    import GallagerPluginProtocol

    // MARK: - PluginUpdate

    /// Describes an available update for an installed plugin.
    public struct PluginUpdate: Sendable, Equatable {
        /// The plugin id.
        public let id: String
        /// The currently-installed version string.
        public let currentVersion: String
        /// The newer version string fetched from the manifest.
        public let newVersion: String
        /// `true` when the fetched `bundle_url`'s host differs from the registry
        /// entry's `bundleURL` host (the bundle is now served from a different host).
        public let sourceChanged: Bool

        public init(id: String, currentVersion: String, newVersion: String, sourceChanged: Bool) {
            self.id = id
            self.currentVersion = currentVersion
            self.newVersion = newVersion
            self.sourceChanged = sourceChanged
        }
    }

    // MARK: - PluginUpdateChecker

    /// Checks for available updates for URL-installed sidecar plugins.
    ///
    /// For each registry entry with `source == .url` and a `manifestURL`, the
    /// checker re-fetches the manifest and compares its `version` against the
    /// currently-installed version. If the remote manifest reports a newer version,
    /// a `PluginUpdate` is appended to the result.
    ///
    /// **Note:** `If-None-Match` / `If-Modified-Since` conditional-request headers
    /// are not sent. The checker always performs a plain re-fetch. This is
    /// intentional — conditional request plumbing is not required for correctness
    /// and adds complexity that the current test suite does not exercise.
    ///
    /// This checker NEVER auto-installs. It only reports what is available.
    public enum PluginUpdateChecker {
        /// Check all URL-installed entries for available updates.
        ///
        /// - Parameters:
        ///   - entries: The list of installed registry entries (from `PluginRegistryFile.plugins`).
        ///   - session: HTTP session to use for manifest fetches.
        /// - Returns: One `PluginUpdate` per entry that has a newer version available.
        ///   Entries that fail to fetch (network errors, bad manifests) are silently
        ///   skipped — update-checking is best-effort.
        public static func check(
            _ entries: [PluginRegistryEntry],
            session: any URLSessionProtocol
        ) async -> [PluginUpdate] {
            await checkDetailed(entries, session: session).updates
        }

        /// Like `check`, but also reports whether at least one manifest fetch
        /// actually completed. From `check` alone, a pass where every fetch
        /// failed (offline, DNS down) is indistinguishable from "everything is
        /// up to date" — callers that stamp a last-checked timestamp need the
        /// difference.
        public static func checkDetailed(
            _ entries: [PluginRegistryEntry],
            session: any URLSessionProtocol
        ) async -> (updates: [PluginUpdate], anyFetchSucceeded: Bool) {
            var updates: [PluginUpdate] = []
            var anyFetchSucceeded = false

            for entry in entries {
                // Mirror checkOne's own eligibility guard so a skipped entry
                // (bundled/folder source) doesn't count as a successful fetch.
                guard entry.source == .url, entry.manifestURL != nil else { continue }
                do {
                    if let update = try await checkOne(entry, session: session) {
                        updates.append(update)
                    }
                    anyFetchSucceeded = true
                } catch {
                    continue
                }
            }

            return (updates, anyFetchSucceeded)
        }

        /// Check a single entry, propagating fetch/decode errors (the manual
        /// Check Now path surfaces them inline; the batch `check` stays
        /// best-effort). Returns nil for non-URL entries and when already up to
        /// date.
        public static func checkOne(
            _ entry: PluginRegistryEntry,
            session: any URLSessionProtocol
        ) async throws -> PluginUpdate? {
            guard entry.source == .url, let manifestURL = entry.manifestURL else { return nil }
            let (fetched, _) = try await PluginInstaller.fetchManifest(manifestURL, session: session)
            guard isNewer(fetched.version, than: entry.version) else { return nil }
            let sourceChanged = bundleHostChanged(
                existingBundleURL: entry.bundleURL,
                fetchedBundleURL: fetched.bundleURL
            )
            return PluginUpdate(
                id: entry.id,
                currentVersion: entry.version,
                newVersion: fetched.version,
                sourceChanged: sourceChanged
            )
        }

        // MARK: - Version comparison

        /// Returns `true` when `candidate` is semantically newer than `installed`.
        ///
        /// Compares by splitting on `.` and comparing each numeric component. Falls
        /// back to plain string comparison when components are non-numeric so that
        /// odd pre-release tags at least produce a deterministic (if imperfect)
        /// answer. Equal versions return `false`.
        static func isNewer(_ candidate: String, than installed: String) -> Bool {
            let candidateParts = candidate.split(separator: ".", omittingEmptySubsequences: false)
                .map(String.init)
            let installedParts = installed.split(separator: ".", omittingEmptySubsequences: false)
                .map(String.init)

            let maxLen = max(candidateParts.count, installedParts.count)
            for i in 0..<maxLen {
                let candidatePart = i < candidateParts.count ? candidateParts[i] : "0"
                let installedPart = i < installedParts.count ? installedParts[i] : "0"

                if let c = Int(candidatePart), let s = Int(installedPart) {
                    if c > s { return true }
                    if c < s { return false }
                } else {
                    // Non-numeric: fall back to string comparison.
                    if candidatePart > installedPart { return true }
                    if candidatePart < installedPart { return false }
                }
            }
            // Equal versions.
            return false
        }

        /// Returns `true` when the `bundleURL` host in the fetched manifest differs
        /// from the host recorded in the registry entry. `nil` bundle URLs produce
        /// `false` (no host to compare).
        static func bundleHostChanged(existingBundleURL: URL?, fetchedBundleURL: URL?) -> Bool {
            guard let existing = existingBundleURL?.host, let fetched = fetchedBundleURL?.host else {
                return false
            }
            return existing != fetched
        }
    }
#endif
