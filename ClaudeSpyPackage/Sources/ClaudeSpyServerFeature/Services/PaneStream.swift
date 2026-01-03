import Foundation

/// The connection state of a pane stream
enum StreamState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case paused
    case error(String)

    var isActive: Bool {
        switch self {
        case .connected, .paused:
            return true
        default:
            return false
        }
    }
}

/// Manages the streaming connection to a single tmux pane
@Observable
@MainActor
final class PaneStream {
    /// The pane target (e.g., "mysession:0.1")
    let target: String

    /// The pane ID (e.g., "%5")
    private(set) var paneId: String = ""

    /// Current connection state
    private(set) var state: StreamState = .disconnected

    /// Pane dimensions
    private(set) var width: Int = 80
    private(set) var height: Int = 24

    /// Callback for incoming data
    var onData: (@MainActor (Data) -> Void)?

    /// Number of lines in scrollback
    private(set) var scrollbackLines: Int = 0

    private let tmuxService: TmuxService
    private var fifoReader: FIFOReader?
    private var streamTask: Task<Void, Never>?
    private var isPaused = false
    private var pauseBuffer: [Data] = []

    init(target: String, tmuxService: TmuxService) {
        self.target = target
        self.tmuxService = tmuxService
    }

    /// Connects to the pane and starts streaming data
    func connect() async throws {
        guard state == .disconnected || state.isError else { return }

        state = .connecting

        do {
            // Validate pane exists
            guard try await tmuxService.validatePane(target) else {
                throw TmuxError.invalidPane(target: target)
            }

            // Get pane ID
            paneId = try await tmuxService.getPaneId(target)

            // Get dimensions
            let dims = try await tmuxService.getPaneDimensions(target)
            width = dims.width
            height = dims.height

            // Capture initial content with cursor positioning for each line
            let initialContent = try await tmuxService.capturePaneWithPositioning(target)
            onData?(initialContent)

            // Start pipe-pane streaming for live updates
            let fifoPath = try await tmuxService.startPipePipe(target)
            let reader = FIFOReader(path: fifoPath)
            fifoReader = reader

            // Start reading from the FIFO
            let stream = try await reader.startReading()

            state = .connected

            // Process incoming data
            streamTask = Task { [weak self] in
                for await data in stream {
                    guard let self, !Task.isCancelled else { break }

                    await MainActor.run {
                        if self.isPaused {
                            self.pauseBuffer.append(data)
                        } else {
                            self.scrollbackLines += data.split(separator: UInt8(ascii: "\n")).count
                            self.onData?(data)
                        }
                    }
                }

                // Stream ended - update state
                await MainActor.run { [weak self] in
                    if self?.state == .connected {
                        self?.state = .disconnected
                    }
                }
            }
        } catch {
            state = .error(error.localizedDescription)
            throw error
        }
    }

    /// Disconnects from the pane
    func disconnect() async {
        streamTask?.cancel()
        streamTask = nil

        if let reader = fifoReader {
            await reader.stop()
            fifoReader = nil
        }

        // Stop pipe-pane in tmux
        try? await tmuxService.stopPipePipe(target)

        state = .disconnected
        pauseBuffer.removeAll()
        isPaused = false
    }

    /// Pauses the stream (buffers incoming data)
    func pause() {
        guard state == .connected else { return }
        isPaused = true
        state = .paused
    }

    /// Resumes the stream (flushes buffered data)
    func resume() {
        guard state == .paused else { return }
        isPaused = false
        state = .connected

        // Flush buffered data
        for data in pauseBuffer {
            scrollbackLines += data.split(separator: UInt8(ascii: "\n")).count
            onData?(data)
        }
        pauseBuffer.removeAll()
    }

    /// Refreshes the pane dimensions
    func refreshDimensions() async throws {
        let dims = try await tmuxService.getPaneDimensions(target)
        width = dims.width
        height = dims.height
    }
}

private extension StreamState {
    var isError: Bool {
        if case .error = self {
            return true
        }
        return false
    }
}
