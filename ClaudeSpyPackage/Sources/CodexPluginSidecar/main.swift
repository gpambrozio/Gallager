#if os(macOS)
    import CodexPluginCore
    import Foundation
    import Logging

    // Configure the logger to write to stderr so the parent supervisor's
    // log-file capture sees it without interleaving with the JSON-RPC
    // protocol on stdout.
    LoggingSystem.bootstrap { label in
        var handler = StreamLogHandler.standardError(label: label)
        handler.logLevel = .info
        return handler
    }

    @MainActor
    func runSidecar() async {
        let sidecar = CodexSidecar()
        do {
            try await sidecar.run()
        } catch {
            FileHandle.standardError.write(
                Data("[codex sidecar] fatal: \(error)\n".utf8)
            )
            exit(1)
        }
    }

    // `@main` would require a single-type entrypoint and forces the
    // orchestrator into a static slot; sticking with a top-level
    // `await` keeps the binary tiny and matches the EchoSidecar fixture.
    await runSidecar()
#endif
