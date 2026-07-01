#if os(macOS)
    import Foundation
    import GallagerPluginProtocol
    import Testing
    @testable import ClaudeSpyServerFeature

    @Suite("PluginInstaller folder-drop")
    struct PluginFolderDropTests {
        @Test("sanitize rejects traversal and uppercase, accepts a clean id")
        func sanitize() {
            #expect(PluginInstaller.sanitize(id: "opencode") == "opencode")
            #expect(PluginInstaller.sanitize(id: "open.code_2-x") == "open.code_2-x")
            #expect(PluginInstaller.sanitize(id: "../evil") == nil)
            #expect(PluginInstaller.sanitize(id: "Open") == nil)
            #expect(PluginInstaller.sanitize(id: String(repeating: "a", count: 200)) == nil)
        }

        @Test("discovery returns valid sidecar folders only")
        func discovery() throws {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pl-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            // valid sidecar folder
            let ok = dir.appendingPathComponent("opencode")
            try FileManager.default.createDirectory(at: ok.appendingPathComponent("bin"), withIntermediateDirectories: true)
            let validManifest = """
            {"schema_version":1,"id":"opencode","display_name":"OpenCode","short_name":"OC","version":"1.0.0","runtime":"sidecar","sidecar":{"executable":"bin/sidecar"},"process_names":["opencode"],"ui":{"color":"#3a7fcb"}}
            """
            try validManifest.write(to: ok.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
            let exe = ok.appendingPathComponent("bin/sidecar")
            try "#!/bin/bash".write(to: exe, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)

            // invalid: no executable present
            let bad = dir.appendingPathComponent("broken")
            try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
            let brokenManifest = """
            {"schema_version":1,"id":"broken","display_name":"B","short_name":"B","version":"1","runtime":"sidecar","ui":{}}
            """
            try brokenManifest.write(to: bad.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)

            let found = PluginInstaller.discoverFolderDropped(pluginsDir: dir)
            #expect(found.map(\.manifest.id) == ["opencode"])
        }
    }
#endif
