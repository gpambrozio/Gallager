import Foundation
import Testing
@testable import GallagerPluginProtocol

@Suite("PluginManifest v2 fields")
struct ManifestV2Tests {
    private func decode(_ json: String) throws -> PluginManifest {
        try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
    }

    @Test("decodes a full sidecar manifest")
    func fullSidecar() throws {
        let m = try decode("""
        {
          "schema_version": 1, "id": "opencode", "display_name": "OpenCode",
          "short_name": "OpenCode", "version": "1.2.0", "publisher": "opencode.ai",
          "manifest_url": "https://opencode.ai/plugins/gallager.json",
          "bundle_url": "https://opencode.ai/plugins/opencode-1.2.0.zip",
          "bundle_sha256": "abc123", "runtime": "sidecar",
          "sidecar": { "executable": "bin/sidecar", "args": ["--serve"] },
          "process_names": ["opencode"],
          "capabilities": { "rich_pane_detection": true, "modal_prompts": false },
          "ui": { "icon": "assets/icon.png", "color": "#3a7fcb" }
        }
        """)
        #expect(m.runtime == .sidecar)
        #expect(m.publisher == "opencode.ai")
        #expect(m.bundleURL?.absoluteString == "https://opencode.ai/plugins/opencode-1.2.0.zip")
        #expect(m.bundleSHA256 == "abc123")
        #expect(m.sidecar?.executable == "bin/sidecar")
        #expect(m.sidecar?.args == ["--serve"])
        #expect(m.capabilities.richPaneDetection == true)
        #expect(m.capabilities.modalPrompts == false)
    }

    @Test("a bundled v1 manifest still decodes; v2 fields default empty/false")
    func bundledStillDecodes() throws {
        let m = try decode("""
        { "schema_version": 1, "id": "claude-code", "display_name": "Claude Code",
          "short_name": "Claude", "version": "1.0.0", "process_names": ["claude"],
          "ui": { "icon": "assets/icon.png", "color": "#cb6f3a" } }
        """)
        #expect(m.runtime == .inProcess)
        #expect(m.sidecar == nil)
        #expect(m.bundleURL == nil)
        #expect(m.capabilities.richPaneDetection == false)
        #expect(m.capabilities.modalPrompts == false)
        #expect(m.otlp == nil)
    }

    @Test("otlp declaration decodes; token_event defaults to api_request (issue #617)")
    func otlpDeclaration() throws {
        let explicit = try decode("""
        { "id": "opencode", "display_name": "opencode", "short_name": "opencode",
          "otlp": { "namespace": "opencode", "token_event": "turn_metrics" } }
        """)
        #expect(explicit.otlp == PluginManifest.OTLP(namespace: "opencode", tokenEvent: "turn_metrics"))

        let defaulted = try decode("""
        { "id": "opencode", "display_name": "opencode", "short_name": "opencode",
          "otlp": { "namespace": "opencode" } }
        """)
        #expect(defaulted.otlp == PluginManifest.OTLP(namespace: "opencode", tokenEvent: "api_request"))

        // An EMPTY token_event also falls back — it would otherwise match a
        // record named exactly "<namespace>." in the accumulator.
        let empty = try decode("""
        { "id": "opencode", "display_name": "opencode", "short_name": "opencode",
          "otlp": { "namespace": "opencode", "token_event": "" } }
        """)
        #expect(empty.otlp == PluginManifest.OTLP(namespace: "opencode", tokenEvent: "api_request"))
    }
}
