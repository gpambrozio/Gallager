#if os(macOS)
    import ClaudeSpyCommon
    import Clocks
    import ConcurrencyExtras
    import Dependencies
    import Foundation
    import GallagerPluginProtocol
    import Testing
    @testable import ClaudeSpyServerFeature

    // MARK: - Harness

    /// Records every callback the manager fires and holds the in-memory registry
    /// file the closures read/write.
    @MainActor
    final class UpdateHarness {
        var registry: PluginRegistryFile
        /// Updates the stub checker reports (filtered to the entries it is given).
        var updates: [PluginUpdate] = []
        /// Plugin ids whose single-entry (manual) check throws.
        var failingChecks: Set<String> = []
        /// Keyed by manifest-URL string; unset URLs succeed.
        var installResults: [String: Result<PluginInstaller.InstallOutcome, InstallError>] = [:]
        var activePlugins: Set<String> = []
        /// id -> set of roots ("default" or the folder path) with the bridge installed.
        var installedRoots: [String: Set<String>] = [:]
        var additionalFolders: [String: [String]] = [:]
        var log: [String] = []
        var notifications: [String] = []

        init(entries: [PluginRegistryEntry]) {
            registry = PluginRegistryFile(schemaVersion: 1, plugins: entries)
        }

        func makeManager(automaticTriggers: Bool = false) -> PluginUpdateManager {
            PluginUpdateManager(
                callbacks: PluginUpdateManager.Callbacks(
                    loadRegistry: { self.registry },
                    saveRegistry: { self.registry = $0 },
                    checkUpdates: { entries in
                        self.log.append("check:\(entries.map(\.id).sorted().joined(separator: ","))")
                        return self.updates.filter { update in entries.contains { $0.id == update.id } }
                    },
                    checkUpdate: { entry in
                        self.log.append("checkOne:\(entry.id)")
                        if self.failingChecks.contains(entry.id) {
                            throw InstallError.invalidSchema
                        }
                        return self.updates.first { $0.id == entry.id }
                    },
                    installFromURL: { url in
                        self.log.append("install:\(url.absoluteString)")
                        return self.installResults[url.absoluteString] ?? .success(.installed(id: "stub"))
                    },
                    hasActiveSessions: { self.activePlugins.contains($0) },
                    disablePlugin: { self.log.append("disable:\($0)") },
                    enablePlugin: { self.log.append("enable:\($0)") },
                    installStatus: { id, root in
                        self.installedRoots[id]?.contains(root ?? "default") == true
                            ? .installed(version: nil)
                            : .notInstalled
                    },
                    installBridge: { id, root in
                        self.log.append("bridge:\(id):\(root ?? "default")")
                        return nil
                    },
                    additionalConfigFolders: { self.additionalFolders[$0] ?? [] },
                    displayName: { $0.capitalized },
                    currentAppVersion: { "2.0.0" },
                    notify: { self.notifications.append($0) }
                ),
                automaticTriggersEnabled: automaticTriggers
            )
        }
    }

    func urlEntry(
        id: String,
        version: String,
        autoUpdate: Bool = true,
        needsBridgeRefresh: Bool = false
    ) -> PluginRegistryEntry {
        PluginRegistryEntry(
            id: id, version: version, source: .url, runtime: .sidecar, enabled: true,
            manifestURL: URL(string: "https://example.com/\(id)/plugin.json"),
            bundleURL: URL(string: "https://cdn.example.com/\(id).zip"),
            bundleSHA256: "abc", autoUpdate: autoUpdate, needsBridgeRefresh: needsBridgeRefresh
        )
    }

    // MARK: - Accessors

    @Suite("PluginUpdateManager accessors")
    @MainActor
    struct PluginUpdateManagerAccessorTests {
        @Test("isUpdatable is true only for url entries with a manifestURL")
        func isUpdatableFiltersSources() throws {
            let folderEntry = PluginRegistryEntry(
                id: "dev", version: "1.0.0", source: .folder, runtime: .sidecar, enabled: true,
                manifestURL: nil, bundleURL: nil, bundleSHA256: nil
            )
            try withDependencies {
                $0[PreferencesService.self] = .inMemory()
            } operation: {
                let harness = UpdateHarness(entries: [urlEntry(id: "pi", version: "1.0.0"), folderEntry])
                let manager = harness.makeManager()
                #expect(manager.isUpdatable("pi") == true)
                #expect(manager.isUpdatable("dev") == false)
                #expect(manager.isUpdatable("missing") == false)
            }
        }

        @Test("setAutoUpdate persists through the registry file")
        func setAutoUpdatePersists() throws {
            try withDependencies {
                $0[PreferencesService.self] = .inMemory()
            } operation: {
                let harness = UpdateHarness(entries: [urlEntry(id: "pi", version: "1.0.0")])
                let manager = harness.makeManager()
                #expect(manager.autoUpdateEnabled("pi") == true)
                manager.setAutoUpdate("pi", enabled: false)
                #expect(manager.autoUpdateEnabled("pi") == false)
                #expect(harness.registry.plugins.first?.autoUpdate == false)
            }
        }
    }
#endif
