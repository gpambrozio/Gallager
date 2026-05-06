#if os(macOS)
    import ClaudeSpyNetworking
    import Foundation
    import Testing
    @testable import ClaudeSpyServerFeature

    /// Captures every event a `PipePaneReader` emits so tests can assert on the
    /// exact stream the delegate sees. Lives on the main actor (matching the
    /// `PipePaneReaderDelegate` isolation).
    @MainActor
    final private class CapturingDelegate: PipePaneReaderDelegate {
        var data: [Data] = []
        var notifications: [TerminalStreamMessage.TerminalNotification] = []
        var titles: [String] = []
        var clipboards: [String] = []
        var progress: [TerminalProgressState] = []

        func pipePaneReader(_ paneId: String, didReceiveData data: Data) {
            self.data.append(data)
        }

        func pipePaneReader(
            _ paneId: String,
            didReceiveNotification notification: TerminalStreamMessage.TerminalNotification
        ) {
            notifications.append(notification)
        }

        func pipePaneReader(_ paneId: String, didReceiveTitle title: String) {
            titles.append(title)
        }

        func pipePaneReader(_ paneId: String, didReceiveClipboard content: String) {
            clipboards.append(content)
        }

        func pipePaneReader(_ paneId: String, didReceiveProgress progress: TerminalProgressState) {
            self.progress.append(progress)
        }

        var concatenatedData: Data {
            data.reduce(Data()) { $0 + $1 }
        }
    }

    @Suite("TmuxControlClient Tests")
    struct TmuxControlClientTests {
        // MARK: - Session Name Extraction Tests

        @Suite("Session Name Extraction")
        struct SessionNameExtractionTests {
            @Test("Full pane target extracts session name")
            @MainActor
            func fullPaneTarget() async {
                let result = TmuxControlClientManager.extractSessionName(from: "mysession:0.1")
                #expect(result == "mysession")
            }

            @Test("Window target extracts session name")
            @MainActor
            func windowTarget() async {
                let result = TmuxControlClientManager.extractSessionName(from: "mysession:0")
                #expect(result == "mysession")
            }

            @Test("Session only returns session name")
            @MainActor
            func sessionOnly() async {
                let result = TmuxControlClientManager.extractSessionName(from: "mysession")
                #expect(result == "mysession")
            }

            @Test("Session with spaces before colon")
            @MainActor
            func sessionWithSpaces() async {
                let result = TmuxControlClientManager.extractSessionName(from: "my session:0.1")
                #expect(result == "my session")
            }

            @Test("Session with numbers")
            @MainActor
            func sessionWithNumbers() async {
                let result = TmuxControlClientManager.extractSessionName(from: "session123:2.0")
                #expect(result == "session123")
            }

            @Test("Pane ID format extracts correctly")
            @MainActor
            func paneIdFormat() async {
                // Sometimes targets might be pane IDs like %0
                let result = TmuxControlClientManager.extractSessionName(from: "%0")
                #expect(result == "%0")
            }
        }

        // MARK: - Command Response Tests

        @Suite("Command Response")
        struct CommandResponseTests {
            @Test("Lines property splits output correctly")
            func linesPropertySplits() {
                let response = CommandResponse(
                    commandNumber: 1,
                    output: "line1\nline2\nline3",
                    isError: false
                )
                #expect(response.lines == ["line1", "line2", "line3"])
            }

            @Test("Lines property handles empty output")
            func linesPropertyEmpty() {
                let response = CommandResponse(
                    commandNumber: 1,
                    output: "",
                    isError: false
                )
                #expect(response.lines == [""])
            }

            @Test("Lines property preserves empty lines")
            func linesPropertyPreservesEmpty() {
                let response = CommandResponse(
                    commandNumber: 1,
                    output: "line1\n\nline3",
                    isError: false
                )
                #expect(response.lines == ["line1", "", "line3"])
            }
        }

        // MARK: - Error Types Tests

        @Suite("Error Types")
        struct ErrorTypesTests {
            @Test("Not connected error has correct description")
            func notConnectedError() {
                let error = TmuxControlError.notConnected
                #expect(error.errorDescription?.contains("Not connected") == true)
            }

            @Test("Already connected error has correct description")
            func alreadyConnectedError() {
                let error = TmuxControlError.alreadyConnected
                #expect(error.errorDescription?.contains("Already connected") == true)
            }

            @Test("Connection failed error includes message")
            func connectionFailedError() {
                let error = TmuxControlError.connectionFailed(message: "test error")
                #expect(error.errorDescription?.contains("test error") == true)
            }

            @Test("Process terminated error includes reason")
            func processTerminatedError() {
                let error = TmuxControlError.processTerminated(reason: "Exit code: 1")
                #expect(error.errorDescription?.contains("Exit code: 1") == true)
            }

            @Test("Process terminated error handles nil reason")
            func processTerminatedNilReason() {
                let error = TmuxControlError.processTerminated(reason: nil)
                #expect(error.errorDescription?.contains("unknown") == true)
            }

            @Test("Timeout error has correct description")
            func timeoutError() {
                let error = TmuxControlError.timeout
                #expect(error.errorDescription?.contains("timed out") == true)
            }
        }
    }

    // MARK: - Block Parsing Tests

    @Suite("Block Parsing")
    struct BlockParsingTests {
        /// Regression: `%error` used to only set a flag without resolving the queued
        /// continuation. The next `%end` would then pop the wrong entry and subsequent
        /// commands would drift, eventually timing out after ~5s — visible to users as
        /// a blank terminal after closing a tmux window.
        @Test("`%error` resolves queued command with isError=true")
        func errorBlockResolvesPendingCommand() async throws {
            let client = TmuxControlClient()
            await client.testMarkInitialAttachHandled()

            // Start each enqueue as an explicit Task and wait for it to land in
            // the queue before starting the next — `async let` doesn't guarantee
            // child-task scheduling order, so under load the wrong continuation
            // can end up at index 0.
            let first = Task { try await client.testEnqueueCommand(id: 1) }
            try await waitForPendingCount(client, equals: 1)
            let second = Task { try await client.testEnqueueCommand(id: 2) }
            try await waitForPendingCount(client, equals: 2)

            let chunk = Data("""
            %begin 1000 100 1
            can't find pane: %1
            %error 1000 100 1
            %begin 1001 101 1
            %end 1001 101 1

            """.utf8)
            await client.testProcessIncomingData(chunk)

            let firstResponse = try await first.value
            let secondResponse = try await second.value
            #expect(firstResponse.commandNumber == 100)
            #expect(firstResponse.isError == true)
            #expect(firstResponse.output == "can't find pane: %1")
            #expect(secondResponse.commandNumber == 101)
            #expect(secondResponse.isError == false)
            #expect(await client.testPendingCommandCount == 0)
        }

        @Test("`%end` resolves queued command with isError=false")
        func endBlockResolvesPendingCommand() async throws {
            let client = TmuxControlClient()
            await client.testMarkInitialAttachHandled()

            let first = Task { try await client.testEnqueueCommand(id: 1) }
            try await waitForPendingCount(client, equals: 1)

            let chunk = Data("""
            %begin 1000 100 1
            output-line
            %end 1000 100 1

            """.utf8)
            await client.testProcessIncomingData(chunk)

            let response = try await first.value
            #expect(response.commandNumber == 100)
            #expect(response.isError == false)
            #expect(response.output == "output-line")
            #expect(await client.testPendingCommandCount == 0)
        }

        /// Yields until the client's pending queue reaches `count`, with a
        /// generous timeout. Replaces `Task.sleep`-based synchronisation, which
        /// is wall-clock-racy under parallel test load on slow CI VMs.
        private func waitForPendingCount(
            _ client: TmuxControlClient,
            equals count: Int,
            timeout: Duration = .seconds(5)
        ) async throws {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while await client.testPendingCommandCount != count {
                if ContinuousClock.now >= deadline {
                    break
                }
                await Task.yield()
            }
            #expect(await client.testPendingCommandCount == count)
        }
    }

    // MARK: - PipePaneReader Tests

    @Suite("PipePaneReader Tests")
    struct PipePaneReaderTests {
        @Suite("Tmux Escape Filtering")
        struct TmuxEscapeFilteringTests {
            @Test("Regular data passes through unchanged")
            func regularData() async {
                let reader = PipePaneReader(paneId: "%0")
                let input = Data("Hello, World!".utf8)
                let result = await reader.testFilterTmuxEscapeSequences(input)
                #expect(String(data: result, encoding: .utf8) == "Hello, World!")
            }

            @Test("ESC k title sequence is stripped")
            func escKTitleSequence() async {
                let reader = PipePaneReader(paneId: "%0")
                // ESC k title ESC \ followed by regular data
                var input = Data()
                input.append(0x1B) // ESC
                input.append(0x6B) // k
                input.append(contentsOf: "title".utf8)
                input.append(0x1B) // ESC
                input.append(0x5C) // backslash
                input.append(contentsOf: "visible".utf8)

                let result = await reader.testFilterTmuxEscapeSequences(input)
                #expect(String(data: result, encoding: .utf8) == "visible")
            }

            @Test("Other ESC sequences pass through")
            func otherEscSequences() async {
                let reader = PipePaneReader(paneId: "%0")
                // ESC [ 31m (red color) should pass through
                let input = Data([0x1B, 0x5B, 0x33, 0x31, 0x6D]) // ESC[31m
                let result = await reader.testFilterTmuxEscapeSequences(input)
                #expect(result == input)
            }

            @Test("Raw UTF-8 bytes pass through")
            func rawUtf8() async {
                let reader = PipePaneReader(paneId: "%0")
                let input = Data([0xE2, 0x94, 0x80]) // ─ (box drawing)
                let result = await reader.testFilterTmuxEscapeSequences(input)
                #expect(result == input)
                #expect(String(data: result, encoding: .utf8) == "─")
            }

            @Test("Mixed content with title sequence in the middle")
            func mixedContent() async {
                let reader = PipePaneReader(paneId: "%0")
                var input = Data("before".utf8)
                input.append(0x1B) // ESC
                input.append(0x6B) // k
                input.append(contentsOf: "title".utf8)
                input.append(0x1B) // ESC
                input.append(0x5C) // backslash
                input.append(contentsOf: "after".utf8)

                let result = await reader.testFilterTmuxEscapeSequences(input)
                #expect(String(data: result, encoding: .utf8) == "beforeafter")
            }

            @Test("Empty data returns empty")
            func emptyData() async {
                let reader = PipePaneReader(paneId: "%0")
                let result = await reader.testFilterTmuxEscapeSequences(Data())
                #expect(result.isEmpty)
            }
        }

        @Suite("FIFO Path")
        struct FifoPathTests {
            @Test("Pane ID is sanitized for filesystem")
            func paneIdSanitized() async {
                let reader = PipePaneReader(paneId: "%5")
                let path = await reader.testFifoPath
                let expectedDir = FileManager.default.temporaryDirectory.path
                #expect(path == "\(expectedDir)/claudespy-pipe-5.fifo")
            }
        }

        @Suite("Buffering")
        @MainActor
        struct BufferingTests {
            @Test("setBuffering(true) → bytes arrive → flushBuffer() delivers them in order")
            func bufferedBytesFlushedInOrder() async {
                let reader = PipePaneReader(paneId: "%0")
                let delegate = CapturingDelegate()
                await reader.setDelegate(delegate)

                await reader.setBuffering(true)
                await reader.testProcessIncomingData(Data("first ".utf8))
                await reader.testProcessIncomingData(Data("second ".utf8))
                await reader.testProcessIncomingData(Data("third".utf8))

                #expect(delegate.data.isEmpty, "Buffered bytes must not reach delegate before flush")

                await reader.flushBuffer()

                #expect(delegate.data.count == 3)
                let combined = String(data: delegate.concatenatedData, encoding: .utf8)
                #expect(combined == "first second third")
            }

            @Test("setBuffering(false) stops Data delivery but keeps OSC events flowing")
            func scanOnlyStillEmitsOSC() async {
                let reader = PipePaneReader(paneId: "%0")
                let delegate = CapturingDelegate()
                await reader.setDelegate(delegate)

                // Default mode after creation is scan-only — explicit toggle just
                // mirrors what the manager does on last-unsubscribe.
                await reader.setBuffering(false)

                // OSC 9 notification + plain text in one chunk.
                var input = Data()
                input.append(contentsOf: "before".utf8)
                input.append(0x1B) // ESC
                input.append(0x5D) // ]
                input.append(contentsOf: "9;hello".utf8)
                input.append(0x07) // BEL
                input.append(contentsOf: "after".utf8)

                await reader.testProcessIncomingData(input)

                #expect(delegate.data.isEmpty, "Scan-only mode must not deliver data bytes")
                #expect(delegate.notifications.count == 1, "OSC 9 notification must still flow")
            }

            @Test("flushBuffer transitions to live: subsequent bytes flow directly")
            func flushTransitionsToLive() async {
                let reader = PipePaneReader(paneId: "%0")
                let delegate = CapturingDelegate()
                await reader.setDelegate(delegate)

                await reader.setBuffering(true)
                await reader.testProcessIncomingData(Data("buffered".utf8))
                await reader.flushBuffer()

                #expect(delegate.data.count == 1)

                // Live mode: bytes go straight to the delegate, in the same order
                // relative to the previously buffered chunk.
                await reader.testProcessIncomingData(Data(" live".utf8))
                #expect(delegate.data.count == 2)
                let combined = String(data: delegate.concatenatedData, encoding: .utf8)
                #expect(combined == "buffered live")
            }

            @Test("Toggling buffering on→off→on starts a fresh buffer (off drops queue)")
            func togglingBufferingDropsQueueOnDisable() async {
                let reader = PipePaneReader(paneId: "%0")
                let delegate = CapturingDelegate()
                await reader.setDelegate(delegate)

                await reader.setBuffering(true)
                await reader.testProcessIncomingData(Data("dropped".utf8))

                // Manager calls setBuffering(false) when the last subscriber leaves;
                // any bytes that hadn't been flushed are intentionally discarded.
                await reader.setBuffering(false)

                // Re-enable buffering and confirm the queue starts fresh.
                await reader.setBuffering(true)
                await reader.testProcessIncomingData(Data("kept".utf8))
                await reader.flushBuffer()
                #expect(delegate.data.count == 1)
                #expect(String(data: delegate.data[0], encoding: .utf8) == "kept")
            }
        }
    }
#endif
