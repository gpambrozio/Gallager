# Terminal Rendering Investigation

## Problem

When the macOS mirror connects to a tmux pane running Claude Code, the rendered
output shows garbled text. The tmux pane itself renders correctly — the issue is
only in the SwiftTerm mirror.

The garbling manifests as text at wrong positions, leftover rendering artifacts
(e.g., menu remnants from Claude Code's Ink-based `/plugin` menu), and visual
corruption in the mirrored terminal.

## Architecture: How Mirroring Works

1. **Connect**: `PaneStream.connect()` captures a rendered snapshot of the pane
   via `capture-pane -p -e` (visible area + scrollback with ANSI colors)
2. **Register**: Registers with `TmuxControlClient` for `%output` events (raw
   terminal bytes from the pane's program)
3. **Feed**: The snapshot is fed to SwiftTerm as initial content
4. **Stream**: Live `%output` events are fed to SwiftTerm incrementally

## Root Cause: Two Incompatible Data Representations

The fundamental issue is that steps 1 and 2 produce **different data formats**:

- **`capture-pane -p -e`** produces **rendered text** — what's visible on screen,
  with ANSI color codes. This is a lossy representation: it preserves text and
  colors but loses terminal state (cursor position, saved cursor, scroll region,
  character set, origin mode, alternate screen buffer, wrap mode, tab stops, etc.)

- **`%output` events** deliver **raw terminal bytes** — the exact VT100/xterm byte
  stream that the program wrote. These bytes include relative cursor movements
  (`CSI nA` = up, `CSI nC` = right), scroll region changes, character set
  switches, and other state-dependent operations.

When we feed the rendered snapshot to SwiftTerm, its internal terminal state
doesn't match tmux's internal terminal state. Then when raw `%output` bytes arrive
(which assume tmux's state), they produce incorrect rendering in SwiftTerm.

For example:
- tmux may have a saved cursor position (DECSC) that SwiftTerm doesn't
- tmux may have a scroll region set (DECSTBM) that SwiftTerm doesn't
- tmux may be in alternate screen buffer mode that SwiftTerm isn't
- The cursor position after processing the snapshot may differ from tmux's cursor

## What's Been Tried

### 1. Removed UTF-8 Splitting (KEPT)

**File**: `TmuxControlClient.parseOutputNotificationBytes()`

Previously, the code tried to split incomplete UTF-8 trailing bytes and buffer
them. This was removed because multi-byte UTF-8 sequences (0x80-0xBF, 0xC0-0xF7)
overlap with ANSI CSI parameter bytes. Splitting on a UTF-8 boundary could bisect
a CSI escape sequence, causing cursor-positioning or color-clearing codes to be
silently dropped. SwiftTerm handles partial UTF-8 natively at the byte level.

**Result**: Valid fix, kept. Prevents escape sequence bisection.

### 2. Locked Terminal Rows to Pane Height (KEPT)

**File**: `TerminalContainerView.Coordinator.paneRows`

Added `paneRows` property that locks the SwiftTerm terminal rows to the tmux
pane's row count. Without this, the mirror window might have a different row count
than the tmux pane, causing cursor positioning (CSI row;col H) to target wrong rows.

**Result**: Valid fix, kept. Ensures terminal grid matches pane.

### 3. One-Time Resync via Re-capture (REPLACED)

**File**: `TerminalContainerView.Coordinator.performResync()`

After initial data burst settles (500ms debounce), re-captures the terminal state
from tmux via `capturePaneWithScrollbackForStreaming` and refeeds it to SwiftTerm.

**Result**: E2E test passes (recording replay renders cleanly after resync), but
real-world use with live Claude Code still garbles. Reasons:

- **Data loss during async capture**: While the resync capture is running (async
  tmux commands), `%output` events continue arriving and being processed. When the
  capture completes and we clear + refeed, we lose the `%output` data that arrived
  during the capture.

- **Same fundamental problem**: The resync uses `capture-pane` which produces
  rendered text, not terminal state. After the resync, the terminal state mismatch
  still exists.

- **Timing issues**: With live Claude Code, 500ms debounce may fire during a brief
  rendering pause. Claude Code continues rendering after resync, re-introducing
  divergence.

### 4. Re-capture with Max-Delay Cap + Data Discarding (REPLACED)

Added a max-delay cap (3 seconds) alongside the debounce so the resync fires even
during continuous data flow. Also added an `isResyncing` flag to discard incoming
`%output` data during the capture to prevent data loss gap.

**Result**: Still garbled in real-world use. The fundamental capture-pane state
mismatch remains — discarding data during capture doesn't help when the capture
itself produces incompatible data.

### 5. Force Re-render via Pane Resize (CURRENT)

**File**: `TmuxService.forceRedrawViaResize()`,
`TerminalContainerView.Coordinator.performResync()`

Instead of re-capturing terminal state, forces the running program to do a full
re-render by briefly resizing the tmux window. Uses `resize-window -x (width-1)`
then `resize-window -x width` with a 50ms pause between. This triggers SIGWINCH,
causing TUI programs (including Claude Code's Ink renderer) to re-render their
entire UI via `%output` events.

Uses dual-timer scheduling:
- **Debounce** (200ms): Fires when data pauses, handles burst-then-quiet patterns
- **Max-delay cap** (1s): Fires regardless, handles continuous data flow

No screen clear needed — the program's re-render overwrites everything with
correct content.

**Result**: Under testing. The approach is sound in theory — the visible area is
rebuilt entirely from `%output` bytes, which SwiftTerm processes natively. However,
the E2E test can't validate this because recording replay uses `cat` + `tail -f`
which don't respond to SIGWINCH.

### 6. Diagnostic Logging (REMOVED)

Added temporary `DiagLog` class writing to `/tmp/claudespy-diag.log` to trace data
flow through `TmuxControlClient.deliverOutput` and
`TerminalContainerView.handleData`.

**Findings**:
- All data is delivered intact (~374KB in ~250 chunks for the recording)
- Terminal dimensions are correct (202x68) throughout
- No `%layout-change` events during `respawn-pane -k`
- No data loss or handler removal during replay

## Theories Investigated and Ruled Out

### capture-pane -C (RULED OUT)

`capture-pane` with the `-C` flag was theorized to output escape sequences instead
of text, producing data closer to a raw terminal byte stream. Testing showed that
`-C` actually **strips** escape codes rather than adding them — it produces even
less state information than `-p -e`. Not useful for our purpose.

### Alternate Screen Buffer (RULED OUT)

Checked whether Claude Code uses alternate screen buffer mode (which would explain
state mismatches). Queried `tmux display -p -t %0 '#{alternate_on}'` and got `0` —
Claude Code does NOT use alternate screen buffer. Ruled out as a contributing
factor.

## Remaining Theories

### Terminal State Reset Sequences

After feeding the capture, send explicit escape sequences to reset terminal state
to a known baseline before `%output` events arrive:
- `ESC[r` (reset scroll region to full screen)
- `ESC[?6l` (reset origin mode)
- `ESC[?7h` (enable auto-wrap)
- `ESC[?25h` (show cursor)
- `ESC(B` (reset character set to ASCII)

**Risk**: May not cover all state differences. State might need to match tmux
exactly, not just be "reset".

### Hybrid Approach (Scrollback Capture + Force Re-render)

Combine scrollback capture with forced re-render:
1. Capture scrollback only (`capture-pane -p -e -S -N -E -1`)
2. Feed scrollback to SwiftTerm (goes into scrollback buffer)
3. Register for `%output`
4. Force program re-render (resize or SIGWINCH)
5. `%output` events build the visible area from scratch

This avoids mixing capture-pane visible content with `%output` entirely.

**Advantage**: Eliminates the fundamental data representation mismatch for the
visible area while preserving scrollback history.

## E2E Test Limitation

The current E2E recording replay test uses `cat recording.data; tail -f /dev/null`
to replay captured terminal data. This tests the data pipeline but cannot validate
the force-redraw approach because `tail` doesn't respond to SIGWINCH. Real-world
validation requires testing with a live Claude Code session.

## Recommended Next Step

If the force-redraw via resize (approach #5) doesn't resolve the issue with live
Claude Code, the **Hybrid Approach** is the most promising next step because it
eliminates the fundamental data representation mismatch for the visible area while
preserving scrollback history. The scrollback is static historical content so
capture-pane works fine for it. The visible area is built entirely from `%output`
which SwiftTerm processes natively.
