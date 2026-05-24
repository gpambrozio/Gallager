"""
osc_bg_probe.py — Mimic Codex's OSC-11 background-color probe.

Sends an OSC 11 query (`\\e]11;?\\a`) to stdout, then reads stdin with
a 100 ms timeout — the same `DEFAULT_TIMEOUT` Codex's
`codex-rs/tui/src/terminal_probe.rs` uses at startup. Parses the
response for `rgb:RRRR/GGGG/BBBB` and renders dramatically different
output depending on the outcome:

* SUCCESS → bright green "OK" ASCII banner, a colored bar in the
  detected bg color, and four "● Working (… esc to interrupt)" lines
  rendered in light grey (what Codex picks adaptively when it knows
  the bg).
* FAILURE → bright red "FAILED" ASCII banner, a black-on-black bar
  (invisible on dark themes), and the same "● Working" lines rendered
  in bold + RGB(0,0,0) — the actual fallback Codex emits when the
  probe times out.

Used as a regression guard for `TmuxService.defaultCommandWrapper`,
which prepends a `printf` of OSC 10/11 *setter* sequences so tmux
caches the pane's fg/bg up front. Without that warming, tmux 3.6a's
broken outer-terminal forwarding (see tmux/tmux#4846,
openai/codex#22761 / #23489) causes Codex's startup probe to time out
and the "● Working" status to render invisibly on dark mirror themes.

Pure stdlib so it runs anywhere Python 3 does.
"""

import re
import select
import sys
import termios
import time
import tty

# Matches openai/codex `codex-rs/tui/src/terminal_probe.rs::DEFAULT_TIMEOUT`.
PROBE_TIMEOUT_SECONDS = 0.1

# After parsing the OSC response, keep stdin in raw mode and drain any
# straggler bytes for this long before restoring cooked mode. tmux 3.6a
# sometimes emits a second OSC reply after our read window closes (see
# tmux/tmux#4846); without the drain those bytes land at the shell prompt
# as visible garbage like `11;rgb:1e1e/1e1e/1e1e\`. 150 ms covers
# observed late replies without slowing the test perceptibly.
DRAIN_DURATION_SECONDS = 0.15

CSI = "\033["
OSC = "\033]"
BEL = "\007"


def probe_background():
    """Send OSC 11 query and return parsed (R, G, B) bytes, or None.

    Reads with `select` so the 100 ms timeout is honored even if the
    terminal never replies (tmux 3.6a behavior when bg cache is cold).
    After parsing — successful or not — drains any straggler bytes still
    in the pty buffer so a late tmux reply doesn't bleed into the shell
    prompt after we restore cooked mode.
    """
    fd = sys.stdin.fileno()
    old_attrs = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)
        sys.stdout.write(f"{OSC}11;?{BEL}")
        sys.stdout.flush()

        # Initial read for the response. Times out at PROBE_TIMEOUT_SECONDS.
        rgb = _read_osc_response(fd)

        # Whether or not we got a parseable response, sweep the buffer for
        # late arrivals. This is the same defense iTerm2 effectively has
        # via its own internal probe-then-suppress pipeline, but applied
        # here at the script level.
        _drain(fd, DRAIN_DURATION_SECONDS)

        return rgb
    finally:
        termios.tcsetattr(fd, termios.TCSANOW, old_attrs)


def _read_osc_response(fd):
    """Read once with timeout, parse rgb:R/G/B, return tuple or None."""
    ready, _, _ = select.select([fd], [], [], PROBE_TIMEOUT_SECONDS)
    if not ready:
        return None
    # Read whatever the terminal queued. 128 bytes is plenty for an
    # OSC response (typically ~24 bytes).
    chunk = sys.stdin.buffer.read1(128)
    if not chunk:
        return None
    match = re.search(rb"rgb:([0-9a-fA-F]+)/([0-9a-fA-F]+)/([0-9a-fA-F]+)", chunk)
    if not match:
        return None

    def high_byte(hex_bytes):
        # OSC 11 responses can be 2-digit or 4-digit per channel.
        # Standard form is 4 (e.g. "rgb:1e1e/1e1e/1e1e"); we just
        # take the high byte either way.
        return int(hex_bytes[:2], 16)

    return (
        high_byte(match.group(1)),
        high_byte(match.group(2)),
        high_byte(match.group(3)),
    )


