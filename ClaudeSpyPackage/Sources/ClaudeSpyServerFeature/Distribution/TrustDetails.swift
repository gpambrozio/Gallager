#if os(macOS)
    import Foundation

    /// Metadata gathered from a remote manifest fetch. Presented to the user
    /// during the plugin install confirmation flow (spec §12).
    ///
    /// `bundleSizeBytes` and `bundleSHA256` are `nil` immediately after
    /// `fetchManifest` returns; they are filled in once the bundle is downloaded
    /// in the Task-13 flow.
    public struct TrustDetails: Sendable, Equatable {
        public let id: String
        public let displayName: String
        public let version: String
        public let publisher: String?
        /// The HTTPS URL from which the manifest was fetched.
        public let sourceURL: URL
        /// The HTTPS URL of the plugin bundle, if declared in the manifest.
        public let bundleURL: URL?
        /// Expected SHA-256 hex digest of the bundle archive.
        public let bundleSHA256: String?
        /// Compressed bundle size in bytes (known only after download).
        public let bundleSizeBytes: Int?

        public init(
            id: String,
            displayName: String,
            version: String,
            publisher: String?,
            sourceURL: URL,
            bundleURL: URL?,
            bundleSHA256: String?,
            bundleSizeBytes: Int?
        ) {
            self.id = id
            self.displayName = displayName
            self.version = version
            self.publisher = publisher
            self.sourceURL = sourceURL
            self.bundleURL = bundleURL
            self.bundleSHA256 = bundleSHA256
            self.bundleSizeBytes = bundleSizeBytes
        }
    }
#endif
