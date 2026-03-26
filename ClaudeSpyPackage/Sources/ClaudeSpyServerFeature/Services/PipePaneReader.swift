#if os(macOS)
    import ClaudeSpyCommon
    import ClaudeSpyNetworking
    import Foundation
    import Logging

    /// Manages FIFO-based raw byte delivery from tmux pipe-pane for a single pane.
    ///
    /// Instead of parsing `%output` events from control mode (which requires octal unescaping,
    /// UTF-8 reconstruction, and line-boundary handling), this reads raw PTY bytes directly
    /// via `pipe-pane -O` piped through a FIFO. The only filtering needed is stripping
    /// tmux's `ESC k ... ESC \` title sequences.
    ///
    /// FIFO connection sequence:
    /// 1. Create FIFO with `mkfifo()`
    /// 2. Send `pipe-pane` command through control mode (returns immediately)
    /// 3. tmux starts `cat > fifo` subprocess (blocks on open until reader connects)
    /// 4. Open FIFO for reading (unblocks writer, data flows)
    actor PipePaneReader {
        private let paneId: String
        private let logger: Logger

        // FIFO state
        private let fifoPath: String
        private var fileHandle: FileHandle?
        private var isRunning = false

        // Data delivery
        private var dataHandler: (@Sendable (Data) -> Void)?
        private var notificationHandler: (@Sendable (TerminalStreamMessage.TerminalNotification) -> Void)?
        private var titleChangeHandler: (@Sendable (String) -> Void)?

        // AsyncStream for FIFO-ordered data processing.
        // readabilityHandler yields into this stream; a single consumer task
        // processes chunks in order, preventing the reordering that occurs
        // with unstructured Task {} per callback.
        private var dataContinuation: AsyncStream<Data>.Continuation?
        private var consumerTask: Task<Void, Never>?

        // Buffering during initial capture
        private var isBuffering = false
        private var buffer: [Data] = []

        // Incomplete tmux escape sequence buffer (ESC k ... ESC \ split across reads)
        private var tmuxEscapeBuffer = Data()

        // Parser for OSC 9/777 notification sequences
        private var notificationParser: TerminalNotificationParser

        init(paneId: String, scanOnly: Bool = false) {
            self.notificationParser = TerminalNotificationParser(scanOnly: scanOnly)
            self.paneId = paneId
            self.logger = Logger(label: "com.claudespy.pipepane.\(paneId)")

            // Sanitize pane ID for filesystem: "%5" -> "5"
            let sanitized = paneId.replacingOccurrences(of: "%", with: "")
            precondition(
                !sanitized.isEmpty && sanitized.allSatisfy(\.isNumber),
                "Pane ID must contain only digits after stripping '%', got: \(paneId)"
            )
            let tmpDir = FileManager.default.temporaryDirectory.path
            self.fifoPath = "\(tmpDir)/claudespy-pipe-\(sanitized).fifo"
        }

        // MARK: - Public API

        /// Sets the handler for incoming raw data.
        func setDataHandler(_ handler: @escaping @Sendable (Data) -> Void) {
            dataHandler = handler
        }

        /// Sets the handler for terminal notifications (OSC 9/777).
        func setNotificationHandler(_ handler: @escaping @Sendable (TerminalStreamMessage.TerminalNotification) -> Void) {
            notificationHandler = handler
        }

        /// Sets the handler for terminal title changes (OSC 0/2).
        func setTitleChangeHandler(_ handler: @escaping @Sendable (String) -> Void) {
            titleChangeHandler = handler
        }

        /// Starts pipe-pane for this pane, creating the FIFO and opening it for reading.
        ///
        /// - Parameter controlClientManager: Used to send the pipe-pane command
        /// - Parameter sessionName: The tmux session name for the control client
        /// - Parameter buffering: If true, data is buffered until `stopBufferingAndFlush()` is called
        func startPipePane(
            controlClientManager: TmuxControlClientManager,
            sessionName: String,
            buffering: Bool = true
        ) async throws {
            guard !isRunning else {
                logger.warning("pipe-pane already running for \(paneId)")
                return
            }

            isBuffering = buffering
            buffer = []

            // Clean up any stale FIFO from a previous crash
            cleanupFifo()

            // Step 1: Create FIFO (retry once if stale file persists after cleanup)
            var result = mkfifo(fifoPath, 0o600)
            if result != 0, errno == EEXIST {
                logger.warning("FIFO still exists after cleanup, force-removing: \(fifoPath)")
                try? FileManager.default.removeItem(atPath: fifoPath)
                result = mkfifo(fifoPath, 0o600)
            }
            guard result == 0 else {
                let errorMessage = String(cString: strerror(errno))
                throw PipePaneError.fifoCreationFailed(path: fifoPath, message: errorMessage)
            }

            logger.debug("Created FIFO at \(fifoPath)")

            // Step 2: Stop any existing pipe-pane for this pane, then start new one
            _ = try? await controlClientManager.sendCommand(
                "pipe-pane -t '\(paneId)'",
                sessionName: sessionName
            )
            _ = try await controlClientManager.sendCommand(
                "pipe-pane -O -t '\(paneId)' 'exec cat > \"\(fifoPath)\"'",
                sessionName: sessionName
            )

            logger.debug("pipe-pane command sent for \(paneId)")

            // Step 3: Open FIFO for reading (this unblocks the cat writer)
            // Must be done on a background thread since open() blocks until writer connects
            let path = fifoPath
            let handle = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<FileHandle, any Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let fd = open(path, O_RDONLY | O_NONBLOCK)
                    if fd < 0 {
                        let errorMessage = String(cString: strerror(errno))
                        continuation.resume(throwing: PipePaneError.fifoOpenFailed(
                            path: path, message: errorMessage
                        ))
                    } else {
                        continuation.resume(returning: FileHandle(fileDescriptor: fd, closeOnDealloc: true))
                    }
                }
            }

            fileHandle = handle
            isRunning = true

            // Step 4: Set up AsyncStream for FIFO-ordered data delivery.
            // readabilityHandler fires on a dispatch queue — yielding into the stream
            // is synchronous and non-blocking. A single consumer task drains the stream
            // in order, guaranteeing no data reordering.
            let (stream, continuation) = AsyncStream<Data>.makeStream()
            dataContinuation = continuation

            // Note: readabilityHandler captures `continuation` strongly, so the handler
            // keeps yielding if PipePaneReader is deallocated without stopPipePane().
            // Callers MUST call stopPipePane() to clean up — see PaneStream.disconnect().
            let fd = handle.fileDescriptor
            handle.readabilityHandler = { [weak self] _ in
                // Read directly from the file descriptor to avoid NSFileHandle's
                // -availableData which throws an uncatchable NSException if the
                // descriptor was closed between the dispatch source firing and
                // the handler executing.
                var buf = [UInt8](repeating: 0, count: 65_536)
                let bytesRead = read(fd, &buf, buf.count)
                guard bytesRead > 0 else {
                    // EOF or error — cat process died or pipe-pane stopped
                    continuation.finish()
                    Task { [weak self] in
                        await self?.handleEOF()
                    }
                    return
                }
                continuation.yield(Data(buf[..<bytesRead]))
            }

            // Single consumer task — processes data in strict FIFO order
            consumerTask = Task { [weak self] in
                for await data in stream {
                    await self?.processIncomingData(data)
                }
            }

            logger.info("pipe-pane started for \(paneId)")
        }

        /// Stops buffering and flushes all buffered data to the handler.
        func stopBufferingAndFlush() {
            guard isBuffering else { return }
            isBuffering = false

            let bufferedData = buffer
            buffer = []

            for data in bufferedData {
                dataHandler?(data)
            }

            logger.debug("Flushed \(bufferedData.count) buffered chunks for \(paneId)")
        }

        /// Stops pipe-pane and cleans up all resources.
        ///
        /// - Parameter controlClientManager: Used to send the stop pipe-pane command
        /// - Parameter sessionName: The tmux session name
        func stopPipePane(
            controlClientManager: TmuxControlClientManager,
            sessionName: String
        ) async {
            guard isRunning else { return }

            logger.debug("Stopping pipe-pane for \(paneId)")

            // Stop the readability handler and stream first
            fileHandle?.readabilityHandler = nil
            dataContinuation?.finish()
            dataContinuation = nil
            consumerTask?.cancel()
            consumerTask = nil
            try? fileHandle?.close()
            fileHandle = nil

            // Stop pipe-pane in tmux (this terminates the cat process)
            _ = try? await controlClientManager.sendCommand(
                "pipe-pane -t '\(paneId)'",
                sessionName: sessionName
            )

            // Clean up FIFO
            cleanupFifo()

            isRunning = false
            isBuffering = false
            buffer = []
            tmuxEscapeBuffer = Data()
            notificationParser.reset()
            dataHandler = nil
            notificationHandler = nil
            titleChangeHandler = nil

            logger.info("pipe-pane stopped for \(paneId)")
        }

        // MARK: - Data Processing

        private func processIncomingData(_ data: Data) {
            // Filter tmux-specific escape sequences (ESC k ... ESC \)
            let tmuxFiltered = filterTmuxEscapeSequences(data)
            guard !tmuxFiltered.isEmpty else { return }

            // Strip DA query sequences so mirroring SwiftTerm instances never
            // see them and never generate response bytes in their send() delegate.
            let daFiltered = TerminalResponseFilter.stripDAQueries(tmuxFiltered)
            guard !daFiltered.isEmpty else { return }

            // Strip Kitty keyboard protocol negotiation sequences so mirroring
            // SwiftTerm instances never enter an unsupported keyboard mode.
            let kittyFiltered = TerminalResponseFilter.stripKittyKeyboardProtocol(daFiltered)
            guard !kittyFiltered.isEmpty else { return }

            // Parse and strip OSC 9/777 notification sequences
            let parseResult = notificationParser.parse(kittyFiltered)

            // Report any detected notifications
            for notification in parseResult.notifications {
                notificationHandler?(notification)
            }

            // Report title changes (OSC 0/2)
            if let title = parseResult.titleChange {
                titleChangeHandler?(title)
            }

            let filtered = parseResult.filteredData
            guard !filtered.isEmpty else { return }

            if isBuffering {
                buffer.append(filtered)
            } else {
                dataHandler?(filtered)
            }
        }

        /// Filters out tmux/screen-specific escape sequences that standard terminals don't handle.
        /// - `ESC k ... ESC \` : tmux title sequence (sets pane title)
        /// Without filtering, terminals output the sequence content as literal text.
        /// Buffers incomplete sequences across reads to handle split data.
        private func filterTmuxEscapeSequences(_ data: Data) -> Data {
            var result = Data()

            // Prepend any buffered incomplete sequence from previous read
            var dataToProcess = data
            if !tmuxEscapeBuffer.isEmpty {
                dataToProcess = tmuxEscapeBuffer + data
                tmuxEscapeBuffer = Data()
            }

            var i = dataToProcess.startIndex

            while i < dataToProcess.endIndex {
                if dataToProcess[i] == 0x1B { // ESC
                    if i + 1 >= dataToProcess.endIndex {
                        // Incomplete: just ESC at end, buffer it
                        tmuxEscapeBuffer = Data(dataToProcess[i...])
                        break
                    }

                    if dataToProcess[i + 1] == 0x6B { // 'k'
                        // ESC k - start of tmux title sequence
                        // Skip until we find ESC \ (0x1B 0x5C) or end of data
                        var j = dataToProcess.index(i, offsetBy: 2)
                        var foundEnd = false

                        while j < dataToProcess.endIndex {
                            if dataToProcess[j] == 0x1B {
                                if j + 1 >= dataToProcess.endIndex {
                                    // ESC at end while inside sequence - buffer from start
                                    tmuxEscapeBuffer = Data(dataToProcess[i...])
                                    return result
                                }
                                if dataToProcess[j + 1] == 0x5C { // '\'
                                    // Found ESC \ - skip entire sequence
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
                            // Reached end without finding ESC \ - buffer incomplete sequence
                            tmuxEscapeBuffer = Data(dataToProcess[i...])
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

        // MARK: - Test Helpers

        /// Exposes filterTmuxEscapeSequences for testing.
        func testFilterTmuxEscapeSequences(_ data: Data) -> Data {
            filterTmuxEscapeSequences(data)
        }

        /// Exposes processIncomingData for testing.
        func testProcessIncomingData(_ data: Data) {
            processIncomingData(data)
        }

        /// Exposes fifoPath for testing.
        var testFifoPath: String {
            fifoPath
        }

        /// Sets buffering state for testing.
        func testSetBuffering(_ enabled: Bool) {
            isBuffering = enabled
            if enabled {
                buffer = []
            }
        }

        // MARK: - Lifecycle

        private func handleEOF() {
            logger.warning("EOF on pipe-pane FIFO for \(paneId) — cat process may have died")
            // Don't clean up here — the caller (PaneStream) should handle reconnection
            // or cleanup via stopPipePane()
            fileHandle?.readabilityHandler = nil
        }

        private func cleanupFifo() {
            unlink(fifoPath)
        }

        /// Cleans up stale FIFOs from previous crashes.
        /// Call once at startup.
        static func cleanupStaleFifos() {
            let fm = FileManager.default
            let tmpDir = fm.temporaryDirectory.path
            guard let contents = try? fm.contentsOfDirectory(atPath: tmpDir) else { return }
            for file in contents where file.hasPrefix("claudespy-pipe-") && file.hasSuffix(".fifo") {
                let path = "\(tmpDir)/\(file)"
                try? fm.removeItem(atPath: path)
                Logger(label: "com.claudespy.pipepane").debug("Cleaned up stale FIFO: \(path)")
            }
        }
    }

    // MARK: - Errors

    enum PipePaneError: Error, LocalizedError {
        case fifoCreationFailed(path: String, message: String)
        case fifoOpenFailed(path: String, message: String)

        var errorDescription: String? {
            switch self {
            case let .fifoCreationFailed(path, message):
                return "Failed to create FIFO at \(path): \(message)"
            case let .fifoOpenFailed(path, message):
                return "Failed to open FIFO at \(path): \(message)"
            }
        }
    }
#endif
