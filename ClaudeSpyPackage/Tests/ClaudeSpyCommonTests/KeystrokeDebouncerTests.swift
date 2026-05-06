import ClaudeSpyNetworking
import Clocks
import ConcurrencyExtras
import Dependencies
import Foundation
import Testing
@testable import ClaudeSpyCommon

@Suite("KeystrokeDebouncer")
@MainActor
struct KeystrokeDebouncerTests {
    @Test("Keys enqueued within the debounce window flush as a single send")
    func batchesWithinWindow() async {
        await withMainSerialExecutor {
            let clock = TestClock()
            let sentOps = LockIsolated<[KeystrokeDebouncer.SendOp]>([])
            await withDependencies {
                $0.continuousClock = clock
            } operation: { @MainActor in
                let debouncer = KeystrokeDebouncer(
                    paneId: "%0",
                    debounceInterval: .milliseconds(30)
                ) { op in
                    sentOps.withValue { $0.append(op) }
                }
                debouncer.enqueue([.text("a")])
                // Halfway through the window — adding more keys must extend the
                // batch, not start a new one.
                await clock.advance(by: .milliseconds(20))
                debouncer.enqueue([.text("b")])
                #expect(sentOps.value.isEmpty)

                // Crossing the deadline AFTER the second enqueue: only one
                // batched send fires, containing both characters.
                await clock.advance(by: .milliseconds(40))
                await Task.megaYield()
                #expect(sentOps.value == [.keys([.text("a"), .text("b")])])
            }
        }
    }

    @Test("Keys spaced beyond the debounce window flush as separate sends")
    func separateSendsAcrossWindow() async {
        await withMainSerialExecutor {
            let clock = TestClock()
            let sentOps = LockIsolated<[KeystrokeDebouncer.SendOp]>([])
            await withDependencies {
                $0.continuousClock = clock
            } operation: { @MainActor in
                let debouncer = KeystrokeDebouncer(
                    paneId: "%0",
                    debounceInterval: .milliseconds(30)
                ) { op in
                    sentOps.withValue { $0.append(op) }
                }
                debouncer.enqueue([.text("a")])
                // First batch flushes after the window.
                await clock.advance(by: .milliseconds(40))
                await Task.megaYield()
                #expect(sentOps.value == [.keys([.text("a")])])

                // Second enqueue starts a fresh batch; it must not be merged
                // with the first.
                debouncer.enqueue([.text("b")])
                await clock.advance(by: .milliseconds(40))
                await Task.megaYield()
                #expect(sentOps.value == [
                    .keys([.text("a")]),
                    .keys([.text("b")]),
                ])
            }
        }
    }

    @Test("Raw input flushes any buffered keys before sending the raw bytes")
    func rawInputFlushesPendingKeys() async {
        await withMainSerialExecutor {
            let clock = TestClock()
            let sentOps = LockIsolated<[KeystrokeDebouncer.SendOp]>([])
            await withDependencies {
                $0.continuousClock = clock
            } operation: { @MainActor in
                let debouncer = KeystrokeDebouncer(
                    paneId: "%0",
                    debounceInterval: .milliseconds(30)
                ) { op in
                    sentOps.withValue { $0.append(op) }
                }
                debouncer.enqueue([.text("x")])
                // Raw input arrives before the debounce window expires —
                // pending keys must be flushed immediately, raw bytes follow.
                debouncer.enqueueRawInput(Data([0x1B, 0x5B, 0x41]))
                await Task.megaYield()
                #expect(sentOps.value == [
                    .keys([.text("x")]),
                    .rawInput(Data([0x1B, 0x5B, 0x41])),
                ])

                // The cancelled flush timer must not fire after the window.
                await clock.advance(by: .seconds(1))
                await Task.megaYield()
                #expect(sentOps.value.count == 2)
            }
        }
    }

    @Test("cancelAll drops pending keys without sending")
    func cancelAllDropsPending() async {
        await withMainSerialExecutor {
            let clock = TestClock()
            let sentOps = LockIsolated<[KeystrokeDebouncer.SendOp]>([])
            await withDependencies {
                $0.continuousClock = clock
            } operation: { @MainActor in
                let debouncer = KeystrokeDebouncer(
                    paneId: "%0",
                    debounceInterval: .milliseconds(30)
                ) { op in
                    sentOps.withValue { $0.append(op) }
                }
                debouncer.enqueue([.text("a")])
                debouncer.cancelAll()
                // Crossing the deadline after cancelAll must not emit anything.
                await clock.advance(by: .seconds(1))
                await Task.megaYield()
                #expect(sentOps.value.isEmpty)
            }
        }
    }
}
