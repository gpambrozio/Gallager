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

/// Manages a tmux control mode connection for real-time pane streaming
///
/// Control mode provides structured event notifications:
/// - `%output %<pane-id> <data>` for terminal data
/// - `%layout-change` when panes resize
/// - `%session-changed` when sessions change
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

    // Pane handlers - keyed by pane ID (e.g., "%0")
    private var paneHandlers: [String: @Sendable (Data) -> Void] = [:]

    // Callbacks for notifications
    private var _onDimensionChange: (@Sendable (String, Int, Int) -> Void)?
    private var _onPaneExited: (@Sendable (String) -> Void)?
    private var _onSessionChanged: (@Sendable (String, String) -> Void)?
    private var _onExit: (@Sendable (String?) -> Void)?

    // Pending command responses
    private var pendingCommands: [Int: CheckedContinuation<CommandResponse, any Error>] = [:]
    private var commandCounter = 0

    // Current command being accumulated (for %begin/%end blocks)
    private var currentCommandNumber: Int?
    private var currentCommandOutput: [String] = []
    private var currentCommandIsError = false

    // Output buffering during resize
    private var isBufferingOutput = false
    private var outputBuffer: [(paneId: String, data: Data)] = []

    // Byte buffer for incomplete lines (handles chunk splitting at line boundaries)
    private var byteBuffer = Data()

    // Per-pane buffer for incomplete UTF-8 sequences (tmux splits UTF-8 across %output lines)
    private var paneUtf8Buffer: [String: Data] = [:]

    // Per-pane buffer for incomplete tmux escape sequences (e.g., ESC k ... ESC \ split across chunks)
    private var paneTmuxEscapeBuffer: [String: Data] = [:]

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

    func setOnSessionChanged(_ handler: @escaping @Sendable (String, String) -> Void) {
        _onSessionChanged = handler
    }

    func setOnExit(_ handler: @escaping @Sendable (String?) -> Void) {
        _onExit = handler
    }

    // MARK: - Connection Management

    /// Connects to a tmux session in control mode
    func connect(sessionTarget: String) async throws {
        guard process == nil else {
            throw TmuxControlError.alreadyConnected
        }

        logger.info("Connecting to tmux control mode", metadata: [
            "session": "\(sessionTarget)",
        ])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)

        var arguments = ["-C", "attach", "-t", sessionTarget]
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

        // Start reading output
        let handle = stdoutPipe.fileHandleForReading

        // Set up readability handler
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            Task { [weak self] in
                await self?.processIncomingData(data)
            }
        }

        logger.info("Connected to tmux control mode")
    }

    /// Disconnects from tmux control mode
    func disconnect() async {
        logger.info("Disconnecting from tmux control mode")

        stdoutPipe?.fileHandleForReading.readabilityHandler = nil

        // Cancel all pending commands
        for (_, continuation) in pendingCommands {
            continuation.resume(throwing: TmuxControlError.notConnected)
        }
        pendingCommands.removeAll()

        if let process, process.isRunning {
            process.terminate()
        }

        stdin = nil
        stdoutPipe = nil
        process = nil

        // Clear state
        paneHandlers.removeAll()
        cachedDimensions.removeAll()
        outputBuffer.removeAll()
        isBufferingOutput = false
        byteBuffer.removeAll()
        paneUtf8Buffer.removeAll()
        paneTmuxEscapeBuffer.removeAll()
    }

    // MARK: - Pane Tracking

    /// Registers a handler to receive output for a specific pane
    func registerPaneHandler(paneId: String, initialDimensions: (width: Int, height: Int), handler: @escaping @Sendable (Data) -> Void) {
        paneHandlers[paneId] = handler
        cachedDimensions[paneId] = initialDimensions
        logger.debug("Registered pane handler", metadata: ["paneId": "\(paneId)"])
    }

    /// Unregisters a pane handler
    func unregisterPaneHandler(paneId: String) {
        paneHandlers.removeValue(forKey: paneId)
        cachedDimensions.removeValue(forKey: paneId)
        paneUtf8Buffer.removeValue(forKey: paneId)
        paneTmuxEscapeBuffer.removeValue(forKey: paneId)
        logger.debug("Unregistered pane handler", metadata: ["paneId": "\(paneId)"])
    }

    // MARK: - Command Execution

    /// Sends a command to tmux and waits for the response
    func sendCommand(_ command: String, timeout: TimeInterval = 5) async throws -> CommandResponse {
        guard let stdin else {
            throw TmuxControlError.notConnected
        }

        commandCounter += 1
        let commandNumber = commandCounter

        logger.debug("Sending command", metadata: [
            "command": "\(command)",
            "number": "\(commandNumber)",
        ])

        // Write command with newline
        let commandData = Data((command + "\n").utf8)
        try stdin.write(contentsOf: commandData)

        // Create timeout task that we can cancel on success
        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(timeout))
            if let cont = self.pendingCommands.removeValue(forKey: commandNumber) {
                cont.resume(throwing: TmuxControlError.timeout)
            }
        }

        // Wait for response
        do {
            let response = try await withCheckedThrowingContinuation { continuation in
                pendingCommands[commandNumber] = continuation
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

            // Parse at byte level - %output lines may contain invalid UTF-8
            await parseLineBytes(lineData)
        }
    }

    /// Parses a line at the byte level to handle %output with split UTF-8
    private func parseLineBytes(_ lineData: Data) async {
        // Check for %output prefix (which may contain raw UTF-8 that's been split)
        let outputPrefix = Data("%output %".utf8)
        if lineData.starts(with: outputPrefix) {
            parseOutputNotificationBytes(lineData)
            return
        }

        // For all other control messages, convert to string (they should be ASCII)
        guard let line = String(data: lineData, encoding: .utf8) else {
            // Non-%output line with invalid UTF-8 - skip
            return
        }

        await parseLine(line)
    }

    // MARK: - Line Parsing

    private func parseLine(_ line: String) async {
        // Note: %output lines are handled at byte level in parseLineBytes
        if line.hasPrefix("%layout-change ") {
            await handleLayoutChange()
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

    // MARK: - %output Parsing (Byte Level)

    /// Parses %output at byte level to handle split UTF-8 characters
    private func parseOutputNotificationBytes(_ lineData: Data) {
        // Format: %output %<pane-id> <data>
        // The pane ID is ASCII, but data may contain raw/split UTF-8

        let prefixLength = "%output %".count

        // Find the space after pane ID (pane ID is single digit or short number)
        guard let spaceIndex = lineData.dropFirst(prefixLength).firstIndex(of: 0x20) else { return }

        // Extract pane ID (ASCII)
        let paneIdData = lineData[prefixLength..<spaceIndex]
        guard let paneIdStr = String(data: Data(paneIdData), encoding: .utf8) else { return }
        let paneId = "%" + paneIdStr

        // Extract data portion as raw bytes (may contain split UTF-8)
        let dataStart = lineData.index(after: spaceIndex)
        let rawData = Data(lineData[dataStart...])

        // Unescape the data (convert \033 etc to bytes)
        // Note: unescapeOutput works on String, so we need to handle this carefully
        // The escaped format uses ASCII backslash + digits, which is always valid UTF-8
        // But raw UTF-8 chars may also be present

        // First, try to convert to string for unescaping
        // If it fails, we have orphaned continuation bytes - prepend buffered data
        var dataToProcess = rawData

        // Prepend any buffered incomplete UTF-8 from previous %output
        if let buffered = paneUtf8Buffer[paneId], !buffered.isEmpty {
            dataToProcess = buffered + dataToProcess
            paneUtf8Buffer[paneId] = nil
        }

        // Now try to convert to string for unescaping
        // The data may still have incomplete UTF-8 at the END
        let unescapedData = unescapeOutputBytes(dataToProcess)

        // Check for incomplete UTF-8 at end and buffer it
        let (completeData, incompleteTrailing) = splitIncompleteUtf8Trailing(unescapedData)
        if !incompleteTrailing.isEmpty {
            paneUtf8Buffer[paneId] = incompleteTrailing
        }

        if isBufferingOutput {
            outputBuffer.append((paneId, completeData))
        } else {
            deliverOutput(paneId: paneId, data: completeData)
        }
    }

    /// Unescapes tmux output working at byte level
    /// Handles both octal escapes (\033) and raw UTF-8 bytes
    func unescapeOutputBytes(_ data: Data) -> Data {
        var result = Data()
        var i = data.startIndex

        while i < data.endIndex {
            let byte = data[i]

            if byte == 0x5C { // backslash
                let next = data.index(after: i)
                if next < data.endIndex {
                    let nextByte = data[next]
                    if nextByte == 0x5C {
                        // Escaped backslash
                        result.append(0x5C)
                        i = data.index(after: next)
                    } else if nextByte >= 0x30 && nextByte <= 0x37 { // '0'-'7' octal digit
                        // Octal escape \xxx
                        var octalEnd = next
                        var digitCount = 0
                        while octalEnd < data.endIndex && digitCount < 3 {
                            let d = data[octalEnd]
                            if d >= 0x30 && d <= 0x37 { // '0'-'7'
                                octalEnd = data.index(after: octalEnd)
                                digitCount += 1
                            } else {
                                break
                            }
                        }
                        let octalBytes = Data(data[next..<octalEnd])
                        if
                            let octalStr = String(data: octalBytes, encoding: .ascii),
                            let value = UInt8(octalStr, radix: 8) {
                            result.append(value)
                        }
                        i = octalEnd
                    } else {
                        // Unknown escape - keep backslash
                        result.append(0x5C)
                        i = next
                    }
                } else {
                    // Backslash at end
                    result.append(0x5C)
                    i = data.index(after: i)
                }
            } else {
                // Regular byte (including raw UTF-8)
                result.append(byte)
                i = data.index(after: i)
            }
        }
        return result
    }

    /// Splits data into complete UTF-8 and any trailing incomplete sequence
    /// Returns (complete, incomplete) where incomplete may be empty
    /// Splits data into complete UTF-8 and any trailing incomplete sequence
    /// Returns (complete, incomplete) where incomplete may be empty
    /// Internal for testing
    func splitIncompleteUtf8Trailing(_ data: Data) -> (Data, Data) {
        guard !data.isEmpty else { return (data, Data()) }

        // Check last 1-3 bytes for incomplete UTF-8 sequence
        // UTF-8 lead bytes: 0xC0-0xDF (2-byte), 0xE0-0xEF (3-byte), 0xF0-0xF7 (4-byte)
        // Continuation bytes: 0x80-0xBF

        let count = data.count

        // Check if last byte is a lead byte (incomplete sequence of 1 byte)
        let last = data[count - 1]
        if last >= 0xC0 && last <= 0xF7 {
            // Lead byte at end - incomplete
            return (data.dropLast(1), Data([last]))
        }

        // Check last 2 bytes for 3 or 4 byte sequence with only 2 bytes
        if count >= 2 {
            let secondLast = data[count - 2]
            // 3-byte lead (0xE0-0xEF) or 4-byte lead (0xF0-0xF7) followed by 1 continuation
            if (secondLast >= 0xE0 && secondLast <= 0xF7) && (last >= 0x80 && last <= 0xBF) {
                return (data.dropLast(2), Data(data.suffix(2)))
            }
        }

        // Check last 3 bytes for 4 byte sequence with only 3 bytes
        if count >= 3 {
            let thirdLast = data[count - 3]
            let secondLast = data[count - 2]
            // 4-byte lead followed by 2 continuations
            if
                (thirdLast >= 0xF0 && thirdLast <= 0xF7) &&
                (secondLast >= 0x80 && secondLast <= 0xBF) &&
                (last >= 0x80 && last <= 0xBF) {
                return (data.dropLast(3), Data(data.suffix(3)))
            }
        }

        // No incomplete sequence at end
        return (data, Data())
    }

    private func deliverOutput(paneId: String, data: Data) {
        guard let handler = paneHandlers[paneId] else { return }
        // Filter out tmux-specific escape sequences that terminals don't understand
        let filtered = filterTmuxEscapeSequences(data, paneId: paneId)
        guard !filtered.isEmpty else { return }
        handler(filtered)
    }

    /// Filters out tmux/screen-specific escape sequences that standard terminals don't handle.
    /// - ESC k ... ESC \ : tmux title sequence (sets pane title)
    /// Without filtering, terminals output the sequence content as literal text.
    /// Buffers incomplete sequences across chunks to handle split data.
    private func filterTmuxEscapeSequences(_ data: Data, paneId: String) -> Data {
        var result = Data()

        // Prepend any buffered incomplete sequence from previous chunk
        var dataToProcess = data
        if let buffered = paneTmuxEscapeBuffer[paneId], !buffered.isEmpty {
            dataToProcess = buffered + data
            paneTmuxEscapeBuffer[paneId] = nil
        }

        var i = dataToProcess.startIndex

        while i < dataToProcess.endIndex {
            // Check for ESC (0x1B)
            if dataToProcess[i] == 0x1B {
                // Check if we have at least one more byte to determine sequence type
                if i + 1 >= dataToProcess.endIndex {
                    // Incomplete: just ESC at end, buffer it
                    paneTmuxEscapeBuffer[paneId] = Data(dataToProcess[i...])
                    break
                }

                if dataToProcess[i + 1] == 0x6B {
                    // ESC k - start of tmux title sequence
                    // Skip until we find ESC \ (0x1B 0x5C) or end of data
                    var j = dataToProcess.index(i, offsetBy: 2) // Skip ESC k
                    var foundEnd = false

                    while j < dataToProcess.endIndex {
                        if dataToProcess[j] == 0x1B {
                            if j + 1 >= dataToProcess.endIndex {
                                // ESC at end while inside sequence - buffer from start of sequence
                                paneTmuxEscapeBuffer[paneId] = Data(dataToProcess[i...])
                                return result
                            }
                            if dataToProcess[j + 1] == 0x5C {
                                // Found ESC \ - skip it and mark sequence complete
                                j = dataToProcess.index(j, offsetBy: 2)
                                foundEnd = true
                                break
                            }
                        }
                        j = dataToProcess.index(after: j)
                    }

                    if foundEnd {
                        i = j
                    } else {
                        // Reached end without finding ESC \ - buffer the incomplete sequence
                        paneTmuxEscapeBuffer[paneId] = Data(dataToProcess[i...])
                        break
                    }
                } else {
                    // ESC followed by something other than 'k' - pass through
                    result.append(dataToProcess[i])
                    i = dataToProcess.index(after: i)
                }
            } else {
                result.append(dataToProcess[i])
                i = dataToProcess.index(after: i)
            }
        }

        return result
    }

    /// Unescapes tmux control mode output
    /// Control mode escapes non-printable characters as octal \xxx
    func unescapeOutput(_ escaped: String) -> Data {
        var result = Data()
        var i = escaped.startIndex

        while i < escaped.endIndex {
            if escaped[i] == "\\" && escaped.index(after: i) < escaped.endIndex {
                let next = escaped.index(after: i)
                if escaped[next] == "\\" {
                    // Escaped backslash
                    result.append(UInt8(ascii: "\\"))
                    i = escaped.index(after: next)
                } else if escaped[next].isOctalDigit {
                    // Octal escape \xxx
                    let octalStart = next
                    var octalEnd = next
                    var digitCount = 0
                    while octalEnd < escaped.endIndex && escaped[octalEnd].isOctalDigit && digitCount < 3 {
                        octalEnd = escaped.index(after: octalEnd)
                        digitCount += 1
                    }
                    let octalStr = String(escaped[octalStart..<octalEnd])
                    if let value = UInt8(octalStr, radix: 8) {
                        result.append(value)
                    }
                    i = octalEnd
                } else {
                    // Unknown escape - keep backslash
                    result.append(UInt8(ascii: "\\"))
                    i = next
                }
            } else {
                // Regular character
                result.append(contentsOf: String(escaped[i]).utf8)
                i = escaped.index(after: i)
            }
        }
        return result
    }

    // MARK: - Layout Change Handling

    private func handleLayoutChange() async {
        logger.debug("Layout change detected, buffering output")

        // Start buffering output until we've notified clients of new dimensions
        isBufferingOutput = true

        // Ensure buffering is always cleared, even on error
        defer {
            let buffered = outputBuffer
            outputBuffer = []
            isBufferingOutput = false

            for (paneId, data) in buffered {
                deliverOutput(paneId: paneId, data: data)
            }
        }

        await refreshStreamingPaneDimensions()
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

                // Only notify for panes we're streaming
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
                paneHandlers.removeValue(forKey: paneId)
                paneUtf8Buffer.removeValue(forKey: paneId)
                paneTmuxEscapeBuffer.removeValue(forKey: paneId)
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
            let commandNumber = Int(parts[2]) else { return }

        currentCommandNumber = commandNumber
        currentCommandOutput = []
        currentCommandIsError = false
    }

    private func parseEndBlock(_ line: String) {
        // Format: %end <timestamp> <command-number> <flags>
        let parts = line.split(separator: " ")
        guard
            parts.count >= 3,
            let commandNumber = Int(parts[2]),
            commandNumber == currentCommandNumber else { return }

        let response = CommandResponse(
            commandNumber: commandNumber,
            output: currentCommandOutput.joined(separator: "\n"),
            isError: currentCommandIsError
        )

        // Complete the pending command
        // Note: We use the pendingCommands dict indexed by command order, not tmux's command number
        // Find the oldest pending command and complete it
        if let (key, continuation) = pendingCommands.first {
            pendingCommands.removeValue(forKey: key)
            continuation.resume(returning: response)
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
        for (_, continuation) in pendingCommands {
            continuation.resume(throwing: TmuxControlError.processTerminated(reason: "Exit code: \(exitCode)"))
        }
        pendingCommands.removeAll()

        _onExit?("Process terminated with code \(exitCode)")

        // Clean up
        process = nil
        stdin = nil
        stdoutPipe = nil
    }
}

// MARK: - Character Extensions

private extension Character {
    var isOctalDigit: Bool {
        self >= "0" && self <= "7"
    }
}
