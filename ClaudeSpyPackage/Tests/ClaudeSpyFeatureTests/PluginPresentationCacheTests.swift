import ClaudeSpyNetworking
import Foundation
import Testing
@testable import ClaudeSpyFeature

@MainActor
@Suite("PluginPresentationCache Tests")
struct PluginPresentationCacheTests {
    // MARK: - Helpers

    /// Build a temp file URL the test owns end-to-end. Each test gets its own
    /// `UUID()` filename so parallel tests don't collide.
    private func makeTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginPresentationCacheTests-\(UUID().uuidString).json")
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func presentation(
        id: String,
        version: String,
        displayName: String? = nil,
        shortName: String? = nil,
        color: String = "#000000",
        iconBytes: Data = Data([1, 2, 3])
    ) -> PluginPresentation {
        PluginPresentation(
            id: id,
            version: version,
            displayName: displayName ?? id.capitalized,
            shortName: shortName ?? id.capitalized,
            color: color,
            iconPNGData: iconBytes
        )
    }

    // MARK: - Lookup

    @Test("Empty cache returns nil for any plugin id")
    func emptyCacheReturnsNil() async {
        let url = makeTempURL()
        defer { cleanup(url) }

        let cache = PluginPresentationCache(diskURL: url)

        #expect(cache.presentation(for: "claude-code") == nil)
        #expect(cache.all.isEmpty)
    }

    @Test("Applying a message exposes its presentations via lookup")
    func applyExposesPresentations() async {
        let url = makeTempURL()
        defer { cleanup(url) }

        let cache = PluginPresentationCache(diskURL: url)
        let claude = presentation(id: "claude-code", version: "1.0.0", displayName: "Claude Code")
        let codex = presentation(id: "codex", version: "0.2.0", displayName: "Codex")

        await cache.apply(PluginPresentationsMessage(presentations: [claude, codex]))

        #expect(cache.presentation(for: "claude-code") == claude)
        #expect(cache.presentation(for: "codex") == codex)
        // `all` is sorted by display name (case-insensitive) — "Claude Code" < "Codex"
        #expect(cache.all == [claude, codex])
    }

    // MARK: - Version Replacement

    @Test("Newer version for the same plugin id replaces the older entry")
    func newerVersionWins() async {
        let url = makeTempURL()
        defer { cleanup(url) }

        let cache = PluginPresentationCache(diskURL: url)
        let v1 = presentation(id: "claude-code", version: "1.0.0", iconBytes: Data([0xAA]))
        let v2 = presentation(id: "claude-code", version: "1.1.0", iconBytes: Data([0xBB]))

        await cache.apply(PluginPresentationsMessage(presentations: [v1]))
        #expect(cache.presentation(for: "claude-code")?.version == "1.0.0")
        #expect(cache.presentation(for: "claude-code")?.iconPNGData == Data([0xAA]))

        await cache.apply(PluginPresentationsMessage(presentations: [v2]))
        #expect(cache.presentation(for: "claude-code")?.version == "1.1.0")
        #expect(cache.presentation(for: "claude-code")?.iconPNGData == Data([0xBB]))
        // Only one entry — the upgrade replaced the previous version in place.
        #expect(cache.all.count == 1)
    }

    @Test("Partial message preserves un-mentioned entries")
    func partialMessagePreservesOthers() async {
        let url = makeTempURL()
        defer { cleanup(url) }

        let cache = PluginPresentationCache(diskURL: url)
        let claude = presentation(id: "claude-code", version: "1.0.0")
        let codex = presentation(id: "codex", version: "0.2.0")

        await cache.apply(PluginPresentationsMessage(presentations: [claude, codex]))
        // Push only an updated claude — codex must remain in the cache.
        let claudeV2 = presentation(id: "claude-code", version: "1.1.0")
        await cache.apply(PluginPresentationsMessage(presentations: [claudeV2]))

        #expect(cache.presentation(for: "claude-code") == claudeV2)
        #expect(cache.presentation(for: "codex") == codex)
    }

    // MARK: - Persistence

    @Test("Persisted cache survives reloading a fresh instance from the same path")
    func persistAndReload() async {
        let url = makeTempURL()
        defer { cleanup(url) }

        let originalCache = PluginPresentationCache(diskURL: url)
        let claude = presentation(id: "claude-code", version: "1.0.0", displayName: "Claude Code")
        let codex = presentation(id: "codex", version: "0.2.0", displayName: "Codex")
        await originalCache.apply(PluginPresentationsMessage(presentations: [claude, codex]))

        // New instance pointed at the same file should pick up both entries.
        let reloaded = PluginPresentationCache(diskURL: url)

        #expect(reloaded.presentation(for: "claude-code") == claude)
        #expect(reloaded.presentation(for: "codex") == codex)
    }

    @Test("Missing disk file initializes an empty cache without error")
    func missingDiskFileTreatedAsEmpty() {
        // Generate a path that is guaranteed not to exist yet.
        let url = makeTempURL()
        defer { cleanup(url) }

        let cache = PluginPresentationCache(diskURL: url)

        #expect(cache.all.isEmpty)
    }
}
