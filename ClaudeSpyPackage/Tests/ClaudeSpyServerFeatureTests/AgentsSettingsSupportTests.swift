#if os(macOS)
    import ClaudeSpyCommon
    import ClaudeSpyEncryption
    import Dependencies
    import Foundation
    import GallagerPluginProtocol
    import Testing
    @testable import ClaudeSpyServerFeature

    @Suite("AgentsSettingsSupport")
    @MainActor
    struct AgentsSettingsSupportTests {
        // MARK: - Helpers

        /// Builds a fresh temp-dir `GallagerPaths` and injects it into a new
        /// `AppCoordinator` so settings read/write goes to an isolated directory.
        private func makeCoordinator() -> (coordinator: AppCoordinator, root: URL) {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("gallager-agents-settings-\(UUID().uuidString)")
                .appendingPathComponent("state")
            let paths = GallagerPaths(stateRootOverride: root)
            paths.ensureBaseDirectories()

            let coordinator = withDependencies {
                $0[PreferencesService.self] = .inMemory()
                $0[SecretsService.self] = .inMemory()
            } operation: {
                AppCoordinator()
            }
            coordinator.gallagerPaths = paths
            return (coordinator, root)
        }

        // MARK: - Settings round-trip

        @Test("pluginSettingsData returns empty data when no file exists yet")
        func settingsDataEmptyBeforeWrite() {
            let (coordinator, root) = makeCoordinator()
            defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

            let data = coordinator.pluginSettingsData(id: "claude-code")
            #expect(data.isEmpty)
        }

        @Test("setPluginSettings persists bytes that pluginSettingsData reads back verbatim")
        func settingsRoundTrip() async throws {
            let (coordinator, root) = makeCoordinator()
            defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

            let payload = Data(#"{"commandPath":"/usr/local/bin/claude","autoRun":true}"#.utf8)
            let error = await coordinator.setPluginSettings(id: "claude-code", payload)
            #expect(error == nil)

            let readBack = coordinator.pluginSettingsData(id: "claude-code")
            #expect(readBack == payload)
        }

        @Test("setPluginSettings surfaces an error when plugin state is not initialised")
        func settingsErrorWithoutPaths() async {
            // A coordinator with no injected gallagerPaths must surface a failure
            // instead of silently swallowing the write (which would leave the live
            // core diverged from disk).
            let coordinator = withDependencies {
                $0[PreferencesService.self] = .inMemory()
                $0[SecretsService.self] = .inMemory()
            } operation: {
                AppCoordinator()
            }

            let error = await coordinator.setPluginSettings(id: "claude-code", Data("{}".utf8))
            #expect(error != nil)
        }

        @Test("setPluginSettings overwrites an existing file")
        func settingsOverwrite() async throws {
            let (coordinator, root) = makeCoordinator()
            defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

            let first = Data(#"{"commandPath":"/v1","autoRun":false}"#.utf8)
            let second = Data(#"{"commandPath":"/v2","autoRun":true}"#.utf8)

            await coordinator.setPluginSettings(id: "codex", first)
            await coordinator.setPluginSettings(id: "codex", second)

            let readBack = coordinator.pluginSettingsData(id: "codex")
            #expect(readBack == second)
        }

        // MARK: - agentPluginList

        @Test("agentPluginList returns empty when registry is not initialised")
        func agentPluginListNoRegistry() {
            let (coordinator, root) = makeCoordinator()
            defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

            // pluginRegistry is nil until setupAllServices() runs; list must be empty.
            let list = coordinator.agentPluginList()
            #expect(list.isEmpty)
        }

        @Test("agentPluginList excludes echo and maps displayName from the manifest")
        func agentPluginListExcludesEcho() {
            let (coordinator, root) = makeCoordinator()
            defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

            // Inject a live registry (no cores enabled — list only needs manifests).
            let registry = PluginRegistry()
            coordinator.pluginRegistry = registry

            let list: [AppCoordinator.AgentPluginEntry] = coordinator.agentPluginList()

            // echo is DEBUG-registered but must be filtered out.
            #expect(!list.contains(where: { $0.id == EchoPluginCore.pluginID }))

            // claude-code and codex are always registered; check both are present.
            let ids = list.map(\.id)
            #expect(ids.contains("claude-code"))
            #expect(ids.contains("codex"))

            // IDs must be sorted (registeredIDs is sorted; filter preserves order).
            #expect(ids == ids.sorted())

            // Names come from the manifest's displayName field.
            let claudeRow = list.first { $0.id == "claude-code" }
            #expect(claudeRow?.name == "Claude Code")
        }
    }
#endif
