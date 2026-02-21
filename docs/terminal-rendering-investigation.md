# Terminal Rendering Investigation: Garbled Output in ClaudeSpy Mirror

## Problem Statement

When mirroring complex terminal applications (like Claude Code) that use extensive cursor positioning, the ClaudeSpy mirror window shows:
1. **Mispositioned text** — content appears at wrong row/column locations
2. **Incorrect colors** — some text displays with wrong SGR attributes

The issue is reproducible. A tmux-rec recording of the same session replayed via raw PTY bytes renders **correctly**, proving the data from tmux is fine but ClaudeSpy's processing introduces the problem.

## Evidence

- `terminal-debug/garbled.png` — screenshot from the ClaudeSpy mirror (text displaced, colors wrong)
- `terminal-debug/correct.png` — screenshot from tmux-rec replay of the same session (correct rendering)
- Both show the same tmux session at roughly the same point in time
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

## Test Results (TerminalRenderingTests.swift)

20 tests across 10 suites. **7 currently failing** — all assert correct (fixed) behavior.
Tests will pass once the corresponding bugs are fixed.

### Failing Tests (assert correct behavior — will pass after fix)

| Hypothesis | Test | Expected (correct) | Actual (buggy) |
|-----------|------|---------------------|-----------------|
| **H2** | `nonCSIDoesNotLeakBytes` | `BeforeAfter` | `Before(BAfter` — `\e(B` leaks `(B` as literal text |
| **H2** | `vt100GraphicsCharsetDoesNotLeak` | `BeforeAfter` | `Before)0After` — `\e)0` leaks `)0` |
| **H2** | `multipleNonCSIDontAccumulate` | `AZ` | `A(B)0(AZ` — multiple non-CSI escapes accumulate leaked bytes |
| **H9** | `oscDoesNotLeakContent` | No leaked text | `]0;Title` appears as literal text |
| **H3/H8** | `relativeCursorMovementsCorrectRegardlessOfMismatch` | Marker at row 54 | Marker at row 31 — cursor clamping |
| **H3/H8** | `inputAreaRedrawWithMismatchedDimensions` | Marker at row 54 | Marker at row 31 — same clamping |
| **H17** | `capturePreservesSGRStateForLiveStream` | Capture color matches raw color | Capture resets to `.defaultColor` via `\e[0m` |

### Passing Tests (verified correct behavior)

| Hypothesis | Test | Details |
|-----------|------|---------|
| **H1** | 6 basic filter tests | `filterToColorCodesOnly` correctly preserves SGR, strips CSI cursor/erase/mode |
| **H7** | `syncUpdatePattern` | Synchronized output pattern renders correctly in SwiftTerm |
| **H12** | `sgrStateLeaksBetweenLines` | Visible area SGR state carries across lines (no resets) — confirmed |
| **Integration** | `inputAreaRedrawMatchingDimensions` | Redraw works correctly when dimensions match |
| **Integration** | `fullScreenRedraw` | EraseDisplay + CursorHome works (full redraws are fine) |
| **Integration** | `accumulatedCursorDrift` | 50 cycles of relative Up/Down stays correct (no drift from math errors) |
| **Pipeline** | `filterThenLiveStream` | Filter + live stream matches unfiltered when content is SGR-only |

### Key Conclusions

1. **H2 is a definite bug** that corrupts output by leaking stray bytes from non-CSI escape sequences. This is the easiest fix (skip the full escape sequence, not just the ESC byte).

2. **H3/H8 (dimension mismatch)** is the most likely root cause of the "garbling worsens over time" observation. When the mirror terminal has fewer rows than the tmux pane, cursor positions are clamped, and ALL relative cursor movements (which Claude Code uses exclusively) operate from wrong positions. This compounds with every update cycle.

3. **H9 (OSC leaks)** contributes to corruption — OSC title-setting sequences (`\e]0;Title\a`) leak their content as literal text via the same H2 mechanism.

4. **H17 (capture-pane vs raw SGR state)** explains color mismatches: the initial capture's `\e[0m` resets leave SwiftTerm in a different SGR state than the live stream expects.

5. **H12 (SGR carryover)** is a secondary color issue — visible area lines inherit SGR state from previous lines without explicit resets.

### Recommended Fix Priority

1. **H2**: Fix `filterToColorCodesOnly` to skip full non-CSI escape sequences (ESC + following byte(s))
2. **H9**: Add OSC sequence handling to `filterToColorCodesOnly` (skip ESC ] ... BEL/ST)
3. **H3/H8**: Ensure mirror terminal rows match tmux pane rows, OR adjust cursor positioning in initial capture
4. **H17**: Preserve SGR state from capture-pane without adding resets (or restore SGR after initial state)
5. **H12**: Add explicit `\e[0m` resets between visible area lines (matching scrollback behavior)
