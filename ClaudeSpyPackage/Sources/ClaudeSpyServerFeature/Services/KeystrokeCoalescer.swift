import ClaudeSpyNetworking
import Foundation

/// Coalesces keystrokes that arrive within a single runloop turn into one
/// batch, then hands the batch to `flush` on the next turn.
///
/// The local terminal feeds keys here because SwiftTerm delivers a Meta/Option
/// sequence as **two synchronous `send()` callbacks** — a lone ESC, then the
/// key. Both land in the same runloop turn, so buffering them and flushing once
/// (on the next turn) keeps them in a single downstream `send-keys`, which the
/// app receives as one Meta keypress (e.g. Option-Backspace → ESC DEL → delete
/// word). Sent as two separate `send-keys` calls, tmux delivers a bare Escape
/// then Backspace and the app only deletes a single character.
///
/// Distinct keystrokes arrive in their own runloop turns and flush
/// independently, so this never merges separate presses — unlike a time-based
/// debounce (see `KeystrokeDebouncer`) it adds no perceptible latency to local
/// typing.
///
/// Must be driven from the main actor (the terminal input path is); the
/// `@unchecked Sendable` mirrors the owning `TerminalContainerView.Coordinator`.
final class KeystrokeCoalescer: @unchecked Sendable {
    private let flush: @MainActor ([TmuxKey]) -> Void
    private var buffer: [TmuxKey] = []
    private var flushScheduled = false

    /// - Parameter flush: invoked once per coalesced batch, on the main actor.
    init(flush: @escaping @MainActor ([TmuxKey]) -> Void) {
        self.flush = flush
    }

    /// Buffer `keys` and schedule a single flush for the next runloop turn.
    /// Calls within the same turn accumulate into that one flush.
    func enqueue(_ keys: [TmuxKey]) {
        buffer.append(contentsOf: keys)
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            let batch = self.buffer
            self.buffer.removeAll()
            guard !batch.isEmpty else { return }
            self.flush(batch)
        }
    }

    /// Drop any buffered keys and clear the pending-flush flag (teardown).
    func reset() {
        buffer.removeAll()
        flushScheduled = false
    }
}
