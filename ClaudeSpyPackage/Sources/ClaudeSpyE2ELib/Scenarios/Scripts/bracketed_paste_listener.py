"""
bracketed_paste_listener.py — Captures one bracketed-paste delivery and exits.

Enables DEC private mode 2004 (bracketed paste), waits for stdin to deliver
text wrapped in `ESC [ 200 ~ … ESC [ 201 ~`, prints `PASTED:<contents>` on
the first delivery, then disables the mode and exits. Used by the file-drop
E2E scenario to verify that `tmux paste-buffer -p` actually wraps the
paste in bracketed-paste markers when the in-pane app has opted in.

If no bracketed paste arrives within IDLE_TIMEOUT seconds it prints
`NO_PASTE` and exits, so a missing dispatch fails the scenario in bounded
time rather than hanging.

Why a custom reader: cbreak alone leaves IEXTEN's VLNEXT (Ctrl+V =
literal-next) on, which would swallow some bytes in the paste payload.
We clear `IEXTEN`, `IXON`, and `ICANON`/`ECHO` so the bytes reach
`os.read` exactly as tmux delivers them. `ISIG` stays on so Ctrl+C
still aborts.
"""

import os
import select
import sys
import termios

IDLE_TIMEOUT = 10.0

ENABLE_BRACKETED_PASTE = "\x1b[?2004h"
DISABLE_BRACKETED_PASTE = "\x1b[?2004l"

PASTE_START = "\x1b[200~"
PASTE_END = "\x1b[201~"

READY_MARKER = "BRACKETED_LISTENER_READY"
HIT_PREFIX = "PASTED:"
MISS_MARKER = "NO_PASTE"

STDIN_FD = sys.stdin.fileno()


def configure_terminal(fd):
    """Disable line discipline features that would intercept paste bytes."""
    attrs = termios.tcgetattr(fd)
    attrs[0] &= ~(termios.IXON | termios.ICRNL)
    attrs[3] &= ~(termios.ECHO | termios.ICANON | termios.IEXTEN)
    attrs[6][termios.VMIN] = 1
    attrs[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attrs)


def read_chunk(timeout):
    ready, _, _ = select.select([STDIN_FD], [], [], timeout)
    if not ready:
        return None
    try:
        data = os.read(STDIN_FD, 4096)
    except OSError:
        return None
    if not data:
        return None
    return data.decode("utf-8", errors="replace")


def main():
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    pasted_text = None
    try:
        configure_terminal(fd)
        # Tell the terminal stack to wrap pastes in CSI 200~/201~ from now
        # on. tmux's `paste-buffer -p` should honor the mode.
        sys.stdout.write(ENABLE_BRACKETED_PASTE)
        sys.stdout.write(READY_MARKER + "\n")
        sys.stdout.flush()

        buffer = ""
        in_paste = False
        deadline_ticks = 0
        max_idle_ticks = max(1, int(IDLE_TIMEOUT))

        while pasted_text is None and deadline_ticks < max_idle_ticks:
            chunk = read_chunk(1.0)
            if chunk is None:
                deadline_ticks += 1
                continue
            deadline_ticks = 0
            buffer += chunk
            while True:
                if not in_paste:
                    start = buffer.find(PASTE_START)
                    if start == -1:
                        # Drop everything before the first ESC so the
                        # buffer can't grow without bound across stray
                        # keystrokes (e.g. the shell sending CR).
                        last_esc = buffer.rfind("\x1b")
                        if last_esc > 0:
                            buffer = buffer[last_esc:]
                        break
                    buffer = buffer[start + len(PASTE_START):]
                    in_paste = True
                else:
                    end = buffer.find(PASTE_END)
                    if end == -1:
                        break
                    pasted_text = buffer[:end]
                    buffer = buffer[end + len(PASTE_END):]
                    break
    finally:
        sys.stdout.write(DISABLE_BRACKETED_PASTE)
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
        if pasted_text is not None:
            sys.stdout.write("\n" + HIT_PREFIX + pasted_text + "\n")
        else:
            sys.stdout.write("\n" + MISS_MARKER + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
