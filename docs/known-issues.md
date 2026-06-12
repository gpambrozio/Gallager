# Known Issues

## ~~When a tmux window is resized it doesn't resize the mirror and the contents get messed up.~~ FIXED

**Status:** Fixed

**Solution Implemented:**
- Leverages the existing 5-second pane refresh in `MainView` (no additional polling)
- `MirrorWindowView` observes `tmuxService.panes` changes and checks if its pane's dimensions changed
- `PaneStreamManager.updateDimensions(paneId:width:height:)` updates the per-pane reader context and forwards an `onDimensionChange` callback to subscribers when dimensions differ
- `MirrorWindowManager.resizeWindow()` updates the NSWindow size with animation

**Files Changed:**
- `ClaudeSpyServerFeature/Services/PaneStreamManager.swift` - Owns dimension state on `ReaderContext` and forwards changes to subscribers
- `ClaudeSpyServerFeature/Views/MirrorWindowView.swift` - Added `.onChange(of: tmuxService.panes)` observer
- `ClaudeSpyServerFeature/Managers/MirrorWindowManager.swift` - Added `resizeWindow()` method

## ~~Available Panes window sometimes appears twice.~~ FIXED

**Status:** Fixed

**Solution Implemented:**
- Disabled macOS automatic window restoration via `NSQuitAlwaysKeepsWindows` UserDefaults key
- Set in `TmuxPaneMirrorApp.init()` before any windows are created

**Files Changed:**
- `ClaudeSpyServer/ClaudeSpyServerApp.swift` - Added window restoration disable in init

## DEC Line Drawing Characters Display Incorrectly When Mirroring Already-Running Applications

### Description

When mirroring a tmux pane that is already running an application using DEC Line Drawing mode (such as btop, htop, or other TUI applications), box-drawing characters may display as ASCII letters (e.g., 'a', 'q', 'x') instead of the proper graphical characters.

This occurs because:
1. Applications like btop use DEC Special Graphics mode (`ESC(0`) where ASCII characters map to box-drawing glyphs
2. The `tmux capture-pane -e` command captures the current screen content with ANSI color codes
3. However, `capture-pane` does NOT capture the terminal's character set state (G0/G1 charset selection)
4. Without the `ESC(0` escape sequence, SwiftTerm displays the raw ASCII characters

### Workaround

Start the mirror **before** launching the TUI application. When the application starts fresh, it sends the charset-switching escape sequences through `pipe-pane`, and the mirror displays correctly.

### Attempted Solutions

1. **Terminal initialization sequences**: Tried sending `ESC%G` (UTF-8 mode), `ESC(B` (G0 ASCII), `ESC)0` (G1 DEC graphics) before feeding captured content. Did not resolve the issue since the captured content uses raw ASCII expecting DEC graphics mode.

2. **Skip capture-pane and force redraw**: Tried starting `pipe-pane` first, then sending `Ctrl+L` to force the application to redraw. This approach was unreliable - not all applications respond to Ctrl+L the same way, and there were timing issues.

3. **Different capture methods**: The core issue is that `capture-pane` converts terminal output to a normalized format that loses charset state information.

### Potential Future Solutions

1. **Parse and translate**: Detect ASCII characters in positions that should be box-drawing (based on surrounding ANSI codes) and translate them to Unicode equivalents.

2. **Send charset reset after capture**: After feeding captured content, send escape sequences to reset charset to a known state, then force a partial redraw of UI elements.

3. **Hybrid approach**: Use `capture-pane` for text content but send a resize signal to force applications to redraw their borders/UI elements.

> **Note:** Since PR #179, live data is delivered via `pipe-pane` raw bytes, which correctly carries charset-switching sequences (`ESC(0`/`ESC(B`). The remaining issue is only with the **initial capture** via `capture-pane -e`, which still loses charset state. Starting the mirror before the TUI application works because the charset sequences arrive through pipe-pane from the start.

### Technical Details

DEC Line Drawing character mappings (when `ESC(0` is active):
- `a` → `▒` (checker pattern)
- `j` → `┘` (bottom-right corner)
- `k` → `┐` (top-right corner)
- `l` → `┌` (top-left corner)
- `m` → `└` (bottom-left corner)
- `n` → `┼` (cross)
- `q` → `─` (horizontal line)
- `t` → `├` (left tee)
- `u` → `┤` (right tee)
- `v` → `┴` (bottom tee)
- `w` → `┬` (top tee)
- `x` → `│` (vertical line)

The raw bytes from `capture-pane` show these ASCII characters, but the terminal state needed to interpret them as graphics is not included.

## Emoji Characters May Slightly Overlap Adjacent Table Borders

### Description

When a terminal table contains emoji characters (e.g., 🔴, 🟢, 🟡), the emoji glyphs may visually overflow into adjacent cells, partially covering box-drawing border characters (`│`, `─`, etc.). The terminal buffer and character positions are correct — this is purely a visual rendering issue.

### Root Cause

