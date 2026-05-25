import Foundation

// MARK: - PluginManifest

/// On-disk manifest for a Gallager plugin (Spec §5).
///
/// Wire-format requirement: serialization MUST use a `JSONEncoder` with
/// `keyEncodingStrategy = .convertToSnakeCase` (and decoder with
/// `keyDecodingStrategy = .convertFromSnakeCase`). All field names are
/// camelCase here and map to snake_case on the wire via the strategy.
public struct PluginManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let id: String
    public let displayName: String
    public let shortName: String
    public let version: String
    public let publisher: String
    public let manifestURL: URL
    public let bundleSHA256: String?
    public let runtime: Runtime
    public let sidecar: SidecarSpec
    public let capabilities: Capabilities
    public let processNames: [String]
    public let ui: UI

    public init(
        schemaVersion: Int,
        id: String,
        displayName: String,
        shortName: String,
        version: String,
        publisher: String,
        manifestURL: URL,
        bundleSHA256: String?,
        runtime: Runtime,
        sidecar: SidecarSpec,
        capabilities: Capabilities,
        processNames: [String],
        ui: UI
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.displayName = displayName
        self.shortName = shortName
        self.version = version
        self.publisher = publisher
        self.manifestURL = manifestURL
        self.bundleSHA256 = bundleSHA256
        self.runtime = runtime
        self.sidecar = sidecar
        self.capabilities = capabilities
        self.processNames = processNames
        self.ui = ui
    }

    // `manifestURL` / `bundleSHA256` would round-trip through
    // `convertFromSnakeCase` as `manifestUrl` / `bundleSha256` — the strategy
    // does its own capitalization and doesn't preserve the multi-letter
    // acronym casing we use in Swift. We patch the keys so the JSON wire
    // name (`manifest_url`, `bundle_sha256`) matches what `convertFromSnakeCase`
    // produces for our chosen raw value.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case displayName
        case shortName
        case version
        case publisher
        case manifestURL = "manifestUrl"
        case bundleSHA256 = "bundleSha256"
        case runtime
        case sidecar
        case capabilities
        case processNames
        case ui
    }

    // MARK: - Runtime

    /// Closed enum for the plugin runtime kind. Currently only `sidecar` is
    /// supported; adding cases here is a coordinated change with the
    /// supervisor in `ClaudeSpyPluginRuntime`.
    public enum Runtime: String, Codable, Sendable, Equatable {
        case sidecar
    }

    // MARK: - SidecarSpec

    /// How to launch the plugin's sidecar process. Paths are relative to
    /// the plugin root (`~/.gallager/plugins/<id>/`).
    public struct SidecarSpec: Codable, Sendable, Equatable {
        public let executable: String
        public let args: [String]

        public init(executable: String, args: [String]) {
            self.executable = executable
            self.args = args
        }
    }

    // MARK: - Capabilities

    /// Bit-field of optional sidecar capabilities. The sidecar's
    /// `initialize` response can further refine this — the manifest just
    /// declares the intent.
    public struct Capabilities: Codable, Sendable, Equatable {
        public let pushesProjects: Bool
        public let translateEvent: Bool
        public let install: Bool
        public let detectPane: Bool
        public let settingsSchema: String?
        /// Opt-in: when `true`, Gallager calls `detect_pane` for every newly-
        /// discovered tmux pane. Defaults to `false` because most plugins
        /// drive their own discovery.
        public let requiresRichDetection: Bool

        public init(
            pushesProjects: Bool,
            translateEvent: Bool,
            install: Bool,
            detectPane: Bool,
            settingsSchema: String?,
            requiresRichDetection: Bool = false
        ) {
            self.pushesProjects = pushesProjects
            self.translateEvent = translateEvent
            self.install = install
            self.detectPane = detectPane
            self.settingsSchema = settingsSchema
            self.requiresRichDetection = requiresRichDetection
        }

        // Custom decoding so `requires_rich_detection` defaults to `false`
        // when absent (per the spec — opt-in).
        private enum CodingKeys: String, CodingKey {
            case pushesProjects
            case translateEvent
            case install
            case detectPane
            case settingsSchema
            case requiresRichDetection
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.pushesProjects = try container.decode(Bool.self, forKey: .pushesProjects)
            self.translateEvent = try container.decode(Bool.self, forKey: .translateEvent)
            self.install = try container.decode(Bool.self, forKey: .install)
            self.detectPane = try container.decode(Bool.self, forKey: .detectPane)
            self.settingsSchema = try container.decodeIfPresent(String.self, forKey: .settingsSchema)
            self.requiresRichDetection =
                try container.decodeIfPresent(Bool.self, forKey: .requiresRichDetection) ?? false
        }
    }

    // MARK: - UI

    /// Plugin presentation paths inside the bundle. `icon` is required;
    /// `iconIOS` is an optional higher-resolution variant forwarded to iOS.
    public struct UI: Codable, Sendable, Equatable {
        public let icon: String
        public let iconIOS: String?

        public init(icon: String, iconIOS: String?) {
            self.icon = icon
            self.iconIOS = iconIOS
        }

        // Custom keys so `iconIOS` round-trips through `convertToSnakeCase`
        // as `icon_ios` (default snake-case conversion would yield `icon_i_o_s`).
        private enum CodingKeys: String, CodingKey {
            case icon
            case iconIOS = "iconIos"
        }
    }

    // MARK: - Validation

    /// Validate fields that aren't expressible at the type system level.
    /// Today: `bundleSHA256` is required when the manifest was downloaded
    /// over `https://` (Spec §5).
    public func validate() throws {
        if manifestURL.scheme?.lowercased() == "https" {
            guard bundleSHA256 != nil else {
                throw PluginManifestError.bundleSHA256RequiredForHTTPS
            }
        }
    }
}

// MARK: - PluginManifestError

/// Errors emitted by `PluginManifest.validate()`.
public enum PluginManifestError: Error, Equatable, Sendable {
    /// An `https://` manifest must declare a `bundle_sha256`; downloads
    /// without a hash are rejected (Spec §5, §9.2).
    case bundleSHA256RequiredForHTTPS
}
