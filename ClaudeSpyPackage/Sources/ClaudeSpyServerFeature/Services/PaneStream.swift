#if os(macOS)
    import ClaudeSpyNetworking
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

    /// Manages the streaming connection to a single tmux pane.
    ///
    /// Uses `PipePaneReader` for raw byte delivery (via pipe-pane) and
    /// `TmuxControlClientManager` for commands (capture-pane) and events
    /// (layout-change, session-changed).
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

        /// Callback for terminal notifications (OSC 9/777)
        var onNotification: (@MainActor (TerminalStreamMessage.TerminalNotification) -> Void)?

        /// Callback for terminal title changes (OSC 0/2)
        var onTitleChange: (@MainActor (String) -> Void)?

        /// Number of lines in scrollback
        private(set) var scrollbackLines = 0

        private let tmuxService: TmuxService
        private let controlClientManager: TmuxControlClientManager
        private var sessionName = ""
        private var pipePaneReader: PipePaneReader?

        init(target: String, tmuxService: TmuxService, controlClientManager: TmuxControlClientManager) {
            self.target = target
            self.tmuxService = tmuxService
            self.controlClientManager = controlClientManager
        }

        /// Connects to the pane and starts streaming data via pipe-pane.
        ///
        /// The flow is:
        /// 1. Start pipe-pane with buffering (raw bytes collected but not delivered)
        /// 2. Capture initial state via control mode (scrollback + visible area)
        /// 3. Flush buffered pipe-pane data (switch to live delivery)
        ///
        /// - Returns: Initial terminal content (scrollback + visible area)
        func connect() async throws -> Data {
            guard state == .disconnected || state.isError else { return Data() }

            state = .connecting

            do {
                // Validate pane exists (subprocess — runs before registration)
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

                // Register pane for dimension tracking via control client
                try await controlClientManager.registerPaneDimensions(
                    paneId: paneId,
                    sessionName: sessionName,
                    dimensions: (width: width, height: height)
                )

                // Create and start pipe-pane reader with buffering
                let reader = PipePaneReader(paneId: paneId)
                pipePaneReader = reader

                // Set up data handler to forward to our callback
                await reader.setDataHandler { [weak self] (data: Data) in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.scrollbackLines += data.split(separator: UInt8(ascii: "\n")).count
                        self.onData?(data)
                    }
                }

                // Set up notification handler
                await reader.setNotificationHandler { [weak self] notification in
                    Task { @MainActor [weak self] in
                        self?.onNotification?(notification)
                    }
                }

                // Set up title change handler for OSC 0/2 sequences
                await reader.setTitleChangeHandler { [weak self] title in
                    Task { @MainActor [weak self] in
                        self?.onTitleChange?(title)
                    }
                }

                // Step 1: Start pipe-pane with buffering
                try await reader.startPipePane(
                    controlClientManager: controlClientManager,
                    sessionName: sessionName,
                    buffering: true
                )

                // Step 2: Capture initial state via control mode
                let initialContent = try await tmuxService.capturePaneViaControlMode(
                    target,
                    height: height,
                    controlClientManager: controlClientManager,
                    sessionName: sessionName
                )

                // Step 3: Flush buffered data and switch to live delivery
                await reader.stopBufferingAndFlush()

                state = .connected
                return initialContent
            } catch {
                // Clean up on failure
                if let reader = pipePaneReader {
                    await reader.stopPipePane(
                        controlClientManager: controlClientManager,
                        sessionName: sessionName
                    )
                    pipePaneReader = nil
                }
                if !paneId.isEmpty && !sessionName.isEmpty {
                    await controlClientManager.unregisterPane(
                        paneId: paneId, sessionName: sessionName
                    )
                }
                state = .error(error.localizedDescription)
                throw error
            }
        }

        /// Disconnects from the pane
        func disconnect() async {
            if let reader = pipePaneReader {
                await reader.stopPipePane(
                    controlClientManager: controlClientManager,
                    sessionName: sessionName
                )
                pipePaneReader = nil
            }

            if !paneId.isEmpty && !sessionName.isEmpty {
                await controlClientManager.unregisterPane(
                    paneId: paneId, sessionName: sessionName
                )
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
