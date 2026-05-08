"""
ctrl_v_listener.py — Detects a single Ctrl+V on stdin and exits.

Reads stdin with input processing fully disabled and prints `CTRL_V_RECEIVED`
on the first Ctrl+V byte (0x16). If no Ctrl+V arrives within IDLE_TIMEOUT
seconds it prints `NO_CTRL_V` instead, so a missing keystroke fails the
scenario in bounded time rather than hanging.

Why not `tty.setcbreak`: cbreak only clears `ICANON` and `ECHO`. The
terminal line discipline still applies `IEXTEN`'s VLNEXT (Ctrl+V =
literal-next) on macOS, which would swallow the very byte we want to
detect. We explicitly clear `IEXTEN` and `IXON` (Ctrl+S/Ctrl+Q flow
control) on the local + input flags so the byte reaches `os.read`.
`OPOST` and `ISIG` stay on so output formatting and Ctrl+C still work.

Used by the Image Paste Remote E2E scenario to verify that the host's
SendImage handler dispatches Ctrl+V into the target tmux pane after
writing the image to the host's pasteboard.
"""

import os
import select
import sys
import termios

IDLE_TIMEOUT = 10.0
CTRL_V = "\x16"
READY_MARKER = "LISTENER_READY"
HIT_MARKER = "CTRL_V_RECEIVED"
MISS_MARKER = "NO_CTRL_V"

STDIN_FD = sys.stdin.fileno()


def read_byte(timeout):
    ready, _, _ = select.select([STDIN_FD], [], [], timeout)
    if not ready:
        return None
    try:
        data = os.read(STDIN_FD, 1)
    except OSError:
        return None
    if not data:
        return None
    return data.decode("utf-8", errors="replace")


def configure_terminal(fd):
    """Disable line discipline features that would intercept Ctrl+V."""
    attrs = termios.tcgetattr(fd)
    # iflags: drop XON/XOFF flow control + CR→NL translation
    attrs[0] &= ~(termios.IXON | termios.ICRNL)
    # lflags: drop echo, canonical mode, and extended (VLNEXT) processing.
    # ISIG stays on so Ctrl+C still aborts the listener.
    attrs[3] &= ~(termios.ECHO | termios.ICANON | termios.IEXTEN)
    attrs[6][termios.VMIN] = 1
    attrs[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attrs)


def main():
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    received = False
    try:
        configure_terminal(fd)
        sys.stdout.write(READY_MARKER + "\n")
        sys.stdout.flush()

        while True:
            ch = read_byte(IDLE_TIMEOUT)
            if ch is None or ch == "\x03":
                break
            if ch == CTRL_V:
                received = True
                break
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
        sys.stdout.write("\n" + (HIT_MARKER if received else MISS_MARKER) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
