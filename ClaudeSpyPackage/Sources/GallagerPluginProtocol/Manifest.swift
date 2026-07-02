import Foundation

// MARK: - PluginManifest (spec §10)

/// The runtime model for a bundled plugin. v1 conformers are always
/// `.inProcess`; the registry switches on `runtime` (v2 adds `.sidecar`).
/// Decoding is tolerant: an absent or `null` `runtime` decodes to `.inProcess`,
/// so v2 introduces no decode-semantics shift at the seam.
public enum Runtime: String, Sendable, Codable {
    case inProcess
    case sidecar
}

/// The minimal v1 manifest. Seeds presentation + pane detection; the remaining
/// reserved fields are v2 forward-compat room the v1 runtime ignores.
public struct PluginManifest: Sendable, Codable, Equatable {
    public let schemaVersion: Int
    public let id: String
    public let displayName: String
    public let shortName: String
    public let version: String
    /// Process names used for pane detection (spec §6).
    public let processNames: [String]
    public let ui: UI
    /// Always `.inProcess` in v1; read (not merely reserved) so v2 needs no
    /// decode change (spec §10).
    public let runtime: Runtime
    public let publisher: String?
    public let manifestURL: URL?
    public let bundleURL: URL?
    public let bundleSHA256: String?
    public let signature: String?
    public let sidecar: Sidecar?
    public let capabilities: Capabilities
    /// OTLP telemetry declaration (issue #617): present when the plugin's agent
    /// exports OTLP log records the host should aggregate into the per-session
    /// token/cost/latency meter. Absent → records in unknown namespaces are
    /// dropped, exactly as before.
    public let otlp: OTLP?

    public struct UI: Sendable, Codable, Equatable {
        /// Relative path to the icon asset under the plugin root (e.g. "assets/icon.png").
        public let icon: String?
        /// Accent color hex; falls back to `#888888` when absent (spec §10).
        public let color: String?

        public init(icon: String?, color: String?) {
            self.icon = icon
            self.color = color
        }
    }

    public struct Sidecar: Sendable, Codable, Equatable {
        public let executable: String
        public let args: [String]
        /// The agent's default config location, shown as the non-removable root
        /// row in the Agents settings tab (e.g. `~/.config/opencode`). When absent
        /// the UI falls back to `~`. Purely presentational — install still passes
        /// `configRoot: nil` for the default row.
        public let defaultConfigRoot: String?

        public init(executable: String, args: [String] = [], defaultConfigRoot: String? = nil) {
            self.executable = executable
            self.args = args
            self.defaultConfigRoot = defaultConfigRoot
        }

        private enum CodingKeys: String, CodingKey {
            case executable
            case args
            case defaultConfigRoot = "default_config_root"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.executable = try container.decode(String.self, forKey: .executable)
            // `args` defaults to empty when absent so manifests can omit it.
            self.args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
            self.defaultConfigRoot = try container.decodeIfPresent(String.self, forKey: .defaultConfigRoot)
        }
    }

    /// Declares the plugin's OTLP event-name namespace so the host's telemetry
    /// accumulator can classify its log records (issue #617). Records named
    /// `<namespace>.<token_event>` must mirror Claude Code's `api_request`
    /// attribute vocabulary (`input_tokens`, `output_tokens`, `cache_read_tokens`,
    /// `cache_creation_tokens`, `cost_usd`, `duration_ms`, `model`) with the
    /// per-message values accumulating by summation, and carry the session join
    /// key in `session.id`.
    public struct OTLP: Sendable, Codable, Equatable {
        /// The event-name namespace, WITHOUT the trailing dot (e.g. `"opencode"`
        /// classifies `opencode.api_request`). The built-in `claude_code` /
        /// `codex` namespaces cannot be claimed; such declarations are ignored.
        public let namespace: String
        /// The namespace-stripped event name carrying the token/latency/model
        /// attributes. Defaults to `"api_request"` (Claude's vocabulary).
        public let tokenEvent: String

        public static let defaultTokenEvent = "api_request"

        public init(namespace: String, tokenEvent: String = OTLP.defaultTokenEvent) {
            self.namespace = namespace
            self.tokenEvent = tokenEvent
        }