Apple Color Emoji glyphs have a fixed advance width (~17pt at 13pt font) that exceeds the allocated terminal cell width (2 × ~7.83pt = ~15.65pt). SwiftTerm positions each glyph at the correct column but does not clip glyph rendering to cell boundaries. Since box-drawing characters are rendered before text glyphs, the emoji overwrites part of the adjacent border.

### Impact

- Table column borders may appear slightly shifted or partially hidden next to emoji
- The effect is ~1pt of overflow (about 13% of a cell width)
- The terminal buffer data is correct — only the visual rendering is affected
- Text-only content (no emoji) renders correctly

### Potential Future Solutions

1. **Upstream SwiftTerm fix**: Request cell-level clipping in `drawTerminalContents` or change render order (box-drawings after text)
2. **Upgrade SwiftTerm**: v1.11.2 adds regional indicator combining for flag emoji, though it doesn't fix the visual overflow
3. **Fork SwiftTerm**: Add per-cell clipping for wide characters in the rendering pipeline

## Ctrl-G editor override only applies to zsh and bash

### Description

ClaudeSpy points `$VISUAL` at the bundled `gallager edit` CLI so Ctrl-G in Claude Code / Codex opens the in-app prompt editor. Because spawned panes run a login shell that sources the user's rc files, a user who `export VISUAL=<their editor>` there would otherwise clobber our value (issue #589). The fix re-asserts `$VISUAL` *after* the rc files run by routing the shell's startup through a generated snippet (`ShellIntegration`): zsh via a Gallager `ZDOTDIR` + `precmd` hook, bash via `--rcfile`.

The snippets live under the durable `~/.gallager/state/shell-integration/` — not `$TMPDIR`, which macOS reaps after a few days of non-access — because their paths are baked into tmux's `default-command` for the app's whole lifetime. The pane launcher additionally checks the snippet is still readable at spawn time and otherwise falls back to a plain login shell, so the worst case is the original issue-#589 behavior (the user's rc override wins), never a shell that silently skips the user's own rc files.

### Impact

- For **zsh** and **bash** (the macOS default and the shells named in the issue) the in-app editor always wins, even when the user's rc exports its own `VISUAL`.
- For **other shells** (fish, nushell, …) we fall back to setting `VISUAL` via tmux `-e`. That value still survives *unless* the user's shell config overrides it — in which case Ctrl-G opens their editor instead of the in-app one.

### Potential Future Solutions

1. Add a fish snippet (e.g. via a `conf.d` drop-in on `XDG_DATA_DIRS`) and equivalents for other shells in `ShellIntegration`.

## ~~E2E on a fresh macOS 15+ machine: app hangs at startup ("app never fully started")~~ FIXED

**Status:** Fixed — the app no longer does a blocking local-network call at startup.

### Description

On a brand-new macOS 15+ machine, `./scripts/e2e-test.sh` failed every scenario at
its launch step with *"macOS app launched but its in-process test server never
responded… the app did not finish starting."* The original report was *"the system
was asking for an authorization and the app never fully started"* — i.e. the **app
itself hung during startup**, not a prompt floating over a running app.

### Root Cause

`PaneStreamManager.defaultPaneTitles` is a stored property (an immediately-evaluated
closure) that called `ProcessInfo.processInfo.hostName`. Per Apple's
[TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy),
resolving the machine's `.local` name is a **local-network DNS operation**, and on a
macOS 15+ machine that hasn't decided Local Network access it **blocks the calling
thread** until the user answers the prompt.

That property is evaluated synchronously on the **main thread** during
`AppCoordinator.init` (itself inside the SwiftUI `App.init`). Meanwhile
`TestAccessibilityServer.start` schedules its `NWListener` on `.main` via
`listener.start(queue: .main)`. So the sequence is: schedule the listener on the
main queue → keep running `init` synchronously → hit the blocking `.local`
resolution → the main thread is now stuck → the main queue never processes the
listener bind → the test server never responds → the orchestrator times out. The
app is launched via LaunchServices, so it doesn't inherit the automatic
local-network allowance TN3179 grants to CLI tools run from Terminal/SSH. Machines
that granted Local Network long ago never blocked, which is why it only bit fresh
ones.

### Fix

`defaultPaneTitles` now uses only `gethostname()` (a pure syscall — no DNS, no Local
Network), which is what tmux uses for the default `pane_title` anyway. The blocking
`ProcessInfo.hostName` call is removed. With no local-network operation at startup,
the prompt no longer appears on a fresh machine and the app starts normally.
(`ClaudeSpyServerFeature/Services/PaneStreamManager.swift`)

### Notes

- Local Network privacy **isn't TCC** (per TN3179): it can't be pre-granted via a
  PPPC/MDM profile or `tccutil`, and there's no reset short of a VM snapshot or a
  fresh user account. So the durable fix is to not perform the operation at all.
- An earlier attempt loopback-bound the `TestAccessibilityServer` listener, on the
  theory that *listening* triggered the prompt. TN3179 is explicit that listening
  for/accepting incoming connections does **not** require local network access — a
  no-op for this bug, reverted.
