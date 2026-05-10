#if os(macOS)
    import ClaudeSpyNetworking
    import Dependencies
    import Foundation
    import Testing
    @testable import ClaudeSpyServerFeature

    /// Integration tests for `LayoutDriver` that drive a real tmux server on a
    /// per-test isolated socket. Skipped when tmux isn't installed at the
    /// expected Homebrew path so the suite still runs on hosts without tmux.
    @Suite("LayoutDriver")
    struct LayoutDriverTests {
        private static let tmuxPath = "/opt/homebrew/bin/tmux"

        private static var tmuxAvailable: Bool {
            FileManager.default.isExecutableFile(atPath: tmuxPath)
        }

        /// Regression test for issue #501: running `gallager apply` twice in a
        /// row against the same yaml must both succeed. Before the fix, the
        /// driver emitted `select-window -t session:!`, which fails with
        /// "can't find window: !" when the session has no previous-window
        /// history — i.e. a freshly built single-window session — making the
        /// second apply (warm-attach path) exit non-zero. The first apply
        /// (cold-start path) hit the same bug whenever the layout produced
        /// only a single window.
        @Test("Applying twice in a row both succeed (#501)")
        @MainActor
        func applyingTwiceInARowBothSucceed() async throws {
            try #require(Self.tmuxAvailable)

            let socketPath = uniqueSocketPath()
            let sessionName = "issue501-twice"
            defer { killServer(socketPath: socketPath) }

            // TmuxService reads ProcessRunner via @Dependency, which has no
            // test default. Inject the live runner so list-sessions /
            // select-window actually shell out to the per-test tmux socket.
            try await withDependencies {
                $0[ProcessRunner.self] = .liveValue
            } operation: {
                let tmux = TmuxService(tmuxPath: Self.tmuxPath, socketPath: socketPath)
                let driver = LayoutDriver(
                    tmuxAccessor: { tmux },
                    descriptionApplier: { _, _ in },
                    colorApplier: { _, _ in },
                    progressApplier: { _, _ in }
                )

                // Single-window layout — that's the case that exposed #501.
                // After cold-start, the session has only ever had window 0
                // selected, so `select-window -t session:!` would fail with
                // "can't find window: !". With the fix (`session:`), both
                // the cold-start finalize and the warm-attach select succeed.
                let config = LayoutConfig(
                    sessionName: sessionName,
                    windows: [
                        LayoutConfig.Window(
                            name: "main",
                            panes: [LayoutConfig.Pane()]
                        ),
                    ]
                )

                let first = try await driver.apply(config)
                #expect(first.created == true)
                #expect(first.sessionName == sessionName)

                let second = try await driver.apply(config)
                #expect(second.created == false)
                #expect(second.sessionName == sessionName)
            }
        }

        // MARK: - Helpers

        private func uniqueSocketPath() -> String {
            // Per-test socket so `swift test --parallel` runs don't collide.
            // `gallager-test-` prefix matches manual-debug conventions and keeps
            // any leaked sockets easy to spot in /tmp.
            let suffix = UUID().uuidString.prefix(8)
            return "/tmp/gallager-test-\(suffix).sock"
        }

        private func killServer(socketPath: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.tmuxPath)
            process.arguments = ["-S", socketPath, "kill-server"]
            process.standardError = Pipe()
            process.standardOutput = Pipe()
            try? process.run()
            process.waitUntilExit()
        }
    }
#endif
