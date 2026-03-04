#if os(macOS)
    import Foundation
    import Testing
    @testable import ClaudeSpyNetworking
    @testable import ClaudeSpyServerFeature

    @Suite("Terminal Notification Parser Tests")
    struct TerminalNotificationParserTests {
        // MARK: - OSC 9 (iTerm2 style)

        @Test("Parses OSC 9 notification with BEL terminator")
        func osc9WithBEL() {
            var parser = TerminalNotificationParser()
            let data = Data("\u{1b}]9;Task completed\u{07}".utf8)
            let result = parser.parse(data)

            #expect(result.notifications.count == 1)
            #expect(result.notifications[0].title == nil)
            #expect(result.notifications[0].body == "Task completed")
            #expect(result.filteredData.isEmpty)
        }

        @Test("Parses OSC 9 notification with ST terminator")
        func osc9WithST() {
            var parser = TerminalNotificationParser()
            let data = Data("\u{1b}]9;Build finished\u{1b}\\".utf8)
            let result = parser.parse(data)

            #expect(result.notifications.count == 1)
            #expect(result.notifications[0].body == "Build finished")
            #expect(result.filteredData.isEmpty)
        }

        @Test("Strips OSC 9 from output data")
        func osc9StripsFromOutput() {
            var parser = TerminalNotificationParser()
            let data = Data("before\u{1b}]9;notify\u{07}after".utf8)
            let result = parser.parse(data)

            #expect(result.notifications.count == 1)
            #expect(String(data: result.filteredData, encoding: .utf8) == "beforeafter")
        }

        // MARK: - OSC 777 (rxvt-unicode style)

        @Test("Parses OSC 777 notification with title and body")
        func osc777WithTitleAndBody() {
            var parser = TerminalNotificationParser()
            let data = Data("\u{1b}]777;notify;Claude Code;Task completed successfully\u{07}".utf8)
            let result = parser.parse(data)

            #expect(result.notifications.count == 1)
            #expect(result.notifications[0].title == "Claude Code")
            #expect(result.notifications[0].body == "Task completed successfully")
            #expect(result.filteredData.isEmpty)
        }

        @Test("Parses OSC 777 with ST terminator")
        func osc777WithST() {
            var parser = TerminalNotificationParser()
            let data = Data("\u{1b}]777;notify;Alert;Something happened\u{1b}\\".utf8)
            let result = parser.parse(data)

            #expect(result.notifications.count == 1)
            #expect(result.notifications[0].title == "Alert")
            #expect(result.notifications[0].body == "Something happened")
        }

        @Test("Parses OSC 777 with semicolons in body")
        func osc777WithSemicolonsInBody() {
            var parser = TerminalNotificationParser()
            let data = Data("\u{1b}]777;notify;Title;Body with;semicolons;inside\u{07}".utf8)
            let result = parser.parse(data)

            #expect(result.notifications.count == 1)
            #expect(result.notifications[0].title == "Title")
            #expect(result.notifications[0].body == "Body with;semicolons;inside")
        }

        // MARK: - Non-notification OSC sequences

        @Test("Passes through non-notification OSC sequences unchanged")
        func nonNotificationOSCPassthrough() {
            var parser = TerminalNotificationParser()
            // OSC 0 (set title) — should pass through
            let data = Data("\u{1b}]0;My Terminal Title\u{07}".utf8)
            let result = parser.parse(data)

            #expect(result.notifications.isEmpty)
            #expect(result.filteredData == data)
        }

        @Test("Passes through OSC 8 hyperlinks unchanged")
        func osc8HyperlinkPassthrough() {
            var parser = TerminalNotificationParser()
            let data = Data("\u{1b}]8;;https://example.com\u{07}link text\u{1b}]8;;\u{07}".utf8)
            let result = parser.parse(data)

            #expect(result.notifications.isEmpty)
            #expect(result.filteredData == data)
        }

        // MARK: - Mixed content

        @Test("Handles notification mixed with regular terminal data")
        func mixedContent() {
            var parser = TerminalNotificationParser()
            let data = Data("Hello \u{1b}[32mworld\u{1b}]9;Done!\u{07} more text".utf8)
            let result = parser.parse(data)

            #expect(result.notifications.count == 1)
            #expect(result.notifications[0].body == "Done!")
            #expect(String(data: result.filteredData, encoding: .utf8) == "Hello \u{1b}[32mworld more text")
        }

        @Test("Handles multiple notifications in one chunk")
        func multipleNotifications() {
            var parser = TerminalNotificationParser()
            let data = Data("\u{1b}]9;First\u{07}text\u{1b}]777;notify;Title;Second\u{07}".utf8)
            let result = parser.parse(data)

            #expect(result.notifications.count == 2)
            #expect(result.notifications[0].body == "First")
            #expect(result.notifications[1].title == "Title")
            #expect(result.notifications[1].body == "Second")
            #expect(String(data: result.filteredData, encoding: .utf8) == "text")
        }

        // MARK: - Split across chunks

        @Test("Buffers incomplete OSC sequence at end of chunk")
        func incompleteSequenceAtEnd() {
            var parser = TerminalNotificationParser()

            // First chunk: starts OSC 9 but doesn't finish
            let chunk1 = Data("text\u{1b}]9;Notif".utf8)
            let result1 = parser.parse(chunk1)

            #expect(result1.notifications.isEmpty)
            #expect(String(data: result1.filteredData, encoding: .utf8) == "text")

            // Second chunk: completes the sequence
            let chunk2 = Data("ication\u{07}more".utf8)
            let result2 = parser.parse(chunk2)

            #expect(result2.notifications.count == 1)
            #expect(result2.notifications[0].body == "Notification")
            #expect(String(data: result2.filteredData, encoding: .utf8) == "more")
        }

        @Test("Buffers ESC at end of chunk")
        func escAtEndOfChunk() {
            var parser = TerminalNotificationParser()

            // First chunk: ends with bare ESC
            let chunk1 = Data("data\u{1b}".utf8)
            let result1 = parser.parse(chunk1)

            #expect(result1.notifications.isEmpty)
            #expect(String(data: result1.filteredData, encoding: .utf8) == "data")

            // Second chunk: ESC is part of non-OSC sequence
            let chunk2 = Data("[32mgreen".utf8)
            let result2 = parser.parse(chunk2)

            #expect(result2.notifications.isEmpty)
            // ESC [ 32m should pass through
            #expect(String(data: result2.filteredData, encoding: .utf8) == "\u{1b}[32mgreen")
        }

        @Test("Handles ST terminator split across chunks")
        func stTerminatorSplit() {
            var parser = TerminalNotificationParser()

            // First chunk: OSC 9 ending with ESC (start of ST)
            let chunk1 = Data("\u{1b}]9;Split test\u{1b}".utf8)
            let result1 = parser.parse(chunk1)

            #expect(result1.notifications.isEmpty)
            #expect(result1.filteredData.isEmpty)

            // Second chunk: backslash completes ST
            let chunk2 = Data("\\done".utf8)
            let result2 = parser.parse(chunk2)

            #expect(result2.notifications.count == 1)
            #expect(result2.notifications[0].body == "Split test")
            #expect(String(data: result2.filteredData, encoding: .utf8) == "done")
        }

        // MARK: - Edge cases

        @Test("Ignores empty OSC 9 body")
        func emptyOSC9Body() {
            var parser = TerminalNotificationParser()
            let data = Data("\u{1b}]9;\u{07}".utf8)
            let result = parser.parse(data)

            #expect(result.notifications.isEmpty)
            // Empty body is stripped (recognized as notification format, just not valid)
            #expect(result.filteredData.isEmpty)
        }

        @Test("Handles data with no escape sequences")
        func plainTextPassthrough() {
            var parser = TerminalNotificationParser()
            let data = Data("Just plain text with no escapes".utf8)
            let result = parser.parse(data)

            #expect(result.notifications.isEmpty)
            #expect(result.filteredData == data)
        }

        @Test("Reset clears buffered state")
        func resetClearsBuffer() {
            var parser = TerminalNotificationParser()

            // Start an incomplete sequence
            _ = parser.parse(Data("\u{1b}]9;partial".utf8))

            // Reset
            parser.reset()

            // Next parse should not try to complete the old sequence
            let result = parser.parse(Data("clean data".utf8))
            #expect(result.notifications.isEmpty)
            #expect(String(data: result.filteredData, encoding: .utf8) == "clean data")
        }

        @Test("Non-notification ESC sequences pass through unchanged")
        func regularEscSequencesPassthrough() {
            var parser = TerminalNotificationParser()
            // ANSI color codes
            let data = Data("\u{1b}[31mRed\u{1b}[0m Normal".utf8)
            let result = parser.parse(data)

            #expect(result.notifications.isEmpty)
            #expect(result.filteredData == data)
        }
    }
#endif
