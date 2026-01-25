#if os(macOS)
    import Foundation

    /// The connection state of a pane stream
    enum StreamState: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case error(String)

        var isActive: Bool {
            self == .connected
        }
    }

    /// Manages the streaming connection to a single tmux pane
    ///
    /// Uses tmux control mode via TmuxControlClientManager for real-time streaming.
    /// Control mode provides immediate resize notifications and structured output.
    @Observable
    @MainActor
    final class PaneStream {
        /// The pane target (e.g., "mysession:0.1")
        let target: String

        /// The pane ID (e.g., "%5")
        private(set) var paneId = ""

        /// Current connection state
        private(set) var state: StreamState = .disconnected

        /// Pane dimensions
        private(set) var width = 80
        private(set) var height = 24

        /// Callback for incoming data
        var onData: (@MainActor (Data) -> Void)?

        /// Callback for dimension changes (newWidth, newHeight)
        var onDimensionChange: (@MainActor (Int, Int) -> Void)?

        /// Number of lines in scrollback
        private(set) var scrollbackLines = 0

        private let tmuxService: TmuxService
        private let controlClientManager: TmuxControlClientManager
        private var sessionName = ""

        init(target: String, tmuxService: TmuxService, controlClientManager: TmuxControlClientManager) {
            self.target = target
            self.tmuxService = tmuxService
            self.controlClientManager = controlClientManager
        }

        /// Connects to the pane and starts streaming data via control mode.
        ///
        /// Returns the initial content (scrollback + visible area) captured before
        /// registering for live updates. The caller should send this content as the
        /// initial state, then live updates will flow via the `onData` callback.
        ///
        /// - Returns: Initial terminal content (scrollback + visible area)
        func connect() async throws -> Data {
            guard state == .disconnected || state.isError else { return Data() }

            state = .connecting

            do {
                // Validate pane exists
                guard try await tmuxService.validatePane(target) else {
                    throw TmuxError.invalidPane(target: target)
                }

                // Get pane ID
                paneId = try await tmuxService.getPaneId(target)

                // Extract session name for control client
                sessionName = TmuxControlClientManager.extractSessionName(from: target)

                // Get dimensions
                let dims = try await tmuxService.getPaneDimensions(target)
                width = dims.width
                height = dims.height

                // Capture initial content with scrollback (3x terminal height)
                // This must happen BEFORE registering with control client to ensure
                // we capture the stable state before live updates start flowing
                let initialContent = try await tmuxService.capturePaneWithScrollbackForStreaming(target)

                // Register with control client for live updates
                // The handler runs on a background thread, so we dispatch to MainActor
                try await controlClientManager.registerPane(
                    paneId: paneId,
                    sessionName: sessionName,
                    dimensions: (width: width, height: height)
                ) { [weak self] (data: Data) in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.scrollbackLines += data.split(separator: UInt8(ascii: "\n")).count
                        self.onData?(data)
                    }
                }

                state = .connected
                return initialContent
            } catch {
                state = .error(error.localizedDescription)
                throw error
            }
        }

        /// Disconnects from the pane
        func disconnect() async {
            // Unregister from control client
            if !paneId.isEmpty && !sessionName.isEmpty {
                await controlClientManager.unregisterPane(paneId: paneId, sessionName: sessionName)
            }

            state = .disconnected
        }

        /// Refreshes the pane dimensions from external source (e.g., control mode layout-change)
        /// Returns true if dimensions changed
        @discardableResult
        func updateDimensions(width newWidth: Int, height newHeight: Int) -> Bool {
            guard newWidth != width || newHeight != height else { return false }
            width = newWidth
            height = newHeight
            onDimensionChange?(newWidth, newHeight)
            return true
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
#endif
