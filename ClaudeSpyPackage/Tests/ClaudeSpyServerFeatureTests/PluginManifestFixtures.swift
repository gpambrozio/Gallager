#if os(macOS)
    import Foundation
    import GallagerPluginProtocol

    extension PluginManifest {
        /// A minimal sidecar manifest for use in supervisor tests.
        static func fixtureSidecar(executable: String, args: [String] = []) -> PluginManifest {
            PluginManifest(
                schemaVersion: 1,
                id: "test-sidecar",
                displayName: "Test Sidecar",
                shortName: "Test",
                version: "1.0.0",
                processNames: [],
                ui: PluginManifest.UI(icon: nil, color: nil),
                runtime: .sidecar,
                sidecar: PluginManifest.Sidecar(executable: executable, args: args)
            )
        }
    }
#endif
