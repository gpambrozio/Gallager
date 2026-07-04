#if os(macOS)
    import Clocks
    import ConcurrencyExtras
    import Dependencies
    import Foundation
    import Testing
    @testable import ClaudeSpyServerFeature

    @Suite("LiveDockIconManager")
    @MainActor
    struct LiveDockIconManagerTests {
        @Test("A single close debounces and updates the policy exactly once after the deadline")
        func singleCloseFiresOnce() async {
            // E2E test mode short-circuits `NSApp.setActivationPolicy` so the
            // unit test doesn't mutate AppKit state on the host machine.
            DockIconConfig.isE2ETestMode = true
            defer { DockIconConfig.isE2ETestMode = false }

            await withMainSerialExecutor {
                let clock = TestClock()
                let updateCount = LockIsolated(0)
                await withDependencies {
                    $0.continuousClock = clock
                } operation: { @MainActor in
                    let manager = LiveDockIconManager(closingDebounce: .milliseconds(100))
                    manager.onActivationPolicyUpdated = {
                        updateCount.withValue { $0 += 1 }
                    }

                    manager.handleWindowClosing()
                    // Just under the debounce — must not fire yet.
                    await clock.advance(by: .milliseconds(99))
                    #expect(updateCount.value == 0)

                    // Cross the deadline — fires exactly once.
                    await clock.advance(by: .milliseconds(2))
                    await Task.megaYield()
                    #expect(updateCount.value == 1)
                }
            }
        }

        @Test("Rapid close events coalesce into a single delayed update")
        func rapidClosesCoalesce() async {
            DockIconConfig.isE2ETestMode = true
            defer { DockIconConfig.isE2ETestMode = false }

            await withMainSerialExecutor {
                let clock = TestClock()
                let updateCount = LockIsolated(0)
                await withDependencies {
                    $0.continuousClock = clock
                } operation: { @MainActor in
                    let manager = LiveDockIconManager(closingDebounce: .milliseconds(100))
                    manager.onActivationPolicyUpdated = {
                        updateCount.withValue { $0 += 1 }
                    }

                    // Three closes within the debounce window — each cancels
                    // the previous timer and starts a new one. Only the last
                    // should ever fire.
                    manager.handleWindowClosing()
                    await clock.advance(by: .milliseconds(40))
                    manager.handleWindowClosing()
                    await clock.advance(by: .milliseconds(40))
                    manager.handleWindowClosing()
                    #expect(updateCount.value == 0)

                    // 80 ms more would fire the cancelled second timer; we
                    // need 100 ms after the last call. Verify both bounds.
                    await clock.advance(by: .milliseconds(99))
                    #expect(updateCount.value == 0)
                    await clock.advance(by: .milliseconds(2))
                    await Task.megaYield()
                    #expect(updateCount.value == 1)
                }
            }
        }

        @Test("setBadgeCount clears before setting so a fresh dock tile receives the value")
        func badgeWritesClearBeforeSet() {
            let manager = withDependencies {
                $0.continuousClock = ImmediateClock()
            } operation: { @MainActor in
                LiveDockIconManager()
            }
            let writes = LockIsolated<[String?]>([])
            manager.badgeLabelWriter = { label in
                writes.withValue { $0.append(label) }
            }

            // NSDockTile.badgeLabel dedups unchanged values in-process, so the
            // clear must precede every set — including a re-set of the SAME
            // value after a policy cycle destroyed the Dock's tile state
            // (issue #217).
            manager.setBadgeCount(3)
            #expect(writes.value == [nil, "3"])

            writes.withValue { $0.removeAll() }
            manager.setBadgeCount(3)
            #expect(writes.value == [nil, "3"])

            writes.withValue { $0.removeAll() }
            manager.setBadgeCount(0)
            #expect(writes.value == [nil])
        }
    }
#endif
