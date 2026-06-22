#if os(macOS)
    import Foundation
    import GallagerPluginProtocol
    import Testing
    @testable import ClaudeSpyServerFeature

    @MainActor
    @Suite("PluginRegistry sidecar path")
    struct PluginRegistrySidecarTests {
        @Test("registerSidecar makes a SidecarPluginCore and reports its source")
        func makesSidecarCore() throws {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("oc-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("bin"),
                withIntermediateDirectories: true
            )
            let exe = root.appendingPathComponent("bin/sidecar")
            try "#!/bin/bash\ncat >/dev/null".write(to: exe, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
            defer { try? FileManager.default.removeItem(at: root) }

            let manifest = PluginManifest(
                schemaVersion: 1,
                id: "opencode",
                displayName: "OpenCode",
                shortName: "OpenCode",
                version: "1.2.0",
                processNames: ["opencode"],
                ui: .init(icon: nil, color: "#3a7fcb"),
                runtime: .sidecar,
                sidecar: .init(executable: "bin/sidecar")
            )

            let registry = PluginRegistry()
            registry.attachPaths(GallagerPaths(stateRootOverride: root.appendingPathComponent("state")))
            registry.registerSidecar(manifest: manifest, root: root, source: .folder)

            let core = registry.makeCore("opencode")
            #expect(core is SidecarPluginCore)
            #expect(registry.listEntries().first(where: { $0.id == "opencode" })?.source == "folder")
        }
    }
#endif
