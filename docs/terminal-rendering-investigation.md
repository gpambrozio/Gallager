# Terminal Rendering Investigation: Garbled Output in ClaudeSpy Mirror

> **Status (PR #179):** The core streaming architecture was rewritten to use `pipe-pane` for raw PTY byte delivery instead of control mode `%output` events. This resolved the truecolor animation rendering artifacts and eliminated the need for octal unescaping, UTF-8 reconstruction, and line-boundary splitting. Hypotheses H6 (octal unescaping) and H14 (readabilityHandler race) are no longer applicable. The architecture diagram below reflects the **old** architecture — see `streaming-architecture.md` for the current data flow.

## Problem Statement

When mirroring complex terminal applications (like Claude Code) that use extensive cursor positioning, the ClaudeSpy mirror window shows:
1. **Mispositioned text** — content appears at wrong row/column locations
2. **Incorrect colors** — some text displays with wrong SGR attributes

The issue is reproducible. A tmux-rec recording of the same session replayed via raw PTY bytes renders **correctly**, proving the data from tmux is fine but ClaudeSpy's processing introduces the problem.

## Evidence

- Side-by-side screenshots of the same tmux session at roughly the same point in time — the ClaudeSpy mirror (text displaced, colors wrong) vs. a tmux-rec replay (correct rendering) — confirmed the mirror was at fault. (The screenshots contained a real working session and were removed from the repo before open-sourcing.)
- E2E scenario screenshots in `E2ETests/16-terminal-rendering-bugs/` visually confirm H17 and scrollback corruption

## Architecture Summary: How Data Flows

```
┌─────────────────────────┐
│    tmux pane (pty)       │
└──────────┬──────────────┘
           │
    ┌──────┴──────┐
    │             │
    ▼             ▼
[pipe-pane]   [control mode -C]
 (tmux-rec)    (ClaudeSpy)
    │             │
    │         ┌───┴────────────┐
    │         │                │
    │    Initial Capture   Live Stream
    │    (capture-pane     (%output events)
    │     + heavy filter)
    │         │                │
    │         ▼                ▼
    │    filterToColorCodesOnly  unescapeOutputBytes
    │    (strips ALL non-SGR)    + filterTmuxEscapeSequences
    │         │                  (only strips ESC k...ESC \)
    │         └───────┬────────┘
    │                 │
    │          SwiftTerm.feed(byteArray:)
    │                 │
    ▼                 ▼
 ✅ Correct       ❌ Garbled
```

## Key Difference: `pipe-pane` vs Control Mode

| Aspect | tmux-rec (pipe-pane) | ClaudeSpy (control mode) |
|--------|---------------------|--------------------------|
| **Initial state** | `capture-pane -e -p` → raw bytes, ALL escapes | `capture-pane -e -p` → **filtered**: only SGR (colors) kept |
| **Live data** | Raw PTY bytes (every byte) | `%output` events (octal-escaped, newline-delimited) |
| **Cursor positioning** | `\e[5A`, `\e[10C`, `\r` all preserved | Preserved in `%output`, **stripped from initial capture** |
| **Private modes** | `\e[?2026h/l` etc. preserved | Preserved in `%output`, **stripped from initial capture** |
| **Screen clearing** | `\e[2J`, `\e[K` preserved | Preserved in `%output`, **stripped from initial capture** |

---

## Hypotheses

### H1: `filterToColorCodesOnly` in Initial Capture Strips Critical Escape Sequences

**Likelihood: HIGH**

The function `filterToColorCodesOnly` (TmuxService.swift:394-434) keeps ONLY CSI sequences ending with `m` (SGR for colors/styles). It **strips**:
- Cursor positioning (`\e[H`, `\e[A`, `\e[B`, `\e[C`, `\e[D`, `\e[f`)
- Line/screen clearing (`\e[J`, `\e[K`)
- Scrolling (`\e[S`, `\e[T`)
- Private mode set/reset (`\e[?...h`, `\e[?...l`)
- Any non-CSI escape sequences (like `\e(B` for charset selection)

**Why this matters:** The visible area capture (Part 2) also passes through `filterToColorCodesOnly` (line 373). This means if the visible screen captured by `capture-pane -e -p` contains embedded cursor positioning or other non-SGR codes, they are silently removed. The content is then output sequentially line by line, which **assumes each line is self-contained text + colors**, but tmux's `capture-pane -e` output may include inline positioning within lines.

**How it could cause garbled output:** If the initial screen state is rendered incorrectly (text in wrong positions, incomplete color state), then all subsequent `%output` updates build on top of a corrupted base. The live stream applies cursor moves relative to wrong positions, compounding the error.

**Test:** Compare `capture-pane -e -p` raw output with what `filterToColorCodesOnly` produces. Check if any non-SGR sequences are semantically meaningful for correct rendering.

---

### H2: Non-CSI Escape Sequences Silently Dropped

**Likelihood: HIGH**

The `filterToColorCodesOnly` function (line 422-426) handles non-CSI escapes:
```swift
} else {
    // Non-CSI escape sequence, skip
    i = input.index(after: i)
}
```

This skips the ESC byte and moves on, but the **next byte** (which is part of the escape sequence) is treated as regular text and **appended to the output**. For example:
- `\e(B` (Select ASCII charset) → ESC is skipped, `(` is output as literal text, then `B` is output as literal text
- `\e)0` (Select VT100 graphics charset) → ESC skipped, `)` and `0` output as literal characters

This is a **bug**: non-CSI sequences should skip the **entire** sequence (ESC + type byte + optional params), not just the ESC byte.

**How it could cause garbled output:** Stray characters like `(`, `B`, `)`, `0` appearing in the output would shift all subsequent text positions.

---

### H3: Dimension Mismatch Between Capture Terminal and Mirror Terminal

**Likelihood: MEDIUM-HIGH**

The initial capture is done with `capture-pane -e -p` which captures based on the **tmux pane's dimensions** (e.g., 202×68 from the recording). The mirror terminal may have a **different number of rows** (rows are calculated dynamically from the container height in `recalculateRowsAndResize`).

The code attempts to handle this (lines 335-387) by:
1. Not using explicit row positioning for visible lines
2. Outputting lines sequentially with `\r\n`
3. Calculating `lastMeaningfulLine` to avoid trailing empties

**But:** If the mirror has fewer rows, the content scrolls differently. The cursor position `\e[Y;XH` at line 387 is calculated from the tmux pane's row, not the mirror's. If lines were scrolled off due to size mismatch, the cursor ends up at a wrong position.

**How it could cause garbled output:** With the cursor at a wrong row after initial state, subsequent `%output` data that uses relative cursor movements (like `\e[5A` = cursor up 5) moves relative to the wrong starting point.

---

### H4: `capture-pane -e -p` Output Format Assumptions Are Wrong

**Likelihood: MEDIUM**

The initial capture processes `capture-pane` output by splitting on `\n`:
```swift
visibleContent.split(separator: "\n", omittingEmptySubsequences: false)
```

**Assumptions:**
1. Each `\n`-separated segment corresponds to one terminal row
2. Lines contain only text + SGR codes (after filtering)
3. Lines are independent (no cross-line escape sequences)

**Potential issues:**
- `capture-pane -e -p` may output `\r\n` (CR+LF) line endings — the code handles this for scrollback (line 315-316) but not explicitly for visible content
- Wide characters (CJK, emoji) in `capture-pane` output may span differently than expected
- If a line contains a newline character within escape sequence parameters, the split creates incorrect segments

---

### H5: Timing/Ordering Issues Between Initial State and Live Stream

**Likelihood: MEDIUM**

The code captures initial state and then registers for live updates:
```swift
// PaneStream.connect()
let initialContent = try await tmuxService.capturePaneWithScrollbackForStreaming(target)
try await controlClientManager.registerPane(...) { data in self?.onData?(data) }
return initialContent
```

There's a potential gap:
1. Initial content is captured at time T1
2. Control mode registration happens at time T2 > T1
3. Any terminal output between T1 and T2 is **lost**

For fast-updating terminals like Claude Code (which frequently redraws), this gap could mean:
- SGR state changes between T1 and T2 are missed (wrong colors going forward)
- Cursor position changes are missed (text at wrong positions)

**How it could cause garbled output:** If Claude Code redraws part of the screen between capture and stream start, the mirror has an inconsistent state: initial capture shows one thing, but the stream continues from a different point.

---

### H6: Control Mode `%output` Octal Unescaping Loses or Corrupts Data

**Likelihood: MEDIUM**

The `unescapeOutputBytes` function (TmuxControlClient.swift:387-438) handles tmux's octal escaping. Control mode represents non-printable bytes as `\xxx` (octal).

**Potential issues:**
- The function handles `\\` (escaped backslash) and octal `\NNN`, but what about other escape characters like `\n`, `\r`, `\t`? tmux control mode may use these.
- If tmux outputs a literal backslash followed by digits that happen to look like an octal code, the function may misinterpret it.
- The function checks for octal digits `0-7` but reads up to 3 digits. If tmux uses `\0` (single octal digit), it may not be handled correctly depending on what follows.

**Test:** Create a test case with known byte sequences, run through `unescapeOutputBytes`, verify output.

---

### H7: Private Mode Sequences (`\e[?...h/l`) Affecting Terminal State

**Likelihood: MEDIUM**

The live `%output` stream preserves private mode sequences like:
- `\e[?2026h` — synchronized output (begin)
- `\e[?2026l` — synchronized output (end)
- `\e[?25h/l` — cursor visibility
- `\e[?1049h/l` — alternate screen buffer
- `\e[?7h/l` — auto-wrap mode

These are **correctly passed through** in the live stream. But:

1. **SwiftTerm may not support all of them** — if SwiftTerm doesn't handle `?2026` (synchronized output), it could cause rendering issues where partial screen updates are visible
2. **Initial state doesn't set up private mode state** — after the initial capture, the terminal's private mode flags are at defaults, not matching the tmux pane's actual state

**How it could cause garbled output:** If the real tmux pane has auto-wrap disabled (`\e[?7l`) but the mirror starts with auto-wrap enabled, text that should stay on one line wraps to the next, displacing everything below.

---

### H8: SwiftTerm Terminal Size vs Tmux Pane Size Discrepancy

**Likelihood: MEDIUM**

The mirror terminal's rows are calculated dynamically:
```swift
// TerminalContainerView.swift:354
let newRows = max(1, Int(containerSize.height / cellHeight))
```

But columns come from tmux:
```swift
// TerminalContainerView.swift:276
terminalView.getTerminal().resize(cols: columns, rows: rows)
```

**Issue:** The SwiftTerm terminal buffer has `rows` rows, but the tmux pane has `height` rows. If `rows != height`:
- Cursor positioning sequences from `%output` (e.g., `\e[68;1H` for row 68) may exceed the mirror's row count
- SwiftTerm may clamp or ignore out-of-bounds positions
- Relative cursor moves (`\e[5A`) may wrap or stop at different boundaries

**Critical:** The recording shows dimensions 202×68. If the mirror window is smaller (fewer rows), the entire bottom portion of the screen is unreachable.

---

### H9: `filterToColorCodesOnly` on Visible Area Breaks Hyperlink/URL Sequences

**Likelihood: LOW-MEDIUM**

Modern terminal applications (like Claude Code) may emit OSC sequences for hyperlinks:
- `\e]8;;URL\e\\text\e]8;;\e\\` — hyperlink
- `\e]0;title\e\\` — set window title
- `\e]52;c;data\e\\` — clipboard operation

These are OSC (Operating System Command) sequences, not CSI. The `filterToColorCodesOnly` function doesn't handle them at all — it would skip the ESC, then output the `]` as literal text, corrupting the line.

**How it could cause garbled output:** Literal `]`, `8`, `;;`, URL text appearing as visible content would shift subsequent text positions.

---

### H10: UTF-8 Boundary Issues in Initial Capture's String Processing

**Likelihood: LOW-MEDIUM**

The initial capture processes content as Swift `String` (via `stdoutString`), which is valid UTF-8. But `capture-pane -e -p` may output bytes that form incomplete or unusual character sequences when escape codes are interspersed.

The `filterToColorCodesOnly` function iterates character-by-character through a Swift String. If `capture-pane` output contains raw bytes that Swift interprets as multi-byte characters spanning across escape sequence boundaries, the function could:
- Miss escape sequence starts (if ESC is consumed as part of a multi-byte char)
- Produce incorrect output

**Likelihood is lower** because `capture-pane -p` should output valid UTF-8.

---

### H11: Line Splitting with `omittingEmptySubsequences: false` Produces Extra Lines

**Likelihood: LOW-MEDIUM**

```swift
let visibleLines = visibleContent
    .split(separator: "\n", omittingEmptySubsequences: false)
    .map(String.init)
```

If `capture-pane` output ends with `\n` (which is trimmed on line 342-344) and there's content like `\n\n` mid-output, the split creates empty strings. These empty lines are output to the terminal:
```swift
output += "\u{1b}[2K" // Clear current line
output += filterToColorCodesOnly(line) // empty string
if index < linesToOutput - 1 {
    output += "\r\n"
}
```

This correctly outputs a cleared empty line, but the `lastMeaningfulLine` calculation (lines 353-362) might include or exclude lines incorrectly, especially around blank lines near the cursor position.

---

### H12: SGR State Carryover Between Lines

**Likelihood: MEDIUM**

Each scrollback line gets an explicit `\e[0m` reset before and after:
```swift
output += "\u{1b}[0m" + filtered + "\u{1b}[0m\r\n"
```

But the **visible area lines do NOT get resets**:
```swift
output += "\u{1b}[2K" + filterToColorCodesOnly(line)
```

If one visible line's SGR state carries over to the next line differently than `capture-pane` intended, colors could be wrong. The `capture-pane -e` output includes SGR codes within each line, but there's no guarantee each line starts with a reset. If `filterToColorCodesOnly` drops a non-SGR sequence that was interleaved with SGR codes, the resulting SGR state machine could be in a different state than intended.

**Example scenario:**
- tmux outputs: `\e[31m` (red) `\e[1A` (cursor up) `\e[32m` (green) text
- After filter: `\e[31m` `\e[32m` text
- The cursor-up was supposed to move to a different line before applying green, but without it, green applies to the current line

---

### H13: `\e[2K` (Clear Line) Before Content May Fight With SwiftTerm's Buffer State

**Likelihood: LOW**

The visible area rendering clears each line before writing:
```swift
output += "\u{1b}[2K" // Clear current line
output += filterToColorCodesOnly(line)
```

SwiftTerm processes `\e[2K` by clearing the entire current row. If the terminal's current cursor column isn't at position 0, the clearing happens but subsequent text still starts at the current cursor position (not column 0). The code doesn't explicitly move to column 0 before the content.

Wait — actually `\r\n` at the end of the previous line moves to column 0 of the next line. And the first line starts after `\e[H` which positions at (1,1). So column 0 should be correct. This is likely **not** an issue.

---

### H14: Race Condition in `readabilityHandler` → `processIncomingData`

**Likelihood: LOW-MEDIUM**

```swift
handle.readabilityHandler = { [weak self] handle in
    let data = handle.availableData
    guard !data.isEmpty else { return }
    Task { [weak self] in
        await self?.processIncomingData(data)
    }
}
```

`readabilityHandler` fires on a background thread, then dispatches to the actor's serial queue via `Task`. But multiple `readabilityHandler` calls can create multiple `Task`s that are enqueued **in order** but potentially processed with interleaving if the actor is busy.

Actually, since `TmuxControlClient` is an `actor`, `processIncomingData` calls are serialized. But `readabilityHandler` could fire rapidly, and the `Data` reads might lose atomicity — if the handler fires between `handle.availableData` calls of two concurrent handlers, data could be split at arbitrary boundaries.

The byte-level buffering (`byteBuffer`) handles this correctly for line-splitting, but it's worth verifying there's no reordering of tasks.

**Revised likelihood:** Low — actor serialization should handle this correctly.

---

### H15: The Batching Layer (TerminalStreamService) Introduces Ordering Issues for Remote Viewers

**Likelihood: MEDIUM (for iOS only)**

`TerminalStreamService` batches data with:
- 8KB max batch size
- 50ms interval timer

The batching is simple append + flush, which preserves ordering. **But:** dimension change messages are sent **outside** the batching pipeline:
```swift
private func handleDimensionChange(paneId: String, width: Int, height: Int) async {
    let message = TerminalStreamMessage.dimensionChange(...)
    await connectionManager.sendTerminalStreamToAll(message)
}
```

If a dimension change arrives between data chunks, the iOS side might receive:
1. Data chunk 1 (for old dimensions)
2. Dimension change
3. Data chunk 2 (for new dimensions)

But if chunk 1 contained data that was generated *after* the dimension change (buffered), the iOS side applies old-dimension data at old dimensions, then resizes, then applies new data. The data in chunk 1 may have been rendered for the new dimensions already.

**How it could cause garbled output:** On the iOS side, cursor positions in batch 1 could exceed the old-dimension bounds, causing wrapping or clamping.

**Note:** This doesn't explain macOS mirror issues (no batching there).

---

### H16: SwiftTerm's Handling of `\e[2K` Followed by SGR-Only Content

**Likelihood: LOW**

After `\e[2K` clears a line, the cursor remains at its current position. If `filterToColorCodesOnly` outputs SGR codes that change background color before text, the cleared line may show the background color filling from the cursor to end-of-line. This could cause color "bleeding" across lines.

---

### H17: tmux `capture-pane -e` Output Differs From PTY Stream

**Likelihood: HIGH (root cause contributor)**

This is a fundamental architectural concern. `capture-pane -e -p` generates a **reconstruction** of the screen, not a replay of the original bytes. It:
- Outputs text content with SGR codes to recreate the visual appearance
- May re-encode colors differently than the original application output
- Inserts its own escape sequences for formatting

Meanwhile, `pipe-pane` (tmux-rec) captures the **original PTY bytes** — exactly what the application wrote.

The `%output` control mode events also provide original PTY bytes (what the pane's program outputs). So after the initial capture:
- Initial state: tmux's reconstruction (may differ from original)
- Live stream: original program bytes

This mismatch means the initial state may set up SwiftTerm's internal state (colors, cursor, modes) differently than the live stream expects, causing compounding errors.

---

## Proposed Testing Strategy

### E2E Test Design

Create a test that:
1. Sets up a tmux session with known dimensions
2. Sends a complex terminal output sequence (with cursor positioning, colors, alternate screen, etc.)
3. Captures the pane via `capture-pane -e -p` (ground truth)
4. Connects ClaudeSpy's streaming pipeline
5. Feeds the initial capture + subsequent `%output` events to a SwiftTerm instance
6. Compares SwiftTerm's buffer content with ground truth

**Specific test cases:**
- Cursor up/down/left/right within a single `%output` chunk
- SGR codes interleaved with cursor positioning
- Private mode sequences (synchronized output, alternate screen)
- Rapid redraws that involve `\e[H` (home) + full screen rewrites
- Content with `\e[2J` (clear screen) followed by `\e[H` and new content

### Replay Test Using tmux-rec Recording

Use the existing `.tmrec` recording to:
1. Replay the raw bytes into a SwiftTerm instance (ground truth)
2. Separately, process the same bytes through the ClaudeSpy pipeline:
   - Pass initial snapshot through `capturePaneWithScrollbackForStreaming`'s processing
   - Pass incremental data through `unescapeOutputBytes` + `filterTmuxEscapeSequences`
3. Compare terminal buffer state at key timestamps
4. If buffers differ, identify exactly which processing step introduced the discrepancy

---

## Recommended Investigation Order

1. **H1 + H2** (initial capture filtering) — Highest impact, most likely root cause
2. **H17** (capture-pane vs PTY byte mismatch) — Architectural concern
3. **H5** (timing gap) — Could explain intermittent issues
4. **H3 + H8** (dimension mismatch) — Window sizing differences
5. **H7** (private mode state) — Terminal mode initialization
6. **H12** (SGR state carryover) — Color issues specifically
7. **H6** (octal unescaping) — Data corruption in live stream
8. **H9** (OSC sequences) — If Claude Code uses hyperlinks

## Quick Diagnostic Experiment

Before diving into code changes, a simple diagnostic:
1. Record the session with tmux-rec (already done)
2. At a point where garbling is visible, also run `tmux capture-pane -e -p` on the same pane
3. Feed ONLY the `capture-pane` output (unmodified) to a fresh SwiftTerm — does it look correct?
4. Feed the `capture-pane` output through `filterToColorCodesOnly` to SwiftTerm — does garbling appear?
5. If yes → H1/H2 confirmed
6. If no → the issue is in the live stream processing, focus on H5-H7

This would isolate whether the problem is in initial capture processing or live stream handling.

---

## Test Results (TerminalRenderingTests.swift + TmuxControlClientTests.swift)

69 tests across 19 suites. **All 69 passing** after fixes.

### All Tests Passing

| Hypothesis | Test | Status |
|-----------|------|--------|
| **H1** | 6 basic filter tests | Pass — `filterToColorCodesOnly` correctly preserves SGR, strips CSI cursor/erase/mode |
| **H2** | `nonCSIDoesNotLeakBytes` | Pass (was failing) — charset selection bytes no longer leak |
| **H2** | `vt100GraphicsCharsetDoesNotLeak` | Pass (was failing) — `\e)0` fully consumed |
| **H2** | `multipleNonCSIDontAccumulate` | Pass (was failing) — multiple non-CSI escapes handled correctly |
| **H9** | `oscDoesNotLeakContent` | Pass (was failing) — OSC payload no longer leaks as text |
| **H3/H8** | `absoluteCursorClampedToTerminalSize` | Pass (was failing) — cursor clamped to last row |
| **H3/H8** | `relativeCursorAfterClamping` | Pass (was failing) — relative movements consistent from clamped position |
| **H7** | `syncUpdatePattern` | Pass — synchronized output renders correctly |
| **H12** | `sgrStateLeaksBetweenLines` | Pass — visible area SGR carryover confirmed |
| **H17** | `sgrStatePreservedAfterCapture` | Pass (was failing) — SGR state restored after capture reconstruction |
| **Integration** | `inputAreaRedrawMatchingDimensions` | Pass — redraw correct when dimensions match |
| **Integration** | `inputAreaRedrawWithMismatch` | Pass (was failing) — redraw correct with clamped cursor |
| **Integration** | `fullScreenRedraw` | Pass — EraseDisplay + CursorHome works |
| **Integration** | `accumulatedCursorDrift` | Pass — 50 cycles of relative Up/Down stays correct |
| **Pipeline** | `filterThenLiveStream` | Pass — filter + live stream matches unfiltered for SGR-only content |

### Key Conclusions

1. **H2 was a definite bug** that corrupted output by leaking stray bytes from non-CSI escape sequences. **Fixed** by properly skipping charset selections (3 bytes) and standard non-CSI escapes (2 bytes).

2. **H3/H8 (dimension mismatch)** was the most likely root cause of the "garbling worsens over time" observation. When the mirror terminal has fewer rows than the tmux pane, cursor positions were unclamped, and all relative cursor movements operated from wrong positions. **Fixed** by clamping cursor to `min(cursorY, linesToOutput - 1)`.

3. **H9 (OSC leaks)** contributed to corruption — OSC title-setting sequences (`\e]0;Title\a`) leaked their content as literal text. **Fixed** by adding OSC sequence handling that consumes bytes until BEL or ST terminator.

4. **H17 (capture-pane vs raw SGR state)** explained color mismatches: the initial capture's `\e[0m` resets left SwiftTerm in a different SGR state than the live stream expected. **Fixed** by adding `extractActiveSGR` helper that walks visible lines to the cursor position and re-emits the active SGR code after cursor positioning.

5. **H12 (SGR carryover)** is a secondary color issue — visible area lines inherit SGR state from previous lines without explicit resets. Not yet addressed; may be mitigated by the H17 fix for the re-capture path.

---

## Resolution

### Fixes Applied (TmuxService.swift)

All production fixes are in `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/TmuxService.swift`.

#### H2: Non-CSI escape byte leaking → Fixed

The `else` branch in `filterToColorCodesOnly` only skipped the ESC byte, leaking the following byte(s) as literal text. Now properly handles:
- **Charset selections** (`ESC ( X`, `ESC ) X`, `ESC * X`, `ESC + X`) — skips 3 bytes
- **Standard non-CSI escapes** (`ESC X`) — skips 2 bytes

#### H9: OSC sequence leaking → Fixed

Added a new `else if input[nextIndex] == "]"` branch in `filterToColorCodesOnly` that consumes OSC sequences (`ESC ] ... BEL` or `ESC ] ... ESC \`) in their entirety. Handles both BEL and ST terminators, plus unterminated sequences.

#### H3/H8: Cursor position out of bounds → Fixed

In `capturePaneWithScrollbackForStreaming`, the cursor Y position is now clamped:
```swift
let effectiveCursorY = min(cursorY, linesToOutput - 1)
```
This prevents sending `\e[Y;XH` with Y beyond the output content, which previously caused relative cursor movements from live stream data to operate from wrong positions.

#### H17: SGR state lost after capture → Fixed

Added `extractActiveSGR(from:cursorX:cursorY:)` method that walks the unfiltered visible lines up to the cursor position, tracking SGR state changes. After cursor positioning in the capture output, the active SGR code is re-emitted. The method stops scanning at the cursor column to avoid processing trailing `\e[0m` resets that tmux appends per line.

#### H5: Timing gap between capture and stream → Fixed

Rewrote `PaneStream.connect()` to route capture commands through the control client's `sendCommand()` instead of subprocesses. Since commands and `%output` events are serialized in the same control mode stream, the capture results are precisely ordered relative to live data — no gap, no overlap.

Key changes across four files:
- **TmuxControlClient.swift**: Added per-pane buffering (`startPaneBuffering`/`stopPaneBuffering`) that silently discards `%output` events during capture, plus FIFO command queue and initial attach response skipping
- **TmuxControlClientManager.swift**: Pass-through methods for `sendCommand`, `startPaneBuffering`, `stopPaneBuffering`
- **TmuxService.swift**: Extracted `processCapturePaneForStreaming` as a pure method, added `capturePaneViaControlMode` that sends capture commands through control mode
- **PaneStream.swift**: New ordering: buffer → register → capture via control mode → unbuffer

#### Cursor off-by-one on re-attach → Fixed

Two bugs caused typed text to appear one row above the correct position after re-attaching to a Claude Code session:

**Bug 1: `capture-pane` trims trailing empty lines.** When the cursor sits on an empty row (common in Claude Code where the cursor is at the very bottom of the pane), the capture returns fewer lines than the pane height. The old code used `min(lastMeaningfulLine, visibleLines.count)` for `linesToOutput`, which clamped the cursor to the last captured line instead of the actual cursor row. **Fixed** by using `max(cursorY + 1, visibleLines.count)` and padding with blank `\e[2K` lines beyond the captured content.

**Bug 2: Mirror terminal rows derived from window height instead of tmux pane height.** The mirror's SwiftTerm terminal had rows calculated from the container's physical height (e.g., 24 rows in a small window), while the tmux pane had 37 rows. Absolute cursor positioning in live `%output` events (e.g., `\e[33;1H`) referenced row numbers that didn't exist in the smaller mirror, getting clamped to the wrong position. **Fixed** in `TerminalContainerView.swift` by locking mirror rows to the tmux pane height via `updateTerminalDimensions(cols:rows:)`. Also switched the initial capture to use relative cursor positioning (`\e[nA` + `\e[nG`) instead of absolute (`\e[Y;XH`).

#### H12: Multi-row background band loses its background on re-capture → Fixed (#578)

A Codex composer's full-width gray background band rendered correctly on first view but lost the background on its continuation rows after navigating away and back. `tmux capture-pane -e` (without `-N`) **trims trailing spaces**, so a multi-row band — drawn with the `\e[48;5;…m` setter on its first row only and carrying the bg across rows via tmux's cross-line SGR state — captured as a setter followed by *empty* continuation rows, byte-identical to genuinely-blank rows. `processCapturePaneForStreaming` rebuilt each row independently with an SGR reset between rows, so the continuation rows rendered black. (The first view is correct because the band is painted by the live byte stream; re-viewing rebuilds from `capture-pane`.)

**Fixed** by capturing the visible area with `-N` (preserve trailing spaces without `-J`'s wrapped-line joining) so continuation rows keep their real bg spaces, and restoring the SGR state carried into each rebuilt row (`accumulateSGRState`) so those spaces inherit the band's background. Empty rows skip the carry, so genuinely-default rows stay default and the #411 leak does not return. The old pad-to-width heuristic (PR #353/#413, issue #429) is removed — `-N` supplies the real trailing cells, so only genuine band rows are full-width. Proven by the `Composer Band Recapture` E2E scenario (full gray band with the fix; continuation rows black without it).

#### H12 follow-up: same fix extended to the scrollback capture → Fixed (#580)

The #578 fix above applied `-N` + cross-line SGR carry to the **visible-area** capture only; the **scrollback** capture was left on plain `-e` and Part 1 of `processCapturePaneForStreaming` still reset the SGR state per line. A multi-row background band that has *scrolled into history* therefore lost its background on its continuation rows in exactly the same way (band setter on the first row only, continuation rows captured as empty/short and rebuilt with a per-line reset).

**Fixed** by applying `-N` to the scrollback capture too (both `capturePaneWithScrollbackForStreaming` and `capturePaneViaControlMode`) and carrying the SGR state across scrollback rows in Part 1, mirroring Part 2. The one extra concern unique to scrollback is reflow permanence: the visible area is redrawn on the resize SIGWINCH, but scrollback is static history that is never redrawn, so a preserved full-width row of *default*-bg spaces would wrap into **permanent** blank continuation rows on a narrower resize (the #429 class, but permanent). `trimTrailingDefaultBackgroundSpaces` drops the now-preserved default-bg trailing spaces back off plain rows (keeping a band's non-default-bg spaces) so plain rows stay short and SwiftTerm's reflow trims their NULL tail. Proven by the `Scrollback Band Recapture` E2E scenario and unit tests `multiRowBackgroundBandSurvivesInScrollback` (band keeps its bg in the scrollback buffer) and `scrollbackNoBlankRowsAfterReflowNarrower` (no reflow blanks after a narrower resize).

### Test Results Update

69 tests across 19 suites. **All 69 passing** after fixes.

New tests added:
- Per-pane buffering state management (start/stop/cleanup)
- `processCapturePaneForStreaming` with nil scrollback, trailing newlines, cursor position
- Dimension mismatch: 37-row tmux output fed to 24-row SwiftTerm terminal
- Live typing and cursor-up movement after initial capture with cursor mid-screen
- Cursor beyond visible lines pads output to reach cursor row

### Remaining Issues

- **~~H12 (SGR carryover between visible lines)~~**: Resolved (#578, extended to scrollback in #580). The rebuild captures both the visible area and the scrollback with `-N` and restores the cross-line SGR state carried into each row, so multi-row background bands keep their background on continuation rows whether they are on screen or have scrolled into history. See the two H12 fix entries above.
- **Scrollback corruption after re-capture**: Documented in the E2E scenario (Phase 2). Re-capture replaces the mirror's accumulated scrollback with tmux's captured content, causing duplication/truncation/reordering. This is a separate architectural issue.
- **~~H6 (octal unescaping)~~**: No longer applicable — pipe-pane delivers raw bytes, no octal unescaping needed.
- **H7 (private modes)**: Not yet investigated with targeted tests. May contribute to edge cases.
- **~~Truecolor animation rendering artifacts (Test 16)~~**: Resolved by pipe-pane rewrite (PR #179). See section below for historical investigation.

---

## Investigation: Truecolor Animation Rendering Artifacts (Test 16)

> **RESOLVED (PR #179):** The pipe-pane rewrite eliminated these artifacts entirely. The root cause was the `%output` processing pipeline (octal unescaping, line-boundary splitting, per-callback `Task {}` reordering). By delivering raw PTY bytes via FIFO with AsyncStream ordering guarantees, all truecolor rendering artifacts were eliminated. A regression E2E test (`TruecolorRenderingScenario`) runs 5 gradient animation variants with 0.00% diff baselines.

### Problem Statement

Test 16 of `terminal-debug/term-stress.py` (Synchronized Output / Mode 2026) produces rendering artifacts in the ClaudeSpy mirror window:
- Gradient extends beyond the intended 50-column bounds
- Literal escape sequence parameters (e.g., `m`, `2;5H`) appear as visible text
- Colored blocks appear beyond the gradient area
- Artifacts appear in **both** "Without synchronized output" and "With synchronized output" sections
- Artifacts are intermittent — frequency varies, sometimes appearing on the first frame, sometimes after several

### Investigation Timeline

Three debugging sessions systematically eliminated suspects. Key finding: **the data pipeline is clean and SwiftTerm's buffer contains correct data, but rendering output is wrong.**

### Proven Facts

1. **Data pipeline delivers complete, well-formed frames.** Feed logging at the SwiftTerm boundary showed 158/160 feeds with complete truecolor frames (250 background sequences per animation frame), zero split escape sequences.

2. **SwiftTerm's terminal buffer is correct after feeding.** Buffer dumps performed immediately after `feed()` calls show the exact expected content — correct characters at correct positions with correct attributes.

3. **The issue is in SwiftTerm's draw/display pipeline or AppKit compositing.** Since buffer contents are correct but rendered output shows artifacts, the bug is between the terminal buffer and what appears on screen.

### What Was Tried and Eliminated

All fixes below were tested experimentally but **none resolved the artifacts**. They are documented here as eliminated causes — the code changes were not merged.

#### 1. TCP Read Splitting → Escape Sequence Fragmentation (IDENTIFIED, FIX DID NOT RESOLVE ARTIFACTS)

**Discovery:** The pipe's `readabilityHandler` delivers data in ~1024-byte chunks, each creating a separate `Task` on the `TmuxControlClient` actor. Animation frames are ~4,500 bytes (3-5 TCP reads), so a single frame's data arrives across multiple Tasks. Without coalescing, escape sequences get split at arbitrary 1024-byte boundaries.

**Evidence:** Feed logging showed ~70 out of 500 feeds with `STARTS_DIGIT!` flag — feeds beginning with digits like `4;50;41m` (middle of a CSI sequence). Many feeds were exactly 1024 bytes — the TCP read buffer size.

**Attempted fix:** Per-pane output accumulator in `TmuxControlClient` with generation counter + 2ms delay coalescing. Each `processIncomingData` increments a counter; a scheduled flush only fires if the counter hasn't changed after sleeping, ensuring all TCP reads from the same burst are coalesced into a single delivery.

**Result:** Effectively eliminated frame splitting (158/160 complete frames, zero `STARTS_DIGIT` entries). But **artifacts persisted**, proving TCP read splitting is not the sole cause. The coalescing approach is sound and worth implementing, but does not fix the rendering issue.

**Key insight on actor Task scheduling:** Swift actor task scheduling does NOT guarantee strict FIFO ordering between independently-created Tasks. A "flush" Task created by `processIncomingData` can execute BEFORE the next `processIncomingData` Task, even though the next TCP read was already queued by `readabilityHandler`. `Task.cancel()` based coalescing is unreliable because the flush Task may already be executing. The generation counter + delay approach is the only reliable method found.

#### 2. `needsLayout = true` After Every Feed (IDENTIFIED, FIX DID NOT RESOLVE ARTIFACTS)

**Discovery:** `InteractiveTerminalView` was calling `needsLayout = true` after every `feed()` call and in the `rangeChanged` delegate callback. This triggered `layout()` → `terminalView.frame.size.height = bounds.height` → unnecessary AppKit display invalidation, creating a layout cascade that interfered with SwiftTerm's incremental display updates.

**Attempted fix:**
- Changed `feed()` and `feedPreservingScroll()` to use `terminalView.needsDisplay = true` instead of `needsLayout = true`
- Changed `rangeChanged` delegate to no-op (was triggering layout cascade on every data update)
- Added guard in `layout()`: only assign `terminalView.frame.size.height` when it differs from `bounds.height`

**Result:** Cleaner display cycle, but **artifacts persisted**.

#### 3. Full-View `needsDisplay = true` (TESTED, DID NOT HELP)

Setting `terminalView.needsDisplay = true` after every feed should force a full-view redraw rather than SwiftTerm's partial dirty rect approach. **Artifacts persisted.**

#### 4. Synchronous `displayIfNeeded()` (TESTED, DID NOT HELP)

Calling `terminalView.displayIfNeeded()` immediately after `needsDisplay = true` forces an immediate synchronous draw, eliminating any timing issues between feed and display. **Artifacts persisted.** This proves the issue is NOT about AppKit display cycle timing or deferred rendering.

#### 5. Flush Per TCP Read (TESTED, MADE THINGS WORSE)

Removing the timer-based coalescing and flushing at the end of each `processIncomingData` call delivered each ~1024-byte TCP read as a separate feed to SwiftTerm. **Artifacts were worse** — more frequent and more severe.

#### 6. `feedPreservingScroll()` Scroll Position Restoration (TESTED, NOT THE CAUSE)

`feedPreservingScroll()` captures scroll position before feed and restores it after via `scroll(toPosition:)`. Hypothesis: this shifts `yDisp`, causing row position miscalculations in `drawTerminalContents`. Tested by bypassing to simple `feed()` path. **Artifacts appeared on first try.** Scroll preservation is NOT the cause.

### SwiftTerm Rendering Pipeline Analysis (macOS)

Deep analysis of SwiftTerm's macOS rendering path revealed several architectural details:

```
feed() → feedPrepare() → terminal.feed(buffer:) → feedFinish()
  → queuePendingDisplay()
    → DispatchQueue.main.asyncAfter(.now() + 1/60) [16.67ms]
      → updateDisplay()
        → terminal.getUpdateRange() → clearUpdateRange()
        → setNeedsDisplay(partialRegion)  ← PARTIAL dirty rect (macOS only)
          → drawTerminalContents()
            → firstRow = displayBuffer.yDisp + Int((boundsMaxY - dirtyRect.maxY) / cellHeight)
            → loop over dirty rows, build attributed strings, draw backgrounds, draw text
```

**Key differences between macOS and iOS:**
- **macOS:** `updateDisplay()` calculates a partial `CGRect` covering only changed rows → `setNeedsDisplay(region)`
- **iOS:** `updateDisplay()` uses `setNeedsDisplay(bounds)` — always full redraw
- **macOS:** `startDisplayUpdates()` / `suspendDisplayUpdates()` are no-ops
- **iOS:** These control CADisplayLink

**`drawTerminalContents` row calculation:**
```swift
firstRow = displayBuffer.yDisp + Int((boundsMaxY - dirtyRect.maxY) / cellHeight)
```
This derives which terminal buffer rows to draw from the dirty rect's pixel coordinates. If `cellHeight` has fractional components or the dirty rect doesn't align perfectly with cell boundaries, row selection could be off.

**`Terminal.resize()` interaction:**
- Calls `refresh(0, rows-1)` to mark all rows dirty
- Does NOT call `clearUpdateRange()` — so a resize during animation could accumulate update ranges from different dimension states

### Remaining Suspects (Not Yet Tested)

These are the areas NOT yet eliminated that could explain why artifacts persist despite clean data:

#### A. SwiftTerm's `drawTerminalContents()` rendering bug

The drawing function converts dirty rects to buffer row ranges using floating-point division. With truecolor animation producing rapid full-screen updates:
- Fractional `cellHeight` could cause row misalignment in `firstRow` calculation
- The `yDisp` offset (scroll position in buffer) combined with partial dirty rects could select wrong rows
- Background color fill pass and text drawing pass might use slightly different row calculations

#### B. AppKit layer compositing with `wantsLayer = true` / `masksToBounds = true`

`InteractiveTerminalView` sets `wantsLayer = true` and `layer?.masksToBounds = true`. The terminal view is wider than its container (e.g., 227 columns at full tmux width) and relies on clipping:
- Layer-backed views use different compositing paths than non-layer views
- `masksToBounds` clips the rendered content but doesn't prevent the terminal from drawing beyond bounds
- Rapid partial redraws of a view wider than its layer could cause compositing artifacts

#### C. Terminal view wider than container

The SwiftTerm TerminalView is sized to fit all columns (e.g., 227 columns), which is wider than the visible window. `InteractiveTerminalView` provides horizontal scrolling. The dirty rect calculations in `drawTerminalContents` may not account for the view being partially off-screen, causing incorrect row/column mapping when the view extends beyond the visible area.

#### D. External resize events during animation

`Terminal.resize()` calls `refresh(0, rows-1)` without clearing the update range. If a resize event arrives during animation (e.g., from `updateContainerSize`), it could accumulate dirty ranges from different dimension states, confusing the partial dirty rect calculation in `updateDisplay()`.

### Suggested Next Steps

1. **Test without InteractiveTerminalView wrapper**: Use SwiftTerm's `TerminalView` directly (no horizontal scrolling, no layer masking) to see if artifacts disappear. This isolates the wrapper/layer setup.

2. **Test with a smaller terminal size**: If the terminal is 80 columns (fits in window without scrolling), the wider-than-container scenario is eliminated.

3. **Test without `wantsLayer`/`masksToBounds`**: Remove layer backing on InteractiveTerminalView to test if AppKit compositing is the issue.

4. **Test with iOS-style full-bounds redraw**: Override SwiftTerm's macOS `updateDisplay` to use `setNeedsDisplay(bounds)` instead of partial regions, matching iOS behavior.

5. **Instrument `drawTerminalContents`**: Add logging to capture the `firstRow`/`lastRow` calculation from dirty rects and compare against expected rows for each frame.

### Diagnostic Techniques Used

These approaches were used during the investigation and can be re-created if needed:

- **Feed logging**: Logging every `feed()` call to `/tmp/claudespy-feeds.txt` with size, first/last bytes, truecolor BG count, bare CSI parameter detection, and starts-with-digit detection. Add to `TerminalContainerView.Coordinator.handleData`.
- **Frame capture**: Binary capture of all frames fed to SwiftTerm to `/tmp/claudespy-frames.bin` with 4-byte little-endian length prefix per frame. Enables offline replay and analysis.
- **Frame replay**: `terminal-debug/replay-frames.py` replays captured binary frames in a real terminal for visual comparison against the mirror window.
- **Buffer dump**: Direct SwiftTerm buffer content extraction immediately after `feed()` calls, comparing buffer state against expected content. Confirms whether data reaches the terminal buffer correctly.