        private enum CodingKeys: String, CodingKey {
            case namespace
            case tokenEvent = "token_event"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.namespace = try container.decode(String.self, forKey: .namespace)
            self.tokenEvent = try container.decodeIfPresent(String.self, forKey: .tokenEvent)
                ?? OTLP.defaultTokenEvent
        }
    }

    public struct Capabilities: Sendable, Codable, Equatable {
        public let richPaneDetection: Bool
        public let modalPrompts: Bool
        public init(richPaneDetection: Bool = false, modalPrompts: Bool = false) {
            self.richPaneDetection = richPaneDetection
            self.modalPrompts = modalPrompts
        }

        private enum CodingKeys: String, CodingKey {
            case richPaneDetection = "rich_pane_detection"
            case modalPrompts = "modal_prompts"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.richPaneDetection = try c.decodeIfPresent(Bool.self, forKey: .richPaneDetection) ?? false
            self.modalPrompts = try c.decodeIfPresent(Bool.self, forKey: .modalPrompts) ?? false
        }
    }

    public init(
        schemaVersion: Int,
        id: String,
        displayName: String,
        shortName: String,
        version: String,
        processNames: [String],
        ui: UI,
        runtime: Runtime = .inProcess,
        publisher: String? = nil,
        manifestURL: URL? = nil,
        bundleURL: URL? = nil,
        bundleSHA256: String? = nil,
        signature: String? = nil,
        sidecar: Sidecar? = nil,
        capabilities: Capabilities = Capabilities(),
        otlp: OTLP? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.displayName = displayName
        self.shortName = shortName
        self.version = version
        self.processNames = processNames
        self.ui = ui
        self.runtime = runtime
        self.publisher = publisher
        self.manifestURL = manifestURL
        self.bundleURL = bundleURL
        self.bundleSHA256 = bundleSHA256
        self.signature = signature
        self.sidecar = sidecar
        self.capabilities = capabilities
        self.otlp = otlp
    }

    /// Default accent color when `ui.color` is absent (spec §10).
    public static let fallbackColor = "#888888"

    /// The effective accent color (manifest value or fallback).
    public var color: String {
        ui.color ?? Self.fallbackColor
    }

    /// Snake_case JSON keys per the manifest schema (spec §10).
    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id
        case displayName = "display_name"
        case shortName = "short_name"
        case version
        case processNames = "process_names"
        case ui
        case runtime
        case publisher
        case manifestURL = "manifest_url"
        case bundleURL = "bundle_url"
        case bundleSHA256 = "bundle_sha256"
        case signature
        case sidecar
        case capabilities
        case otlp
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.id = try container.decode(String.self, forKey: .id)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.shortName = try container.decode(String.self, forKey: .shortName)
        self.version = try container.decodeIfPresent(String.self, forKey: .version) ?? "0.0.0"
        self.processNames = try container.decodeIfPresent([String].self, forKey: .processNames) ?? []
        self.ui = try container.decodeIfPresent(UI.self, forKey: .ui) ?? UI(icon: nil, color: nil)
        // Absent or null runtime → inProcess (spec §10).
        self.runtime = try container.decodeIfPresent(Runtime.self, forKey: .runtime) ?? .inProcess
        self.publisher = try container.decodeIfPresent(String.self, forKey: .publisher)
        self.manifestURL = try container.decodeIfPresent(URL.self, forKey: .manifestURL)
        self.bundleURL = try container.decodeIfPresent(URL.self, forKey: .bundleURL)
        self.bundleSHA256 = try container.decodeIfPresent(String.self, forKey: .bundleSHA256)
        self.signature = try container.decodeIfPresent(String.self, forKey: .signature)
        self.sidecar = try container.decodeIfPresent(Sidecar.self, forKey: .sidecar)
        self.capabilities = try container.decodeIfPresent(Capabilities.self, forKey: .capabilities)
            ?? Capabilities()
        self.otlp = try container.decodeIfPresent(OTLP.self, forKey: .otlp)
    }

    /// Load and decode a manifest from `<pluginRoot>/plugin.json`.
    public static func load(fromPluginRoot pluginRoot: URL) throws -> PluginManifest {
        let url = pluginRoot.appendingPathComponent("plugin.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PluginManifest.self, from: data)
    }
}
