#if os(macOS)
    import ClaudeSpyCommon
    import ClaudeSpyEncryption
    import ClaudeSpyNetworking
    import Dependencies
    import Foundation
    import Testing
    @testable import ClaudeSpyServerFeature

    /// Proves the viewer-side presentation sink that
    /// `AppCoordinator.setupViewerConnectionManager` installs via
    /// `wirePresentationSink`: a host's pushed `PluginPresentationsMessage`
    /// lands in the remote `SessionStore`, so a remote project-row agent badge
    /// resolves the plugin's `short_name` ("claude") instead of falling back to
    /// the raw plugin id ("claude-code").
    ///
    /// Regression for issue #705: the Mac viewer wired every other host push
    /// (`onAgentSessionStatus`, `onSessionState`, …) but not
    /// `onPluginPresentations`, so `presentation(forPluginID:)` always returned
    /// nil and every remote badge showed the raw id. iOS never had the bug
    /// because it wires the identical sink in `ContentView`.
    @MainActor
    @Suite
    struct RemotePresentationSinkWiringTests {
        /// A viewer `ViewerConnectionManager` built against in-memory secrets so
        /// the test never touches the real Keychain (its init loads/generates a
        /// key pair via `SecretsService`).
        private func makeManager() async throws -> ViewerConnectionManager {
            try await withDependencies {
                $0[SecretsService.self] = .inMemory()
            } operation: {
                try await ViewerConnectionManager()
            }
        }

        /// The badge text `RemoteHostSidebarSection` renders for a project row:
        /// the presentation `short_name`, with the plugin id as fallback.
        private func badge(_ store: SessionStore, pluginID: String) -> String {
            store.presentation(forPluginID: pluginID)?.shortName ?? pluginID
        }

        private func claudeCodePresentation() -> PluginPresentation {
            PluginPresentation(
                id: "claude-code",
                version: "1.0.0",
                displayName: "Claude Code",
                shortName: "claude",
                color: "#cb6f3a"
            )
        }

        @Test("the wired sink routes a host's presentations into the store, so the badge resolves to the short_name")
        func sinkRoutesPresentationsIntoStore() async throws {
            let manager = try await makeManager()
            let store = SessionStore()

            AppCoordinator.wirePresentationSink(on: manager, into: store)

            // The sink must be installed — a nil callback is exactly the #705 bug.
            let sink = try #require(manager.onPluginPresentations)

            // Before any push the store is empty, so the badge falls back to the
            // raw plugin id — the wrong "claude-code" the user reported.
            #expect(store.presentation(forPluginID: "claude-code") == nil)
            #expect(badge(store, pluginID: "claude-code") == "claude-code")

            // The host pushes its enabled-plugin presentation set through the sink.
            sink(PluginPresentationsMessage(
                pairId: "host-1",
                presentations: [claudeCodePresentation()]
            ))

            // Now the badge resolves to the plugin's short_name.
            #expect(store.presentation(forPluginID: "claude-code")?.shortName == "claude")
            #expect(badge(store, pluginID: "claude-code") == "claude")
        }

        @Test("the sink full-replaces the store's presentation set on every push")
        func sinkFullReplacesOnEachPush() async throws {
            let manager = try await makeManager()
            let store = SessionStore()

            AppCoordinator.wirePresentationSink(on: manager, into: store)
            let sink = try #require(manager.onPluginPresentations)

            sink(PluginPresentationsMessage(
                pairId: "host-1",
                presentations: [
                    claudeCodePresentation(),
                    PluginPresentation(
                        id: "codex",
                        version: "1.0.0",
                        displayName: "Codex",
                        shortName: "codex",
                        color: "#10a37f"
                    ),
                ]
            ))
            #expect(badge(store, pluginID: "claude-code") == "claude")
            #expect(badge(store, pluginID: "codex") == "codex")

            // A later push with codex disabled drops it (spec §7.2/§7.3 full
            // replace), so its badge falls back to the id while claude stays.
            sink(PluginPresentationsMessage(
                pairId: "host-1",
                presentations: [claudeCodePresentation()]
            ))
            #expect(badge(store, pluginID: "claude-code") == "claude")
            #expect(store.presentation(forPluginID: "codex") == nil)
        }
    }
#endif
