"""
keystroke_logger.py — Records incoming keystrokes for E2E tests.

Reads stdin in cbreak mode and accumulates a compact sequence of every
key it sees. Exits when no input arrives for IDLE_TIMEOUT seconds (or on
Ctrl-C), then prints a single SEQUENCE line summarizing what was typed.

Encoding (tokens separated by spaces on the SEQUENCE line):
  D       = Down arrow
  U       = Up arrow
  L       = Left arrow
  R       = Right arrow
  E       = Enter / newline
  S       = Space
  T<text> = a run of printable text (e.g. T<Mango>)
  X<hex>  = any other non-printable byte

Used by the AskUserQuestion E2E scenario to assert that the keystrokes
actually delivered to tmux match what the unit tests say should be
generated.
"""

import os
import select
import sys
import termios
import tty

IDLE_TIMEOUT = 3.0
ESC_TIMEOUT = 0.2

STDIN_FD = sys.stdin.fileno()


def read_byte(timeout):
    """Read one byte from stdin, or return None if nothing arrives in `timeout` seconds."""
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


def main():
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    parts = []
    text_buf = ""
    try:
        tty.setcbreak(fd)
        sys.stdout.write("LOGGER_READY\n")
        sys.stdout.flush()

        while True:
            ch = read_byte(IDLE_TIMEOUT)
            if ch is None or ch == "\x03":
                break

            if ch == "\x1b":
                # Flush any pending text first.
                if text_buf:
                    parts.append(f"T<{text_buf}>")
                    text_buf = ""
                seq = ""
                while True:
                    nb = read_byte(ESC_TIMEOUT)
                    if nb is None:
                        break
                    seq += nb
                    if seq and (seq[-1].isalpha() or seq[-1] == "~"):
                        break
                token = {"[A": "U", "[B": "D", "[C": "R", "[D": "L"}.get(seq)
                parts.append(token if token else f"ESC<{seq}>")
                continue

            if ch in ("\r", "\n"):
                if text_buf:
                    parts.append(f"T<{text_buf}>")
                    text_buf = ""
                parts.append("E")
                continue

            if ch == " ":
                if text_buf:
                    parts.append(f"T<{text_buf}>")
                    text_buf = ""
                parts.append("S")
                continue

            if ch.isprintable():
                text_buf += ch
            else:
                if text_buf:
                    parts.append(f"T<{text_buf}>")
                    text_buf = ""
                parts.append(f"X<{ord(ch):#x}>")

        if text_buf:
            parts.append(f"T<{text_buf}>")
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
        sys.stdout.write("\nSEQUENCE: " + " ".join(parts) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
