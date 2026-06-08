"""
link_block.py — Render an OSC 8 hyperlink as a large multi-line block.

A reusable E2E helper for scenarios that need to *click* a terminal hyperlink.
The link is painted as a big filled rectangle (ROWS x COLS of `OPEN-LINK-<n>`
tokens) wrapped in a single OSC 8 sequence, so a click anywhere inside the block
opens the link. A wide target tolerates the small content shifts that make
pixel-precise terminal clicks fragile — the tab-bar height changing (e.g. a new
tab icon) or the Panes window auto-growing after session creation both shift
terminal content by a few rows, which is enough to make a one-row-tall link
target miss.

Usage:
    link_block.py URL [URL ...]

The first URL is shown immediately. Each byte read from stdin advances to the
next URL in the list (wrapping), so one long-lived process can drive several
links: the scenario sends a key between clicks to change the link. `q` (or EOF
on stdin) exits cleanly.

The block is filled with `OPEN-LINK-<n>` (1-based index into the URL list), so a
scenario can wait on `macWaitForElementQuery(.valueContains("OPEN-LINK-<n>"))`
to confirm the requested link is on screen before clicking. The visible text
never contains the raw URL — only the (non-printing) OSC 8 escape carries it —
so a mis-aimed click can never scrape URL-looking text off the screen instead of
opening the intended target; it simply hits blank cells and the scenario's
"sheet appeared" / "tab opened" wait fails loudly.

Why a custom terminal config: cbreak/`ICANON` off plus `ECHO`/`IEXTEN`/`IXON`
off makes a single keystroke reach `os.read` immediately, without echoing into
the rendered block or being swallowed by line editing. `ISIG` stays on so Ctrl+C
still aborts.
"""

import os
import sys
import termios

ESC = "\x1b"
BEL = "\a"

# Block geometry. Large enough that a click near the terminal's upper-middle
# lands inside even after the content shifts down by a row or two; small enough
# to leave the URL list's index legible and fit a 30-row pane.
ROWS = 18
COLS = 72

CLEAR_HOME = f"{ESC}[2J{ESC}[H"
STDIN_FD = sys.stdin.fileno()


def configure_terminal(fd):
    """Deliver single keystrokes to os.read raw (no echo, no line editing)."""
    attrs = termios.tcgetattr(fd)
    attrs[0] &= ~(termios.IXON | termios.ICRNL)
    attrs[3] &= ~(termios.ECHO | termios.ICANON | termios.IEXTEN)
    attrs[6][termios.VMIN] = 1
    attrs[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attrs)


def render(index, url):
    """Clear the pane and paint the OSC 8 link as a ROWS x COLS filled block."""
    token = f"OPEN-LINK-{index + 1}-"
    line = (token * ((COLS // len(token)) + 1))[:COLS]
    parts = [CLEAR_HOME, f"{ESC}]8;;{url}{BEL}"]
    parts.extend(f"{line}\n" for _ in range(ROWS))
    parts.append(f"{ESC}]8;;{BEL}")
    sys.stdout.write("".join(parts))
    sys.stdout.flush()


def main():
    urls = sys.argv[1:]
    if not urls:
        sys.stderr.write("usage: link_block.py URL [URL ...]\n")
        return 2

    index = 0
    saved = termios.tcgetattr(STDIN_FD)
    try:
        configure_terminal(STDIN_FD)
        render(index, urls[index])
        while True:
            data = os.read(STDIN_FD, 1)
            if not data or data == b"q":
                break
            index = (index + 1) % len(urls)
            render(index, urls[index])
    finally:
        termios.tcsetattr(STDIN_FD, termios.TCSADRAIN, saved)
    return 0


if __name__ == "__main__":
    sys.exit(main())
