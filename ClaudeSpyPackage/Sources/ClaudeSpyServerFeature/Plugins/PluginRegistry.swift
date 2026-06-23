#if os(macOS)
    import ClaudeCodePluginCore
    import ClaudeSpyNetworking
    import CodexPluginCore
    import Foundation
    import GallagerPluginProtocol
    import Logging

    /// Owns the agent-blind plugin runtime's compile-time factory table, the
    /// bundled manifests, and the enabled-core lifecycle (spec §4.1). This is the
    /// **only** place in the runtime that names concrete core types — everything
    /// downstream touches `any PluginCore` / `PluginHost`.
    ///
    /// `@MainActor` so its mutable `active`/`failedInit` maps are isolated; the
    /// cores it holds are actors and the hosts/dispatcher it hands them are
    /// `Sendable`, so cross-actor calls stay safe.
    @MainActor
    final public class PluginRegistry {
        private let logger = Logger(label: "com.claudespy.plugin-registry")

        /// Compile-time table: id → core factory. Adding a bundled agent edits
        /// **only** this table (spec §4.1). The `echo` reference core is added in
        /// Debug/E2E builds only — it never ships in Release.
        private let factories: [String: @Sendable () -> any PluginCore]

        /// Bundled manifests, keyed by id, loaded once at construction.
        public private(set) var manifests: [String: PluginManifest]

        /// Plugin root URL per id (where `plugin.json` + assets live), used to read
        /// the icon for presentations. `let` for bundled; extended via `registerSidecar`.
        private var pluginRoots: [String: URL]

        /// Per-plugin install source (bundled/url/folder). Bundled plugins carry an
        /// implicit `.bundled` not stored here; only sidecar registrations write it.
        private var sources: [String: PluginRegistryEntry.Source] = [:]

        /// Gallager paths needed to build `PluginRootLayout` for sidecar cores.
        /// Set once at startup via `attachPaths(_:)` before any sidecar is enabled.
        private var paths: GallagerPaths?

        /// Enabled + successfully-initialized cores, keyed by id.
        public private(set) var active: [String: any PluginCore] = [:]

        /// Most recent failed-init error per id (surfaced in Settings; spec §11).
        public private(set) var failedInit: [String: String] = [:]

        // MARK: - Initialization

        /// - Parameter bundle: where the bundled `plugins/<id>/plugin.json` tree
        ///   lives. `nil` (the default) resolves to `Bundle.module` (the
        ///   ServerFeature resource bundle); tests can pass a different bundle. The
        ///   default is `nil` rather than `.module` because `Bundle.module` is
        ///   module-internal and cannot appear in a default argument value.
        public init(bundle: Bundle? = nil) {
            let bundle = bundle ?? .module
            var factories: [String: @Sendable () -> any PluginCore] = [
                ClaudeCodePluginCore.pluginID: { ClaudeCodePluginCore() },
                CodexPluginCore.pluginID: { CodexPluginCore() },
            ]
            #if DEBUG
                // Reference core for contract/E2E tests; not shipped in Release.
                factories[EchoPluginCore.pluginID] = { EchoPluginCore() }
            #endif
            self.factories = factories

            var manifests: [String: PluginManifest] = [:]
            var roots: [String: URL] = [:]
            for id in factories.keys {
                guard let root = Self.pluginRoot(for: id, in: bundle) else {
                    // Tolerate a missing bundle (e.g. echo ships no manifest) —
                    // skip it; the registry simply can't enable it.
                    continue
                }
                do {
                    let manifest = try PluginManifest.load(fromPluginRoot: root)
                    manifests[id] = manifest
                    roots[id] = root
                } catch {
                    Logger(label: "com.claudespy.plugin-registry")
                        .warning("Skipping plugin '\(id)': failed to load manifest: \(error)")
                }
            }
            self.manifests = manifests
            self.pluginRoots = roots
        }

        // MARK: - Sidecar registration

        /// Store the Gallager paths needed to build `PluginRootLayout` for sidecar
        /// cores. Call once at startup before enabling any sidecar plugin.
        public func attachPaths(_ paths: GallagerPaths) {
            self.paths = paths
        }

        /// Register a runtime-discovered sidecar manifest (url/folder install
        /// channel). Adds the manifest and root so `makeCore`/`enable`/`listEntries`
        /// all see it. `source` is surfaced by `listEntries()`.
        public func registerSidecar(
            manifest: PluginManifest,
            root: URL,
            source: PluginRegistryEntry.Source
        ) {
            manifests[manifest.id] = manifest
            pluginRoots[manifest.id] = root
            sources[manifest.id] = source
        }

        // MARK: - Manifest accessors (for pane detection, spec §6)

        /// Process names for an enabled plugin's pane detection, keyed by id.
        public var processNamesByPlugin: [String: [String]] {
            manifests.mapValues(\.processNames)
        }

        /// The plugin root for an id, if it has a loaded manifest.
        public func pluginRoot(_ id: String) -> URL? {
            pluginRoots[id]
        }

        // MARK: - Core construction

        /// Construct (but do not initialize) a core for `id`, switching on the
        /// manifest `runtime`. In-process conformers use the factory table; sidecar
        /// conformers are built from `PluginRootLayout` + `SidecarSupervisor`.
        /// Returns `nil` for an unknown id or when required config is missing.
        public func makeCore(_ id: String) -> (any PluginCore)? {
            // A missing manifest defaults to in-process (the factory table is the
            // source of truth for compiled-in cores).
            let runtime = manifests[id]?.runtime ?? .inProcess
            switch runtime {
            case .inProcess:
                guard let factory = factories[id] else { return nil }
                return factory()
            case .sidecar:
                guard let manifest = manifests[id], let root = pluginRoots[id], let paths else {
                    logger.warning(
                        "Cannot construct sidecar '\(id)': missing manifest/root/paths"
                    )
                    return nil
                }
                let layout = PluginRootLayout(
                    pluginRoot: root,
                    stateDir: paths.pluginStateDir(id),
                    logDir: paths.pluginLogPath(id).deletingLastPathComponent(),
                    ingressSocketPath: paths.ingressSocketPath.path,
                    appVersion: VersionCompatibility.currentAppVersion
                )
                let supervisor = SidecarSupervisor(manifest: manifest, layout: layout)
                return SidecarPluginCore(manifest: manifest, layout: layout, supervisor: supervisor)
            }
        }

        // MARK: - Enable / disable lifecycle

        /// Construct + `initialize` the core for `id`. On a thrown error the core is
        /// left disabled and the error recorded in `failedInit` (spec §11).
        public func enable(_ id: String, host: any PluginHost, env: PluginEnv) async {
            guard active[id] == nil else { return }
            guard let core = makeCore(id) else {
                failedInit[id] = "No core registered for plugin '\(id)'"
                return
            }
            do {
                try await core.initialize(env, host: host)
                active[id] = core
                failedInit[id] = nil
            } catch {
                failedInit[id] = String(describing: error)
                logger.error("Plugin '\(id)' failed to initialize: \(error)")
            }
        }

        /// `shutdown()` the core for `id` and remove it from `active`.
        public func disable(_ id: String) async {
            guard let core = active.removeValue(forKey: id) else { return }
            await core.shutdown()
        }

        /// The core for `id`, if enabled (used by the ingress router).
        public func core(_ id: String) -> (any PluginCore)? {
            active[id]
        }

        // MARK: - CLI accessors (spec §14)

        /// One row of `gallager plugin list`. `source` reflects the install channel:
        /// `"bundled"` for factory-table entries, or the `rawValue` of the
        /// `PluginRegistryEntry.Source` recorded at `registerSidecar` time.
        public struct CLIEntry: Sendable, Equatable {
            public let id: String
            public let version: String
            public let enabled: Bool
            public let source: String

            public init(id: String, version: String, enabled: Bool, source: String) {
                self.id = id
                self.version = version
                self.enabled = enabled
                self.source = source
            }
        }

        /// Every registered plugin (one row per factory-table entry plus any
        /// runtime-registered sidecar), sorted by id for stable output. `version`
        /// comes from the manifest when present (a factory-only plugin with no
        /// manifest, e.g. `echo`, reports `""`). `source` is `"bundled"` for
        /// factory-table entries and the `PluginRegistryEntry.Source.rawValue` for
        /// sidecar entries registered via `registerSidecar`.
        public func listEntries() -> [CLIEntry] {
            // Union of factory ids and sidecar-registered ids, sorted.
            let allIDs = Set(factories.keys).union(sources.keys).sorted()
            return allIDs.map { id in
                CLIEntry(
                    id: id,
                    version: manifests[id]?.version ?? "",
                    enabled: active[id] != nil,
                    source: sources[id]?.rawValue ?? "bundled"
                )
            }
        }

        /// All registered plugin ids (factory-table keys plus runtime-registered
        /// sidecar ids), sorted.
        public var registeredIDs: [String] {
            Set(factories.keys).union(sources.keys).sorted()
        }

        /// Whether `id` is a registered plugin — either has a factory (in-process)
        /// or was registered as a sidecar via `registerSidecar`.
        public func isRegistered(_ id: String) -> Bool {
            factories[id] != nil || manifests[id]?.runtime == .sidecar
        }

        /// Whether `id` is currently enabled (constructed + initialized).
        public func isEnabled(_ id: String) -> Bool {
            active[id] != nil
        }

        /// The manifest for `id`, if one was loaded.
        public func manifest(_ id: String) -> PluginManifest? {
            manifests[id]
        }

        /// The most recent failed-init error for `id`, if any (spec §11).
        public func failedInitError(_ id: String) -> String? {
            failedInit[id]
        }

        /// Outcome of a `gallager plugin call` core-method dispatch.
        public enum CallOutcome: Sendable, Equatable {
            /// The method ran; `result` is a human/JSON-friendly status string.
            case ok(result: String)
            /// The core is not enabled, so no method could run.
            case notEnabled
            /// The method name isn't one this dispatcher routes.
            case unknownMethod(String)
            /// The core method threw; carries its description.
            case failed(String)
        }

        /// Direct debugging dispatch into the in-process core (spec §14
        /// `plugin call`). Routes the **core-only** methods that need no host/env
        /// (`refreshProjects`, `installStatus`, `install`, `uninstall`); the
        /// lifecycle verbs `enable`/`disable` are handled by the caller (they
        /// require the app-built host/env). Returns `.notEnabled` when no active
        /// core exists for `id`.
        public func callCore(_ id: String, method: String, configRoot: String? = nil) async -> CallOutcome {
            guard let core = active[id] else { return .notEnabled }
            switch method {
            case "refreshProjects":
                await core.refreshProjects()
                return .ok(result: "refreshed")
            case "installStatus":
                let status = await core.installStatus(configRoot: configRoot)
                return .ok(result: Self.describe(status))
            case "install":
                do {
                    let result = try await core.install(configRoot: configRoot)
                    switch result {
                    case let .installed(message): return .ok(result: message)
                    case .alreadyInstalled: return .ok(result: "already-installed")
                    }
                } catch {
                    return .failed(String(describing: error))
                }
            case "uninstall":
                do {
                    try await core.uninstall(configRoot: configRoot)
                    return .ok(result: "uninstalled")
                } catch {
                    return .failed(String(describing: error))
                }
            default:
                // Spec §10: for sidecar cores, forward arbitrary method strings over
                // the sidecar transport rather than refusing with .unknownMethod.
                // In-process cores (not SidecarPluginCore) still return .unknownMethod.
                if let sidecar = core as? SidecarPluginCore {
                    do {
                        let result = try await sidecar.callRPC(method, params: nil)
                        switch result {
                        case let .string(s): return .ok(result: s)
                        case let .int(i): return .ok(result: String(i))
                        case let .bool(b): return .ok(result: String(b))
                        default:
                            // Encode non-primitive result as JSON string.
                            if
                                let data = try? JSONEncoder().encode(result),
                                let str = String(data: data, encoding: .utf8) {
                                return .ok(result: str)
                            }
                            return .ok(result: "ok")
                        }
                    } catch {
                        return .failed(String(describing: error))
                    }
                }
                return .unknownMethod(method)
            }
        }

        /// Render an install status as the human/JSON-friendly string surfaced by
        /// `plugin call installStatus` (debugging output, not parsed by the app).
        private static func describe(_ status: PluginInstallStatus) -> String {
            switch status {
            case let .installed(version): "installed\(version.map { " v\($0)" } ?? "")"
            case .notInstalled: "not-installed"
            case .agentUnavailable: "agent-unavailable"
            }
        }

        // MARK: - Presentation

        /// The complete enabled-plugin presentation set for iOS (spec §7.2). Built
        /// from each enabled plugin's manifest; `iconB64` is the base64 of the
        /// manifest's `ui.icon` file under the plugin root when present.
        public func presentations() -> [PluginPresentation] {
            active.keys.compactMap { id in
                guard let manifest = manifests[id] else { return nil }
                return PluginPresentationBuilder.make(
                    manifest: manifest,
                    pluginRoot: pluginRoots[id]
                )
            }
        }

        // MARK: - Bundle lookup

        /// Resolve the directory holding `<id>/plugin.json` inside `bundle`. The
        /// ServerFeature target bundles `PluginBundles/plugins` via `.copy`, so the
        /// resource lands at `plugins/<id>/plugin.json` in `Bundle.module`.
        private static func pluginRoot(for id: String, in bundle: Bundle) -> URL? {
            if
                let url = bundle.url(
                    forResource: "plugin",
                    withExtension: "json",
                    subdirectory: "plugins/\(id)"
                ) {
                return url.deletingLastPathComponent()
            }
            // Fallback: locate the `plugins` directory and append the id.
            if let pluginsDir = bundle.url(forResource: "plugins", withExtension: nil) {
                let candidate = pluginsDir.appendingPathComponent(id, isDirectory: true)
                if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("plugin.json").path) {
                    return candidate
                }
            }
            return nil
        }
    }

    // MARK: - PluginPresentationBuilder

    /// Builds a `PluginPresentation` from a manifest + plugin root (spec §7.2/§10).
    /// Kept as a tiny pure helper so both the registry and tests can reuse it.
    public enum PluginPresentationBuilder {
        public static func make(manifest: PluginManifest, pluginRoot: URL?) -> PluginPresentation {
            PluginPresentation(
                id: manifest.id,
                version: manifest.version,
                displayName: manifest.displayName,
                shortName: manifest.shortName,
                color: manifest.color,
                iconB64: iconBase64(manifest: manifest, pluginRoot: pluginRoot)
            )
        }

        /// Base64 of the manifest's `ui.icon` file under `pluginRoot`, or `nil` when
        /// absent / unreadable. Trap-free.
        private static func iconBase64(manifest: PluginManifest, pluginRoot: URL?) -> String? {
            guard
                let iconRelativePath = manifest.ui.icon,
                let pluginRoot
            else {
                return nil
            }
            let iconURL = pluginRoot.appendingPathComponent(iconRelativePath)
            guard let data = try? Data(contentsOf: iconURL) else { return nil }
            return data.base64EncodedString()
        }
    }
#endif
