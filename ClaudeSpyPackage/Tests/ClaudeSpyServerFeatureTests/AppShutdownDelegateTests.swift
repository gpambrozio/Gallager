#if os(macOS)
    import Clocks
    import ConcurrencyExtras
    import Dependencies
    import Foundation
    import Testing
    @testable import ClaudeSpyServerFeature

    @Suite("AppShutdownDelegate")
    @MainActor
    struct AppShutdownDelegateTests {
        /// Builds a delegate with a stubbed reply handler that signals when AppKit would have been told to terminate.
        private func makeDelegate(
            timeout: Duration,
            onReply: @escaping @MainActor () -> Void
        ) -> AppShutdownDelegate {
            let delegate = AppShutdownDelegate(shutdownTimeout: timeout)
            delegate.replyHandler = { onReply() }
            return delegate
        }

        @Test("Cleanup completing before the deadline replies immediately")
        func cleanupBeforeDeadline() async {
            await withMainSerialExecutor {
                let clock = TestClock()
                let replyCount = LockIsolated(0)
                await withDependencies {
                    $0.continuousClock = clock
                } operation: { @MainActor in
                    let delegate = makeDelegate(timeout: .seconds(3)) {
                        replyCount.withValue { $0 += 1 }
                    }
                    delegate.onShouldTerminate = { /* finishes immediately */ }
                    let reply = delegate.applicationShouldTerminate(.shared)
                    #expect(reply == .terminateLater)
                    // Cleanup task runs on the next main-actor hop, before any clock advance.
                    await Task.megaYield()
                    #expect(replyCount.value == 1)
                    // Advancing past the deadline must not double-fire the reply.
                    await clock.advance(by: .seconds(5))
                    #expect(replyCount.value == 1)
                }
            }
        }

        @Test("Cleanup hanging past the timeout fires the deadline reply")
        func cleanupExceedsDeadline() async {
            await withMainSerialExecutor {
                let clock = TestClock()
                let replyCount = LockIsolated(0)
                await withDependencies {
                    $0.continuousClock = clock
                } operation: { @MainActor in
                    let delegate = makeDelegate(timeout: .seconds(3)) {
                        replyCount.withValue { $0 += 1 }
                    }
                    // Cleanup awaits the same TestClock, so it cannot finish until we advance.
                    delegate.onShouldTerminate = {
                        try? await clock.sleep(for: .seconds(60))
                    }
                    _ = delegate.applicationShouldTerminate(.shared)
                    // Just under the timeout: deadline hasn't fired yet.
                    await clock.advance(by: .seconds(2))
                    #expect(replyCount.value == 0)
                    // Cross the deadline: the timeout task fires reply exactly once.
                    await clock.advance(by: .seconds(2))
                    #expect(replyCount.value == 1)
                }
            }
        }

        @Test("Without a cleanup handler the delegate replies immediately and never schedules a deadline")
        func noCleanupHandlerReturnsTerminateNow() async {
            await withMainSerialExecutor {
                let clock = TestClock()
                let replyCount = LockIsolated(0)
                await withDependencies {
                    $0.continuousClock = clock
                } operation: { @MainActor in
                    let delegate = makeDelegate(timeout: .seconds(3)) {
                        replyCount.withValue { $0 += 1 }
                    }
                    let reply = delegate.applicationShouldTerminate(.shared)
                    #expect(reply == .terminateNow)
                    // No tasks were spawned — advancing the clock must not fire replyHandler.
                    await clock.advance(by: .seconds(60))
                    #expect(replyCount.value == 0)
                }
            }
        }
    }
#endif
