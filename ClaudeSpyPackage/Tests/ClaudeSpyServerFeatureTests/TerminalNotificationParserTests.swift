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

        @Test("Parses OSC 777 with title only (no body) as fallback")
        func osc777TitleOnlyFallback() {
            var parser = TerminalNotificationParser()
            let data = Data("\u{1b}]777;notify;TitleOnly\u{07}".utf8)
            let result = parser.parse(data)

            #expect(result.notifications.count == 1)
            // When there's no semicolon after the title, the entire payload
            // becomes the body (title-only is treated as body-only fallback)
            #expect(result.notifications[0].title == nil)
            #expect(result.notifications[0].body == "TitleOnly")
            #expect(result.filteredData.isEmpty)
        }

        // MARK: - Scan-only mode

        @Test("Scan-only mode extracts notifications without building filtered data")
        func scanOnlyMode() {
            var parser = TerminalNotificationParser(scanOnly: true)
            let data = Data("before\u{1b}]9;Hello\u{07}after\u{1b}]0;Title\u{07}more".utf8)
            let result = parser.parse(data)

            #expect(result.notifications.count == 1)
            #expect(result.notifications[0].body == "Hello")
            // In scan-only mode, filteredData is always empty
            #expect(result.filteredData.isEmpty)
        }

        @Test("Scan-only mode handles cross-chunk sequences")
        func scanOnlyCrossChunk() {
            var parser = TerminalNotificationParser(scanOnly: true)

            let chunk1 = Data("data\u{1b}]9;Split".utf8)
            let result1 = parser.parse(chunk1)
            #expect(result1.notifications.isEmpty)
            #expect(result1.filteredData.isEmpty)

            let chunk2 = Data(" notification\u{07}more".utf8)
            let result2 = parser.parse(chunk2)
            #expect(result2.notifications.count == 1)
            #expect(result2.notifications[0].body == "Split notification")
            #expect(result2.filteredData.isEmpty)
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

        // MARK: - Content sanitization

        @Test("Discards OSC 9 notification with only escape sequences")
        func osc9WithOnlyEscapeSequences() {
            var parser = TerminalNotificationParser()
            // Body is just ANSI escape codes with no readable text
            let data = Data("\u{1b}]9;\u{1b}[0m\u{1b}[?25h\u{07}".utf8)
            let result = parser.parse(data)

            // Sequence is recognized (stripped from output) but no notification emitted
            #expect(result.notifications.isEmpty)
            #expect(result.filteredData.isEmpty)
        }

        @Test("Discards OSC 9 notification with only control characters")
        func osc9WithOnlyControlCharacters() {
            var parser = TerminalNotificationParser()
            let data = Data("\u{1b}]9;\u{01}\u{02}\u{03}\u{07}".utf8)
            let result = parser.parse(data)

            #expect(result.notifications.isEmpty)
            #expect(result.filteredData.isEmpty)
        }

        @Test("Sanitizes OSC 9 notification by stripping escape sequences from text")
        func osc9SanitizesEscapeSequences() {
            var parser = TerminalNotificationParser()
            // Body has ANSI color codes around readable text
            let data = Data("\u{1b}]9;\u{1b}[32mBuild complete\u{1b}[0m\u{07}".utf8)
            let result = parser.parse(data)

            #expect(result.notifications.count == 1)
            #expect(result.notifications[0].body == "Build complete")
        }

        @Test("Sanitizes OSC 777 notification title and body")
        func osc777SanitizesContent() {
            var parser = TerminalNotificationParser()
            let data = Data("\u{1b}]777;notify;\u{1b}[1mAlert\u{1b}[0m;Task \u{1b}[32mdone\u{1b}[0m\u{07}".utf8)
            let result = parser.parse(data)

            #expect(result.notifications.count == 1)
            #expect(result.notifications[0].title == "Alert")
            #expect(result.notifications[0].body == "Task done")
        }

        @Test("Discards OSC 777 notification when body is only escape sequences")
        func osc777DiscardsEscapeOnlyBody() {
            var parser = TerminalNotificationParser()
            let data = Data("\u{1b}]777;notify;Title;\u{1b}[0m\u{07}".utf8)
            let result = parser.parse(data)

            #expect(result.notifications.isEmpty)
            #expect(result.filteredData.isEmpty)
        }

        // MARK: - ConEmu-style OSC 9 sub-commands

        @Test("Discards ConEmu OSC 9 progress state sub-command")
        func osc9ConEmuProgressState() {
            var parser = TerminalNotificationParser()
            // ESC]9;4;0;BEL — ConEmu "set progress state" (state=0, clear progress)
            let data = Data("\u{1b}]9;4;0;\u{07}".utf8)
            let result = parser.parse(data)

            #expect(result.notifications.isEmpty)
            #expect(result.filteredData.isEmpty)
        }

        @Test("Discards ConEmu OSC 9 tab title sub-command")
        func osc9ConEmuTabTitle() {
            var parser = TerminalNotificationParser()
            // ESC]9;1;filenameBEL — ConEmu "set tab title"
            let data = Data("\u{1b}]9;1;my-session\u{07}".utf8)
            let result = parser.parse(data)

            #expect(result.notifications.isEmpty)
            #expect(result.filteredData.isEmpty)
        }

        @Test("Keeps real OSC 9 notification that starts with a digit but no sub-command")
        func osc9NotificationStartingWithDigit() {
            var parser = TerminalNotificationParser()
            // "3 tasks completed" starts with a digit but has no digit-only prefix before semicolon
            let data = Data("\u{1b}]9;3 tasks completed\u{07}".utf8)
            let result = parser.parse(data)

            #expect(result.notifications.count == 1)
            #expect(result.notifications[0].body == "3 tasks completed")
        }

        @Test("Keeps real OSC 9 notification without any semicolons in body")
        func osc9NotificationNoSemicolons() {
            var parser = TerminalNotificationParser()
            let data = Data("\u{1b}]9;Build complete\u{07}".utf8)
            let result = parser.parse(data)

            #expect(result.notifications.count == 1)
            #expect(result.notifications[0].body == "Build complete")
        }

        // MARK: - Nested OSC in notification body

        @Test("Strips nested OSC sequence from notification body")
        func osc9WithNestedOSCSequence() {
            var parser = TerminalNotificationParser()
            // Body contains ESC]4;0; (nested OSC without its own terminator)
            let data = Data("\u{1b}]9;\u{1b}]4;0;\u{07}".utf8)
            let result = parser.parse(data)

            // Nested OSC consumes remaining content — empty body → discard
            #expect(result.notifications.isEmpty)
            #expect(result.filteredData.isEmpty)
        }

        @Test("Strips nested OSC sequence but keeps surrounding text")
        func osc9WithNestedOSCAndText() {
            var parser = TerminalNotificationParser()
            // Body has text, then a nested OSC, then more text
            let data = Data("\u{1b}]9;Hello \u{1b}]0;title\u{07}world\u{07}".utf8)
            let result = parser.parse(data)

            // The first BEL terminates the nested OSC within sanitization,
            // but "world" is after the outer BEL so it's not part of the notification body.
            // The outer parser sees: ESC]9; then scans for BEL → finds first BEL after "title"
            // So body is "Hello ESC]0;title", sanitizer strips nested OSC → "Hello "
            // Wait, actually the outer parser finds the FIRST BEL, so body includes up to first BEL.
            // Let me reconsider: the outer parser's content is "Hello \u{1b}]0;title"
            // (stops at first BEL). Sanitizer: "Hello " + ESC] skips to end → "Hello"
            #expect(result.notifications.count == 1)
            #expect(result.notifications[0].body == "Hello")
        }
        // MARK: - Idle prompt filtering

        @Test("Discards Claude Code idle prompt OSC 9 notification")
        func osc9IdlePromptFiltered() {
            var parser = TerminalNotificationParser()
            let data = Data("\u{1b}]9;Claude is waiting for your input\u{07}".utf8)
            let result = parser.parse(data)

            #expect(result.notifications.isEmpty)
            #expect(result.filteredData.isEmpty)
        }

        @Test("Discards Claude Code idle prompt OSC 777 notification")
        func osc777IdlePromptFiltered() {
            var parser = TerminalNotificationParser()
            let data = Data("\u{1b}]777;notify;Claude Code;Claude is waiting for your input\u{07}".utf8)
            let result = parser.parse(data)

            #expect(result.notifications.isEmpty)
            #expect(result.filteredData.isEmpty)
        }

        @Test("Strips idle prompt from mixed content without affecting surrounding data")
        func idlePromptStrippedFromMixedContent() {
            var parser = TerminalNotificationParser()
            let data = Data("before\u{1b}]9;Claude is waiting for your input\u{07}after".utf8)
            let result = parser.parse(data)

            #expect(result.notifications.isEmpty)
            #expect(String(data: result.filteredData, encoding: .utf8) == "beforeafter")
        }

        @Test("Does not filter non-idle notifications with similar text")
        func nonIdleNotificationNotFiltered() {
            var parser = TerminalNotificationParser()
            let data = Data("\u{1b}]9;Task completed successfully\u{07}".utf8)
            let result = parser.parse(data)

            #expect(result.notifications.count == 1)
            #expect(result.notifications[0].body == "Task completed successfully")
        }
    }
#endif
