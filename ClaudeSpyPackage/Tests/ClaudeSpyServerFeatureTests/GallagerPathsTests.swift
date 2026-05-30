#if os(macOS)
    import Foundation
    import Testing
    @testable import ClaudeSpyServerFeature

    @Suite("GallagerPaths")
    struct GallagerPathsTests {
        @Test("default layout derives from ~/.gallager")
        func defaultLayout() {
            let paths = GallagerPaths()
            let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path

            // Compare `.path` so a directory URL's trailing-slash representation
            // doesn't matter — only the layout does.
            #expect(paths.gallagerRoot.path == "\(home)/.gallager")
            #expect(paths.stateRoot.path == "\(home)/.gallager/state")
            #expect(paths.registryPath.path == "\(home)/.gallager/registry.json")
            #expect(paths.ingressSocketPath.path == "\(home)/.gallager/state/ingress.sock")
            #expect(paths.pluginStateDir("claude-code").path == "\(home)/.gallager/state/plugins/claude-code")
            #expect(
                paths.pluginSettingsPath("claude-code").path
                    == "\(home)/.gallager/state/plugins/claude-code/settings.json"
            )
            #expect(
                paths.pluginLogPath("claude-code").path
                    == "\(home)/.gallager/state/plugins/claude-code/logs/sidecar.log"
            )
        }

        @Test("override root redirects the whole tree and keeps registry adjacent")
        func overrideLayout() {
            let override = URL(fileURLWithPath: "/tmp/gallager-test-xyz/state")
            let paths = GallagerPaths(stateRootOverride: override)

            #expect(paths.stateRoot.path == "/tmp/gallager-test-xyz/state")
            // registry.json stays adjacent to the redirected state/ directory.
            #expect(paths.gallagerRoot.path == "/tmp/gallager-test-xyz")
            #expect(paths.registryPath.path == "/tmp/gallager-test-xyz/registry.json")
            #expect(paths.ingressSocketPath.path == "/tmp/gallager-test-xyz/state/ingress.sock")
            #expect(paths.pluginLogPath("codex").path == "/tmp/gallager-test-xyz/state/plugins/codex/logs/sidecar.log")
        }

        @Test("ensurePluginStateDir materializes the directory tree")
        func ensurePluginStateDirCreatesDirs() {
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("gallager-paths-\(UUID().uuidString)/state")
            defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }

            let paths = GallagerPaths(stateRootOverride: tmp)
            let dir = paths.ensurePluginStateDir("echo")

            #expect(FileManager.default.fileExists(atPath: dir.path))
            #expect(FileManager.default.fileExists(atPath: paths.pluginLogDir("echo").path))
        }
    }
#endif
