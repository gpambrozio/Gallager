#if os(macOS)
    import ClaudeSpyNetworking
    import Foundation
    import GallagerPluginProtocol
    import Testing
    @testable import ClaudeSpyServerFeature

    @Suite("PluginRegistry")
    @MainActor
    struct PluginRegistryTests {
        private func makeEnv(stateDir: URL) -> PluginEnv {
            PluginEnv(
                pluginRoot: URL(fileURLWithPath: "/tmp/echo-root"),
                stateDir: stateDir,
                appVersion: "1.0.0",
                settings: Data(),
                marketplaceSource: URL(fileURLWithPath: "/tmp/marketplace")
            )
        }

        @Test("loads bundled manifests with correct process names and colors")
        func loadsBundledManifests() {
            let registry = PluginRegistry()

            let claude = registry.manifests["claude-code"]
            #expect(claude != nil)
            #expect(claude?.processNames == ["claude"])
            #expect(claude?.color == "#cb6f3a")
            #expect(claude?.displayName == "Claude Code")
            #expect(claude?.runtime == .inProcess)

            let codex = registry.manifests["codex"]
            #expect(codex != nil)
            #expect(codex?.processNames == ["codex"])
            #expect(codex?.color == "#3B82F6")
            #expect(codex?.shortName == "Codex")
        }

        @Test("processNamesByPlugin surfaces detection names for both bundled plugins")
        func processNamesExposed() {
            let registry = PluginRegistry()
            let names = registry.processNamesByPlugin
            #expect(names["claude-code"] == ["claude"])
            #expect(names["codex"] == ["codex"])
        }

        @Test("enable initializes a core and disable shuts it down")
        func enableDisableLifecycle() async {
            let registry = PluginRegistry()
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("gallager-reg-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tmp) }

            let dispatcher = PluginEventDispatcher()
            let sink = PluginLogSink(logFileURL: tmp.appendingPathComponent("sidecar.log"))
            let host = LivePluginHost(pluginID: "echo", dispatcher: dispatcher, logSink: sink)

            #expect(registry.core("echo") == nil)
            // Echo has a factory (DEBUG) but no bundled manifest; makeCore tolerates
            // a missing manifest by defaulting to .inProcess, so enable succeeds.
            await registry.enable("echo", host: host, env: makeEnv(stateDir: tmp))
            #expect(registry.core("echo") != nil)
            #expect(registry.failedInit["echo"] == nil)

            await registry.disable("echo")
            #expect(registry.core("echo") == nil)
        }

        @Test("enabling an unknown plugin records a failed-init error")
        func unknownPluginFailsInit() async {
            let registry = PluginRegistry()
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("gallager-reg-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tmp) }

            let dispatcher = PluginEventDispatcher()
            let sink = PluginLogSink(logFileURL: tmp.appendingPathComponent("sidecar.log"))
            let host = LivePluginHost(pluginID: "nope", dispatcher: dispatcher, logSink: sink)

            await registry.enable("nope", host: host, env: makeEnv(stateDir: tmp))
            #expect(registry.core("nope") == nil)
            #expect(registry.failedInit["nope"] != nil)
        }

        @Test("presentations returns exactly the enabled plugins that have manifests")
        func presentationsForEnabledSet() async {
            let registry = PluginRegistry()
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("gallager-reg-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tmp) }

            let dispatcher = PluginEventDispatcher()
            let sink = PluginLogSink(logFileURL: tmp.appendingPathComponent("sidecar.log"))

            // Nothing enabled yet → no presentations.
            #expect(registry.presentations().isEmpty)

            let claudeHost = LivePluginHost(pluginID: "claude-code", dispatcher: dispatcher, logSink: sink)
            await registry.enable("claude-code", host: claudeHost, env: makeEnv(stateDir: tmp))

            let presentations = registry.presentations()
            #expect(presentations.count == 1)
            let claude = presentations.first
            #expect(claude?.id == "claude-code")
            #expect(claude?.displayName == "Claude Code")
            #expect(claude?.shortName == "Claude")
            #expect(claude?.color == "#cb6f3a")
            #expect(claude?.version == "1.0.0")

            await registry.disable("claude-code")
            #expect(registry.presentations().isEmpty)
        }

        // MARK: - CLI accessors (spec §14)

        @Test("listEntries reports id/version/enabled/source for every registered plugin")
        func listEntriesReportsAllPlugins() async {
            let registry = PluginRegistry()
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("gallager-reg-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tmp) }

            let entriesBefore = registry.listEntries()
            // claude-code + codex are always registered; echo is DEBUG-only.
            #expect(entriesBefore.contains { $0.id == "claude-code" })
            #expect(entriesBefore.contains { $0.id == "codex" })
            #expect(entriesBefore.allSatisfy { $0.source == "bundled" })
            // Sorted by id for stable output.
            #expect(entriesBefore.map(\.id) == entriesBefore.map(\.id).sorted())
            // Nothing enabled yet.
            #expect(entriesBefore.allSatisfy { !$0.enabled })

            let claude = entriesBefore.first { $0.id == "claude-code" }
            #expect(claude?.version == "1.0.0")

            // Enabling flips the `enabled` flag for that row only.
            let dispatcher = PluginEventDispatcher()
            let sink = PluginLogSink(logFileURL: tmp.appendingPathComponent("sidecar.log"))
            let host = LivePluginHost(pluginID: "claude-code", dispatcher: dispatcher, logSink: sink)
            await registry.enable("claude-code", host: host, env: makeEnv(stateDir: tmp))

            let entriesAfter = registry.listEntries()
            #expect(entriesAfter.first { $0.id == "claude-code" }?.enabled == true)
            #expect(entriesAfter.first { $0.id == "codex" }?.enabled == false)
        }

        @Test("isRegistered / isEnabled track factory + active state")
        func registeredAndEnabledFlags() async {
            let registry = PluginRegistry()
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("gallager-reg-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tmp) }

            #expect(registry.isRegistered("claude-code"))
            #expect(!registry.isRegistered("does-not-exist"))
            #expect(!registry.isEnabled("claude-code"))

            let dispatcher = PluginEventDispatcher()
            let sink = PluginLogSink(logFileURL: tmp.appendingPathComponent("sidecar.log"))
            let host = LivePluginHost(pluginID: "claude-code", dispatcher: dispatcher, logSink: sink)
            await registry.enable("claude-code", host: host, env: makeEnv(stateDir: tmp))
            #expect(registry.isEnabled("claude-code"))
        }

        @Test("callCore dispatches core-only methods and reports not-enabled / unknown-method")
        func callCoreDispatch() async {
            let registry = PluginRegistry()
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("gallager-reg-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tmp) }

            // No active core → notEnabled.
            #expect(await registry.callCore("echo", method: "installStatus") == .notEnabled)

            let dispatcher = PluginEventDispatcher()
            let sink = PluginLogSink(logFileURL: tmp.appendingPathComponent("sidecar.log"))
            let host = LivePluginHost(pluginID: "echo", dispatcher: dispatcher, logSink: sink)
            await registry.enable("echo", host: host, env: makeEnv(stateDir: tmp))

            // EchoPluginCore always reports installed; install returns alreadyInstalled.
            // describe(.installed(version: "echo")) → "installed vecho" (no space after v).
            #expect(await registry.callCore("echo", method: "installStatus") == .ok(result: "installed vecho"))
            #expect(await registry.callCore("echo", method: "install") == .ok(result: "already-installed"))
            #expect(await registry.callCore("echo", method: "installStatus") == .ok(result: "installed vecho"))
            #expect(await registry.callCore("echo", method: "refreshProjects") == .ok(result: "refreshed"))
            #expect(await registry.callCore("echo", method: "uninstall") == .ok(result: "uninstalled"))

            // Unknown method name is reported back verbatim.
            #expect(await registry.callCore("echo", method: "bogus") == .unknownMethod("bogus"))
        }

        @Test("PluginPresentationBuilder uses the fallback color when manifest omits one")
        func presentationBuilderFallbackColor() {
            let manifest = PluginManifest(
                schemaVersion: 1,
                id: "x",
                displayName: "X",
                shortName: "X",
                version: "2.0.0",
                processNames: ["x"],
                ui: .init(icon: nil, color: nil)
            )
            let presentation = PluginPresentationBuilder.make(manifest: manifest, pluginRoot: nil)
            #expect(presentation.color == PluginManifest.fallbackColor)
            #expect(presentation.iconB64 == nil)
        }
    }
#endif
