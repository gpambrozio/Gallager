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
                terminal.feed(text: "\u{1b}[68;1HText at row 68")

                // Text should appear somewhere (clamped to terminal bounds)
                let foundAnywhere = (0..<24).contains { row in
                    getRowText(terminal, row: row).contains("Text at row 68")
                }
                #expect(foundAnywhere, "Text should appear somewhere after cursor clamping")
            }

            @Test(
                "Relative cursor movements produce wrong output when cursor position was clamped"
            )
            func relativeCursorAfterClamping() {
                // tmux pane: 80x68, mirror: 80x40
                // Content fills 60 rows, cursor at row 63 (clamped to 40)
                let mirrorRows = 40

                let (terminal, _) = makeTerminal(cols: 80, rows: mirrorRows)

                // Fill content
                for i in 0..<60 {
                    terminal.feed(text: String(format: "Content line %02d\r\n", i))
                }

                // Position cursor at tmux's cursor row (63), will be clamped
                terminal.feed(text: "\u{1b}[63;1H")

                // CursorUp:8 — in tmux goes to row 55, in mirror from clamped row 40
                terminal.feed(text: "\r\u{1b}[8AMARKER")

                let markerRow = (0..<mirrorRows).first { row in
                    getRowText(terminal, row: row).contains("MARKER")
                }

                #expect(markerRow != nil, "MARKER should be visible")
                // In tmux (68 rows): cursor 63, up 8 = row 55 (0-indexed: 54)
                // In mirror (40 rows): cursor clamped to 40, up 8 = row 32 (0-indexed: 31)
                // These are different positions — this demonstrates the bug
                let expectedInTmux = 63 - 8 - 1 // 0-indexed: 54
                #expect(
                    markerRow != expectedInTmux,
                    "MARKER at row \(markerRow) should differ from tmux row \(expectedInTmux) due to clamping"
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
            @Test("OSC sequences leak content as literal text")
            @MainActor
            func oscLeaksContent() {
                let service = TmuxService()
                // OSC 0 (set title): ESC ] 0 ; Title BEL
                let input = "Before\u{1b}]0;Title\u{07}After"
                let result = service.filterToColorCodesOnly(input)
                // The function doesn't handle OSC sequences
                // ESC is followed by ']' (not '['), so it's treated as non-CSI
                // ESC is skipped, ']0;Title\u{07}After' remains as literal text
                let hasLeak = result.contains("]0;Title")
                #expect(hasLeak, "OSC content leaked as literal text: \(result)")
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

            @Test("Input area redraw FAILS with mismatched dimensions when cursor is deep")
            func inputAreaRedrawFailsWithMismatch() {
                // Later in a session, content has grown and cursor is deep in the terminal
                let mirrorRows = 40
                let cursorRow = 63 // tmux cursor position

                let (terminal, _) = makeTerminal(cols: 80, rows: mirrorRows)

                // Fill 60 rows of content
                for i in 0..<60 {
                    terminal.feed(text: String(format: "Content %02d\r\n", i))
                }

                // Position cursor where tmux says (will be clamped)
                terminal.feed(text: "\u{1b}[\(cursorRow);1H")

                // Claude Code's typical CursorUp:8 redraw
                terminal.feed(text: "\r\u{1b}[8AMARKER")

                let markerRow = (0..<mirrorRows).first { row in
                    getRowText(terminal, row: row).contains("MARKER")
                }

                // In tmux: row 63 - 8 = 55 (0-indexed: 54)
                // In mirror: clamped to 40, then 40 - 8 = 32 (0-indexed: 31)
                // The marker ends up at wrong row
                #expect(markerRow != nil, "MARKER should be visible")
                let expectedInTmux = 63 - 8 - 1 // 0-indexed: 54
                #expect(
                    markerRow != expectedInTmux,
                    "MARKER displaced: at row \(String(describing: markerRow)), tmux expects \(expectedInTmux)"
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
            @Test("capture-pane resets SGR but raw stream doesn't — color mismatch")
            func sgrStateDivergesAfterInitialCapture() {
                let (termCapture, _) = makeTerminal(cols: 80, rows: 10)
                let (termRaw, _) = makeTerminal(cols: 80, rows: 10)

                // Raw PTY style: set magenta, write text, no reset. Cursor stays after text.
                // SGR state: magenta is still active.
                var rawOutput = "\u{1b}[H\u{1b}[2J"
                rawOutput += "\u{1b}[35mLine 5"
                termRaw.feed(text: rawOutput)

                // Capture-pane style: capture-pane -e -p includes the color but tmux
                // appends a reset at the end of each line in the capture.
                // After filterToColorCodesOnly, ClaudeSpy reconstructs with \e[0m at line end.
                var captureOutput = "\u{1b}[H\u{1b}[2J"
                captureOutput += "\u{1b}[35mLine 5\u{1b}[0m"
                termCapture.feed(text: captureOutput)

                // Now type a character — arrives via live stream, same for both
                termCapture.feed(text: "X")
                termRaw.feed(text: "X")

                // In raw: "X" inherits magenta (SGR still active)
                // In capture: "X" is default color (SGR was reset by \e[0m])
                let rawColor = getFgColor(termRaw, col: 6, row: 0)
                let captureColor = getFgColor(termCapture, col: 6, row: 0)

                #expect(
                    rawColor != .defaultColor,
                    "Raw terminal 'X' should be magenta, got: \(rawColor)"
                )
                #expect(
                    captureColor == .defaultColor,
                    "Capture terminal 'X' should be default, got: \(captureColor)"
                )
                #expect(
                    captureColor != rawColor,
                    "SGR state diverges: capture=\(captureColor) raw=\(rawColor)"
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
#endif