def _drain(fd, duration):
    """Consume any bytes that arrive on `fd` within `duration` seconds.

    Loops short `select` waits and discards whatever shows up. Returns
    once a full poll quantum passes with nothing to read AND the total
    elapsed time has reached `duration`.
    """
    end_at = time.monotonic() + duration
    poll_interval = 0.05  # 50 ms — short enough to catch late replies quickly
    while time.monotonic() < end_at:
        remaining = end_at - time.monotonic()
        ready, _, _ = select.select([fd], [], [], min(poll_interval, remaining))
        if not ready:
            continue
        try:
            sys.stdin.buffer.read1(1024)
        except (BlockingIOError, OSError):
            break


def write(text):
    sys.stdout.write(text)


# 5-row ASCII glyphs sized for high-visibility status banners.
LETTERS = {
    "O": [" ███ ", "█   █", "█   █", "█   █", " ███ "],
    "K": ["█   █", "█  █ ", "███  ", "█  █ ", "█   █"],
    "F": ["█████", "█    ", "███  ", "█    ", "█    "],
    "A": [" ███ ", "█   █", "█████", "█   █", "█   █"],
    "I": ["█████", "  █  ", "  █  ", "  █  ", "█████"],
    "L": ["█    ", "█    ", "█    ", "█    ", "█████"],
    "E": ["█████", "█    ", "███  ", "█    ", "█████"],
    "D": ["████ ", "█   █", "█   █", "█   █", "████ "],
    " ": ["     ", "     ", "     ", "     ", "     "],
}


def render_banner(text):
    """Return 5 lines of large ASCII art for the uppercase text."""
    rows = ["", "", "", "", ""]
    for ch in text.upper():
        glyph = LETTERS.get(ch, LETTERS[" "])
        for i in range(5):
            rows[i] += glyph[i] + "  "
    return rows


def render_ok(rgb):
    r, g, b = rgb
    write(f"{CSI}2J{CSI}H")
    write(f"{CSI}1;38;2;120;230;120m")
    for row in render_banner("OK"):
        write("  " + row + "\n")
    write(f"{CSI}0m\n")
    write(f"  OSC 11 probe succeeded — tmux reported bg = rgb({r:02x},{g:02x},{b:02x})\n\n")

    # 60-cell bar painted in the detected bg color. On the DefaultDark
    # mirror with our wrapper installed this is a visible #1e1e1e bar.
    bar = "█" * 60
    write(f"  {CSI}38;2;{r};{g};{b}m{bar}{CSI}0m\n\n")

    # "Working" lines in light grey — the kind of adaptive choice Codex
    # makes when it knows the bg.
    write(f"{CSI}38;2;200;200;200m")
    for sec in (10, 20, 30, 42):
        write(f"  ● Working  (5m {sec}s · esc to interrupt)\n")
    write(f"{CSI}0m\n")
    write(f"{CSI}1;38;2;120;230;120m  REGRESSION GUARD INTACT{CSI}0m\n")


def render_failed(reason):
    write(f"{CSI}2J{CSI}H")
    write(f"{CSI}1;38;2;230;80;80m")
    for row in render_banner("FAILED"):
        write("  " + row + "\n")
    write(f"{CSI}0m\n")
    write(f"  OSC 11 probe failed: {reason}\n\n")

    # 60-cell bar painted pure black — invisible on dark mirror themes.
    bar = "█" * 60
    write(f"  {CSI}38;2;0;0;0m{bar}{CSI}0m\n\n")

    # "Working" lines in bold pure black — exactly what Codex emits
    # when its probe times out (the bug this scenario guards against).
    for sec in (10, 20, 30, 42):
        write(f"  {CSI}1;38;2;0;0;0m● Working  (5m {sec}s · esc to interrupt){CSI}0m\n")
    write(f"\n{CSI}1;38;2;230;80;80m  REGRESSION DETECTED{CSI}0m\n")


def main():
    rgb = probe_background()
    if rgb is None:
        render_failed("timeout or no response")
    elif rgb == (0, 0, 0):
        # tmux 3.6a's default reply when its pane bg cache is cold is
        # `rgb:0000/0000/0000` — technically a response, but exactly the
        # failure mode the regression test is supposed to catch (Codex sees
        # this, decides "bg is black", and picks colors that don't work).
        # Treat pure black the same as no response.
        render_failed("tmux returned rgb(00,00,00) — pane bg cache is empty")
    else:
        render_ok(rgb)
    sys.stdout.flush()


if __name__ == "__main__":
    main()
