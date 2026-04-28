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

    /// Gets the background color attribute at a specific position
    private func getBgColor(_ terminal: Terminal, col: Int, row: Int) -> Attribute.Color {
        guard let line = terminal.getLine(row: row) else { return .defaultColor }
        return line[col].attribute.bg
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

        // MARK: - DEC line drawing (SO/SI) handling

        @Suite("DEC line drawing: SO/SI character translation")
        struct DECLineDrawingTests {
            @Test("Translates DEC box-drawing characters between SO/SI to UTF-8")
            @MainActor
            func translatesDECBoxDrawing() {
                let service = TmuxService()
                // SO (0x0E) + 'lqqqqk' + SI (0x0F) = ┌────┐
                let input = "\u{0e}lqqqqk\u{0f}"
                let result = service.filterToColorCodesOnly(input)
                #expect(result == "┌────┐", "DEC box chars should translate to UTF-8: got '\(result)'")
            }

            @Test("Translates full DEC table with mixed normal text")
            @MainActor
            func translatesFullTable() {
                let service = TmuxService()
                // Top: SO + lqqqqwqqqqk + SI
                let top = "\u{0e}lqqqqwqqqqk\u{0f}"
                // Row: SO + x + SI + " AB " + SO + x + SI + " CD " + SO + x + SI
                let row = "\u{0e}x\u{0f} AB \u{0e}x\u{0f} CD \u{0e}x\u{0f}"
                // Bottom: SO + mqqqqvqqqqj + SI
                let bottom = "\u{0e}mqqqqvqqqqj\u{0f}"

                let topResult = service.filterToColorCodesOnly(top)
                let rowResult = service.filterToColorCodesOnly(row)
                let bottomResult = service.filterToColorCodesOnly(bottom)

                #expect(topResult == "┌────┬────┐", "Top: got '\(topResult)'")
                #expect(rowResult == "│ AB │ CD │", "Row: got '\(rowResult)'")
                #expect(bottomResult == "└────┴────┘", "Bottom: got '\(bottomResult)'")
            }

            @Test("Preserves SGR codes within DEC mode")
            @MainActor
            func preservesSGRInDECMode() {
                let service = TmuxService()
                // SGR color code between SO/SI should be preserved
                let input = "\u{0e}\u{1b}[31mqqqq\u{1b}[0m\u{0f}"
                let result = service.filterToColorCodesOnly(input)
                #expect(result == "\u{1b}[31m────\u{1b}[0m", "SGR in DEC mode: got '\(result)'")
            }

            @Test("SO/SI bytes are stripped from output")
            @MainActor
            func soSiBytesAreStripped() {
                let service = TmuxService()
                let input = "Before\u{0e}qq\u{0f}After"
                let result = service.filterToColorCodesOnly(input)
                // SO/SI should not appear in output, only translated chars
                #expect(!result.contains("\u{0e}"), "SO byte should be stripped")
                #expect(!result.contains("\u{0f}"), "SI byte should be stripped")
                #expect(result == "Before──After", "Mixed content: got '\(result)'")
            }

            @Test("Characters without DEC mapping pass through unchanged")
            @MainActor
            func unmappedCharsPassThrough() {
                let service = TmuxService()
                // Space and digits don't have DEC line drawing mappings
                let input = "\u{0e} 123\u{0f}"
                let result = service.filterToColorCodesOnly(input)
                #expect(result == " 123", "Unmapped chars in DEC mode: got '\(result)'")
            }

            @Test("Handles unterminated SO (no closing SI)")
            @MainActor
            func unterminatedSO() {
                let service = TmuxService()
                let input = "\u{0e}lqqqqk"
                let result = service.filterToColorCodesOnly(input)
                #expect(result == "┌────┐", "Unterminated SO: got '\(result)'")
            }

            @Test("Renders correctly when fed to SwiftTerm")
            @MainActor
            func rendersCorrectlyInSwiftTerm() {
                let service = TmuxService()
                let (terminal, _) = makeTerminal(cols: 40, rows: 10)

                // Simulate capture-pane output with DEC box-drawing table
                let top = "\u{0e}lqqqqwqqqqk\u{0f}"
                let row = "\u{0e}x\u{0f} AB \u{0e}x\u{0f} CD \u{0e}x\u{0f}"
                let bottom = "\u{0e}mqqqqvqqqqj\u{0f}"

                var output = "\u{1b}[H" // Home
                output += "\u{1b}[2K" + service.filterToColorCodesOnly(top) + "\r\n"
                output += "\u{1b}[2K" + service.filterToColorCodesOnly(row) + "\r\n"
                output += "\u{1b}[2K" + service.filterToColorCodesOnly(bottom)

                terminal.feed(text: output)

                let row0 = getRowText(terminal, row: 0)
                let row1 = getRowText(terminal, row: 1)
                let row2 = getRowText(terminal, row: 2)

                #expect(row0.contains("┌"), "Row 0 should have ┌: got '\(row0)'")
                #expect(row0.contains("┐"), "Row 0 should have ┐: got '\(row0)'")
                #expect(row1.contains("│"), "Row 1 should have │: got '\(row1)'")
                #expect(row1.contains("AB"), "Row 1 should have AB: got '\(row1)'")
                #expect(row2.contains("└"), "Row 2 should have └: got '\(row2)'")
                #expect(row2.contains("┘"), "Row 2 should have ┘: got '\(row2)'")
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

            @Test("Background SGR does not leak into next line via EL clear (#411)")
            @MainActor
            func backgroundDoesNotLeakViaEraseLine() {
                let service = TmuxService()
                // Simulates tmux capture-pane output for a pane where row 0 has
                // 80 cells of bg-blue (a status bar filling the row). tmux's
                // `capture-pane -p` trims trailing cells even when they have a
                // non-default attribute, leaving a lone `\e[44m` SGR setter on
                // that row. Row 1 has plain text starting with `\e[0m` to reset
                // before the default-attribute content.
                //
                // Without the fix: the for-loop that writes visible lines emits
                // `\r\n` after row 0's `\e[44m`, leaving SwiftTerm's SGR state
                // at "bg blue". The next iteration emits `\e[2K` (Erase in Line)
                // which clears with the CURRENT background — painting row 1
                // entirely blue. The subsequent `\e[0m> Input` content writes
                // the prompt with default attributes, but the cells AFTER the
                // prompt remain blue, producing the user-visible bug.
                let visibleLines = [
                    "\u{1b}[44m", // 80 trimmed bg-blue spaces — only the SGR setter remains
                    "\u{1b}[0m> Input",
                    "Hello",
                ]
                let visibleOutput = visibleLines.joined(separator: "\n")
                let cursorOutput = "0,2,1" // cursor on the 'Hello' line

                let data = service.processCapturePaneForStreaming(
                    scrollbackOutput: nil,
                    visibleOutput: visibleOutput,
                    cursorOutput: cursorOutput,
                    height: 10
                )

                let (terminal, _) = makeTerminal(cols: 80, rows: 10)
                terminal.feed(byteArray: Array(data))

                // Verify the prompt content is on row 1
                let row1Text = getRowText(terminal, row: 1)
                #expect(row1Text.contains("> Input"), "Row 1 should have prompt: '\(row1Text)'")

                // The cells AFTER the prompt content on row 1 must have default
                // background. Without the fix, col 20 (well past "> Input") has
                // bg blue from the leaked clear.
                let bgAfterPrompt = getBgColor(terminal, col: 20, row: 1)
                #expect(
                    bgAfterPrompt == .defaultColor,
                    "Row 1 col 20 must have default bg, not leaked bg blue, got: \(bgAfterPrompt)"
                )

                // Row 2 ('Hello') should also be default — covers the case where
                // the leak compounds across multiple lines.
                let bgRow2 = getBgColor(terminal, col: 20, row: 2)
                #expect(
                    bgRow2 == .defaultColor,
                    "Row 2 col 20 must have default bg, got: \(bgRow2)"
                )
            }

            @Test("Full-row bg band is preserved when capture trims trailing bg spaces (#411)")
            @MainActor
            func backgroundBandSurvivesTrimmedCapture() {
                let service = TmuxService()
                // Same trimmed-row shape as `backgroundDoesNotLeakViaEraseLine`
                // (row 0 captured as a lone `\e[44m`), but here we assert the
                // *positive* side: the band must still render across the entire
                // row. The fix achieves this by writing content first, then
                // emitting `\e[K` so EL erases with the line's active bg —
                // even when capture-pane left no spaces to draw.
                let visibleLines = [
                    "\u{1b}[44m", // trimmed bg-blue row — only the SGR setter remains
                    "\u{1b}[0m> Input",
                ]
                let visibleOutput = visibleLines.joined(separator: "\n")
                let cursorOutput = "8,1,1"

                let data = service.processCapturePaneForStreaming(
                    scrollbackOutput: nil,
                    visibleOutput: visibleOutput,
                    cursorOutput: cursorOutput,
                    height: 10
                )

                let (terminal, _) = makeTerminal(cols: 80, rows: 10)
                terminal.feed(byteArray: Array(data))

                // Every cell on row 0 should carry the bg-blue attribute,
                // including cells the capture didn't enumerate explicitly.
                let bgRow0Start = getBgColor(terminal, col: 0, row: 0)
                let bgRow0Mid = getBgColor(terminal, col: 40, row: 0)
                let bgRow0End = getBgColor(terminal, col: 79, row: 0)
                #expect(bgRow0Start != .defaultColor, "Row 0 col 0 must have bg, got: \(bgRow0Start)")
                #expect(bgRow0Mid != .defaultColor, "Row 0 col 40 must have bg, got: \(bgRow0Mid)")
                #expect(bgRow0End != .defaultColor, "Row 0 col 79 must have bg, got: \(bgRow0End)")
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
        func nilScrollback() throws {
            let service = TmuxService()
            let result = service.processCapturePaneForStreaming(
                scrollbackOutput: nil,
                visibleOutput: "line1\nline2",
                cursorOutput: "0,0,1",
                height: 24
            )
            let str = try #require(String(data: result, encoding: .utf8))
            #expect(str.contains("\u{1b}[H")) // Home position
            #expect(str.contains("\u{1b}[K")) // Per-line erase-to-EOL
            #expect(str.contains("line1"))
            #expect(str.contains("line2"))
        }

        @Test("Handles trailing newline in visible output")
        func trailingNewline() {
            let service = TmuxService()
            // Subprocess output has trailing newline, control mode may not
            let withNewline = service.processCapturePaneForStreaming(
                scrollbackOutput: nil,
                visibleOutput: "line1\nline2\n",
                cursorOutput: "0,0,1",
                height: 24
            )
            let withoutNewline = service.processCapturePaneForStreaming(
                scrollbackOutput: nil,
                visibleOutput: "line1\nline2",
                cursorOutput: "0,0,1",
                height: 24
            )
            // Both should produce the same output
            #expect(withNewline == withoutNewline)
        }

        @Test("Cursor position is included in output")
        func cursorPosition() throws {
            let service = TmuxService()
            let result = service.processCapturePaneForStreaming(
                scrollbackOutput: nil,
                visibleOutput: "line1\nline2\nline3",
                cursorOutput: "5,1,1",
                height: 24
            )
            let str = try #require(String(data: result, encoding: .utf8))
            // Cursor at row 1 (0-indexed), 3 lines output.
            // After drawing 3 lines cursor is on line 3. Move up 3-1-1=1 line, col 6.
            #expect(str.contains("\u{1b}[1A")) // move up 1
            #expect(str.contains("\u{1b}[6G")) // column 6
        }

        @Test("Scrollback content is included with SGR resets")
        func scrollbackIncluded() throws {
            let service = TmuxService()
            // Scrollback must have >= height lines to be included (otherwise
            // it's treated as stale post-clear content and suppressed).
            let scrollbackLines = (1...6).map { "scrollback line \($0)" }
            let result = service.processCapturePaneForStreaming(
                scrollbackOutput: scrollbackLines.joined(separator: "\n"),
                visibleOutput: "visible line",
                cursorOutput: "0,0,1",
                height: 5
            )
            let str = try #require(String(data: result, encoding: .utf8))
            #expect(str.contains("scrollback line 1"))
            #expect(str.contains("visible line"))
            // Scrollback should have SGR resets
            #expect(str.contains("\u{1b}[0m"))
        }

        @Test("Cursor beyond visible lines pads output to reach cursor row")
        func cursorBeyondVisibleLines() throws {
            let service = TmuxService()
            // Cursor at row 10 but only 2 lines of content.
            // capture-pane trims trailing empty lines, so this is normal when
            // the cursor is below the last non-empty line.
            // We must pad output to row 10 so cursor positioning is correct.
            let result = service.processCapturePaneForStreaming(
                scrollbackOutput: nil,
                visibleOutput: "line1\nline2",
                cursorOutput: "0,10,1",
                height: 24
            )
            let str = try #require(String(data: result, encoding: .utf8))
            // linesToOutput = max(11, 2) = 11. After drawing 11 lines (2 content + 9 blank),
            // cursor is on line 11. effectiveCursorY = 10, linesUp = 11-1-10 = 0.
            #expect(str.contains("\u{1b}[1G")) // column 1
            #expect(!str.contains("\u{1b}[1A")) // no cursor-up needed (cursor is on last line)
        }

        @Test("Hidden cursor flag emits DECTCEM hide sequence")
        func hiddenCursorFlag() throws {
            let service = TmuxService()
            let result = service.processCapturePaneForStreaming(
                scrollbackOutput: nil,
                visibleOutput: "line1\nline2",
                cursorOutput: "0,0,0",
                height: 24
            )
            let str = try #require(String(data: result, encoding: .utf8))
            #expect(str.hasSuffix("\u{1b}[?25l"))
        }

        @Test("Visible cursor flag does not emit hide sequence")
        func visibleCursorFlag() throws {
            let service = TmuxService()
            let result = service.processCapturePaneForStreaming(
                scrollbackOutput: nil,
                visibleOutput: "line1\nline2",
                cursorOutput: "0,0,1",
                height: 24
            )
            let str = try #require(String(data: result, encoding: .utf8))
            #expect(!str.contains("\u{1b}[?25l"))
        }

        @Test("Missing cursor flag defaults to visible (no hide sequence)")
        func missingCursorFlag() throws {
            let service = TmuxService()
            // Legacy format without cursor_flag — should default to visible
            let result = service.processCapturePaneForStreaming(
                scrollbackOutput: nil,
                visibleOutput: "line1\nline2",
                cursorOutput: "0,0",
                height: 24
            )
            let str = try #require(String(data: result, encoding: .utf8))
            #expect(!str.contains("\u{1b}[?25l"))
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
            let cursorOutput = "15,21,1"

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
            let cursorOutput = "13,\(inputRow),1"

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
            let cursorOutput = "13,21,1"

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

        @Test("Scrollback pushed to buffer via LF, no gap when scrolling up")
        @MainActor
        func scrollbackPushedToBuffer() {
            let service = TmuxService()
            let tmuxRows = 40
            let cols = 80

            // Build scrollback content (simulating `seq 1 100` on a 40-row terminal)
            // The scrollback capture (-E -1) includes only scrollback lines,
            // NOT the visible area.
            let scrollbackLines = (1...62).map { "Line \($0)" }
            let scrollbackOutput = scrollbackLines.joined(separator: "\n")

            // Build visible content (last 40 lines)
            var visibleLines: [String] = []
            for i in 63...101 {
                visibleLines.append("Line \(i)")
            }
            visibleLines.append("$ ") // shell prompt on last line
            let visibleOutput = visibleLines.joined(separator: "\n")

            // Cursor at end of prompt
            let cursorOutput = "2,\(tmuxRows - 1),1"

            let initialData = service.processCapturePaneForStreaming(
                scrollbackOutput: scrollbackOutput,
                visibleOutput: visibleOutput,
                cursorOutput: cursorOutput,
                height: tmuxRows
            )

            // Feed into a correctly-sized terminal (matching tmux pane dimensions)
            let (terminal, _) = makeTerminal(cols: cols, rows: tmuxRows)
            terminal.feed(byteArray: Array(initialData))

            // Verify visible area shows Part 2 content
            let visibleRow0 = getRowText(terminal, row: 0)
            #expect(visibleRow0.contains("Line 63"), "Visible row 0 should show Part 2 content, got '\(visibleRow0)'")

            // Verify ALL scrollback content is in the terminal's scrollback buffer.
            // Use getScrollInvariantLine to read both scrollback and visible area.
            // Lines should be continuous from Line 1 through Line 101 with no gaps.
            var allContent: [String] = []
            // yDisp == yBase here (no user scrolling has occurred), giving us
            // the total line count (scrollback + visible). yBase would be
            // preferable but it's internal to SwiftTerm.
            let totalLines = terminal.buffer.yDisp + terminal.rows
            for row in 0..<totalLines {
                guard let line = terminal.getScrollInvariantLine(row: row) else { continue }
                let text = line.translateToString(trimRight: true)
                if !text.isEmpty {
                    allContent.append(text)
                }
            }

            // Verify early scrollback is preserved (this is what SU was destroying)
            #expect(
                allContent.contains { $0.contains("Line 1") },
                "First scrollback line should be preserved"
            )
            #expect(
                allContent.contains { $0.contains("Line 30") },
                "Middle scrollback line should be preserved (was destroyed by SU)"
            )
            #expect(
                allContent.contains { $0.contains("Line 62") },
                "Last scrollback-only line should be preserved"
            )
            #expect(
                allContent.contains { $0.contains("Line 63") },
                "First visible line should be present"
            )

            // Verify no gap: find all "Line N" entries and check they are continuous
            let lineNumbers = allContent.compactMap { line -> Int? in
                guard line.hasPrefix("Line ") else { return nil }
                return Int(line.dropFirst(5))
            }
            let sortedNumbers = lineNumbers.sorted()
            #expect(!lineNumbers.isEmpty, "Should have found at least one 'Line N' entry in buffer")
            for i in 1..<sortedNumbers.count {
                #expect(
                    sortedNumbers[i] == sortedNumbers[i - 1] + 1,
                    "Gap in scrollback: Line \(sortedNumbers[i - 1]) → Line \(sortedNumbers[i])"
                )
            }
        }
    }

    // MARK: - Emoji Width in Tables

    @Suite("Emoji width handling in tables")
    struct EmojiWidthTests {
        @Test("Emoji characters occupy 2 columns in SwiftTerm")
        func emojiOccupiesTwoColumns() throws {
            let (terminal, _) = makeTerminal(cols: 80, rows: 10)

            // Feed a line: "A🔴B" — if 🔴 is 2 cols wide, B should be at col 4
            // A(col 0) + 🔴(col 1-2) + B(col 3)
            terminal.feed(text: "\u{1b}[H") // home
            terminal.feed(text: "A\u{1f534}B")

            let cursorCol = terminal.buffer.x
            // After A(1 col) + 🔴(2 cols) + B(1 col), cursor should be at col 4
            #expect(cursorCol == 4, "Cursor should be at col 4 after A+🔴+B, got \(cursorCol)")

            // Check that B is at col 3
            let line = try #require(terminal.getLine(row: 0))
            let bChar = line[3].getCharacter()
            #expect(bChar == "B", "Col 3 should have 'B', got '\(bChar)'")
        }

        @Test("Various emoji all occupy 2 columns")
        func variousEmojiWidth() throws {
            let (terminal, _) = makeTerminal(cols: 80, rows: 10)

            let emoji: [(String, Character)] = [
                ("\u{1f534}", "🔴"), // Red circle (U+1F534, Unicode 6)
                ("\u{1f7e1}", "🟡"), // Yellow circle (U+1F7E1, Unicode 12)
                ("\u{1f7e2}", "🟢"), // Green circle (U+1F7E2, Unicode 12)
                ("\u{1f535}", "🔵"), // Blue circle (U+1F535, Unicode 6)
            ]

            for (i, (emojiStr, label)) in emoji.enumerated() {
                terminal.feed(text: "\u{1b}[\(i + 1);1H") // move to row
                terminal.feed(text: "X\(emojiStr)Y")

                let line = try #require(terminal.getLine(row: i))

                // X at col 0, emoji at col 1-2, Y at col 3
                let xChar = line[0].getCharacter()
                let yChar = line[3].getCharacter()

                #expect(xChar == "X", "\(label): col 0 should be 'X', got '\(xChar)'")
                #expect(yChar == "Y", "\(label): col 3 should be 'Y' (emoji=2 cols), got '\(yChar)'")
            }
        }

        @Test("Table with emoji renders with aligned columns")
        func tableWithEmojiAlignment() throws {
            let (terminal, _) = makeTerminal(cols: 40, rows: 10)

            // Build a small table:
            // ┌──────┬────────────────┐  (col widths: 6, 16)
            // │ St   │ Notes          │
            // ├──────┼────────────────┤
            // │ 🔴   │ Bug found      │
            // │ 🟢   │ All passing    │
            // └──────┴────────────────┘
            let c1 = 6
            let c2 = 16
            let top = "┌" + String(repeating: "─", count: c1) + "┬" + String(repeating: "─", count: c2) + "┐"
            let header = "│ St   │ Notes          │"
            let sep = "├" + String(repeating: "─", count: c1) + "┼" + String(repeating: "─", count: c2) + "┤"
            // Emoji (2 cols) + 3 spaces = 5 display cols; with leading space = 6 cols
            let row1 = "│ \u{1f534}   │ Bug found      │"
            let row2 = "│ \u{1f7e2}   │ All passing    │"
            let bottom = "└" + String(repeating: "─", count: c1) + "┴" + String(repeating: "─", count: c2) + "┘"

            terminal.feed(text: "\u{1b}[H") // home
            terminal.feed(text: top + "\r\n")
            terminal.feed(text: header + "\r\n")
            terminal.feed(text: sep + "\r\n")
            terminal.feed(text: row1 + "\r\n")
            terminal.feed(text: row2 + "\r\n")
            terminal.feed(text: bottom)

            // The ┬ on the top border and ┼ on the separator should be at the same column.
            // ┌(0) + 6 dashes(1-6) + ┬(7) → col 7
            let topLine = try #require(terminal.getLine(row: 0))
            let sepLine = try #require(terminal.getLine(row: 2))
            let dataLine1 = try #require(terminal.getLine(row: 3))
            let dataLine2 = try #require(terminal.getLine(row: 4))

            // Check that ┬ and ┼ are at col 7
            let topSep = topLine[7].getCharacter()
            let midSep = sepLine[7].getCharacter()
            #expect(topSep == "┬", "Top border: col 7 should be ┬, got '\(topSep)'")
            #expect(midSep == "┼", "Mid separator: col 7 should be ┼, got '\(midSep)'")

            // Check that │ separators in data rows are ALSO at col 7
            let data1Sep = dataLine1[7].getCharacter()
            let data2Sep = dataLine2[7].getCharacter()
            #expect(
                data1Sep == "│",
                "Data row 1 (🔴): col 7 should be │, got '\(data1Sep)' — emoji width mismatch?"
            )
            #expect(
                data2Sep == "│",
                "Data row 2 (🟢): col 7 should be │, got '\(data2Sep)' — emoji width mismatch?"
            )

            // Also check the right border alignment at col 24 (7 + 1 + 16 = 24)
            let expectedRightCol = 1 + c1 + 1 + c2 // = 24
            let topRight = topLine[expectedRightCol].getCharacter()
            let data1Right = dataLine1[expectedRightCol].getCharacter()
            #expect(topRight == "┐", "Top right corner at col \(expectedRightCol): got '\(topRight)'")
            #expect(
                data1Right == "│",
                "Data row 1 right border at col \(expectedRightCol): got '\(data1Right)' — column shift from emoji?"
            )
        }

        @Test("Table with emoji via processCapturePaneForStreaming")
        @MainActor
        func tableWithEmojiViaCapture() throws {
            let service = TmuxService()
            let cols = 40
            let rows = 10
            let c1 = 6
            let c2 = 16

            // Simulate capture-pane -e output of a table with emoji.
            // capture-pane outputs the visible screen content with ANSI codes.
            // Emoji are output as UTF-8 (not DEC graphics).
            let visibleLines = [
                "┌" + String(repeating: "─", count: c1) + "┬" + String(repeating: "─", count: c2) + "┐",
                "│ St   │ Notes          │",
                "├" + String(repeating: "─", count: c1) + "┼" + String(repeating: "─", count: c2) + "┤",
                "│ \u{1f534}   │ Bug found      │",
                "│ \u{1f7e2}   │ All passing    │",
                "└" + String(repeating: "─", count: c1) + "┴" + String(repeating: "─", count: c2) + "┘",
            ]
            let visibleOutput = visibleLines.joined(separator: "\n")

            let initialData = service.processCapturePaneForStreaming(
                scrollbackOutput: nil,
                visibleOutput: visibleOutput,
                cursorOutput: "0,6,1",
                height: rows
            )

            let (terminal, _) = makeTerminal(cols: cols, rows: rows)
            terminal.feed(byteArray: Array(initialData))

            // Verify column alignment after going through the capture pipeline
            let topLine = try #require(terminal.getLine(row: 0))
            let dataLine1 = try #require(terminal.getLine(row: 3))

            let topSep = topLine[7].getCharacter()
            let data1Sep = dataLine1[7].getCharacter()

            #expect(topSep == "┬", "Top: col 7 = ┬, got '\(topSep)'")
            #expect(
                data1Sep == "│",
                "Capture path — Data row 1 (🔴): col 7 should be │, got '\(data1Sep)'"
            )

            // Right border
            let rightCol = 1 + c1 + 1 + c2 // 24
            let topRight = topLine[rightCol].getCharacter()
            let data1Right = dataLine1[rightCol].getCharacter()
            #expect(topRight == "┐", "Capture: top right at col \(rightCol) = ┐, got '\(topRight)'")
            #expect(
                data1Right == "│",
                "Capture: data row 1 right border at col \(rightCol) = │, got '\(data1Right)'"
            )
        }
    }

    // MARK: - Display Width Tests

    @Suite("Character display width calculation")
    struct DisplayWidthTests {
        @Test("ASCII characters are 1 column wide")
        func asciiWidth() {
            #expect(TmuxService.displayWidth(of: "A") == 1)
            #expect(TmuxService.displayWidth(of: "z") == 1)
            #expect(TmuxService.displayWidth(of: " ") == 1)
            #expect(TmuxService.displayWidth(of: "0") == 1)
        }

        @Test("Emoji are 2 columns wide")
        func emojiWidth() {
            #expect(TmuxService.displayWidth(of: "🔴") == 2)
            #expect(TmuxService.displayWidth(of: "🟡") == 2)
            #expect(TmuxService.displayWidth(of: "🟢") == 2)
            #expect(TmuxService.displayWidth(of: "🔵") == 2)
            #expect(TmuxService.displayWidth(of: "😀") == 2)
            #expect(TmuxService.displayWidth(of: "🎉") == 2)
        }

        @Test("Emoji in SwiftTerm eastAsianWide are 2 columns wide")
        func eastAsianWideEmojiWidth() {
            // These are in SwiftTerm's eastAsianWide table (always 2-wide)
            #expect(TmuxService.displayWidth(of: "\u{26BD}") == 2) // ⚽ Soccer ball
            #expect(TmuxService.displayWidth(of: "\u{231A}") == 2) // ⌚ Watch
            #expect(TmuxService.displayWidth(of: "\u{2614}") == 2) // ☔ Umbrella with rain
            #expect(TmuxService.displayWidth(of: "\u{2B50}") == 2) // ⭐ Star
            #expect(TmuxService.displayWidth(of: "\u{2B1B}") == 2) // ⬛ Black large square
            #expect(TmuxService.displayWidth(of: "\u{2705}") == 2) // ✅ Check mark
            #expect(TmuxService.displayWidth(of: "\u{2757}") == 2) // ❗ Exclamation mark
        }

        @Test("Emoji NOT in eastAsianWide are 1 column wide (only wide with VS16)")
        func vs16OnlyEmojiWidth() {
            // These are in SwiftTerm's emojiVs16Base, NOT eastAsianWide
            // They render as 1-wide unless followed by U+FE0F
            #expect(TmuxService.displayWidth(of: "\u{2744}") == 1) // ❄ Snowflake
            #expect(TmuxService.displayWidth(of: "\u{2764}") == 1) // ❤ Red heart
            #expect(TmuxService.displayWidth(of: "\u{25B6}") == 1) // ▶ Play button
            #expect(TmuxService.displayWidth(of: "\u{25C0}") == 1) // ◀ Reverse button
            #expect(TmuxService.displayWidth(of: "\u{25AA}") == 1) // ▪ Black small square
            #expect(TmuxService.displayWidth(of: "\u{2708}") == 1) // ✈ Airplane
            #expect(TmuxService.displayWidth(of: "\u{2B05}") == 1) // ⬅ Left arrow
            #expect(TmuxService.displayWidth(of: "\u{2600}") == 1) // ☀ Sun
        }

        @Test("CJK characters are 2 columns wide")
        func cjkWidth() {
            #expect(TmuxService.displayWidth(of: "中") == 2)
            #expect(TmuxService.displayWidth(of: "日") == 2)
            #expect(TmuxService.displayWidth(of: "한") == 2) // Hangul
        }

        @Test("Non-emoji symbols are 1 column wide")
        func nonEmojiSymbolsWidth() {
            #expect(TmuxService.displayWidth(of: "\u{266A}") == 1) // ♪ Eighth note
            #expect(TmuxService.displayWidth(of: "\u{266B}") == 1) // ♫ Beamed eighth notes
            #expect(TmuxService.displayWidth(of: "\u{2603}") == 1) // ☃ Snowman
            #expect(TmuxService.displayWidth(of: "\u{2014}") == 1) // — Em dash
            #expect(TmuxService.displayWidth(of: "\u{2013}") == 1) // – En dash
        }

        @Test("Box-drawing characters are 1 column wide")
        func boxDrawingWidth() {
            #expect(TmuxService.displayWidth(of: "│") == 1)
            #expect(TmuxService.displayWidth(of: "─") == 1)
            #expect(TmuxService.displayWidth(of: "┌") == 1)
            #expect(TmuxService.displayWidth(of: "┘") == 1)
        }
    }

    // MARK: - extractActiveSGR with Wide Characters

    @Suite("extractActiveSGR wide character handling")
    struct ExtractActiveSGRWideCharTests {
        @Test("Correctly tracks SGR past emoji characters")
        @MainActor
        func sgrPastEmoji() {
            let service = TmuxService()
            // Line: "🔴 \e[31mhello" — emoji at cols 0-1, space at col 2, SGR at col 3+
            // Cursor at col 5 (inside "hello")
            let lines = ["🔴 \u{1b}[31mhello"]
            let sgr = service.extractActiveSGR(from: lines, cursorX: 5, cursorY: 0)
            #expect(sgr == "\u{1b}[31m", "Should find SGR after emoji (2-col wide)")
        }

        @Test("Stops at correct column with emoji before cursor")
        @MainActor
        func stopsAtCorrectColumnWithEmoji() {
            let service = TmuxService()
            // Line: "A🔴\e[32mB\e[33mC"
            // A at col 0 (1 col), 🔴 at col 1-2 (2 cols), B at col 3, C at col 4
            // Cursor at col 3: should have picked up \e[32m but cursor is AT col 3
            // so we stop before processing col 3
            let lines = ["A\u{1f534}\u{1b}[32mB\u{1b}[33mC"]
            let sgr = service.extractActiveSGR(from: lines, cursorX: 3, cursorY: 0)
            // At col 3, we've passed A(col 0) and 🔴(cols 1-2), col is now 3 >= cursorX=3, so we stop
            // The \e[32m hasn't been processed yet since it's at col 3
            #expect(sgr == "", "Should stop before SGR at cursor column")
        }

        @Test("Picks up SGR between emoji")
        @MainActor
        func sgrBetweenEmoji() {
            let service = TmuxService()
            // Line: "🔴\e[31m🟡X"
            // 🔴 at cols 0-1, \e[31m (no col), 🟡 at cols 2-3, X at col 4
            // Cursor at col 4 should have \e[31m
            let lines = ["\u{1f534}\u{1b}[31m\u{1f7e1}X"]
            let sgr = service.extractActiveSGR(from: lines, cursorX: 4, cursorY: 0)
            #expect(sgr == "\u{1b}[31m", "Should find SGR between two emoji")
        }

        @Test("Cursor positioned correctly with emoji in table row")
        @MainActor
        func cursorPositionWithEmojiInTable() {
            let service = TmuxService()
            // Line: "\e[31mA🔴\e[32mBC"
            // A at col 0, 🔴 at cols 1-2, B at col 3, C at col 4
            // Without the wide-char fix, col would be 1 after 🔴 (wrong),
            // so cursor at col 4 would stop too late and pick up \e[33m.
            // With the fix, col is 3 after 🔴 (correct).
            let lines = ["\u{1b}[31mA\u{1f534}\u{1b}[32mBC"]
            // cursorX=4: A(0), 🔴(1-2), B(3), at col 4 we stop
            let sgr = service.extractActiveSGR(from: lines, cursorX: 4, cursorY: 0)
            // SGR state: \e[31m (from before A), then \e[32m (from before B)
            #expect(sgr == "\u{1b}[31m\u{1b}[32m", "Should track SGR correctly past 2-col emoji")
        }

        @Test("Empty cursor line does not inherit SGR from unmatched earlier set (#352)")
        @MainActor
        func emptyCursorLineDoesNotLeakSGR() {
            let service = TmuxService()
            // tmux's `capture-pane -p` trims trailing cells (even non-default).
            // A row of 80 underlined spaces captured with `-p` becomes just
            // `\e[4m` — the spaces are gone and no `\e[0m` is emitted if every
            // row below it is also empty. If the cursor is parked on one of
            // those empty rows, the capture has no reset at all.
            //
            // Without the fix the accumulated `\e[4m` leaks to the cursor, and
            // the capture restoration puts SwiftTerm into underline mode. Live-
            // streamed typed characters would then render underlined even
            // though the real pane has default attributes at the cursor cell.
            let lines = [
                "", // row 0: empty
                "\u{1b}[4m", // row 1: row of fully-underlined trimmed spaces
                "", // row 2: empty
                "", // row 3: empty (cursor parked here)
            ]
            let sgr = service.extractActiveSGR(from: lines, cursorX: 0, cursorY: 3)
            #expect(sgr == "", "Cursor on empty line must reset SGR, not inherit unmatched \\e[4m")
        }
    }

    // MARK: - Clear Screen Recapture

    @Suite("Clear screen recapture behavior")
    struct ClearScreenRecaptureTests {
        @Test("After clear, recapture visible area shows only prompt — not scrollback")
        @MainActor
        func clearRecaptureShowsOnlyPrompt() throws {
            // Simulate: user ran `seq 1 10` then `clear` in a 24-row terminal.
            // After clear, tmux state:
            //   Scrollback: history including "$ clear"
            //   Visible: prompt on row 0, cursor on row 1, rows 2-23 empty
            //
            // capture-pane trims trailing empty lines, so:
            //   Scrollback capture: [history..., "$ clear", prompt_line1, prompt_line2]
            //   Visible capture:    [prompt_line1, prompt_line2]

            let service = TmuxService()
            let height = 24

            // Build scrollback: some history + the "$ clear" command + visible overlap
            var scrollbackLines: [String] = []
            scrollbackLines.append("$ seq 1 10")
            for idx in 1...10 {
                scrollbackLines.append("\(idx)")
            }
            scrollbackLines.append("$ clear")
            // Visible overlap (capture-pane -S -N -E -1 includes visible too)
            scrollbackLines.append("user@host ~")
            scrollbackLines.append("$ ")

            let scrollbackOutput = scrollbackLines.joined(separator: "\n") + "\n"
            // Visible: full height with trailing empties (tmux doesn't trim visible capture)
            var visibleLinesList = ["user@host ~", "$ "]
            for _ in 2..<height {
                visibleLinesList.append("")
            }
            let visibleOutput = visibleLinesList.joined(separator: "\n") + "\n"
            let cursorOutput = "2,1,1" // cursor at col 2, row 1

            let data = service.processCapturePaneForStreaming(
                scrollbackOutput: scrollbackOutput,
                visibleOutput: visibleOutput,
                cursorOutput: cursorOutput,
                height: height
            )

            // Feed into a SwiftTerm terminal of the same height
            let (terminal, _) = makeTerminal(cols: 80, rows: height)
            try terminal.feed(text: #require(String(data: data, encoding: .utf8)))

            // The visible buffer should show the prompt at rows 0-1, rest empty.
            // "$ clear" must NOT appear in the visible area — it should be in scrollback only.
            let row0 = getRowText(terminal, row: 0)
            let row1 = getRowText(terminal, row: 1)
            // SwiftTerm fills cleared cells with \u{0000} (null), not space.
            // getRowText trims whitespace but not nulls, so check for null-only content.
            let row2Raw = getRowText(terminal, row: 2)
            let row2 = row2Raw.filter { $0 != "\0" }

            #expect(row0.contains("user@host"), "Row 0 should have the prompt, got: '\(row0)'")
            #expect(row1.contains("$"), "Row 1 should have '$ ', got: '\(row1)'")
            #expect(row2.isEmpty, "Row 2 should be empty after clear, got: '\(row2)'")

            // Verify "$ clear" is NOT in the visible area
            for row in 0..<height {
                let text = getRowText(terminal, row: row).filter { $0 != "\0" }
                #expect(
                    !text.contains("clear"),
                    "Row \(row) should not contain 'clear' in visible area, got: '\(text)'"
                )
            }
        }

        @Test("After clear, scrollback is NOT output (stale content suppressed)")
        @MainActor
        func clearRecaptureOmitsScrollback() throws {
            // When scrollback capture has fewer lines than visible capture (typical
            // after `clear`), scrollback should be suppressed entirely.
            let service = TmuxService()
            let height = 24

            // Scrollback capture: 14 lines (< visible 24)
            var scrollbackLines: [String] = []
            scrollbackLines.append("$ seq 1 10")
            for idx in 1...10 {
                scrollbackLines.append("\(idx)")
            }
            scrollbackLines.append("$ clear")
            scrollbackLines.append("user@host ~")
            scrollbackLines.append("$ ")

            let scrollbackOutput = scrollbackLines.joined(separator: "\n") + "\n"
            // Visible: full 24 lines (tmux doesn't trim trailing empties for visible)
            var visibleLinesList = ["user@host ~", "$ "]
            for _ in 2..<height {
                visibleLinesList.append("")
            }
            let visibleOutput = visibleLinesList.joined(separator: "\n") + "\n"
            let cursorOutput = "2,1,1"

            let data = service.processCapturePaneForStreaming(
                scrollbackOutput: scrollbackOutput,
                visibleOutput: visibleOutput,
                cursorOutput: cursorOutput,
                height: height
            )

            // Use an OVERSIZED terminal so all content is visible (no scrollback)
            let oversizedRows = 200
            let (terminal, _) = makeTerminal(cols: 80, rows: oversizedRows)
            try terminal.feed(text: #require(String(data: data, encoding: .utf8)))

            // Collect all non-empty rows
            var allContent: [String] = []
            for row in 0..<oversizedRows {
                let text = getRowText(terminal, row: row).filter { $0 != "\0" }
                if !text.isEmpty {
                    allContent.append(text)
                }
            }

            // Should NOT contain scrollback history — it was suppressed
            #expect(!allContent.contains { $0.contains("seq 1 10") }, "Scrollback should be suppressed after clear")
            #expect(!allContent.contains { $0.contains("clear") }, "$ clear should not appear after clear")
            // Should still have prompt
            #expect(allContent.contains { $0.contains("user@host") }, "Should still have prompt")
        }

        @Test("After clear with large scrollback, scrollback is still suppressed")
        @MainActor
        func clearRecaptureWithLargeScrollback() throws {
            // seq 1 100 && clear in a 40-row terminal: scrollback has >100 lines
            // but the visible area is mostly empty (just prompt).
            let service = TmuxService()
            let height = 40

            var scrollbackLines: [String] = []
            scrollbackLines.append("$ seq 1 100")
            for idx in 1...100 {
                scrollbackLines.append("\(idx)")
            }
            scrollbackLines.append("$ clear")
            scrollbackLines.append("user@host ~")
            scrollbackLines.append("$ ")
            let scrollbackOutput = scrollbackLines.joined(separator: "\n") + "\n"

            // Visible: full 40 lines, only prompt at top
            var visibleLinesList = ["user@host ~", "$ "]
            for _ in 2..<height {
                visibleLinesList.append("")
            }
            let visibleOutput = visibleLinesList.joined(separator: "\n") + "\n"

            let data = service.processCapturePaneForStreaming(
                scrollbackOutput: scrollbackOutput,
                visibleOutput: visibleOutput,
                cursorOutput: "2,1,1",
                height: height
            )

            let oversizedRows = 300
            let (terminal, _) = makeTerminal(cols: 80, rows: oversizedRows)
            try terminal.feed(text: #require(String(data: data, encoding: .utf8)))

            var allContent: [String] = []
            for row in 0..<oversizedRows {
                let text = getRowText(terminal, row: row).filter { $0 != "\0" }
                if !text.isEmpty { allContent.append(text) }
            }

            // Scrollback should be suppressed despite having many lines
            #expect(!allContent.contains { $0.contains("seq 1 100") }, "Scrollback suppressed after clear")
            #expect(!allContent.contains { $0.contains("clear") }, "$ clear suppressed")
            #expect(allContent.contains { $0.contains("user@host") }, "Prompt still present")
        }

        @Test("After clear + screen re-fill, stale scrollback is suppressed via line count")
        @MainActor
        func clearThenFillScreenSuppressesScrollback() throws {
            // Scenario: user runs `clear`, then a script that fills the screen
            // (e.g., python3 draw_table.py which also does \e[2J internally).
            // The visible area is full (screenWasCleared = false), but the
            // scrollback capture (-E -1) contains only a few stale pre-clear
            // lines — tmux trims trailing blank lines from the pushed cleared
            // area. Since the scrollback has fewer lines than the terminal
            // height, it's suppressed.
            let service = TmuxService()
            let height = 24

            // Build scrollback: only pre-clear content (tmux -E -1 does NOT
            // include the visible area, and trims trailing blank lines)
            var scrollbackLines: [String] = []
            scrollbackLines.append("user@host ~")
            scrollbackLines.append("$ export PS1='$ '")
            scrollbackLines.append("$ clear")
            scrollbackLines.append("") // tmux keeps ~1 blank after clear
            scrollbackLines.append("$ python3 /tmp/draw_table.py")
            // Total: 5 lines (< height=24) → suppressed
            let scrollbackOutput = scrollbackLines.joined(separator: "\n") + "\n"

            // Visible: full screen with table content (drawn by script's \e[2J\e[H)
            var visibleLinesList = ["Box-Drawing Table Rendering Test"]
            for i in 1...15 {
                visibleLinesList.append("Row \(i) data")
            }
            visibleLinesList.append("All services operational.")
            visibleLinesList.append("$ ")
            while visibleLinesList.count < height {
                visibleLinesList.append("")
            }
            let visibleOutput = visibleLinesList.joined(separator: "\n") + "\n"

            let data = service.processCapturePaneForStreaming(
                scrollbackOutput: scrollbackOutput,
                visibleOutput: visibleOutput,
                cursorOutput: "2,17,1",
                height: height
            )

            let oversizedRows = 200
            let (terminal, _) = makeTerminal(cols: 80, rows: oversizedRows)
            try terminal.feed(text: #require(String(data: data, encoding: .utf8)))

            var allContent: [String] = []
            for row in 0..<oversizedRows {
                let text = getRowText(terminal, row: row).filter { $0 != "\0" }
                if !text.isEmpty { allContent.append(text) }
            }

            // Pre-clear content should NOT appear (scrollback suppressed)
            #expect(
                !allContent.contains { $0.contains("export PS1") },
                "Pre-clear content should be suppressed"
            )
            #expect(
                !allContent.contains { $0.contains("clear") },
                "$ clear should not appear"
            )
            // Visible content SHOULD appear
            #expect(
                allContent.contains { $0.contains("Box-Drawing Table") },
                "Table content should be present"
            )
            #expect(
                allContent.contains { $0.contains("Row 1 data") },
                "Table rows should be present"
            )
        }

        @Test("Scrollback IS output when there is genuine scrollback content")
        @MainActor
        func scrollbackOutputWhenContentExceedsVisible() throws {
            // When scrollback capture has MORE lines than visible (typical for
            // `seq 1 200`), scrollback should be output normally (not suppressed
            // by the screenWasCleared heuristic). The scrollback data is written
            // to the output stream and pushed into the terminal's scrollback
            // buffer via LF scrolling.
            let service = TmuxService()
            let height = 24

            // Scrollback: 160 lines (>> visible 24)
            var scrollbackLines: [String] = []
            for idx in 1...158 {
                scrollbackLines.append("Line \(idx)")
            }
            scrollbackLines.append("Visible 1")
            scrollbackLines.append("$ ")

            let scrollbackOutput = scrollbackLines.joined(separator: "\n") + "\n"
            var visibleLinesList: [String] = []
            for idx in 135...158 {
                visibleLinesList.append("Line \(idx)")
            }
            let visibleOutput = visibleLinesList.joined(separator: "\n") + "\n"
            let cursorOutput = "0,23,1"

            let data = service.processCapturePaneForStreaming(
                scrollbackOutput: scrollbackOutput,
                visibleOutput: visibleOutput,
                cursorOutput: cursorOutput,
                height: height
            )

            // Verify the raw output includes scrollback data
            let rawStr = try #require(String(data: data, encoding: .utf8))
            #expect(rawStr.contains("Line 1"), "Raw output should have early scrollback content")
            #expect(rawStr.contains("Line 100"), "Raw output should have deep scrollback content")

            // When fed to a correctly-sized terminal, visible area should show
            // Part 2 content and scrollback should be in the scrollback buffer.
            let (terminal, _) = makeTerminal(cols: 80, rows: height)
            terminal.feed(text: rawStr)
            let visibleRow0 = getRowText(terminal, row: 0)
            #expect(visibleRow0.contains("Line 135"), "Visible row 0 should show Part 2 content")

            // Verify scrollback was pushed into terminal's scrollback buffer.
            // Row 0 of the scroll-invariant buffer is the first line of scrollback.
            if let scrollbackLine = terminal.getScrollInvariantLine(row: 0) {
                var text = ""
                for col in 0..<terminal.cols {
                    text += String(scrollbackLine[col].getCharacter())
                }
                #expect(
                    text.trimmingCharacters(in: .whitespaces).contains("Line 1"),
                    "First scrollback line in terminal buffer should be 'Line 1'"
                )
            } else {
                Issue.record("Terminal scrollback buffer is empty — LF scroll did not push content")
            }
        }
    }
#endif
