import Foundation
import GallagerPluginProtocol
import Testing
@testable import ClaudeSpyPluginRuntime

@Suite("BundledPluginDiscovery")
struct BundledPluginDiscoveryTests {
    // MARK: - Helpers

    /// Write a `plugin.json` file with the supplied manifest fields onto disk.
    /// Returns the directory the file landed in.
    @discardableResult
    private func writeManifest(
        in root: URL,
        id: String,
        schemaVersion: Int = 1,
        displayName: String? = nil,
        version: String = "1.0.0",
        icon: String = "icon.png"
    ) throws -> URL {
        let pluginDir = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        // Hand-roll the JSON so we can deliberately ship a bad schema_version
        // in the failure cases — the typed `PluginManifest` codable path
        // wouldn't let us encode a non-1 value.
        let json = """
        {
          "schema_version": \(schemaVersion),
          "id": "\(id)",
          "display_name": "\(displayName ?? id)",
          "short_name": "\(id)",
          "version": "\(version)",
          "publisher": "test",
          "manifest_url": "bundle://\(id)/plugin.json",
          "bundle_sha256": null,
          "runtime": "sidecar",
          "sidecar": { "executable": "sidecar", "args": [] },
          "capabilities": {
            "pushes_projects": true,
            "translate_event": true,
            "install": false,
            "detect_pane": false,
            "settings_schema": null,
            "requires_rich_detection": false
          },
          "process_names": ["\(id)"],
          "ui": { "icon": "\(icon)", "icon_ios": null }
        }
        """
        try json.write(
            to: pluginDir.appendingPathComponent("plugin.json"),
            atomically: true,
            encoding: .utf8
        )
        return pluginDir
    }

    private func withTempDir(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BundledPluginDiscovery-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    // MARK: - Tests

    @Test("discovers two bundled plugins in alphabetical order")
    func discoversTwoPlugins() throws {
        try withTempDir { root in
            try writeManifest(in: root, id: "codex", displayName: "Codex")
            try writeManifest(in: root, id: "claude-code", displayName: "Claude Code")

            let discovery = BundledPluginDiscovery()
            let records = try discovery.discover(in: root)
            #expect(records.count == 2)

            // Sorted by directory name.
            #expect(records[0].manifest.id == "claude-code")
            #expect(records[1].manifest.id == "codex")

            // Registry entries are populated correctly.
            for record in records {
                #expect(record.registryEntry.id == record.manifest.id)
                #expect(record.registryEntry.source == .bundled)
                #expect(record.registryEntry.bundleSHA256 == nil)
                #expect(record.registryEntry.enabled == true)
                #expect(
                    record.registryEntry.manifestURL
                        == URL(string: "bundle://\(record.manifest.id)/plugin.json")
                )
            }
        }
    }

    @Test("missing directory yields an empty list")
    func missingDirectoryReturnsEmpty() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)", isDirectory: true)
        let discovery = BundledPluginDiscovery()
        let records = try discovery.discover(in: missing)
        #expect(records.isEmpty)
    }

    @Test("subdirectory without plugin.json is skipped silently")
    func subdirectoryWithoutManifestSkipped() throws {
        try withTempDir { root in
            // One legit plugin and one unrelated subdirectory (e.g. a
            // sibling resource folder).
            try writeManifest(in: root, id: "claude-code")
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("not-a-plugin", isDirectory: true),
                withIntermediateDirectories: true
            )

            let records = try BundledPluginDiscovery().discover(in: root)
            #expect(records.count == 1)
            #expect(records[0].manifest.id == "claude-code")
        }
    }

    @Test("rejects manifest with schema_version != 1")
    func rejectsUnsupportedSchemaVersion() throws {
        try withTempDir { root in
            try writeManifest(in: root, id: "future-plugin", schemaVersion: 2)

            let discovery = BundledPluginDiscovery()
            #expect(throws: BundledPluginDiscoveryError.self) {
                _ = try discovery.discover(in: root)
            }
        }
    }

    @Test("rejects malformed manifest JSON")
    func rejectsMalformedJSON() throws {
        try withTempDir { root in
            let pluginDir = root.appendingPathComponent("broken", isDirectory: true)
            try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
            try "{ this isn't JSON".write(
                to: pluginDir.appendingPathComponent("plugin.json"),
                atomically: true,
                encoding: .utf8
            )

            let discovery = BundledPluginDiscovery()
            #expect(throws: BundledPluginDiscoveryError.self) {
                _ = try discovery.discover(in: root)
            }
        }
    }
}
