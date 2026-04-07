import ClaudeSpyNetworking
import Foundation

/// Accumulates rapid keystrokes and flushes them as a single command after a short delay.
///
/// Shared between iOS and macOS viewer terminal views. The debounce window batches
/// keystrokes to reduce WebSocket message volume, and the send chain preserves
/// ordering without waiting for the round-trip response.
@MainActor
final public class KeystrokeDebouncer {
    private static let debounceInterval: Duration = .milliseconds(8)

    private let paneId: String
    private let relayClient: ViewerRelayClient

    private var keyBuffer: [TmuxKey] = []
    private var flushTask: Task<Void, Never>?
    private var pendingKeyTask: Task<Void, Never>?

    public init(paneId: String, relayClient: ViewerRelayClient) {
        self.paneId = paneId
        self.relayClient = relayClient
    }

    /// Add keys to the buffer and reset the flush timer.
    /// Keys arriving within the debounce window are batched into a single send.
    public func enqueue(_ keys: [TmuxKey]) {
        keyBuffer.append(contentsOf: keys)

        // Reset the flush timer — if more keys arrive within the debounce window, they'll be batched together
        flushTask?.cancel()
        flushTask = Task {
            do {
                try await Task.sleep(for: Self.debounceInterval)
            } catch {
                return
            }

            let keysToSend = keyBuffer
            keyBuffer.removeAll()

            // Chain on the WebSocket write (not response) to preserve ordering
            // without serializing on the full network round-trip.
            // sendCommand returns immediately for commands where requiresResponse is false.
            let previous = pendingKeyTask
            pendingKeyTask = Task {
                _ = await previous?.value
                _ = await relayClient.sendCommand(
                    SendKeystroke(keysToSend),
                    paneId: paneId
                )
            }
        }
    }

    /// Cancel any pending debounce and in-flight sends.
    public func cancelAll() {
        flushTask?.cancel()
        flushTask = nil
        keyBuffer.removeAll()
        pendingKeyTask?.cancel()
        pendingKeyTask = nil
    }
}
