import Foundation
import GallagerPluginProtocol
import Testing
@testable import ClaudeSpyPluginRuntime

@Suite("PluginRegistry")
struct PluginRegistryTests {
    // MARK: - Helpers

    /// Create a fresh temp directory and a `PluginRootLayout` pointing at it,
    /// then run the block. Cleans up afterwards.
    ///
    /// Each test gets its own UUID-suffixed dir so parallel tests don't
    /// stomp on each other.
    private func withTempLayout<R: Sendable>(
        _ body: (PluginRootLayout, URL) async throws -> R
    ) async throws -> R {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeSpyPluginRuntime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = PluginRootLayout.live(rootOverride: root, bundledOverride: root)
        return try await body(layout, root)
    }

    private func makeEntry(
        id: String,
        version: String = "1.0.0",
        source: PluginRegistryEntry.Source = .bundled,
        enabled: Bool = true,
        bundleSHA256: String? = nil,
        installedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> PluginRegistryEntry {
        let manifestURL: URL
        switch source {
        case .bundled:
            manifestURL = URL(string: "bundle://\(id)/plugin.json")!
        case .url:
            manifestURL = URL(string: "https://example.com/\(id)/plugin.json")!
        }
        return PluginRegistryEntry(
            id: id,
            version: version,
            source: source,
            manifestURL: manifestURL,
            bundleSHA256: bundleSHA256,
            enabled: enabled,
            installedAt: installedAt
        )
    }

    // MARK: - Empty registry

    @Test("loading from a missing registry file returns an empty list")
    func emptyRegistryReturnsEmpty() async throws {
        try await withTempLayout { layout, _ in
            let registry = PluginRegistry(layout: layout)
            let entries = try await registry.entries()
            #expect(entries.isEmpty)
        }
    }

    // MARK: - Read + write round-trip

    @Test("write a 3-entry registry, re-load, get the same entries")
    func readWriteRoundTrip() async throws {
        try await withTempLayout { layout, _ in
            let originalEntries = [
                makeEntry(id: "claude-code", version: "1.2.3"),
                makeEntry(id: "codex", version: "0.9.0"),
                makeEntry(
                    id: "opencode",
                    version: "0.1.0",
                    source: .url,
                    bundleSHA256: "abc123def456"
                ),
            ]

            // Fresh registry; persist via addUserInstall (the user-install
            // path appends new entries).
            let writer = PluginRegistry(layout: layout)
            for entry in originalEntries {
                try await writer.addUserInstall(entry)
            }

            // Re-load with a brand-new actor so the cache is cold and we
            // exercise the disk read.
            let reader = PluginRegistry(layout: layout)
            let loaded = try await reader.entries()
            #expect(loaded == originalEntries)
        }
    }

    // MARK: - Atomic replace

    @Test("a failed write leaves the existing file untouched")
    func atomicReplacePreservesPreviousFileOnFailure() async throws {
        try await withTempLayout { layout, _ in
            // Seed a single bundled entry so we have a known good registry
            // on disk.
            let initialEntry = makeEntry(id: "claude-code", version: "1.0.0")
            let registry = PluginRegistry(layout: layout)
            try await registry.addUserInstall(initialEntry)

            // Capture the on-disk bytes — this is the file the failing
            // write should NOT clobber.
            let registryURL = layout.registryURL()
            let originalData = try Data(contentsOf: registryURL)

            // Make the registry directory read-only so the next persist
            // attempt blows up partway through (can't write the temp file
            // OR rename into the dir).
            let registryDir = registryURL.deletingLastPathComponent()
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o500)],
                ofItemAtPath: registryDir.path
            )

