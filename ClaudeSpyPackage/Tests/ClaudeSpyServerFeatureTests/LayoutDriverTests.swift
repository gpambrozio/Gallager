#if os(macOS)
    import ClaudeSpyCommon
    import ClaudeSpyNetworking
    import Dependencies
    import Foundation
    import Testing
    @testable import ClaudeSpyServerFeature

    /// Integration tests for `LayoutDriver` that drive a real tmux server on a
    /// per-test isolated socket. Skipped when tmux isn't installed in any of the
    /// common locations (Homebrew, MacPorts, /usr/bin) so the suite still runs
    /// on hosts without tmux.
    @Suite("LayoutDriver")
    struct LayoutDriverTests {
        private static let tmuxPath: String? = TmuxBinaryLocator.liveValue.find()

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
            let tmuxPath = try #require(Self.tmuxPath)

            let socketPath = uniqueSocketPath()
            let sessionName = "issue501-twice"
            defer { killServer(tmuxPath: tmuxPath, socketPath: socketPath) }

            // TmuxService reads ProcessRunner via @Dependency, which has no
            // test default. Inject the live runner so list-sessions /
            // select-window actually shell out to the per-test tmux socket.
            try await withDependencies {
                $0[ProcessRunner.self] = .liveValue
            } operation: {
                let tmux = TmuxService(tmuxPath: tmuxPath, socketPath: socketPath)
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

        /// Regression test: a pane-level `start_directory` on the *first* pane
        /// of a window was silently dropped because the window/session was
        /// created with only the window-level (or session-level) cwd. The first
        /// pane's `start_directory` is now folded into the cascade so:
        /// - For window > 0: `tmux.newWindow` is invoked with the pane's dir.
        /// - For window 0:   `tmux.createSession` is invoked with the pane's dir.
        /// Regression: a pane-level `start_directory` on the *first* pane of a
        /// window was silently dropped because the window/session was created
        /// using only the window-level (or session-level) cwd. Fix folds the
        /// first pane's directory into the cascade so:
        /// - window > 0  → `tmux.newWindow` is invoked with the pane's dir.
        /// - window == 0 → `tmux.createSession` is invoked with the pane's dir.
        @Test("First pane's start_directory is honored for window > 0")
        @MainActor
        func firstPaneStartDirectoryHonoredForLaterWindow() async throws {
            try await withDryRunDriver { driver in
                let config = LayoutConfig(
                    sessionName: "first-pane-cwd-w1",
                    windows: [
                        LayoutConfig.Window(name: "w0", panes: [LayoutConfig.Pane()]),
                        LayoutConfig.Window(
                            name: "w1",
                            panes: [
                                LayoutConfig.Pane(
                                    shellCommands: ["./serve.sh"],
                                    startDirectory: "/tmp"
                                ),
                            ]
                        ),
                    ]
                )

                let result = try await driver.apply(config, dryRun: true, configDirectory: "/tmp")

                #expect(result.plannedActions.contains {
                    $0.contains("window.create name=w1") && $0.contains("path=/tmp")
                })
            }
        }

        @Test("First pane's start_directory is honored for window 0")
        @MainActor
        func firstPaneStartDirectoryHonoredForBootstrapWindow() async throws {
            try await withDryRunDriver { driver in
                let config = LayoutConfig(
                    sessionName: "first-pane-cwd-w0",
                    windows: [
                        LayoutConfig.Window(
                            name: "w0",
                            panes: [
                                LayoutConfig.Pane(
                                    shellCommands: ["./run.sh"],
                                    startDirectory: "/tmp"
                                ),
                            ]
                        ),
                    ]
                )

                let result = try await driver.apply(config, dryRun: true, configDirectory: "/var")

                #expect(result.plannedActions.contains {
                    $0.contains("session.create name=first-pane-cwd-w0") && $0.contains("path=/tmp")
                })
            }
        }

        // MARK: - Helpers

        /// Builds a `LayoutDriver` pointed at a non-existent tmux socket so
        /// `sessionExists` returns false without spinning up a real server.
        /// Suitable for dry-run-only assertions that never hit live tmux.
        @MainActor
        private func withDryRunDriver(
            _ body: @MainActor (LayoutDriver) async throws -> Void
        ) async throws {
            let tmuxPath = try #require(Self.tmuxPath)
            let socketPath = uniqueSocketPath()
            defer { killServer(tmuxPath: tmuxPath, socketPath: socketPath) }
            try await withDependencies {
                $0[ProcessRunner.self] = .liveValue
            } operation: {
                let tmux = TmuxService(tmuxPath: tmuxPath, socketPath: socketPath)
                let driver = LayoutDriver(
                    tmuxAccessor: { tmux },
                    descriptionApplier: { _, _ in },
                    colorApplier: { _, _ in },
                    progressApplier: { _, _ in }
                )
                try await body(driver)
            }
        }

        private func uniqueSocketPath() -> String {
            // Per-test socket so `swift test --parallel` runs don't collide.
            // `gallager-test-` prefix matches manual-debug conventions and keeps
            // any leaked sockets easy to spot in /tmp.
            let suffix = UUID().uuidString.prefix(8)
            return "/tmp/gallager-test-\(suffix).sock"
        }

        private func killServer(tmuxPath: String, socketPath: String) {
            // Fire-and-forget: `kill-server` finishes in milliseconds, and
            // `defer` doesn't support `async`, so we don't wait. Avoids
            // blocking the @MainActor test on Process.waitUntilExit().
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tmuxPath)
            process.arguments = ["-S", socketPath, "kill-server"]
            process.standardError = Pipe()
            process.standardOutput = Pipe()
            try? process.run()
        }
    }
#endif
