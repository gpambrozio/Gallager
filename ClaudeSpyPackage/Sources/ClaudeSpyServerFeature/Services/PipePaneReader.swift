#if os(macOS)
    import ClaudeSpyCommon
    import ClaudeSpyNetworking
    import Foundation
    import Logging

    /// Receives events parsed by `PipePaneReader`.
    ///
    /// All methods are called on the main actor; the reader awaits each call so
    /// events are delivered in strict FIFO order with respect to the underlying
    /// pipe-pane stream.
    @MainActor
    protocol PipePaneReaderDelegate: AnyObject, Sendable {
        func pipePaneReader(_ paneId: String, didReceiveData data: Data)
        func pipePaneReader(
            _ paneId: String,
            didReceiveNotification notification: TerminalStreamMessage.TerminalNotification
        )
        func pipePaneReader(_ paneId: String, didReceiveTitle title: String)
        func pipePaneReader(_ paneId: String, didReceiveClipboard content: String)
        func pipePaneReader(_ paneId: String, didReceiveProgress progress: TerminalProgressState)
    }

    /// Manages FIFO-based raw byte delivery from tmux pipe-pane for a single pane.
    ///
    /// A single `PipePaneReader` lives for the full lifetime of its tmux pane.
    /// It starts in scan-only mode (data discarded, OSC notifications still
    /// extracted) and switches into buffering / live modes via
    /// `setBuffering(_:)` and `flushBuffer()` when subscribers attach.
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
        /// Three data-delivery modes the reader can be in.
        ///
        /// - `scanOnly`: parser is in scan-only mode (no `filteredData` built),
        ///   incoming bytes are discarded. OSC notification/title/clipboard/progress
        ///   events still flow to the delegate. This is the default after start
        ///   and the resting state when no subscribers are attached.
        /// - `buffering`: parser builds `filteredData`, but bytes are queued
        ///   for a later `flushBuffer()` instead of being forwarded. Used during
        ///   an initial `capture-pane` snapshot so live bytes that arrive
        ///   between "buffering on" and "snapshot taken" aren't dropped.
        /// - `live`: parser builds `filteredData` and bytes flow directly to the
        ///   delegate. The state after `flushBuffer()` returns.
        private enum Mode { case scanOnly, buffering, live }

        /// `paneId` never changes after init; expose nonisolated so the delegate
        /// (which receives the id with every callback) doesn't need to cross
        /// actor boundaries to read it.
        nonisolated let paneId: String
        private let logger: Logger

        // FIFO state
        private let fifoPath: String
        private var fileHandle: FileHandle?
        private var isRunning = false

        // Delivery
        private weak var delegate: (any PipePaneReaderDelegate)?
        private var mode: Mode = .scanOnly
        private var buffer: [Data] = []

        // AsyncStream for FIFO-ordered data processing.
        // readabilityHandler yields into this stream; a single consumer task
        // processes chunks in order, preventing the reordering that occurs
        // with unstructured Task {} per callback.
        private var dataContinuation: AsyncStream<Data>.Continuation?
        private var consumerTask: Task<Void, Never>?

        // Incomplete tmux escape sequence buffer (ESC k ... ESC \ split across reads)
        private var tmuxEscapeBuffer = Data()

        // Parser for OSC 9/777 notification sequences. `scanOnly` is flipped
        // by `setBuffering(_:)` so the same instance can be reused across modes.
        private var notificationParser = TerminalNotificationParser(scanOnly: true)

        init(paneId: String) {
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

        /// Sets the delegate that receives parsed events. Stored weakly; the
        /// delegate must outlive the reader.
        func setDelegate(_ delegate: (any PipePaneReaderDelegate)?) {
            self.delegate = delegate
        }

        /// Starts pipe-pane for this pane, creating the FIFO and opening it for reading.
        ///
        /// The reader begins in scan-only mode — bytes are parsed for OSC events
        /// but discarded otherwise. Use `setBuffering(true)` + `flushBuffer()`
        /// when a subscriber attaches and wants live bytes.
        ///
        /// - Parameter controlClientManager: Used to send the pipe-pane command
        /// - Parameter sessionName: The tmux session name for the control client
        func startPipePane(
            controlClientManager: TmuxControlClientManager,
            sessionName: String
        ) async throws {
            guard !isRunning else {
                logger.warning("pipe-pane already running for \(paneId)")
                return
            }

            mode = .scanOnly
            notificationParser.scanOnly = true
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
            // Callers MUST call stopPipePane() to clean up — see PaneStreamManager.
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

        /// Switches data-delivery mode.
        ///
        /// - `true`: Switch to buffering mode. The parser starts building
        ///   `filteredData` and incoming bytes are queued instead of forwarded
        ///   to the delegate. Drop any prior buffered bytes first — buffering
        ///   is meant to start clean before a `capture-pane` snapshot.
        /// - `false`: Switch back to scan-only mode. The parser stops building
        ///   `filteredData`, the queue is discarded, and only OSC events keep
        ///   flowing. Call when the last subscriber leaves.
        ///
        /// Use `flushBuffer()` to drain the queue and transition into live mode
        /// (bytes flow directly to the delegate).
        func setBuffering(_ enabled: Bool) {
            buffer = []
            if enabled {
                notificationParser.scanOnly = false
                mode = .buffering
            } else {
                notificationParser.scanOnly = true
                mode = .scanOnly
            }
        }

        /// Drains any queued bytes through the delegate in the order they were
        /// received, then transitions to live mode (subsequent bytes flow
        /// directly to the delegate). The buffer is empty after this call.
        ///
        /// Stays in `.buffering` mode while iterating. Each `await delegate…`
        /// suspends the actor, and during that suspension the consumer task
        /// can deliver fresh bytes via `processIncomingData`. If we flipped to
        /// `.live` up-front those bytes would race past whatever was still in
        /// `toFlush`; keeping `.buffering` parks them on the queue, and the
        /// outer `while` catches them in the next iteration. The flip to
        /// `.live` only happens once the queue is fully empty, with no
        /// `await` between the empty check and the mode change.
        func flushBuffer() async {
            notificationParser.scanOnly = false
            var totalChunks = 0
            while !buffer.isEmpty {
                let toFlush = buffer
                buffer = []
                totalChunks += toFlush.count
                for chunk in toFlush {
                    await delegate?.pipePaneReader(paneId, didReceiveData: chunk)
                }
            }
            mode = .live
            logger.debug("Flushed \(totalChunks) buffered chunks for \(paneId)")
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
            mode = .scanOnly
            buffer = []
            tmuxEscapeBuffer = Data()
            notificationParser.reset()
            notificationParser.scanOnly = true
            delegate = nil

            logger.info("pipe-pane stopped for \(paneId)")
        }

        // MARK: - Data Processing

        private func processIncomingData(_ data: Data) async {
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
                await delegate?.pipePaneReader(paneId, didReceiveNotification: notification)
            }

            // Report title changes (OSC 0/2)
            if let title = parseResult.titleChange {
                await delegate?.pipePaneReader(paneId, didReceiveTitle: title)
            }

            // Report clipboard content (OSC 52)
            if let clipboardContent = parseResult.clipboardContent {
                await delegate?.pipePaneReader(paneId, didReceiveClipboard: clipboardContent)
            }

            // Report progress updates (OSC 9;4)
            if let progressUpdate = parseResult.progressUpdate {
                await delegate?.pipePaneReader(paneId, didReceiveProgress: progressUpdate)
            }

            let filtered = parseResult.filteredData
            guard !filtered.isEmpty else { return }

            switch mode {
            case .scanOnly:
                // Parser was in scanOnly mode so filteredData should already be empty;
                // defensive drop in case mode changed mid-chunk.
                break
            case .buffering:
                buffer.append(filtered)
            case .live:
                await delegate?.pipePaneReader(paneId, didReceiveData: filtered)
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
        func testProcessIncomingData(_ data: Data) async {
            await processIncomingData(data)
        }

        /// Exposes fifoPath for testing.
        var testFifoPath: String {
            fifoPath
        }

        // MARK: - Lifecycle

        private func handleEOF() {
            logger.warning("EOF on pipe-pane FIFO for \(paneId) — cat process may have died")
            // Don't clean up here — the caller (PaneStreamManager) should handle reconnection
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
