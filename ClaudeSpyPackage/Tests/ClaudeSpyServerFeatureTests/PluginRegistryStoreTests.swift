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

        @Test("legacy registry JSON without update fields decodes with defaults")
        func legacyEntryDecodesWithUpdateDefaults() throws {
            let json = """
            {"schemaVersion":1,"plugins":[{"id":"pi","version":"1.0.0","source":"url","runtime":"sidecar","enabled":true,"manifestURL":"https://example.com/pi/plugin.json","bundleURL":"https://cdn.example.com/pi.zip","bundleSHA256":"abc"}]}
            """
            let file = try JSONDecoder().decode(PluginRegistryFile.self, from: Data(json.utf8))
            let entry = try #require(file.plugins.first)
            #expect(entry.autoUpdate == true)
            #expect(entry.needsBridgeRefresh == false)
        }

        @Test("autoUpdate=false and needsBridgeRefresh=true survive a save/load round-trip")
        func updateFieldsRoundTrip() throws {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("registry-roundtrip-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("registry.json")

            let entry = PluginRegistryEntry(
                id: "pi", version: "1.0.0", source: .url, runtime: .sidecar, enabled: true,
                manifestURL: URL(string: "https://example.com/pi/plugin.json"),
                bundleURL: URL(string: "https://cdn.example.com/pi.zip"),
                bundleSHA256: "abc",
                autoUpdate: false,
                needsBridgeRefresh: true
            )
            try PluginRegistryStore.save(PluginRegistryFile(schemaVersion: 1, plugins: [entry]), to: url)
            let loaded = PluginRegistryStore.load(url)
            let roundTripped = try #require(loaded.plugins.first)
            #expect(roundTripped.autoUpdate == false)
            #expect(roundTripped.needsBridgeRefresh == true)
        }
    }
#endif
