import Foundation
import Logging

/// Response from a control mode command
struct CommandResponse: Sendable {
    let commandNumber: Int
    let output: String
    let isError: Bool

    var lines: [String] {
        output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}

/// Errors that can occur with the tmux control client
enum TmuxControlError: Error, LocalizedError {
    case notConnected
    case alreadyConnected
    case connectionFailed(message: String)
    case processTerminated(reason: String?)
    case commandFailed(message: String)
    case invalidResponse(message: String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to tmux control mode"
        case .alreadyConnected:
            return "Already connected to tmux control mode"
        case let .connectionFailed(message):
            return "Failed to connect to tmux: \(message)"
        case let .processTerminated(reason):
            return "tmux control mode terminated: \(reason ?? "unknown reason")"
        case let .commandFailed(message):
            return "Command failed: \(message)"
        case let .invalidResponse(message):
            return "Invalid response from tmux: \(message)"
        case .timeout:
            return "Command timed out"
        }
    }
}

/// Manages a tmux control mode connection for commands and event notifications.
///
/// With `-f no-output` the control client only handles:
/// - Command execution via `sendCommand()` (capture-pane, list-panes, pipe-pane, etc.)
/// - `%layout-change` for dimension tracking
/// - `%session-changed` for session monitoring
/// - `%exit` for connection lifecycle
///
/// Live terminal data is delivered separately via `PipePaneReader` (pipe-pane raw bytes).
actor TmuxControlClient {
    private let tmuxPath: String
    private let socketPath: String?
    private let logger = Logger(label: "com.claudespy.tmuxcontrol")

    // Connection state
    private var process: Process?
    private var stdin: FileHandle?
    private var stdoutPipe: Pipe?

    // Cached dimensions for change detection
    private var cachedDimensions: [String: (width: Int, height: Int)] = [:]

    // Callbacks for notifications
    private var _onDimensionChange: (@Sendable (String, Int, Int) -> Void)?
    private var _onPaneExited: (@Sendable (String) -> Void)?
    private var _onLayoutChange: (@Sendable () -> Void)?
    private var _onSessionChanged: (@Sendable (String, String) -> Void)?
    private var _onExit: (@Sendable (String?) -> Void)?

    // FIFO queue of pending command continuations, in the order commands were written to stdin.
    // tmux processes commands in FIFO order, so the front of this queue always corresponds
    // to the next %begin/%end response from tmux for a CLIENT command.
    //
    // NOTE: The only non-client %begin/%end is the initial `attach` response (skipped via
    // receivedInitialResponse flag). All subsequent %begin/%end blocks correspond 1:1
    // with commands we wrote to stdin, in order.
    private var pendingCommandQueue: [(id: Int, continuation: CheckedContinuation<CommandResponse, any Error>)] = []
    private var commandCounter = 0

    // Current command being accumulated (for %begin/%end blocks)
    private var currentCommandNumber: Int?
    private var currentCommandOutput: [String] = []
    private var currentCommandIsError = false

    // The first %begin/%end after connecting is tmux's response to the `attach` command
    // itself (not a command we sent). We track this to skip the entire block.
    private var skippingInitialBlock = false
    private var receivedInitialResponse = false

    // AsyncStream for ordered data processing from readabilityHandler.
    // Same pattern as PipePaneReader: yield from dispatch queue, consume in single task.
    private var dataContinuation: AsyncStream<Data>.Continuation?
    private var consumerTask: Task<Void, Never>?

    // Byte buffer for incomplete lines (handles chunk splitting at line boundaries)
    private var byteBuffer = Data()

    var isConnected: Bool {
        process?.isRunning == true
    }

    init(tmuxPath: String = "/opt/homebrew/bin/tmux", socketPath: String? = nil) {
        self.tmuxPath = tmuxPath
        self.socketPath = socketPath
    }

    // MARK: - Callback Setters

    func setOnDimensionChange(_ handler: @escaping @Sendable (String, Int, Int) -> Void) {
        _onDimensionChange = handler
    }

    func setOnPaneExited(_ handler: @escaping @Sendable (String) -> Void) {
        _onPaneExited = handler
    }

    func setOnLayoutChange(_ handler: @escaping @Sendable () -> Void) {
        _onLayoutChange = handler
    }

    func setOnSessionChanged(_ handler: @escaping @Sendable (String, String) -> Void) {
        _onSessionChanged = handler
    }

    func setOnExit(_ handler: @escaping @Sendable (String?) -> Void) {
        _onExit = handler
    }

    // MARK: - Connection Management

    /// Connects to a tmux session in control mode with `-f no-output,ignore-size`.
    ///
    /// The `no-output` flag suppresses `%output` events — live data is delivered
    /// via `PipePaneReader` instead. The `ignore-size` flag prevents the control
    /// client from affecting pane sizing.
    func connect(sessionTarget: String) async throws {
        guard process == nil else {
            throw TmuxControlError.alreadyConnected
        }

        logger.info("Connecting to tmux control mode", metadata: [
            "session": "\(sessionTarget)",
        ])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)

        var arguments = ["-C", "-f", "no-output,ignore-size", "attach", "-t", sessionTarget]
        if let socketPath, !socketPath.isEmpty {
            arguments = ["-S", socketPath] + arguments
        }
        process.arguments = arguments

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Set up termination handler
        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            Task {
                await self.handleProcessTermination(exitCode: proc.terminationStatus)
            }
        }

        do {
            try process.run()
        } catch {
            throw TmuxControlError.connectionFailed(message: error.localizedDescription)
        }

        self.process = process
        stdin = stdinPipe.fileHandleForWriting
        self.stdoutPipe = stdoutPipe

        // Start reading output via AsyncStream for ordered processing.
        // readabilityHandler fires on a dispatch queue — yielding into the stream
        // is synchronous and non-blocking. A single consumer task drains the stream
        // in order, preventing reordering of control messages.
        let handle = stdoutPipe.fileHandleForReading
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        dataContinuation = continuation

        handle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            continuation.yield(data)
        }

        consumerTask = Task { [weak self] in
            for await data in stream {
                await self?.processIncomingData(data)
            }
        }

        logger.info("Connected to tmux control mode (no-output mode)")
    }

    /// Disconnects from tmux control mode
    func disconnect() async {
        logger.info("Disconnecting from tmux control mode")

        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        dataContinuation?.finish()
        dataContinuation = nil
        consumerTask?.cancel()
        consumerTask = nil

        // Cancel all pending commands
        for entry in pendingCommandQueue {
            entry.continuation.resume(throwing: TmuxControlError.notConnected)
        }
        pendingCommandQueue.removeAll()
        receivedInitialResponse = false
        skippingInitialBlock = false

        if let process, process.isRunning {
            process.terminate()
        }

        stdin = nil
        stdoutPipe = nil
        process = nil

        // Clear state
        cachedDimensions.removeAll()
        byteBuffer.removeAll()
    }

    // MARK: - Dimension Tracking

    /// Registers initial dimensions for a pane so layout-change events can detect changes.
    func registerPaneDimensions(paneId: String, width: Int, height: Int) {
        cachedDimensions[paneId] = (width, height)
        logger.debug("Registered pane dimensions", metadata: ["paneId": "\(paneId)"])
    }

    /// Unregisters a pane from dimension tracking.
    func unregisterPane(paneId: String) {
        cachedDimensions.removeValue(forKey: paneId)
        logger.debug("Unregistered pane", metadata: ["paneId": "\(paneId)"])
    }

    // MARK: - Command Execution

    /// Sends a command to tmux and waits for the response
    func sendCommand(_ command: String, timeout: TimeInterval = 5) async throws -> CommandResponse {
        guard let stdin else {
            throw TmuxControlError.notConnected
        }

        commandCounter += 1
        let commandNumber = commandCounter

        // Write command with newline
        let commandData = Data((command + "\n").utf8)
        try stdin.write(contentsOf: commandData)

        // Create timeout task that we can cancel on success
        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(timeout))
            // Remove from queue on timeout
            if let idx = self.pendingCommandQueue.firstIndex(where: { $0.id == commandNumber }) {
                let entry = self.pendingCommandQueue.remove(at: idx)
                entry.continuation.resume(throwing: TmuxControlError.timeout)
            }
        }

        // Wait for response
        do {
            let response = try await withCheckedThrowingContinuation { continuation in
                pendingCommandQueue.append((id: commandNumber, continuation: continuation))
            }
            timeoutTask.cancel()
            return response
        } catch {
            timeoutTask.cancel()
            throw error
        }
    }

    // MARK: - Read Loop

    private func processIncomingData(_ data: Data) async {
        // Append raw bytes to buffer first (handles chunk splitting)
        byteBuffer.append(data)

        // Process complete lines (ending with newline byte 0x0A)
        let newlineByte: UInt8 = 0x0A

        while let newlineIndex = byteBuffer.firstIndex(of: newlineByte) {
            let lineData = Data(byteBuffer[..<newlineIndex])
            byteBuffer = Data(byteBuffer[(newlineIndex + 1)...])

            // All lines are control messages (no %output with no-output flag)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            parseLine(line)
        }
    }

    // MARK: - Line Parsing

    private func parseLine(_ line: String) {
        if line.hasPrefix("%layout-change ") {
            handleLayoutChange(line)
        } else if line.hasPrefix("%begin ") {
            parseBeginBlock(line)
        } else if line.hasPrefix("%end ") {
            parseEndBlock(line)
        } else if line.hasPrefix("%error ") {
            parseErrorBlock(line)
        } else if line.hasPrefix("%exit") {
            parseExit(line)
        } else if line.hasPrefix("%session-changed ") {
            parseSessionChanged(line)
        } else if currentCommandNumber != nil {
            // Accumulating command output
            currentCommandOutput.append(line)
        }
    }

    // MARK: - Layout Change Handling

    private func handleLayoutChange(_ line: String) {
        logger.debug("Layout change detected")

        // Extract pane dimensions directly from the layout string in the event.
        // Format: "%layout-change @<window-id> <layout-string> [<visible-layout>]"
        // This fires BEFORE pipe-pane delivers the shell's SIGWINCH redraw data,
        // so the terminal resizes before processing absolute cursor positioning
        // sequences that assume the new column count.
        let parts = line.split(separator: " ", maxSplits: 2)
        if parts.count >= 3 {
            let layoutString = String(parts[2])
            if let layout = TmuxLayoutParser.parse(layoutString) {
                updateTrackedDimensionsFromLayout(layout)
            }
        }

        // Still refresh via list-panes to detect pane exits (panes no longer in layout)
        Task { [weak self] in
            await self?.refreshStreamingPaneDimensions()
        }
        // Notify listeners that the layout changed — this triggers a full pane list
        // refresh so new panes (splits) and layout string updates are detected instantly
        // instead of waiting for the 5-second polling timer.
        _onLayoutChange?()
    }

    /// Walks the layout tree and fires dimension change callbacks for tracked panes
    /// whose dimensions differ from cached values.
    private func updateTrackedDimensionsFromLayout(_ node: LayoutNode) {
        switch node {
        case let .pane(id, width, height):
            let paneId = "%\(id)"
            if
                let cached = cachedDimensions[paneId],
                cached.width != width || cached.height != height {
                cachedDimensions[paneId] = (width, height)
                logger.debug("Pane dimension changed (from layout)", metadata: [
                    "paneId": "\(paneId)",
                    "width": "\(width)",
                    "height": "\(height)",
                ])
                _onDimensionChange?(paneId, width, height)
            }
        case let .horizontal(children, _, _),
             let .vertical(children, _, _):
            for child in children {
                updateTrackedDimensionsFromLayout(child)
            }
        }
    }

    private func refreshStreamingPaneDimensions() async {
        guard !cachedDimensions.isEmpty else { return }

        do {
            let response = try await sendCommand("list-panes -a -F '#{pane_id} #{pane_width} #{pane_height}'")

            // Collect pane IDs that still exist
            var existingPaneIds = Set<String>()

            for line in response.lines where !line.isEmpty {
                let parts = line.split(separator: " ")
                guard
                    parts.count == 3,
                    let width = Int(parts[1]),
                    let height = Int(parts[2]) else { continue }

                let paneId = String(parts[0])
                existingPaneIds.insert(paneId)

                // Only notify for panes we're tracking
                if
                    let cached = cachedDimensions[paneId],
                    cached.width != width || cached.height != height {
                    cachedDimensions[paneId] = (width, height)
                    logger.debug("Pane dimension changed", metadata: [
                        "paneId": "\(paneId)",
                        "width": "\(width)",
                        "height": "\(height)",
                    ])
                    _onDimensionChange?(paneId, width, height)
                }
            }

            // Check for panes we're tracking that no longer exist
            let trackedPaneIds = Set(cachedDimensions.keys)
            let exitedPaneIds = trackedPaneIds.subtracting(existingPaneIds)

            for paneId in exitedPaneIds {
                logger.info("Pane exited (no longer in list)", metadata: ["paneId": "\(paneId)"])
                cachedDimensions.removeValue(forKey: paneId)
                _onPaneExited?(paneId)
            }
        } catch {
            logger.error("Failed to refresh pane dimensions: \(error.localizedDescription)")
        }
    }

    // MARK: - Command Response Parsing

    private func parseBeginBlock(_ line: String) {
        // Format: %begin <timestamp> <command-number> <flags>
        let parts = line.split(separator: " ")
        guard
            parts.count >= 3,
            let tmuxCommandNumber = Int(parts[2]) else { return }

        // Skip the initial attach response (first %begin/%end after connecting).
        // This is tmux's response to the `tmux -C attach` command itself,
        // not a command we sent via sendCommand().
        if !receivedInitialResponse {
            receivedInitialResponse = true
            skippingInitialBlock = true
            currentCommandNumber = tmuxCommandNumber
            currentCommandOutput = []
            currentCommandIsError = false
            return
        }

        currentCommandNumber = tmuxCommandNumber
        currentCommandOutput = []
        currentCommandIsError = false
    }

    private func parseEndBlock(_ line: String) {
        // Format: %end <timestamp> <command-number> <flags>
        let parts = line.split(separator: " ")
        guard
            parts.count >= 3,
            let tmuxCommandNumber = Int(parts[2]),
            tmuxCommandNumber == currentCommandNumber else { return }

        let response = CommandResponse(
            commandNumber: tmuxCommandNumber,
            output: currentCommandOutput.joined(separator: "\n"),
            isError: currentCommandIsError
        )

        // Skip the initial attach response (flagged in parseBeginBlock)
        if skippingInitialBlock {
            skippingInitialBlock = false
            currentCommandNumber = nil
            currentCommandOutput = []
            return
        }

        // Pop the front of the FIFO queue — tmux responds in the same order
        // we wrote commands to stdin. Every %begin/%end after the initial attach
        // corresponds 1:1 with a sendCommand() call.
        if !pendingCommandQueue.isEmpty {
            let entry = pendingCommandQueue.removeFirst()
            entry.continuation.resume(returning: response)
        }

        currentCommandNumber = nil
        currentCommandOutput = []
    }

    private func parseErrorBlock(_ line: String) {
        // Format: %error <timestamp> <command-number> <flags>
        currentCommandIsError = true
    }

    // MARK: - Session and Exit Parsing

    private func parseSessionChanged(_ line: String) {
        // Format: %session-changed $<session-id> <session-name>
        let parts = line.split(separator: " ")
        guard parts.count >= 3 else { return }

        let sessionId = String(parts[1])
        let sessionName = String(parts[2])

        logger.info("Session changed", metadata: [
            "sessionId": "\(sessionId)",
            "sessionName": "\(sessionName)",
        ])

        _onSessionChanged?(sessionId, sessionName)
    }

    private func parseExit(_ line: String) {
        // Format: %exit [reason]
        let reason = line.hasPrefix("%exit ") ? String(line.dropFirst("%exit ".count)) : nil

        logger.info("tmux control mode exited", metadata: [
            "reason": "\(reason ?? "none")",
        ])

        _onExit?(reason)
    }

    private func handleProcessTermination(exitCode: Int32) async {
        logger.warning("tmux process terminated", metadata: [
            "exitCode": "\(exitCode)",
        ])

        // Cancel all pending commands
        for entry in pendingCommandQueue {
            entry.continuation.resume(throwing: TmuxControlError.processTerminated(reason: "Exit code: \(exitCode)"))
        }
        pendingCommandQueue.removeAll()

        _onExit?("Process terminated with code \(exitCode)")

        // Clean up
        process = nil
        stdin = nil
        stdoutPipe = nil
    }
}