            // Restore permissions on the way out — otherwise the cleanup
            // `removeItem` call in `withTempLayout` can't traverse the dir.
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o755)],
                    ofItemAtPath: registryDir.path
                )
            }

            // Attempt a mutation. It should throw because the temp+rename
            // can't write to the now-read-only directory.
            let secondEntry = makeEntry(id: "codex", version: "0.9.0")
            await #expect(throws: (any Error).self) {
                try await registry.addUserInstall(secondEntry)
            }

            // The original file must still be exactly what we wrote.
            let afterData = try Data(contentsOf: registryURL)
            #expect(afterData == originalData)
        }
    }

    // MARK: - Merge bundled

    @Test("mergeBundled replaces bundled entries, keeps user entries, preserves enabled")
    func mergeBundledPreservesUserEntriesAndEnabledBits() async throws {
        try await withTempLayout { layout, _ in
            // Pre-seed the registry with:
            //  - an old bundled "claude-code" v1.0.0 (user has disabled it)
            //  - an old bundled "codex" v0.5.0 (still enabled)
            //  - a user-installed "opencode" (must survive the merge)
            let oldClaude = makeEntry(id: "claude-code", version: "1.0.0", enabled: false)
            let oldCodex = makeEntry(id: "codex", version: "0.5.0", enabled: true)
            let userOpenCode = makeEntry(
                id: "opencode",
                version: "0.1.0",
                source: .url,
                enabled: true,
                bundleSHA256: "userhash"
            )

            let registry = PluginRegistry(layout: layout)
            try await registry.addUserInstall(oldClaude)
            try await registry.addUserInstall(oldCodex)
            try await registry.addUserInstall(userOpenCode)

            // Now ship a new bundled set: claude bumps to 1.5.0, codex
            // bumps to 0.9.0, both supplied as `enabled = true` (default).
            let newBundled = [
                makeEntry(id: "claude-code", version: "1.5.0", enabled: true),
                makeEntry(id: "codex", version: "0.9.0", enabled: true),
            ]
            try await registry.mergeBundled(newBundled)

            let merged = try await registry.entries()

            // Claude was bumped to 1.5.0 — but the user's `enabled = false`
            // bit must survive.
            let claude = try #require(merged.first { $0.id == "claude-code" })
            #expect(claude.version == "1.5.0")
            #expect(claude.enabled == false)

            // Codex was bumped to 0.9.0; enabled bit was true and stays true.
            let codex = try #require(merged.first { $0.id == "codex" })
            #expect(codex.version == "0.9.0")
            #expect(codex.enabled == true)

            // User-installed plugin untouched.
            let openCode = try #require(merged.first { $0.id == "opencode" })
            #expect(openCode == userOpenCode)
        }
    }

    @Test("mergeBundled drops bundled entries that are no longer shipped")
    func mergeBundledDropsRemovedBundles() async throws {
        try await withTempLayout { layout, _ in
            // Pre-seed with two bundled entries, one of which the next
            // ship round-trip wants to drop.
            let droppedBundled = makeEntry(id: "discontinued", version: "1.0.0")
            let keptBundled = makeEntry(id: "claude-code", version: "1.0.0")

            let registry = PluginRegistry(layout: layout)
            try await registry.addUserInstall(droppedBundled)
            try await registry.addUserInstall(keptBundled)

            // Only claude-code remains in the new bundled set.
            try await registry.mergeBundled([
                makeEntry(id: "claude-code", version: "1.5.0"),
            ])

            let merged = try await registry.entries()
            #expect(merged.contains(where: { $0.id == "claude-code" }))
            #expect(!merged.contains(where: { $0.id == "discontinued" }))
        }
    }

    @Test("mergeBundled persists across actor reloads")
    func mergeBundledPersistsToDisk() async throws {
        try await withTempLayout { layout, _ in
            let registry = PluginRegistry(layout: layout)
            try await registry.mergeBundled([
                makeEntry(id: "claude-code", version: "1.5.0"),
                makeEntry(id: "codex", version: "0.9.0"),
            ])

            // Cold re-load.
            let reloader = PluginRegistry(layout: layout)
            let loaded = try await reloader.entries()
            #expect(loaded.count == 2)
            #expect(loaded.contains { $0.id == "claude-code" && $0.version == "1.5.0" })
            #expect(loaded.contains { $0.id == "codex" && $0.version == "0.9.0" })
        }
    }

    // MARK: - Set enabled

    @Test("setEnabled toggles a single entry and persists")
    func setEnabledTogglesAndPersists() async throws {
        try await withTempLayout { layout, _ in
            let registry = PluginRegistry(layout: layout)
            try await registry.addUserInstall(
                makeEntry(id: "claude-code", version: "1.0.0", enabled: true)
            )
            try await registry.addUserInstall(
                makeEntry(id: "codex", version: "0.5.0", enabled: true)
            )

            try await registry.setEnabled(id: "claude-code", enabled: false)

            // Other entries are untouched.
            let inMemory = try await registry.entries()
            #expect(inMemory.first { $0.id == "claude-code" }?.enabled == false)
            #expect(inMemory.first { $0.id == "codex" }?.enabled == true)

            // Disk reflects the change.
            let cold = PluginRegistry(layout: layout)
            let onDisk = try await cold.entries()
            #expect(onDisk.first { $0.id == "claude-code" }?.enabled == false)
            #expect(onDisk.first { $0.id == "codex" }?.enabled == true)
        }
    }

    // MARK: - Remove

    @Test("remove deletes a single entry by id and persists")
    func removeDeletesAndPersists() async throws {
        try await withTempLayout { layout, _ in
            let registry = PluginRegistry(layout: layout)
            try await registry.addUserInstall(makeEntry(id: "claude-code"))
            try await registry.addUserInstall(makeEntry(id: "codex"))

            try await registry.remove(id: "claude-code")

            let cold = PluginRegistry(layout: layout)
            let remaining = try await cold.entries()
            #expect(remaining.count == 1)
            #expect(remaining.first?.id == "codex")
        }
    }
}
