# Known Issues

## When a tmux window is resized it doesn't resize the mirror and the contents get messed up.

### Solution

We need to detect when a tmux session is resized and resize the terminal window on the mirror accordingly.

## Sparkle is not being removed when a claude session ends.

Neither the sparkle on the Avalilable Panes window go away or the window closes as expected when a claude session ends.

## Available Panes window sometimes appears twice.

Sometimes when starting the app the Available Panes window shows up twice.

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

1. **Use tmux control mode**: tmux's control mode (`tmux -C`) provides more detailed terminal state information that might include charset state.

2. **Parse and translate**: Detect ASCII characters in positions that should be box-drawing (based on surrounding ANSI codes) and translate them to Unicode equivalents.

3. **Send charset reset after capture**: After feeding captured content, send escape sequences to reset charset to a known state, then force a partial redraw of UI elements.

4. **Hybrid approach**: Use `capture-pane` for text content but send a resize signal to force applications to redraw their borders/UI elements.

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
