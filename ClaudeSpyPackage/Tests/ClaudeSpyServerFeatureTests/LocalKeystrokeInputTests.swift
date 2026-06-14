#if os(macOS)
    import ClaudeSpyCommon
    import ClaudeSpyNetworking
    import ConcurrencyExtras
    import Dependencies
    import Foundation
    import Testing
    @testable import ClaudeSpyServerFeature

    /// Covers the local-typing keystroke path that fixed Option-Backspace
    /// (PR #593). SwiftTerm delivers a Meta/Option sequence as two synchronous
    /// `send()` callbacks (ESC, then the key). The coalescer merges them into one
    /// batch, and `TmuxService.sendKeystrokes` turns that batch into a single
    /// `send-keys Escape BSpace` (contiguous `\u{1b}\u{7f}`) — sent one-by-one the
    /// app only deletes a character instead of a word.
    @MainActor
    struct LocalKeystrokeInputTests {
        @Test("Keys enqueued in the same runloop turn coalesce into one batch")
        func coalescesSameTurnEnqueues() async {
            await withMainSerialExecutor {
                let batches = LockIsolated<[[TmuxKey]]>([])
                let coalescer = KeystrokeCoalescer { keys in
                    batches.withValue { $0.append(keys) }
                }

                // SwiftTerm emits Option-Backspace as two synchronous callbacks.
                coalescer.enqueue([.escape])
                coalescer.enqueue([.backspace])
                await Task.megaYield()

                #expect(batches.value == [[.escape, .backspace]])
            }
        }

        @Test("Keys enqueued in separate runloop turns flush independently")
        func separateTurnsFlushSeparately() async {
            await withMainSerialExecutor {
                let batches = LockIsolated<[[TmuxKey]]>([])
                let coalescer = KeystrokeCoalescer { keys in
                    batches.withValue { $0.append(keys) }
                }

                coalescer.enqueue([.text("a")])
                await Task.megaYield()
                coalescer.enqueue([.text("b")])
                await Task.megaYield()

                // Distinct presses land in their own turns — never merged.
                #expect(batches.value == [[.text("a")], [.text("b")]])
            }
        }

        @Test("flushPending drains buffered keys synchronously before the scheduled turn")
        func flushPendingDrainsImmediately() async {
            await withMainSerialExecutor {
                let batches = LockIsolated<[[TmuxKey]]>([])
                let coalescer = KeystrokeCoalescer { keys in
                    batches.withValue { $0.append(keys) }
                }

                // A key buffered earlier in this turn must flush before a
                // following raw event is chained, keeping input FIFO.
                coalescer.enqueue([.escape])
                coalescer.flushPending()

                // The flush happened synchronously, not on the next turn.
                #expect(batches.value == [[.escape]])

                // The already-scheduled flush fires but finds an empty buffer:
                // it must not emit a second (empty) batch.
                await Task.megaYield()
                #expect(batches.value == [[.escape]])
            }
        }

        @Test("flushPending is a no-op when nothing is buffered")
        func flushPendingNoopWhenEmpty() async {
            await withMainSerialExecutor {
                let batches = LockIsolated<[[TmuxKey]]>([])
                let coalescer = KeystrokeCoalescer { keys in
                    batches.withValue { $0.append(keys) }
                }

                coalescer.flushPending()
                await Task.megaYield()

                #expect(batches.value.isEmpty)
            }
        }

        @Test("sendKeystrokes batches a coalesced run into one send-keys invocation")
        func sendKeystrokesBatchesNamedKeys() async throws {
            let commands = LockIsolated<[[String]]>([])
            try await withDependencies {
                $0[ProcessRunner.self].run = { @Sendable _, arguments, _, _ in
                    commands.withValue { $0.append(arguments) }
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
            } operation: {
                let tmux = TmuxService(tmuxPath: "/usr/bin/tmux")
                // The coalesced Option-Backspace batch must go out as a single
                // `send-keys Escape BSpace`, not two separate invocations.
                try await tmux.sendKeystrokes("%1", keys: [.escape, .backspace])
            }

            let sendKeysCalls = commands.value.filter { $0.contains("send-keys") }
            #expect(sendKeysCalls.count == 1)
            let args = try #require(sendKeysCalls.first)
            let escape = try #require(args.firstIndex(of: "Escape"))
            let bspace = try #require(args.firstIndex(of: "BSpace"))
            #expect(escape < bspace)
        }
    }
#endif
