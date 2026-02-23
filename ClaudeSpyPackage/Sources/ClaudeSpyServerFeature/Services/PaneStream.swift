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
        /// Uses per-pane buffering to eliminate the timing gap (H5) between capture
        /// and stream registration. The flow is:
        /// 1. Register pane handler with buffering (events discarded during capture)
        /// 2. Capture via control mode (commands ordered with `%output` events)
        /// 3. Stop buffering (switch to live delivery)
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

                // Step 1: Enable per-pane buffering BEFORE registering the handler.
                // While buffering is active, %output events for this pane are silently
                // discarded — they'll be reflected in the capture results.
                try await controlClientManager.startPaneBuffering(
                    paneId: paneId, sessionName: sessionName
                )

                // Step 2: Register the pane handler for live updates.
                // Events arriving now are discarded by per-pane buffering.
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

                // Step 3: Capture via control mode. These commands are ordered relative
                // to %output events in the control mode stream, so the capture results
                // include the effects of all discarded events.
                let initialContent = try await tmuxService.capturePaneViaControlMode(
                    target,
                    height: height,
                    controlClientManager: controlClientManager,
                    sessionName: sessionName
                )

                // Step 4: Stop buffering — switch to live delivery.
                // All events after the last capture command are new and will be delivered.
                try await controlClientManager.stopPaneBuffering(
                    paneId: paneId, sessionName: sessionName
                )

                state = .connected
                return initialContent
            } catch {
                // Clean up on failure: stop buffering and unregister if we got that far
                if !paneId.isEmpty && !sessionName.isEmpty {
                    try? await controlClientManager.stopPaneBuffering(
                        paneId: paneId, sessionName: sessionName
                    )
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
            if !paneId.isEmpty && !sessionName.isEmpty {
                // Stop any active per-pane buffering (safety cleanup)
                try? await controlClientManager.stopPaneBuffering(
                    paneId: paneId, sessionName: sessionName
                )
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
