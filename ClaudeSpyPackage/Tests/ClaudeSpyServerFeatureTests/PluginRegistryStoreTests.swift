#if os(macOS)
    import Foundation
    import GallagerPluginProtocol
    import Testing
    @testable import ClaudeSpyServerFeature

    @Suite("PluginRegistryStore")
    struct PluginRegistryStoreTests {
        private func tmp() -> URL {
            URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("reg-\(UUID().uuidString).json")
        }

        @Test("save then load round-trips entries")
        func roundTrip() throws {
            let url = tmp()
            defer { try? FileManager.default.removeItem(at: url) }

            let file = PluginRegistryFile(schemaVersion: 1, plugins: [
                .init(
                    id: "claude-code",
                    version: "1.0.0",
                    source: .bundled,
                    runtime: .inProcess,
                    enabled: true,
                    manifestURL: nil,
                    bundleURL: nil,
                    bundleSHA256: nil
                ),
                .init(
                    id: "opencode",
                    version: "1.2.0",
                    source: .url,
                    runtime: .sidecar,
                    enabled: true,
                    manifestURL: URL(string: "https://opencode.ai/g.json"),
                    bundleURL: URL(string: "https://opencode.ai/o.zip"),
                    bundleSHA256: "abc"
                ),
            ])

            try PluginRegistryStore.save(file, to: url)
            let back = PluginRegistryStore.load(url)

            #expect(back.plugins.count == 2)
            #expect(back.plugins[1].source == .url)
            #expect(back.plugins[1].bundleSHA256 == "abc")
        }

        @Test("loading a missing file yields an empty registry")
        func missingFile() {
            let back = PluginRegistryStore.load(tmp())
            #expect(back.plugins.isEmpty)
            #expect(back.schemaVersion == 1)
        }
    }
#endif
