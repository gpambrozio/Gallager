import Foundation
import GallagerPluginProtocol
import Testing
@testable import ClaudeSpyE2ELib

@Suite("EchoPluginInstaller")
struct EchoPluginInstallerTests {
    /// Smoke test: `install` populates the expected files inside the
    /// state-root and the resulting `registry.json` decodes cleanly into
    /// a `[PluginRegistryEntry]`.
    ///
    /// Skipped automatically when the `EchoPluginSidecar` binary isn't on
    /// disk yet (e.g. test bundles built without the executable target
    /// dependency). The full Task 25 scenarios re-exercise the same path
    /// through the orchestrator.
    @Test("install populates plugin dir + registry entry")
    func installPopulatesStateRoot() throws {
        let stateRoot = makeTempStateRoot()
        defer { try? FileManager.default.removeItem(at: stateRoot) }

        let installer = EchoPluginInstaller()
        let pluginDir: URL
        do {
            pluginDir = try installer.install(into: stateRoot)
        } catch let error as EchoPluginInstallerError {
            // The test bundle was built without the EchoPluginSidecar
            // dependency (e.g. an Xcode test plan that skips it). Skip
            // rather than red-fail.
            if case .binaryMissing = error {
                Issue.record("EchoPluginSidecar binary missing; skipping smoke test: \(error)")
                return
            }
            throw error
        }

        let fm = FileManager.default
        #expect(pluginDir == stateRoot
            .appendingPathComponent("plugins")
            .appendingPathComponent("echo"))

        // Fixture tree copied through.
        #expect(fm.fileExists(atPath: pluginDir
                .appendingPathComponent("plugin.json").path))
        #expect(fm.fileExists(atPath: pluginDir
                .appendingPathComponent("ui/settings.json").path))
        #expect(fm.fileExists(atPath: pluginDir
                .appendingPathComponent("assets/icon.png").path))

        // Binary copied + made executable.
        let binaryPath = pluginDir.appendingPathComponent("bin/sidecar").path
        #expect(fm.fileExists(atPath: binaryPath))
        #expect(fm.isExecutableFile(atPath: binaryPath))

        // Registry decodes cleanly and contains the echo entry.
        let registryURL = stateRoot.appendingPathComponent("registry.json")
        #expect(fm.fileExists(atPath: registryURL.path))
        let data = try Data(contentsOf: registryURL)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([PluginRegistryEntry].self, from: data)
        let echo = try #require(entries.first { $0.id == "echo" })
        #expect(echo.version == "1.0.0")
        #expect(echo.enabled)
        // EchoPlugin lives outside the .app so it's recorded as a
        // user-installed plugin (`source: .url`) to avoid colliding with
        // `PluginRegistry.mergeBundled`'s "drop bundled entries not in the
        // shipping app" pass.
        #expect(echo.source == .url)
    }

    /// Re-running `install` must be idempotent — common when a test
    /// scenario is rerun on the same temp dir.
    @Test("install is idempotent")
    func installIsIdempotent() throws {
        let stateRoot = makeTempStateRoot()
        defer { try? FileManager.default.removeItem(at: stateRoot) }

        let installer = EchoPluginInstaller()
        do {
            _ = try installer.install(into: stateRoot)
            _ = try installer.install(into: stateRoot)
        } catch let error as EchoPluginInstallerError {
            if case .binaryMissing = error {
                Issue.record("EchoPluginSidecar binary missing; skipping idempotency test")
                return
            }
            throw error
        }

        let registryURL = stateRoot.appendingPathComponent("registry.json")
        let data = try Data(contentsOf: registryURL)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([PluginRegistryEntry].self, from: data)
        // Exactly one echo entry — the upsert removed the first before
        // appending the second.
        #expect(entries.filter { $0.id == "echo" }.count == 1)
    }

    // MARK: - Helpers

    private func makeTempStateRoot() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("EchoPluginInstallerTests-\(UUID().uuidString)", isDirectory: true)
        return url
    }
}
