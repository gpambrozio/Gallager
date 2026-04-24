#if os(macOS)
    import Foundation
    import Testing
    @testable import ClaudeSpyServerFeature

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

            async let first = client.testEnqueueCommand(id: 1)
            async let second = client.testEnqueueCommand(id: 2)
            // Ensure both continuations are queued before feeding responses.
            try await Task.sleep(for: .milliseconds(50))
            #expect(await client.testPendingCommandCount == 2)

            let chunk = Data("""
            %begin 1000 100 1
            can't find pane: %1
            %error 1000 100 1
            %begin 1001 101 1
            %end 1001 101 1

            """.utf8)
            await client.testProcessIncomingData(chunk)

            let firstResponse = try await first
            let secondResponse = try await second
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

            async let first = client.testEnqueueCommand(id: 1)
            try await Task.sleep(for: .milliseconds(50))

            let chunk = Data("""
            %begin 1000 100 1
            output-line
            %end 1000 100 1

            """.utf8)
            await client.testProcessIncomingData(chunk)

            let response = try await first
            #expect(response.commandNumber == 100)
            #expect(response.isError == false)
            #expect(response.output == "output-line")
            #expect(await client.testPendingCommandCount == 0)
        }
    }

    // MARK: - PipePaneReader Tests

    @Suite("PipePaneReader Tests")
    struct PipePaneReaderTests {
        @Suite("Tmux Escape Filtering")
        struct TmuxEscapeFilteringTests {
            /// Helper to run filterTmuxEscapeSequences by feeding data through the reader
            private func filterData(_ data: Data) async -> Data {
                let reader = PipePaneReader(paneId: "%0")
                nonisolated(unsafe) var received = [Data]()
                await reader.setDataHandler { received.append($0) }

                // Feed data through the reader's processing by simulating pipe-pane delivery
                // We use a direct approach: test the filtering via the actor's internal method
                // by starting pipe-pane with buffering, then flushing
                await reader.testProcessIncomingData(data)
                await reader.stopBufferingAndFlush()

                return received.reduce(Data()) { $0 + $1 }
            }

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
        struct BufferingTests {
            @Test("Data is buffered when buffering is enabled")
            func dataBuffered() async {
                let reader = PipePaneReader(paneId: "%0")
                nonisolated(unsafe) var received = [Data]()
                await reader.setDataHandler { received.append($0) }

                // Enable buffering and process data
                await reader.testSetBuffering(true)
                await reader.testProcessIncomingData(Data("hello".utf8))
                #expect(received.isEmpty)

                // Flush
                await reader.stopBufferingAndFlush()
                #expect(received.count == 1)
                #expect(String(data: received[0], encoding: .utf8) == "hello")
            }

            @Test("Data is delivered immediately when not buffering")
            func dataImmediate() async {
                let reader = PipePaneReader(paneId: "%0")
                nonisolated(unsafe) var received = [Data]()
                await reader.setDataHandler { received.append($0) }

                await reader.testSetBuffering(false)
                await reader.testProcessIncomingData(Data("hello".utf8))
                #expect(received.count == 1)
            }
        }
    }
#endif
