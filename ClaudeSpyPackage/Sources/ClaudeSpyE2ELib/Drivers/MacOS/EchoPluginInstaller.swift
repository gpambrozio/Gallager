import Foundation
import GallagerPluginProtocol

/// Copies the EchoPlugin fixture tree + the built `EchoPluginSidecar`
/// binary into a test instance's `--gallager-state-root` so the running
/// app loads echo through the normal plugin-discovery path.
///
/// Layout under the state root after `install`:
///
/// ```
/// <stateRoot>/
///   registry.json                     ← echo entry appended
///   plugins/echo/
///     plugin.json                     ← copied from fixture
///     ui/settings.json                ← copied from fixture
///     assets/icon.png                 ← copied from fixture
///     bin/sidecar                     ← copied from SPM build output (+x)
/// ```
///
/// Bundled plugins (claude-code / codex) still come from
/// `Gallager.app/Contents/Resources/plugins/`. Echo deliberately lives
/// under the user-installed `plugins/<id>/` tree so it doesn't appear in
/// the bundled list — scenarios invoke `EchoPluginInstaller` explicitly
/// whenever they need it.
public struct EchoPluginInstaller: Sendable {
    public init() { }

    /// Copy the fixture + binary into `stateRoot` and append an entry to
    /// `<stateRoot>/registry.json`. Returns the resolved plugin directory
    /// (`<stateRoot>/plugins/echo`) so callers can sanity-check the layout
    /// or compute the ingress-socket path.
    @discardableResult
    public func install(into stateRoot: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: stateRoot, withIntermediateDirectories: true)

        let pluginDir = stateRoot
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent("echo", isDirectory: true)
        try fm.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        // 1. Copy the fixture tree.
        let fixtureRoot = try resolveFixtureRoot()
        for relative in ["plugin.json", "ui", "assets"] {
            let src = fixtureRoot.appendingPathComponent(relative)
            let dst = pluginDir.appendingPathComponent(relative)
            try? fm.removeItem(at: dst)
            try fm.copyItem(at: src, to: dst)
        }

