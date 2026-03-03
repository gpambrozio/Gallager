#if os(macOS)
    import Foundation
    import SwiftTerm
    import Testing
    @testable import ClaudeSpyServerFeature

    // MARK: - Test Helpers

    /// Minimal TerminalDelegate for headless SwiftTerm usage in tests
    final private class TestTerminalDelegate: TerminalDelegate {
        func send(source _: Terminal, data _: ArraySlice<UInt8>) { }
        func showCursor(source _: Terminal) { }
        func hideCursor(source _: Terminal) { }
        func setTerminalTitle(source _: Terminal, title _: String) { }
        func setTerminalIconTitle(source _: Terminal, title _: String) { }
        func sizeChanged(source _: Terminal) { }
        func scrolled(source _: Terminal, yDisp _: Int) { }
        func hostCurrentDirectoryUpdated(source _: Terminal) { }
        func hostCurrentDocumentUpdated(source _: Terminal) { }
    }

    /// Creates a headless terminal for testing
    private func makeTerminal(cols: Int, rows: Int) -> (Terminal, TestTerminalDelegate) {
        let delegate = TestTerminalDelegate()
        let terminal = Terminal(delegate: delegate)
        terminal.resize(cols: cols, rows: rows)
        return (terminal, delegate)
    }

    /// Returns the visible text at a given row, trimmed
    private func getRowText(_ terminal: Terminal, row: Int) -> String {
        guard let line = terminal.getLine(row: row) else { return "" }
        var text = ""
        for col in 0..<terminal.cols {
            let ch = line[col]
            text += String(ch.getCharacter())
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Gets the foreground color attribute at a specific position
    private func getFgColor(_ terminal: Terminal, col: Int, row: Int) -> Attribute.Color {
        guard let line = terminal.getLine(row: row) else { return .defaultColor }
        return line[col].attribute.fg
    }

    // MARK: - Tests

    @Suite("Terminal Rendering - Garbled Output Investigation")
    struct TerminalRenderingTests {
        // MARK: - H1: filterToColorCodesOnly strips too aggressively

        @Suite("H1: filterToColorCodesOnly behavior")
        struct FilterToColorCodesOnlyTests {
            @Test("Preserves SGR color codes")
            @MainActor
            func preservesSGR() {
                let service = TmuxService()
                let input = "\u{1b}[31mRed\u{1b}[0m Normal"
                let result = service.filterToColorCodesOnly(input)
                #expect(result == "\u{1b}[31mRed\u{1b}[0m Normal")
            }

            @Test("Preserves 256-color and truecolor SGR")
            @MainActor
            func preservesExtendedColors() {
                let service = TmuxService()
                let input = "\u{1b}[38;2;135;0;255mPurple\u{1b}[39m"
                let result = service.filterToColorCodesOnly(input)
                #expect(result == input)
            }

            @Test("Strips cursor positioning (CSI H)")
            @MainActor
            func stripsCursorPosition() {
                let service = TmuxService()
                let input = "\u{1b}[5;10HText"
                let result = service.filterToColorCodesOnly(input)
                #expect(result == "Text")
            }

            @Test("Strips cursor movement (CSI A/B/C/D)")
            @MainActor
            func stripsCursorMovement() {
                let service = TmuxService()
                let input = "Start\u{1b}[5AMiddle\u{1b}[3CEnd"
                let result = service.filterToColorCodesOnly(input)
                #expect(result == "StartMiddleEnd")
            }

            @Test("Strips erase sequences (CSI J/K)")
            @MainActor
            func stripsEraseSequences() {
                let service = TmuxService()
                let input = "\u{1b}[2JCleared\u{1b}[2K"
                let result = service.filterToColorCodesOnly(input)
                #expect(result == "Cleared")
            }

            @Test("Strips private mode sequences (CSI ?...h/l)")
            @MainActor
            func stripsPrivateModes() {
                let service = TmuxService()
                let input = "\u{1b}[?2026hContent\u{1b}[?2026l"
                let result = service.filterToColorCodesOnly(input)
                #expect(result == "Content")
            }
        }

        // MARK: - H2: Non-CSI escape handling leaks bytes

        @Suite("H2: Non-CSI escape sequence handling")
        struct NonCSIEscapeTests {
            @Test("Non-CSI escape sequences should not leak following byte as text")
            @MainActor
            func nonCSIDoesNotLeakBytes() {
                let service = TmuxService()
                // ESC ( B = Select ASCII charset (G0)
                // The function should skip both ESC and the type + param bytes, not just ESC
                let input = "Before\u{1b}(BAfter"
                let result = service.filterToColorCodesOnly(input)
                // If H2 bug exists: result would be "Before(BAfter" (leaked '(' and 'B')
                // Correct behavior: result should be "BeforeAfter"
                let hasLeakedBytes = result.contains("(B")
                #expect(hasLeakedBytes == false, "Non-CSI sequence leaked bytes: \(result)")
            }

            @Test("ESC ) 0 (VT100 graphics charset) should not leak characters")
            @MainActor
            func vt100GraphicsCharsetDoesNotLeak() {
                let service = TmuxService()
                let input = "Before\u{1b})0After"
                let result = service.filterToColorCodesOnly(input)
                let hasLeakedBytes = result.contains(")0") || result.contains(")")
                #expect(
                    hasLeakedBytes == false,
                    "VT100 charset sequence leaked bytes: \(result)"
                )
            }

            @Test("Multiple non-CSI escapes don't accumulate leaked bytes")
            @MainActor
            func multipleNonCSIDontAccumulate() {
                let service = TmuxService()
                // Multiple charset switches
                let input = "A\u{1b}(B\u{1b})0\u{1b}(AZ"
                let result = service.filterToColorCodesOnly(input)
                // Without the bug fix, leaked bytes would be: "A(B)0(AZ"
                // Correct: "AZ"
                #expect(result == "AZ", "Only text content should remain: got '\(result)'")
            }
        }

        // MARK: - H3/H8: Dimension mismatch causes cursor position errors

        @Suite("H3/H8: Dimension mismatch between tmux and mirror")
        struct DimensionMismatchTests {
            @Test(
                "Absolute cursor position is clamped when exceeding terminal rows"
            )
            func absoluteCursorClampedToTerminalSize() {
                let (terminal, _) = makeTerminal(cols: 80, rows: 24)

                // Try to position cursor at row 68 (beyond terminal bounds)
                // SwiftTerm clamps this to the last row (row 24, 1-indexed)
                terminal.feed(text: "\u{1b}[68;1HText at row 68")

                // Text should appear at the last row (clamped by SwiftTerm)
                let lastRow = getRowText(terminal, row: 23) // 0-indexed
                #expect(lastRow.contains("Text at row 68"), "Text should appear at last row after clamping")
            }

            @Test(
                "Clamped cursor position gives consistent relative movements"
            )
            func relativeCursorAfterClamping() {
                // Simulates what happens after capturePaneWithScrollbackForStreaming
                // clamps cursorY to linesToOutput-1 in the output.
                //
                // tmux pane: 80x68, cursor at row 63
                // linesToOutput = 60 (content fills 60 rows)
                // effectiveCursorY = min(63, 60-1) = 59
                // Mirror terminal receives: \e[60;1H (1-indexed)
                let mirrorRows = 60
                let effectiveCursorRow = 60 // 1-indexed (clamped to linesToOutput)

                let (terminal, _) = makeTerminal(cols: 80, rows: mirrorRows)

                // Fill content (simulating visible area output)
                for i in 0..<mirrorRows {
                    terminal.feed(text: String(format: "Content line %02d\r\n", i))
                }

                // Position cursor at the clamped position (what our fix sends)
                terminal.feed(text: "\u{1b}[\(effectiveCursorRow);1H")

                // CursorUp:8 from the clamped position
                terminal.feed(text: "\r\u{1b}[8AMARKER")

                let markerRow = (0..<mirrorRows).first { row in
                    getRowText(terminal, row: row).contains("MARKER")
                }

                #expect(markerRow != nil, "MARKER should be visible")
                // effectiveCursorRow is 60 (1-indexed), up 8 = row 52 (1-indexed) = 51 (0-indexed)
                let expected = effectiveCursorRow - 8 - 1 // 0-indexed: 51
                #expect(
                    markerRow == expected,
                    "MARKER should be at row \(expected), but was at \(String(describing: markerRow))"
                )
            }
        }

        // MARK: - H7: Synchronized output

        @Suite("H7: Synchronized output pattern")
        struct SynchronizedOutputTests {
            @Test("Claude Code sync update pattern renders correctly")
            func syncUpdatePattern() {
                let (terminal, _) = makeTerminal(cols: 80, rows: 24)

                // Write initial content at specific rows using absolute positioning
                terminal.feed(text: "\u{1b}[1;1HLine 1\u{1b}[2;1HLine 2\u{1b}[3;1HLine 3")
                // Cursor is now at row 3, after "Line 3"
                // Move cursor to row 5 (a "home" position for edits)
                terminal.feed(text: "\u{1b}[5;1H")

                // Simulate sync update: go up to row 3 (up 2), write, go to row 4 (down 1), write, return
                let syncUpdate =
                    "\u{1b}[?2026h\r\u{1b}[2ANew Line 3\r\u{1b}[1BNew Line 4\r\u{1b}[1B\u{1b}[?2026l"
                terminal.feed(text: syncUpdate)

                let row3 = getRowText(terminal, row: 2) // 0-indexed
                let row4 = getRowText(terminal, row: 3)
                #expect(row3.contains("New Line 3"), "Row 2: '\(row3)'")
                #expect(row4.contains("New Line 4"), "Row 3: '\(row4)'")
            }
        }

        // MARK: - H12: SGR state carryover between lines

        @Suite("H12: SGR state carryover in visible area")
        struct SGRStateTests {
            @Test("Visible area without resets leaks SGR state across lines")
            func sgrStateLeaksBetweenLines() {
                let (terminal, _) = makeTerminal(cols: 80, rows: 10)

                // Simulate ClaudeSpy's visible area output:
                // No explicit reset between lines (unlike scrollback which gets \e[0m wrapping)
                var output = "\u{1b}[H" // Home

                // Line 1: set red foreground, write text (no reset at end)
                output += "\u{1b}[2K\u{1b}[31mRed text"
                output += "\r\n"

                // Line 2: no SGR codes, just text — inherits red from line 1
                output += "\u{1b}[2KShould be default color"

                terminal.feed(text: output)

                // Line 2's text is red (inherited) not default
                let line2FgColor = getFgColor(terminal, col: 0, row: 1)
                #expect(
                    line2FgColor != .defaultColor,
                    "Line 2 inherits SGR state from line 1 (no reset between visible lines)"
                )
            }
        }

        // MARK: - H9: OSC sequences in filterToColorCodesOnly

        @Suite("H9: OSC sequence handling in filter")
        struct OSCSequenceTests {
            @Test("OSC sequences should be stripped without leaking content")
            @MainActor
            func oscDoesNotLeakContent() {
                let service = TmuxService()
                // OSC 0 (set title): ESC ] 0 ; Title BEL
                let input = "Before\u{1b}]0;Title\u{07}After"
                let result = service.filterToColorCodesOnly(input)
                // Correct behavior: OSC sequence is fully consumed, only text remains
                let hasLeak = result.contains("]0;Title")
                #expect(hasLeak == false, "OSC content leaked as literal text: \(result)")
            }
        }

        // MARK: - Integration: Claude Code redraw patterns

        @Suite("Integration: Claude Code drawing patterns")
        struct ClaudeCodePatternTests {
            @Test("Input area redraw works with matching dimensions")
            func inputAreaRedrawMatchingDimensions() {
                let (terminal, _) = makeTerminal(cols: 80, rows: 68)

                // Position cursor at row 24 using absolute positioning
                // (simulating state after initial capture placed content)
                for i in 1...23 {
                    terminal.feed(text: "\u{1b}[\(i);1HLine \(i - 1)")
                }
                terminal.feed(text: "\u{1b}[24;1H")

                // Claude Code types "I": sync, CR, Right:2, Up:5, char, sync_end
                let liveUpdate =
                    "\u{1b}[?2026h\r\u{1b}[2C\u{1b}[5AI\u{1b}[7m \u{1b}[27m"
                        + String(repeating: " ", count: 45)
                        + "\r\r\n\r\n\r\n\r\n\r\n\u{1b}[?2026l"
                terminal.feed(text: liveUpdate)

                // "I" should appear at row 19 (24-5), 0-indexed: 18, col 2
                let promptRow = getRowText(terminal, row: 18)
                #expect(
                    promptRow.contains("I"),
                    "Character 'I' should appear on row 18. Got: '\(promptRow)'"
                )
            }

            @Test("Input area redraw should work with clamped cursor when content is deep")
            func inputAreaRedrawWithMismatch() {
                // Simulates a session where cursor is deep in tmux (row 63) but
                // capturePaneWithScrollbackForStreaming clamps it to linesToOutput-1.
                // linesToOutput = 60 (content fills 60 rows), so effectiveCursorY = 59 (0-indexed)
                let mirrorRows = 60
                let effectiveCursorRow = 60 // 1-indexed (clamped from 63 to 59, then +1)

                let (terminal, _) = makeTerminal(cols: 80, rows: mirrorRows)

                // Fill content (simulating visible area output from capture)
                for i in 0..<mirrorRows {
                    terminal.feed(text: String(format: "Content %02d\r\n", i))
                }

                // Position cursor at the clamped position (what our fix sends)
                terminal.feed(text: "\u{1b}[\(effectiveCursorRow);1H")

                // Claude Code's typical CursorUp:8 redraw
                terminal.feed(text: "\r\u{1b}[8AMARKER")

                let markerRow = (0..<mirrorRows).first { row in
                    getRowText(terminal, row: row).contains("MARKER")
                }

                #expect(markerRow != nil, "MARKER should be visible")
                // effectiveCursorRow 60 (1-indexed), up 8 = row 52 (1-indexed) = 51 (0-indexed)
                let expected = effectiveCursorRow - 8 - 1 // 0-indexed: 51
                #expect(
                    markerRow == expected,
                    "MARKER should be at row \(expected), but was at \(String(describing: markerRow))"
                )
            }

            @Test("Full screen redraw (EraseDisplay + CursorHome) works correctly")
            func fullScreenRedraw() {
                let (terminal, _) = makeTerminal(cols: 80, rows: 40)

                // Put old content
                terminal.feed(text: "OLD CONTENT\r\nOLD CONTENT 2\r\n")

                // Full redraw from recording event 11729
                var redraw = "\u{1b}[?2026h"
                redraw += "\u{1b}[2J" // erase all
                redraw += "\u{1b}[3J" // erase scrollback
                redraw += "\u{1b}[H" // cursor home
                redraw += "\r\r\n" // row 2
                redraw += "\u{1b}[4C" // right 4
                redraw += "\u{1b}[1mClaude Code\u{1b}[22m"
                redraw += "\u{1b}[?2026l"
                terminal.feed(text: redraw)

                let row0 = getRowText(terminal, row: 0)
                #expect(!row0.contains("OLD CONTENT"), "Old content should be erased")

                let row1 = getRowText(terminal, row: 1)
                #expect(row1.contains("Claude Code"), "New content at row 1: '\(row1)'")
            }

            @Test("Accumulated cursor drift from many relative movements")
            func accumulatedCursorDrift() {
                let (terminal, _) = makeTerminal(cols: 80, rows: 30)

                // Set up: 20 lines of content, cursor at row 25
                for i in 0..<20 {
                    terminal.feed(text: "Line \(i)\r\n")
                }
                terminal.feed(text: "\u{1b}[25;1H")

                // Simulate 50 Claude Code update cycles
                for cycle in 0..<50 {
                    var update = "\u{1b}[?2026h"
                    update += "\r\u{1b}[5A" // up 5 from row 25 → row 20
                    let text = "Cycle \(cycle)"
                    update += text + String(repeating: " ", count: max(0, 70 - text.count))
                    update += "\r\u{1b}[5B" // down 5 back to row 25
                    update += "\u{1b}[?2026l"
                    terminal.feed(text: update)
                }

                // Row 20 (0-indexed: 19) should show "Cycle 49"
                let row20 = getRowText(terminal, row: 19)
                #expect(row20.contains("Cycle 49"), "After 50 cycles: '\(row20)'")
            }
        }

        // MARK: - H17: capture-pane reconstruction vs PTY bytes

        @Suite("H17: Initial state vs live stream format mismatch")
        struct CaptureVsPTYTests {
            @Test("capture-pane reconstruction should preserve SGR state for live stream")
            @MainActor
            func sgrStatePreservedAfterCapture() {
                let service = TmuxService()
                let (termCapture, _) = makeTerminal(cols: 80, rows: 10)
                let (termRaw, _) = makeTerminal(cols: 80, rows: 10)

                // Raw PTY style: set magenta, write text, no reset. Cursor stays after text.
                // SGR state: magenta is still active.
                var rawOutput = "\u{1b}[H\u{1b}[2J"
                rawOutput += "\u{1b}[35mLine 5"
                termRaw.feed(text: rawOutput)

                // Capture-pane style: capture-pane -e -p includes the color but tmux
                // appends a reset at the end of each line in the capture.
                // capturePaneWithScrollbackForStreaming filters lines and outputs them,
                // then positions the cursor and restores active SGR state.
                let visibleLines = ["\u{1b}[35mLine 5\u{1b}[0m"]
                let cursorX = 6 // After "Line 5" (6 chars)
                let cursorY = 0

                // Build output the way the fixed pipeline does:
                // 1. Home cursor
                var captureOutput = "\u{1b}[H\u{1b}[2J"
                // 2. Output the filtered line
                captureOutput += "\u{1b}[2K" + service.filterToColorCodesOnly(visibleLines[0])
                // 3. Clear below + position cursor
                captureOutput += "\u{1b}[J"
                captureOutput += "\u{1b}[\(cursorY + 1);\(cursorX + 1)H"
                // 4. Restore the active SGR state using the production helper
                let activeSGR = service.extractActiveSGR(from: visibleLines, cursorX: cursorX, cursorY: cursorY)
                captureOutput += activeSGR
                termCapture.feed(text: captureOutput)

                // Now type a character — arrives via live stream, same for both
                termCapture.feed(text: "X")
                termRaw.feed(text: "X")

                // Both should show "X" in magenta
                let rawColor = getFgColor(termRaw, col: 6, row: 0)
                let captureColor = getFgColor(termCapture, col: 6, row: 0)

                #expect(
                    rawColor != .defaultColor,
                    "Raw terminal 'X' should be magenta, got: \(rawColor)"
                )
                #expect(
                    captureColor == rawColor,
                    "Capture terminal should match raw SGR state: capture=\(captureColor) raw=\(rawColor)"
                )
            }
        }

        // MARK: - Full pipeline simulation

        @Suite("Full pipeline simulation")
        struct FullPipelineTests {
            @Test("filterToColorCodesOnly then live stream produces same result as unfiltered")
            @MainActor
            func filterThenLiveStream() {
                let service = TmuxService()
                let (termFiltered, _) = makeTerminal(cols: 80, rows: 30)
                let (termUnfiltered, _) = makeTerminal(cols: 80, rows: 30)

                // Content with only SGR codes (which filter preserves)
                let lines = [
                    "\u{1b}[38;2;135;0;255m✻\u{1b}[39m",
                    "Line 1",
                    "\u{1b}[31mImportant\u{1b}[0m",
                    "Line 3",
                    "Line 4",
                ]

                // Unfiltered terminal
                var unfilteredInitial = "\u{1b}[H"
                for line in lines {
                    unfilteredInitial += "\u{1b}[2K" + line + "\r\n"
                }
                unfilteredInitial += "\u{1b}[J\u{1b}[6;1H"
                termUnfiltered.feed(text: unfilteredInitial)

                // Filtered terminal
                var filteredInitial = "\u{1b}[H"
                for line in lines {
                    filteredInitial += "\u{1b}[2K" + service.filterToColorCodesOnly(line) + "\r\n"
                }
                filteredInitial += "\u{1b}[J\u{1b}[6;1H"
                termFiltered.feed(text: filteredInitial)

                // Both should match since filter only strips non-SGR (none here)
                for row in 0..<5 {
                    let filteredText = getRowText(termFiltered, row: row)
                    let unfilteredText = getRowText(termUnfiltered, row: row)
                    #expect(
                        filteredText == unfilteredText,
                        "Row \(row): filtered='\(filteredText)' unfiltered='\(unfilteredText)'"
                    )
                }

                // Apply the same live stream update to both
                let liveUpdate =
                    "\u{1b}[?2026h\r\u{1b}[3A\u{1b}[31mUpdated!\u{1b}[0m\r\u{1b}[3B\u{1b}[?2026l"
                termFiltered.feed(text: liveUpdate)
                termUnfiltered.feed(text: liveUpdate)

                // Compare
                for row in 0..<5 {
                    let filteredText = getRowText(termFiltered, row: row)
                    let unfilteredText = getRowText(termUnfiltered, row: row)
                    #expect(
                        filteredText == unfilteredText,
                        "After update, row \(row): filtered='\(filteredText)' unfiltered='\(unfilteredText)'"
                    )
                }
            }
        }
    }

    // MARK: - Capture Processing Tests

    @Suite("Capture Processing (processCapturePaneForStreaming)")
    @MainActor
    struct CaptureProcessingTests {
        @Test("Produces valid output with nil scrollback")
        func nilScrollback() async {
            let service = TmuxService()
            let result = service.processCapturePaneForStreaming(
                scrollbackOutput: nil,
                visibleOutput: "line1\nline2",
                cursorOutput: "0,0",
                height: 24
            )
            let str = String(data: result, encoding: .utf8)!
            #expect(str.contains("\u{1b}[H")) // Home position
            #expect(str.contains("\u{1b}[2K")) // Line clear
            #expect(str.contains("line1"))
            #expect(str.contains("line2"))
        }

        @Test("Handles trailing newline in visible output")
        func trailingNewline() async {
            let service = TmuxService()
            // Subprocess output has trailing newline, control mode may not
            let withNewline = service.processCapturePaneForStreaming(
                scrollbackOutput: nil,
                visibleOutput: "line1\nline2\n",
                cursorOutput: "0,0",
                height: 24
            )
            let withoutNewline = service.processCapturePaneForStreaming(
                scrollbackOutput: nil,
                visibleOutput: "line1\nline2",
                cursorOutput: "0,0",
                height: 24
            )
            // Both should produce the same output
            #expect(withNewline == withoutNewline)
        }

        @Test("Cursor position is included in output")
        func cursorPosition() async {
            let service = TmuxService()
            let result = service.processCapturePaneForStreaming(
                scrollbackOutput: nil,
                visibleOutput: "line1\nline2\nline3",
                cursorOutput: "5,1",
                height: 24
            )
            let str = String(data: result, encoding: .utf8)!
            // Cursor at row 1 (0-indexed), 3 lines output.
            // After drawing 3 lines cursor is on line 3. Move up 3-1-1=1 line, col 6.
            #expect(str.contains("\u{1b}[1A")) // move up 1
            #expect(str.contains("\u{1b}[6G")) // column 6
        }

        @Test("Scrollback content is included with SGR resets")
        func scrollbackIncluded() async {
            let service = TmuxService()
            let result = service.processCapturePaneForStreaming(
                scrollbackOutput: "scrollback line",
                visibleOutput: "visible line",
                cursorOutput: "0,0",
                height: 5
            )
            let str = String(data: result, encoding: .utf8)!
            #expect(str.contains("scrollback line"))
            #expect(str.contains("visible line"))
            // Scrollback should have SGR resets
            #expect(str.contains("\u{1b}[0m"))
        }

        @Test("Cursor beyond visible lines pads output to reach cursor row")
        func cursorBeyondVisibleLines() async {
            let service = TmuxService()
            // Cursor at row 10 but only 2 lines of content.
            // capture-pane trims trailing empty lines, so this is normal when
            // the cursor is below the last non-empty line.
            // We must pad output to row 10 so cursor positioning is correct.
            let result = service.processCapturePaneForStreaming(
                scrollbackOutput: nil,
                visibleOutput: "line1\nline2",
                cursorOutput: "0,10",
                height: 24
            )
            let str = String(data: result, encoding: .utf8)!
            // linesToOutput = max(11, 2) = 11. After drawing 11 lines (2 content + 9 blank),
            // cursor is on line 11. effectiveCursorY = 10, linesUp = 11-1-10 = 0.
            #expect(str.contains("\u{1b}[1G")) // column 1
            #expect(!str.contains("\u{1b}[1A")) // no cursor-up needed (cursor is on last line)
        }

        @Test("Live typing after initial capture lands on correct row with cursor mid-screen")
        @MainActor
        func liveTypingAfterCaptureCorrectRow() {
            let service = TmuxService()
            let rows = 24
            let cols = 80

            // Build visible content: 24 lines, all with content
            // Cursor at row 21 (0-indexed), like a Claude Code input area
            var visibleLines: [String] = []
            for i in 0..<rows {
                if i < 20 {
                    visibleLines.append("Content line \(i + 1)")
                } else if i == 20 {
                    visibleLines.append(String(repeating: "─", count: cols))
                } else if i == 21 {
                    visibleLines.append("> Input: BEFORE")
                } else if i == 22 {
                    visibleLines.append("[status]")
                } else {
                    visibleLines.append("[bottom]")
                }
            }
            let visibleOutput = visibleLines.joined(separator: "\n")

            // Some scrollback
            var scrollbackLines: [String] = []
            for i in 0..<30 {
                scrollbackLines.append("History \(i + 1)")
            }
            let scrollbackOutput = scrollbackLines.joined(separator: "\n")

            // Cursor at col 15, row 21 (0-indexed) — on the input line after "> Input: BEFORE"
            // "> Input: BEFORE" = 15 chars (positions 0-14), cursor at col 15
            let cursorOutput = "15,21"

            // Generate initial capture data
            let initialData = service.processCapturePaneForStreaming(
                scrollbackOutput: scrollbackOutput,
                visibleOutput: visibleOutput,
                cursorOutput: cursorOutput,
                height: rows
            )

            // Feed to SwiftTerm
            let (terminal, _) = makeTerminal(cols: cols, rows: rows)
            let bytes = Array(initialData)
            terminal.feed(byteArray: bytes)

            // Verify cursor is at the correct position
            let cursorRow = terminal.buffer.y // 0-indexed in SwiftTerm
            let cursorCol = terminal.buffer.x
            #expect(
                cursorRow == 21,
                "Cursor should be at row 21 (0-indexed), got \(cursorRow)"
            )
            #expect(
                cursorCol == 15,
                "Cursor should be at col 15, got \(cursorCol)"
            )

            // Verify the input line content
            let inputLineText = getRowText(terminal, row: 21)
            #expect(
                inputLineText.contains("> Input: BEFORE"),
                "Row 21 should have input content, got '\(inputLineText)'"
            )

            // Now simulate live typing: a character arrives via %output
            // This is what happens after attachment
            terminal.feed(text: "X")

            // The "X" should appear at the same row as BEFORE
            let afterRow = terminal.buffer.y
            #expect(
                afterRow == 21,
                "After typing, cursor should still be at row 21, got \(afterRow)"
            )

            // The input line should now contain "X" appended
            let inputLineAfter = getRowText(terminal, row: 21)

            #expect(
                inputLineAfter.contains("BEFOREX"),
                "Row 21 should have BEFOREX"
            )
        }

        @Test("Dimension mismatch: tmux has more rows than mirror")
        @MainActor
        func dimensionMismatchTyping() {
            let service = TmuxService()
            let tmuxRows = 37 // tmux pane dimensions
            let mirrorRows = 24 // mirror terminal dimensions (smaller!)
            let cols = 90

            // Build visible content: 37 lines of tmux output (Claude Code-like)
            var visibleLines: [String] = []
            for i in 0..<tmuxRows {
                if i < tmuxRows - 5 {
                    visibleLines.append("Content line \(i + 1)")
                } else if i == tmuxRows - 5 {
                    visibleLines.append(String(repeating: "─", count: cols))
                } else if i == tmuxRows - 4 {
                    visibleLines.append("> hello world")
                } else if i == tmuxRows - 3 {
                    visibleLines.append(String(repeating: "─", count: cols))
                } else if i == tmuxRows - 2 {
                    visibleLines.append("[status bar]")
                } else {
                    visibleLines.append("[bottom]")
                }
            }
            let visibleOutput = visibleLines.joined(separator: "\n")

            // Cursor on the input line (tmux row 33, 0-indexed)
            // "> hello world" = 13 chars, cursor at col 13
            let inputRow = tmuxRows - 4
            let cursorOutput = "13,\(inputRow)"

            let initialData = service.processCapturePaneForStreaming(
                scrollbackOutput: nil,
                visibleOutput: visibleOutput,
                cursorOutput: cursorOutput,
                height: tmuxRows
            )

            // Create a SMALLER terminal (like the mirror)
            let (terminal, _) = makeTerminal(cols: cols, rows: mirrorRows)
            terminal.feed(byteArray: Array(initialData))

            // Find which mirror row has "> hello world"
            let inputMirrorRow = (0..<mirrorRows).first { getRowText(terminal, row: $0).contains("> hello world") } ?? -1
            #expect(inputMirrorRow >= 0, "Should find input line in mirror")

            // Verify cursor is on the same row as the input content
            let cursorRow = terminal.buffer.y
            #expect(
                cursorRow == inputMirrorRow,
                "Cursor (row \(cursorRow)) should be on the input line (row \(inputMirrorRow))"
            )

            // Now simulate live typing: type " test"
            terminal.feed(text: " test")

            // The typed text should appear on the same line as "hello world"
            let inputLineAfter = getRowText(terminal, row: inputMirrorRow)

            #expect(
                inputLineAfter.contains("hello world test"),
                "Input line should have 'hello world test' but got '\(inputLineAfter)'"
            )
        }

        @Test("Live cursor-up movement after initial capture lands on correct row")
        @MainActor
        func liveCursorUpAfterCapture() {
            let service = TmuxService()
            let rows = 24
            let cols = 80

            // Build visible content similar to Claude Code
            var visibleLines: [String] = []
            for i in 0..<rows {
                if i < 20 {
                    visibleLines.append("Content line \(i + 1)")
                } else if i == 20 {
                    visibleLines.append(String(repeating: "─", count: cols))
                } else if i == 21 {
                    visibleLines.append("> Input area")
                } else if i == 22 {
                    visibleLines.append("[status]")
                } else {
                    visibleLines.append("[bottom]")
                }
            }
            let visibleOutput = visibleLines.joined(separator: "\n")
            let scrollbackOutput = (1...30).map { "History \($0)" }.joined(separator: "\n")

            // Cursor on input line (row 21, col 13)
            let cursorOutput = "13,21"

            let initialData = service.processCapturePaneForStreaming(
                scrollbackOutput: scrollbackOutput,
                visibleOutput: visibleOutput,
                cursorOutput: cursorOutput,
                height: rows
            )

            let (terminal, _) = makeTerminal(cols: cols, rows: rows)
            terminal.feed(byteArray: Array(initialData))

            // Verify initial cursor position
            #expect(terminal.buffer.y == 21, "Initial cursor row should be 21")

            // Simulate Claude Code's input redraw: move cursor up 1, clear line, write, move back
            // This is a common pattern: \e[A (up 1) \e[2K (clear) write \e[B (down 1) \e[2K write
            let liveUpdate = "\u{1b}[A\u{1b}[2K> Updated input\u{1b}[B"
            terminal.feed(text: liveUpdate)

            // After: cursor moved up to row 20, cleared, wrote, moved down to row 21
            // The cursor should now be at row 21 (moved down from 20)
            // But wait — row 20 is the separator line.
            // The "Updated input" should be on row 20 (the line above input)
            // and cursor should be back at row 21

            let row20text = getRowText(terminal, row: 20)
            let finalCursorRow = terminal.buffer.y

            #expect(
                row20text.contains("> Updated input"),
                "Row 20 should have updated content, got '\(row20text)'"
            )
            #expect(
                finalCursorRow == 21,
                "Cursor should be back at row 21 after down, got \(finalCursorRow)"
            )
        }

        @Test("No blank gap in scrollback when mirror is smaller than tmux pane")
        @MainActor
        func scrollbackGapWithSmallerMirror() {
            let service = TmuxService()
            let tmuxRows = 50
            let cols = 80

            // Build 200 lines of scrollback (numbered for easy identification)
            let scrollbackLines = (1...200).map { "Line \($0)" }
            let scrollbackOutput = scrollbackLines.joined(separator: "\n")

            // Build visible content (bottom 50 lines of a terminal after `seq 1 200`)
            var visibleLines: [String] = []
            for i in 0..<tmuxRows {
                if i < tmuxRows - 1 {
                    visibleLines.append("Visible \(i + 1)")
                } else {
                    visibleLines.append("$ ") // shell prompt on last line
                }
            }
            let visibleOutput = visibleLines.joined(separator: "\n")

            // Cursor at end of prompt
            let cursorOutput = "2,\(tmuxRows - 1)"

            let initialData = service.processCapturePaneForStreaming(
                scrollbackOutput: scrollbackOutput,
                visibleOutput: visibleOutput,
                cursorOutput: cursorOutput,
                height: tmuxRows
            )

            // Feed into an OVERSIZED terminal so all content (scrollback + visible)
            // fits on screen without any terminal scrollback. This lets us check
            // every line via getLine(row:) (which is public) without needing
            // internal SwiftTerm buffer APIs.
            let bigRows = 500
            let (terminal, _) = makeTerminal(cols: cols, rows: bigRows)
            terminal.feed(byteArray: Array(initialData))

            // Collect all line texts from the oversized terminal
            var allLines: [String] = []
            for row in 0..<bigRows {
                allLines.append(getRowText(terminal, row: row))
            }

            // Find the first and last non-empty lines
            let firstNonEmpty = allLines.firstIndex { !$0.isEmpty } ?? 0
            let lastNonEmpty = allLines.lastIndex { !$0.isEmpty } ?? 0

            // Between the first and last non-empty lines, there should be
            // no blank lines (that would be the "gap")
            var blankGapLines: [Int] = []
            for i in firstNonEmpty...lastNonEmpty where allLines[i].isEmpty {
                blankGapLines.append(i)
            }

            #expect(
                blankGapLines.isEmpty,
                """
                Found \(blankGapLines.count) blank gap line(s) between \
                content at rows \(firstNonEmpty) and \(lastNonEmpty). \
                Blank rows: \(blankGapLines.prefix(10))
                """
            )

            // Verify we have meaningful content — scrollback + visible should both appear
            let hasScrollbackContent = allLines.contains { $0.hasPrefix("Line ") }
            let hasVisibleContent = allLines.contains { $0.hasPrefix("Visible ") || $0.hasPrefix("$") }
            #expect(hasScrollbackContent, "Should contain scrollback lines")
            #expect(hasVisibleContent, "Should contain visible lines")
        }
    }
#endif
