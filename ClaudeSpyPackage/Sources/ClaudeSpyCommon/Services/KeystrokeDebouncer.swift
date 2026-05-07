import ClaudeSpyNetworking
import Dependencies
import Foundation

/// Accumulates rapid keystrokes and flushes them as a single command after a short delay.
///
/// Shared between iOS and macOS viewer terminal views. The debounce window batches
/// keystrokes to reduce WebSocket message volume, and the send chain preserves
/// ordering without waiting for the round-trip response.
///
/// ## Ordering guarantee
///
/// A single `sendTask` drains a FIFO queue of send operations. Each flush or
/// raw-input call appends to the queue and signals the task. Because only one
/// task reads from the queue, WebSocket writes are strictly ordered even when
/// multiple flush timers fire close together (Swift does not guarantee FIFO
/// scheduling of `@MainActor` continuations).
@MainActor
final public class KeystrokeDebouncer {
    /// Window in which consecutive keystrokes are batched into a single send.
    /// Must exceed the worst-case inter-key gap of any expected source —
    /// notably AppleScript's `keystroke` synthesis, which can pause up to
    /// ~15 ms between chars on a loaded system. A short window splits long
    /// strings across multiple WebSocket commands and exposes a race where
    /// the trailing batch can be lost en route to the host (see the Rapid
    /// Keystroke Order e2e flake).
    static let defaultDebounceInterval: Duration = .milliseconds(30)

    private let paneId: String
    private let debounceInterval: Duration
    private let sendOp: @MainActor (SendOp) async -> Void

    @Dependency(\.continuousClock) private var clock

    private var keyBuffer: [TmuxKey] = []
    private var flushTask: Task<Void, Never>?

    /// FIFO queue of operations for the send task.
    private var sendQueue: [SendOp] = []
    private var sendTask: Task<Void, Never>?
    private var sendContinuation: CheckedContinuation<Void, Never>?

    /// Operation queued for sending. Internal so tests can match against the
    /// values pulled out of the queue.
    enum SendOp: Equatable {
        case keys([TmuxKey])
        case rawInput(Data)
    }

    public convenience init(paneId: String, relayClient: ViewerRelayClient) {
        self.init(paneId: paneId) { op in
            switch op {
            case let .keys(keys):
                _ = await relayClient.sendCommand(SendKeystroke(keys), paneId: paneId)
            case let .rawInput(data):
                _ = await relayClient.sendCommand(SendRawInput(data: data), paneId: paneId)
            }
        }
    }

    /// Internal initialiser used by tests to capture send operations without
    /// standing up a full `ViewerRelayClient`. The debounce interval is also
    /// exposed here so tests can pin it to a known value driven by `TestClock`.
    init(
        paneId: String,
        debounceInterval: Duration = KeystrokeDebouncer.defaultDebounceInterval,
        sendOp: @escaping @MainActor (SendOp) async -> Void
    ) {
        self.paneId = paneId
        self.debounceInterval = debounceInterval
        self.sendOp = sendOp
        startSendLoop()
    }

    /// Add keys to the buffer and reset the flush timer.
    /// Keys arriving within the debounce window are batched into a single send.
    public func enqueue(_ keys: [TmuxKey]) {
        keyBuffer.append(contentsOf: keys)

        // Reset the flush timer — if more keys arrive within the debounce window,
        // they'll be batched together.
        flushTask?.cancel()
        let interval = debounceInterval
        flushTask = Task { [weak self] in
            do {
                try await self?.clock.sleep(for: interval)
            } catch {
                return
            }
            self?.flushBuffer()
        }
    }

    /// Immediately flush any buffered keystrokes, then send raw bytes
    /// (e.g., mouse escape sequences).
    ///
    /// Raw input is not debounced — it's already batched by the scroll event
    /// overlay — but it goes through the send queue to preserve ordering with
    /// keystrokes.
    public func enqueueRawInput(_ data: Data) {
        flushTask?.cancel()
        flushBuffer()
        enqueueSendOp(.rawInput(data))
    }

    /// Cancel any pending debounce and in-flight sends.
    public func cancelAll() {
        flushTask?.cancel()
        flushTask = nil
        keyBuffer.removeAll()
        sendQueue.removeAll()
        sendTask?.cancel()
        sendTask = nil
        if let cont = sendContinuation {
            sendContinuation = nil
            cont.resume()
        }
    }

    // MARK: - Private

    /// Move buffered keys into the send queue.
    private func flushBuffer() {
        guard !keyBuffer.isEmpty else { return }
        let keys = keyBuffer
        keyBuffer.removeAll()
        enqueueSendOp(.keys(keys))
    }

    /// Append an operation and wake the send loop.
    private func enqueueSendOp(_ op: SendOp) {
        sendQueue.append(op)
        if let cont = sendContinuation {
            sendContinuation = nil
            cont.resume()
        }
    }

    /// Long-running task that drains the send queue in FIFO order.
    private func startSendLoop() {
        sendTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                if self.sendQueue.isEmpty {
                    // Park until enqueueSendOp wakes us.
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        self.sendContinuation = cont
                    }
                    continue
                }

                let op = self.sendQueue.removeFirst()
                await self.sendOp(op)
            }
        }
    }
}