        // 2. Copy the binary into `bin/sidecar` with the executable bit set.
        let binDir = pluginDir.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        let binaryDst = binDir.appendingPathComponent("sidecar")
        try? fm.removeItem(at: binaryDst)
        let binarySrc = try resolveSidecarBinary()
        try fm.copyItem(at: binarySrc, to: binaryDst)
        try fm.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: binaryDst.path
        )

        // 3. Append (or upsert) the registry entry. Reuses the same
        //    `PluginRegistryEntry` shape the app's `PluginRegistry` reads,
        //    so the running app picks echo up on its next discovery pass.
        try upsertRegistryEntry(in: stateRoot)

        return pluginDir
    }

    // MARK: - Fixture resolution

    /// Find the fixture tree at runtime. Two strategies:
    ///   1. `Bundle.module.resourceURL/EchoPlugin/` — works when SPM
    ///      copied the fixture as a `.copy` resource of `ClaudeSpyE2ELib`
    ///      (the production path; declared in `Package.swift`).
    ///   2. `#filePath`-based parent walk — only used as a fallback during
    ///      development if the bundle path goes missing.
    private func resolveFixtureRoot() throws -> URL {
        if
            let bundled = Bundle.module.url(
                forResource: "EchoPlugin",
                withExtension: nil
            ) {
            return bundled
        }
        // Source-tree fallback: walk up from this file to find the
        // `Fixtures/EchoPlugin` directory.
        let here = URL(fileURLWithPath: #filePath)
        let candidate = here
            .deletingLastPathComponent() // Drivers/MacOS
            .deletingLastPathComponent() // Drivers
            .deletingLastPathComponent() // ClaudeSpyE2ELib
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("EchoPlugin")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        throw EchoPluginInstallerError.fixtureMissing(
            "EchoPlugin fixture not found via Bundle.module or source-tree fallback"
        )
    }

    /// Locate the SPM-built `EchoPluginSidecar` binary.
    ///
    /// The binary can live in two layouts depending on how the caller
    /// is run:
    ///
    /// * **`swift test` / `swift run`** — SPM places executables in
    ///   `<package>/.build/<config>/<TargetName>` and tests run with
    ///   CWD inside the package, so a relative `.build/debug/...`
    ///   resolves directly. The `ClaudeSpyE2ETests` test target
    ///   declares `EchoPluginSidecar` as a dependency to force SPM to
    ///   build it before the test bundle runs.
    /// * **`xcodebuild -scheme ClaudeSpyE2E`** — Xcode builds the
    ///   orchestrator executable into `<DerivedData>/Build/Products/Debug/`,
    ///   but skips executable targets that aren't on the active build
    ///   graph. The `scripts/e2e-test.sh` script invokes
    ///   `swift build --product EchoPluginSidecar` separately and
    ///   copies the binary next to the orchestrator, so the
    ///   `Bundle.main.executableURL` sibling check picks it up.
    ///
    /// We probe both layouts (plus the source-tree walk-up that the
    /// fixture resolver uses) so the installer keeps working no matter
    /// which entry point the caller chose.
    private func resolveSidecarBinary() throws -> URL {
        let fm = FileManager.default
        var candidates: [URL] = []

        // 1. Sibling of the orchestrator binary. The `e2e-test.sh`
        //    build phase copies EchoPluginSidecar here after building
        //    via SPM. Also covers `swift test` (xctest bundle lives in
        //    `.build/<config>/` next to the executables).
        if let exec = Bundle.main.executableURL {
            candidates.append(exec.deletingLastPathComponent()
                .appendingPathComponent("EchoPluginSidecar"))
        }

        // 2. xctest bundle layouts (Xcode runs xctest from
        //    `.../<Pkg>PackageTests.xctest/Contents/MacOS/`).
        if let bundle = Bundle.allBundles.first(where: { $0.bundlePath.hasSuffix(".xctest") }) {
            let bundleURL = URL(fileURLWithPath: bundle.bundlePath)
            candidates.append(
                bundleURL.deletingLastPathComponent()
                    .appendingPathComponent("EchoPluginSidecar")
            )
        }

        // 3. CWD-rooted SPM build paths — `swift test` from the
        //    package root or repo root.
        let cwd = FileManager.default.currentDirectoryPath
        let cwdRoots = [
            URL(fileURLWithPath: cwd),
            URL(fileURLWithPath: cwd).appendingPathComponent("ClaudeSpyPackage"),
        ]
        for root in cwdRoots {
            for config in ["debug", "release"] {
                candidates.append(root
                    .appendingPathComponent(".build")
                    .appendingPathComponent(config)
                    .appendingPathComponent("EchoPluginSidecar"))
            }
        }

        // 4. Source-tree walk-up from this file. Lets `swift run` from
        //    arbitrary working directories still find the binary —
        //    `#filePath` always points inside the package, so we can
        //    derive the package root and join `.build/<config>/`.
        let here = URL(fileURLWithPath: #filePath)
        let packageRoot = here
            .deletingLastPathComponent() // …/MacOS
            .deletingLastPathComponent() // …/Drivers
            .deletingLastPathComponent() // …/ClaudeSpyE2ELib
            .deletingLastPathComponent() // …/Sources
            .deletingLastPathComponent() // …/ClaudeSpyPackage
        for config in ["debug", "release"] {
            candidates.append(packageRoot
                .appendingPathComponent(".build")
                .appendingPathComponent(config)
                .appendingPathComponent("EchoPluginSidecar"))
        }

        for candidate in candidates where fm.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        throw EchoPluginInstallerError.binaryMissing(
            "EchoPluginSidecar binary not found; searched: "
                + candidates.map(\.path).joined(separator: ", ")
        )
    }

    // MARK: - Registry upsert

    private func upsertRegistryEntry(in stateRoot: URL) throws {
        let registryURL = stateRoot.appendingPathComponent("registry.json")
        let fm = FileManager.default

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601

        var entries: [PluginRegistryEntry] = []
        if fm.fileExists(atPath: registryURL.path) {
            let data = try Data(contentsOf: registryURL)
            entries = (try? decoder.decode([PluginRegistryEntry].self, from: data)) ?? []
        }
        entries.removeAll { $0.id == "echo" }
        let entry = PluginRegistryEntry(
            id: "echo",
            version: "1.0.0",
            // Fixture lives outside the .app, so it's modeled as a
            // user-installed plugin in the registry — the app's
            // `PluginRegistry.mergeBundled` won't try to delete it when
            // it doesn't find an echo entry inside the .app's Resources.
            source: .url,
            manifestURL: URL(string: "bundle://echo/plugin.json")!,
            bundleSHA256: nil,
            enabled: true,
            installedAt: Date()
        )
        entries.append(entry)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entries)
        try data.write(to: registryURL, options: .atomic)
    }
}

// MARK: - Errors

public enum EchoPluginInstallerError: Error, CustomStringConvertible {
    case fixtureMissing(String)
    case binaryMissing(String)

    public var description: String {
        switch self {
        case let .fixtureMissing(message),
             let .binaryMissing(message):
            return message
        }
    }
}
