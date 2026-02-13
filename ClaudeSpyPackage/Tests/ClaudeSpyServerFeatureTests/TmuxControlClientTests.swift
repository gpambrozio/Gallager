#if os(macOS)
    import Foundation
    import Testing
    @testable import ClaudeSpyServerFeature

    @Suite("TmuxControlClient Tests")
    struct TmuxControlClientTests {
        // MARK: - Output Unescaping Tests

        @Suite("Output Unescaping")
        struct OutputUnescapingTests {
            @Test("Regular ASCII text passes through unchanged")
            func regularText() async {
                let client = TmuxControlClient()
                let result = await client.unescapeOutput("Hello, World!")
                let string = String(data: result, encoding: .utf8)
                #expect(string == "Hello, World!")
            }

            @Test("Escaped backslash becomes single backslash")
            func escapedBackslash() async {
                let client = TmuxControlClient()
                let result = await client.unescapeOutput("path\\\\to\\\\file")
                let string = String(data: result, encoding: .utf8)
                #expect(string == "path\\to\\file")
            }

            @Test("Octal escape sequence \\033 becomes ESC character")
            func octalEscape() async {
                let client = TmuxControlClient()
                let result = await client.unescapeOutput("\\033[31mRed\\033[0m")
                let string = String(data: result, encoding: .utf8)
                #expect(string == "\u{1b}[31mRed\u{1b}[0m")
            }

            @Test("Carriage return as octal \\015")
            func carriageReturnOctal() async {
                let client = TmuxControlClient()
                let result = await client.unescapeOutput("line1\\015\\012line2")
                let string = String(data: result, encoding: .utf8)
                #expect(string == "line1\r\nline2")
            }

            @Test("Null byte as octal \\000")
            func nullByteOctal() async {
                let client = TmuxControlClient()
                let result = await client.unescapeOutput("before\\000after")
                #expect(result.count == 12)
                #expect(result[6] == 0)
            }

            @Test("Mixed content with escapes and regular text")
            func mixedContent() async {
                let client = TmuxControlClient()
                let result = await client.unescapeOutput("\\033[2KHello\\015World\\033[0m")
                let string = String(data: result, encoding: .utf8)
                #expect(string == "\u{1b}[2KHello\rWorld\u{1b}[0m")
            }

            @Test("UTF-8 characters pass through unchanged")
            func utf8Characters() async {
                let client = TmuxControlClient()
                let result = await client.unescapeOutput("Hello 世界 🌍")
                let string = String(data: result, encoding: .utf8)
                #expect(string == "Hello 世界 🌍")
            }

            @Test("Backslash followed by non-octal digit stays as backslash")
            func backslashNonOctal() async {
                let client = TmuxControlClient()
                let result = await client.unescapeOutput("a\\9b")
                let string = String(data: result, encoding: .utf8)
                #expect(string == "a\\9b")
            }

            @Test("Incomplete octal at end of string")
            func incompleteOctal() async {
                let client = TmuxControlClient()
                let result = await client.unescapeOutput("test\\03")
                // \03 is valid octal (ETX character, value 3)
                #expect(result.count == 5) // "test" + one byte
                #expect(result[4] == 3)
            }

            @Test("Empty string returns empty data")
            func emptyString() async {
                let client = TmuxControlClient()
                let result = await client.unescapeOutput("")
                #expect(result.isEmpty)
            }
        }

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

        // MARK: - UTF-8 Splitting Tests

        @Suite("UTF-8 Splitting")
        struct Utf8SplittingTests {
            @Test("Complete UTF-8 returns empty incomplete portion")
            func completeUtf8() async {
                let client = TmuxControlClient()
                let data = Data("Hello 世界".utf8)
                let (complete, incomplete) = await client.splitIncompleteUtf8Trailing(data)
                #expect(complete == data)
                #expect(incomplete.isEmpty)
            }

            @Test("Detects incomplete 2-byte sequence (lead byte only)")
            func incomplete2ByteSequence() async {
                let client = TmuxControlClient()
                // 0xC3 is lead byte for 2-byte sequence (like ä, ö, ü)
                var data = Data("test".utf8)
                data.append(0xC3)
                let (complete, incomplete) = await client.splitIncompleteUtf8Trailing(data)
                #expect(String(data: complete, encoding: .utf8) == "test")
                #expect(incomplete == Data([0xC3]))
            }

            @Test("Detects incomplete 3-byte sequence (lead byte only)")
            func incomplete3ByteLeadOnly() async {
                let client = TmuxControlClient()
                // 0xE2 is lead byte for 3-byte sequence (box drawing chars)
                var data = Data("test".utf8)
                data.append(0xE2)
                let (complete, incomplete) = await client.splitIncompleteUtf8Trailing(data)
                #expect(String(data: complete, encoding: .utf8) == "test")
                #expect(incomplete == Data([0xE2]))
            }

            @Test("Detects incomplete 3-byte sequence (lead + 1 continuation)")
            func incomplete3BytePartial() async {
                let client = TmuxControlClient()
                // 0xE2 0x94 is start of box drawing char (needs one more byte)
                var data = Data("test".utf8)
                data.append(contentsOf: [0xE2, 0x94])
                let (complete, incomplete) = await client.splitIncompleteUtf8Trailing(data)
                #expect(String(data: complete, encoding: .utf8) == "test")
                #expect(incomplete == Data([0xE2, 0x94]))
            }

            @Test("Detects incomplete 4-byte sequence (lead + 2 continuations)")
            func incomplete4BytePartial() async {
                let client = TmuxControlClient()
                // 0xF0 0x9F 0x8C is start of emoji (needs one more byte)
                var data = Data("test".utf8)
                data.append(contentsOf: [0xF0, 0x9F, 0x8C])
                let (complete, incomplete) = await client.splitIncompleteUtf8Trailing(data)
                #expect(String(data: complete, encoding: .utf8) == "test")
                #expect(incomplete == Data([0xF0, 0x9F, 0x8C]))
            }

            @Test("Empty data returns empty")
            func emptyData() async {
                let client = TmuxControlClient()
                let (complete, incomplete) = await client.splitIncompleteUtf8Trailing(Data())
                #expect(complete.isEmpty)
                #expect(incomplete.isEmpty)
            }

            @Test("Box drawing character split scenario from real bug")
            func boxDrawingSplit() async {
                let client = TmuxControlClient()
                // Simulate: line ends with 0xE2 (start of ─ which is E2 94 80)
                var data = Data("prefix".utf8)
                data.append(0xE2)
                let (complete, incomplete) = await client.splitIncompleteUtf8Trailing(data)
                #expect(String(data: complete, encoding: .utf8) == "prefix")
                #expect(incomplete == Data([0xE2]))

                // Next chunk has the continuation bytes
                var nextData = incomplete
                nextData.append(contentsOf: [0x94, 0x80]) // completes ─
                nextData.append(contentsOf: Data("suffix".utf8))
                let (complete2, incomplete2) = await client.splitIncompleteUtf8Trailing(nextData)
                #expect(String(data: complete2, encoding: .utf8) == "─suffix")
                #expect(incomplete2.isEmpty)
            }
        }

        // MARK: - Byte-Level Unescaping Tests

        @Suite("Byte-Level Unescaping")
        struct ByteLevelUnescapingTests {
            @Test("Octal escapes converted correctly")
            func octalEscapes() async {
                let client = TmuxControlClient()
                let input = Data("\\033[31m".utf8)
                let result = await client.unescapeOutputBytes(input)
                #expect(result[0] == 0x1B) // ESC
                #expect(String(data: result.dropFirst(), encoding: .utf8) == "[31m")
            }

            @Test("Raw UTF-8 bytes pass through")
            func rawUtf8() async {
                let client = TmuxControlClient()
                // Raw box drawing char bytes (not escaped)
                let input = Data([0xE2, 0x94, 0x80]) // ─
                let result = await client.unescapeOutputBytes(input)
                #expect(result == input)
                #expect(String(data: result, encoding: .utf8) == "─")
            }

            @Test("Mixed octal escapes and raw UTF-8")
            func mixedContent() async {
                let client = TmuxControlClient()
                // \033[90m followed by raw ─ (E2 94 80)
                var input = Data("\\033[90m".utf8)
                input.append(contentsOf: [0xE2, 0x94, 0x80])
                let result = await client.unescapeOutputBytes(input)
                #expect(result[0] == 0x1B) // ESC
                // Last 3 bytes should be the box drawing char
                #expect(Array(result.suffix(3)) == [0xE2, 0x94, 0x80])
            }

            @Test("Escaped backslash")
            func escapedBackslash() async {
                let client = TmuxControlClient()
                let input = Data("path\\\\file".utf8)
                let result = await client.unescapeOutputBytes(input)
                #expect(String(data: result, encoding: .utf8) == "path\\file")
            }

            @Test("Backslash at end of data")
            func backslashAtEnd() async {
                let client = TmuxControlClient()
                let input = Data("test\\".utf8)
                let result = await client.unescapeOutputBytes(input)
                #expect(String(data: result, encoding: .utf8) == "test\\")
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
#endif
