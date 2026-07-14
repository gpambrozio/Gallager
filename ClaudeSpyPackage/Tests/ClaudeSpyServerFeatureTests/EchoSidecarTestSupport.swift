#if os(macOS)
    import ClaudeSpyNetworking
    import Foundation
    import GallagerPluginProtocol
    @testable import ClaudeSpyServerFeature

    // MARK: - Binary locator

    /// Locate the `EchoPluginSidecar` binary within the SPM build-products tree.
    ///
    /// SPM creates a stable symlink `.build/debug` → `.build/<arch>/debug/` so we
    /// don't have to hard-code the architecture string. The package root is found
    /// by walking upward from the source file path until a directory containing
    /// `Package.swift` is found — this is resilient to SPM's `-file-prefix-map`
    /// rewriting that can omit the package subdirectory from `#file` paths.
    func locateEchoSidecarBinary(sourceFile: String = #file) throws -> URL {
        var dir = URL(fileURLWithPath: sourceFile).deletingLastPathComponent()
        var packageRoot: URL?
        let fm = FileManager.default
        for _ in 0..<10 {
            if fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                packageRoot = dir
                break
            }
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break } // hit filesystem root
            dir = parent
        }

        var searched: [String] = []

        if let root = packageRoot {
            // Primary: .build/debug (SPM's arch-neutral symlink, always present locally).
            let primary = root.appendingPathComponent(".build/debug/EchoPluginSidecar")
            searched.append(primary.path)
            if fm.isExecutableFile(atPath: primary.path) {
                return primary
            }
            // Fallback: .build/release.
            let release = root.appendingPathComponent(".build/release/EchoPluginSidecar")
            searched.append(release.path)
            if fm.isExecutableFile(atPath: release.path) {
                return release
            }
        }

        throw BinaryNotFoundError(searched: searched, sourceFile: sourceFile)
    }

    struct BinaryNotFoundError: Error, CustomStringConvertible {
        let searched: [String]
        let sourceFile: String
        var description: String {
            "EchoPluginSidecar binary not found. Searched: \(searched). " +
                "sourceFile=\(sourceFile). " +
                "Run `swift build` in ClaudeSpyPackage before running this test."
        }
    }

    // MARK: - Writable plugin root

    /// Copy the built `EchoPluginSidecar` binary into a fresh writable temp directory
    /// so tests that write under `pluginRoot` (e.g. `install`) don't mutate the build
    /// products directory.
    ///
    /// Returns: a `(pluginRoot, binaryURL)` pair where `binaryURL` = `<pluginRoot>/EchoPluginSidecar`.
    func makeWritablePluginRoot(
        binaryURL: URL,
        suffix: String = UUID().uuidString
    ) throws -> (pluginRoot: URL, binaryURL: URL) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("echo-sidecar-\(suffix)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let dest = tmp.appendingPathComponent("EchoPluginSidecar")
        try FileManager.default.copyItem(at: binaryURL, to: dest)
        // Ensure +x bit survives the copy.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755 as NSNumber],
            ofItemAtPath: dest.path
        )
        return (pluginRoot: tmp, binaryURL: dest)
    }

    // MARK: - Noop delegate (shared)

    actor SharedNoopSidecarDelegate: SidecarTransportDelegate {
        func handleNotification(_: String, _: JSONValue?) async { }
        func handleInboundRequest(_ m: String, _: JSONValue?) async -> Result<JSONValue, RPCError> {
            .failure(.methodNotFound(m))
        }
    }
#endif
