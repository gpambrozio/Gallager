import Foundation
import Testing
@testable import GallagerPluginProtocol

@Suite("PluginManifest")
struct PluginManifestTests {
    // MARK: - Fixtures

    /// The exact Claude Code manifest JSON from Spec §5.
    private static let claudeCodeManifestJSON = #"""
    {
      "schema_version": 1,
      "id": "claude-code",
      "display_name": "Claude Code",
      "short_name": "Claude",
      "version": "1.0.0",
      "publisher": "Anthropic",
      "manifest_url": "bundle://claude-code/plugin.json",
      "bundle_sha256": null,
      "runtime": "sidecar",
      "sidecar": {
        "executable": "bin/sidecar",
        "args": []
      },
      "capabilities": {
        "pushes_projects": true,
        "translate_event": true,
        "install": true,
        "detect_pane": true,
        "settings_schema": "ui/settings.json",
        "requires_rich_detection": false
      },
      "process_names": ["claude"],
      "ui": {
        "icon": "assets/icon.png",
        "icon_ios": "assets/icon@2x.png"
      }
    }
    """#

    private static func snakeCaseDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private static func snakeCaseEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    // MARK: - Spec §5 round-trip

    @Test("Claude Code manifest from Spec §5 decodes successfully")
    func specManifestDecodes() throws {
        let data = Data(Self.claudeCodeManifestJSON.utf8)
        let manifest = try Self.snakeCaseDecoder().decode(PluginManifest.self, from: data)

        #expect(manifest.schemaVersion == 1)
        #expect(manifest.id == "claude-code")
        #expect(manifest.displayName == "Claude Code")
        #expect(manifest.shortName == "Claude")
        #expect(manifest.version == "1.0.0")
        #expect(manifest.publisher == "Anthropic")
        #expect(manifest.manifestURL == URL(string: "bundle://claude-code/plugin.json"))
        #expect(manifest.bundleSHA256 == nil)
        #expect(manifest.runtime == .sidecar)
        #expect(manifest.sidecar.executable == "bin/sidecar")
        #expect(manifest.sidecar.args == [])
        #expect(manifest.capabilities.pushesProjects == true)
        #expect(manifest.capabilities.translateEvent == true)
        #expect(manifest.capabilities.install == true)
        #expect(manifest.capabilities.detectPane == true)
        #expect(manifest.capabilities.settingsSchema == "ui/settings.json")
        #expect(manifest.capabilities.requiresRichDetection == false)
        #expect(manifest.processNames == ["claude"])
        #expect(manifest.ui.icon == "assets/icon.png")
        #expect(manifest.ui.iconIOS == "assets/icon@2x.png")
    }

    @Test("Claude Code manifest round-trips through Codable")
    func specManifestRoundTrips() throws {
        let data = Data(Self.claudeCodeManifestJSON.utf8)
        let manifest = try Self.snakeCaseDecoder().decode(PluginManifest.self, from: data)

        let encoded = try Self.snakeCaseEncoder().encode(manifest)
        let decoded = try Self.snakeCaseDecoder().decode(PluginManifest.self, from: encoded)

        #expect(decoded == manifest)
    }

    // MARK: - validate()

    @Test("https manifest without bundle_sha256 fails validation")
    func httpsManifestRequiresHash() throws {
        let manifest = PluginManifest(
            schemaVersion: 1,
            id: "opencode",
            displayName: "OpenCode",
            shortName: "OpenCode",
            version: "1.0.0",
            publisher: "OpenCode",
            manifestURL: URL(string: "https://example.com/opencode/plugin.json")!,
            bundleSHA256: nil,
            runtime: .sidecar,
            sidecar: .init(executable: "bin/sidecar", args: []),
            capabilities: .init(
                pushesProjects: true,
                translateEvent: true,
                install: false,
                detectPane: false,
                settingsSchema: nil,
                requiresRichDetection: false
            ),
            processNames: ["opencode"],
            ui: .init(icon: "assets/icon.png", iconIOS: nil)
        )

        #expect(throws: PluginManifestError.bundleSHA256RequiredForHTTPS) {
            try manifest.validate()
        }
    }

    @Test("https manifest with bundle_sha256 passes validation")
    func httpsManifestWithHashValidates() throws {
        let manifest = PluginManifest(
            schemaVersion: 1,
            id: "opencode",
            displayName: "OpenCode",
            shortName: "OpenCode",
            version: "1.0.0",
            publisher: "OpenCode",
            manifestURL: URL(string: "https://example.com/opencode/plugin.json")!,
            bundleSHA256: String(repeating: "0", count: 64),
            runtime: .sidecar,
            sidecar: .init(executable: "bin/sidecar", args: []),
            capabilities: .init(
                pushesProjects: true,
                translateEvent: true,
                install: false,
                detectPane: false,
                settingsSchema: nil,
                requiresRichDetection: false
            ),
            processNames: ["opencode"],
            ui: .init(icon: "assets/icon.png", iconIOS: nil)
        )

        try manifest.validate() // does not throw
    }

    @Test("bundle:// manifest without bundle_sha256 passes validation")
    func bundleSchemeWithoutHashValidates() throws {
        let data = Data(Self.claudeCodeManifestJSON.utf8)
        let manifest = try Self.snakeCaseDecoder().decode(PluginManifest.self, from: data)
        try manifest.validate() // does not throw
    }
}
