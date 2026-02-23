#!/usr/bin/env python3
"""
tmux-rec: Record and replay tmux sessions with full fidelity.

Records every byte (ANSI escape sequences, colors, cursor movements,
animations, alternate screen switches) with microsecond timing.
Replays in a correctly-sized tmux session with speed control.

Usage:
  tmux-rec record                          Interactive session picker
  tmux-rec record -t mysession             Record a specific session
  tmux-rec play recording.tmrec            Replay at normal speed
  tmux-rec play recording.tmrec -s 3       Replay at 3× speed
  tmux-rec play recording.tmrec -s 5 -i 2  5× speed, cap idle at 2s

Format: NDJSON (.tmrec) — header line + [elapsed, base64_data] lines.
"""

import sys
import os
import json
import time
import base64
import subprocess
import select
import argparse

RECORDING_EXT = ".tmrec"
VERSION = 2


# ─── Utilities ────────────────────────────────────────────────────────

def tmux_running():
    """Check if tmux server is reachable."""
    r = subprocess.run(["tmux", "info"], capture_output=True)
    return r.returncode == 0


def tmux_cmd(args, check=True, **kw):
    """Run a tmux command and return the result."""
    return subprocess.run(["tmux"] + args, capture_output=True, text=True,
                          check=check, **kw)


def fmt_duration(seconds):
    """Format seconds as human-readable duration."""
    if seconds < 60:
        return f"{seconds:.1f}s"
    m, s = divmod(int(seconds), 60)
    if m < 60:
        return f"{m}m{s:02d}s"
    h, m = divmod(m, 60)
    return f"{h}h{m:02d}m{s:02d}s"


def fmt_size(nbytes):
    """Format byte count as human-readable size."""
    for unit in ("B", "KB", "MB", "GB"):
        if nbytes < 1024:
            return f"{nbytes:.1f} {unit}" if unit != "B" else f"{nbytes} {unit}"
        nbytes /= 1024
    return f"{nbytes:.1f} TB"


# ─── Session / pane discovery ─────────────────────────────────────────

def get_sessions():
    """Return list of tmux session dicts."""
    r = tmux_cmd(["list-sessions", "-F",
                   "#{session_id}|#{session_name}|#{session_windows}"
                   "|#{session_attached}|#{session_created}"], check=False)
    if r.returncode != 0:
        return []
    sessions = []
    for line in r.stdout.strip().splitlines():
        parts = line.split("|")
        if len(parts) < 5:
            continue
        sessions.append({
            "id":       parts[0],
            "name":     parts[1],
            "windows":  int(parts[2]),
            "attached": int(parts[3]),
            "created":  int(parts[4]),
        })
    return sessions


def get_panes(session_name):
    """Return list of pane dicts for a session."""
    r = tmux_cmd(["list-panes", "-t", session_name, "-F",
                   "#{pane_id}|#{pane_index}|#{pane_width}|#{pane_height}"
                   "|#{pane_current_command}|#{pane_active}"])
    panes = []
    for line in r.stdout.strip().splitlines():
        parts = line.split("|")
        if len(parts) < 6:
            continue
        panes.append({
            "id":      parts[0],
            "index":   int(parts[1]),
            "width":   int(parts[2]),
            "height":  int(parts[3]),
            "command": parts[4],
            "active":  int(parts[5]),
        })
    return panes


def get_pane_size(target):
    """Return (width, height) for a tmux target."""
    r = tmux_cmd(["display-message", "-t", target, "-p",
                   "#{pane_width}|#{pane_height}"])
    w, h = r.stdout.strip().split("|")
    return int(w), int(h)


# ─── Interactive pickers ──────────────────────────────────────────────

C_RESET  = "\033[0m"
C_BOLD   = "\033[1m"
C_DIM    = "\033[90m"
C_CYAN   = "\033[1;36m"
C_GREEN  = "\033[32m"
C_RED    = "\033[1;31m"
C_YELLOW = "\033[1;33m"
DOT_ON   = f"{C_GREEN}●{C_RESET}"
DOT_OFF  = f"{C_DIM}○{C_RESET}"


def pick_session():
    """Interactive session picker. Returns session name."""
    sessions = get_sessions()
    if not sessions:
        print(f"\n{C_RED}Error:{C_RESET} No tmux sessions found.")
        print(f"  Start one first:  {C_BOLD}tmux new-session -s mysession{C_RESET}\n")
        sys.exit(1)

    bar = "─" * 56
    print(f"\n{C_CYAN}┌─ tmux sessions {bar[16:]}┐{C_RESET}")
    for i, s in enumerate(sessions, 1):
        dot = DOT_ON if s["attached"] else DOT_OFF
        ts  = time.strftime("%H:%M:%S", time.localtime(s["created"]))
        wins = f'{s["windows"]} win' + ("s" if s["windows"] != 1 else " ")
        print(f"{C_CYAN}│{C_RESET}  {dot} {C_BOLD}[{i}]{C_RESET} "
              f'{s["name"]:<22} {wins:<8} started {ts}')
    print(f"{C_CYAN}└{bar}┘{C_RESET}")

    while True:
        try:
            raw = input(f"\n{C_BOLD}Select session [1-{len(sessions)}]:{C_RESET} ").strip()
            idx = int(raw) - 1
            if 0 <= idx < len(sessions):
                return sessions[idx]["name"]
        except (ValueError, EOFError, KeyboardInterrupt):
            print()
            sys.exit(0)
        print(f"  Enter a number between 1 and {len(sessions)}")


def pick_pane(session_name):
    """Pick a pane within a session. Returns pane dict."""
    panes = get_panes(session_name)
    if len(panes) == 1:
        return panes[0]

    bar = "─" * 56
    print(f"\n{C_CYAN}┌─ panes in '{session_name}' {bar[len(session_name)+14:]}┐{C_RESET}")
    for p in panes:
        dot = DOT_ON if p["active"] else DOT_OFF
        dims = f'{p["width"]}×{p["height"]}'
        print(f'{C_CYAN}│{C_RESET}  {dot} {C_BOLD}[{p["index"]}]{C_RESET} '
              f'{p["command"]:<22} {dims}')
    print(f"{C_CYAN}└{bar}┘{C_RESET}")

    while True:
        try:
            raw = input(f"\n{C_BOLD}Select pane [0-{len(panes)-1}]:{C_RESET} ").strip()
            idx = int(raw)
            for p in panes:
                if p["index"] == idx:
                    return p
        except (ValueError, EOFError, KeyboardInterrupt):
            print()
            sys.exit(0)


# ─── Recording ────────────────────────────────────────────────────────

def record(target=None, outfile=None):
    """Record a tmux pane's byte stream with timing."""

    if not tmux_running():
        print(f"\n{C_RED}Error:{C_RESET} tmux server not running.\n")
        sys.exit(1)

    # Resolve target
    if target is None:
        session_name = pick_session()
        pane = pick_pane(session_name)
        target = pane["id"]
        width, height = pane["width"], pane["height"]
    else:
        try:
            width, height = get_pane_size(target)
        except subprocess.CalledProcessError:
            print(f"\n{C_RED}Error:{C_RESET} tmux target '{target}' not found.\n")
            sys.exit(1)

    # Output filename
    if outfile is None:
        ts = time.strftime("%Y%m%d-%H%M%S")
        outfile = f"tmux-recording-{ts}{RECORDING_EXT}"
    elif not outfile.endswith(RECORDING_EXT):
        outfile += RECORDING_EXT

    outfile_abs = os.path.abspath(outfile)
    script_path = os.path.abspath(__file__)

    # ── Capture initial screen state (with escape sequences for color) ──
    r = subprocess.run(
        ["tmux", "capture-pane", "-t", target, "-e", "-p"],
        capture_output=True,
    )
    initial_screen = r.stdout  # bytes, includes ANSI escapes

    # ── Write header ──
    header = {
        "version":   VERSION,
        "width":     width,
        "height":    height,
        "timestamp": int(time.time()),
        "target":    target,
        "env": {
            "TERM": os.environ.get("TERM", ""),
        },
    }
    with open(outfile_abs, "w") as f:
        f.write(json.dumps(header) + "\n")
        # Time-zero event: initial screen snapshot
        if initial_screen:
            enc = base64.b64encode(initial_screen).decode("ascii")
            f.write(json.dumps([0.0, enc]) + "\n")

    # ── Start pipe-pane → sink subprocess ──
    sink_cmd = (
        f'python3 \'{script_path}\' --sink \'{outfile_abs}\' {width} {height}'
    )
    tmux_cmd(["pipe-pane", "-t", target, "-o", sink_cmd])

    print(f"\n{C_GREEN}⏺  Recording started{C_RESET}")
    print(f"   Target : {C_BOLD}{target}{C_RESET} ({width}×{height})")
    print(f"   Output : {C_BOLD}{outfile}{C_RESET}")
    print(f"\n   {C_DIM}Switch to your tmux session and interact normally.{C_RESET}")
    print(f"   {C_BOLD}Press Enter (or Ctrl-C) here to stop recording.{C_RESET}\n")

    try:
        input()
    except (EOFError, KeyboardInterrupt):
        print()

    # ── Stop pipe-pane ──
    tmux_cmd(["pipe-pane", "-t", target], check=False)

    # Brief pause to let the sink flush
    time.sleep(0.2)

    # ── Summary ──
    size = os.path.getsize(outfile_abs)
    # Count events to compute duration
    duration = 0.0
    with open(outfile_abs) as f:
        f.readline()  # skip header
        for line in f:
            try:
                evt = json.loads(line)
                duration = evt[0]
            except Exception:
                pass

    print(f"{C_GREEN}⏹  Recording stopped{C_RESET}  "
          f"({fmt_duration(duration)}, {fmt_size(size)})")

    bn = os.path.basename(sys.argv[0])
    print(f"\n   Replay commands:")
    print(f"     {C_BOLD}{bn} play {outfile}{C_RESET}")
    print(f"     {C_BOLD}{bn} play {outfile} -s 3{C_RESET}          (3× speed)")
    print(f"     {C_BOLD}{bn} play {outfile} -s 5 -i 2{C_RESET}    (5× speed, cap idle at 2s)\n")


# ─── Sink (called by pipe-pane) ───────────────────────────────────────

def sink(outfile, width, height):
    """
    Read raw bytes from stdin (piped by tmux pipe-pane),
    append timestamped base64-encoded chunks to the recording file.
    """
    start = time.monotonic()
    stdin_fd = sys.stdin.fileno()
    stdin_bin = os.fdopen(stdin_fd, "rb", buffering=0)

    with open(outfile, "a") as f:
        while True:
            try:
                ready, _, _ = select.select([stdin_bin], [], [], 1.0)
                if ready:
                    chunk = stdin_bin.read(8192)
                    if not chunk:
                        break
                    elapsed = round(time.monotonic() - start, 6)
                    enc = base64.b64encode(chunk).decode("ascii")
                    f.write(json.dumps([elapsed, enc]) + "\n")
                    f.flush()
            except (IOError, OSError, KeyboardInterrupt):
                break


# ─── Playback ─────────────────────────────────────────────────────────

def play(infile, speed=1.0, max_idle=None, in_tmux=False):
    """Replay a .tmrec recording to stdout with timing."""

    if not os.path.exists(infile):
        print(f"{C_RED}Error:{C_RESET} File not found: {infile}", file=sys.stderr)
        sys.exit(1)

    with open(infile) as f:
        lines = f.readlines()

    if not lines:
        print(f"{C_RED}Error:{C_RESET} Empty recording file.", file=sys.stderr)
        sys.exit(1)

    # Parse header
    try:
        header = json.loads(lines[0])
    except json.JSONDecodeError:
        print(f"{C_RED}Error:{C_RESET} Invalid recording format.", file=sys.stderr)
        sys.exit(1)

    width  = header.get("width", 80)
    height = header.get("height", 24)

    # Parse events
    events = []
    for line in lines[1:]:
        line = line.strip()
        if not line:
            continue
        try:
            evt = json.loads(line)
            events.append((float(evt[0]), base64.b64decode(evt[1])))
        except Exception:
            continue

    if not events:
        print(f"{C_RED}Error:{C_RESET} No events in recording.", file=sys.stderr)
        sys.exit(1)

    total   = events[-1][0]
    adj     = total / speed if speed else total

    # ── Terminal size check ──
    try:
        ts = os.get_terminal_size()
        if ts.columns < width or ts.lines < height:
            sys.stderr.write(
                f"{C_YELLOW}Warning:{C_RESET} Recording is {width}×{height} "
                f"but terminal is {ts.columns}×{ts.lines}. "
                f"Resize for best results.\n"
            )
            time.sleep(1)
    except OSError:
        pass

    # ── Info banner (stderr so it doesn't pollute the byte stream) ──
    if not in_tmux:
        sys.stderr.write(
            f"{C_CYAN}▶ Playing:{C_RESET} {os.path.basename(infile)}  "
            f"{C_DIM}({width}×{height}, {fmt_duration(total)}"
        )
        if speed != 1.0:
            sys.stderr.write(f" → {fmt_duration(adj)} at {speed}×")
        sys.stderr.write(f"){C_RESET}\n")
        sys.stderr.write(f"{C_DIM}  Press Ctrl-C to stop.{C_RESET}\n\n")
        sys.stderr.flush()
        time.sleep(0.3)

    # ── Stream events ──
    stdout_bin = os.fdopen(sys.stdout.fileno(), "wb", buffering=0, closefd=False)
    prev = 0.0

    try:
        for elapsed, data in events:
            delay = (elapsed - prev) / speed
            if max_idle is not None and delay > max_idle:
                delay = max_idle
            if delay > 0.001:
                time.sleep(delay)
            stdout_bin.write(data)
            stdout_bin.flush()
            prev = elapsed
    except (KeyboardInterrupt, BrokenPipeError):
        pass

    if not in_tmux:
        # Reset attributes and print a newline so the shell prompt is clean
        stdout_bin.write(b"\033[0m")
        stdout_bin.flush()
        sys.stderr.write(f"\n{C_CYAN}⏹ Replay finished.{C_RESET}\n")


def play_in_tmux(infile, speed, max_idle):
    """Spawn a new tmux session at the correct size and replay inside it."""

    with open(infile) as f:
        header = json.loads(f.readline())

    width  = header.get("width", 80)
    height = header.get("height", 24)

    session_name = f"replay-{int(time.time()) % 100000}"
    script_path  = os.path.abspath(__file__)
    infile_abs   = os.path.abspath(infile)

    parts = [f"python3 '{script_path}' play '{infile_abs}' --in-tmux"]
    if speed != 1.0:
        parts.append(f"-s {speed}")
    if max_idle is not None:
        parts.append(f"-i {max_idle}")
    cmd = " ".join(parts)

    # After replay, pause so the user can inspect the final state
    shell_cmd = (
        f'{cmd}; echo; echo "\\033[1;36m⏹ Replay finished. '
        f'Press Enter to close.\\033[0m"; read'
    )

    # If tmux server isn't running, start one; otherwise add a session
    try:
        tmux_cmd(["new-session", "-d",
                   "-s", session_name,
                   "-x", str(width), "-y", str(height),
                   shell_cmd])
    except subprocess.CalledProcessError:
        print(f"{C_RED}Error:{C_RESET} Could not create tmux session.", file=sys.stderr)
        print("Falling back to direct replay.\n", file=sys.stderr)
        play(infile, speed, max_idle)
        return

    print(f"{C_GREEN}▶ Replay started{C_RESET} in tmux session "
          f"'{C_BOLD}{session_name}{C_RESET}' ({width}×{height})")
    print(f"  Attaching now…\n")

    # Attach (replaces current process)
    os.execvp("tmux", ["tmux", "attach-session", "-t", session_name])


# ─── CLI ──────────────────────────────────────────────────────────────

def main():
    p = argparse.ArgumentParser(
        prog="tmux-rec",
        description="Record and replay tmux sessions with full fidelity.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""\
examples:
  %(prog)s record                          Interactive session picker
  %(prog)s record -t mysession             Record specific session
  %(prog)s record -t mysession -o demo     Record to demo.tmrec

  %(prog)s play demo.tmrec                 Replay (opens in new tmux session)
  %(prog)s play demo.tmrec -s 3            3× speed
  %(prog)s play demo.tmrec -s 5 -i 2       5× speed, cap idle at 2 seconds
  %(prog)s play demo.tmrec --no-tmux       Replay in current terminal
""",
    )
    sub = p.add_subparsers(dest="command")

    # ── record ──
    rp = sub.add_parser("record", help="Record a tmux session")
    rp.add_argument("-t", "--target",
                    help="tmux target (session, window, or pane identifier)")
    rp.add_argument("-o", "--output",
                    help=f"Output file (default: auto-timestamped{RECORDING_EXT})")

    # ── play ──
    pp = sub.add_parser("play", help="Replay a recording")
    pp.add_argument("file", help="Recording file to replay")
    pp.add_argument("-s", "--speed", type=float, default=1.0,
                    help="Playback speed multiplier (default: 1.0)")
    pp.add_argument("-i", "--idle-max", type=float, default=None,
                    help="Cap idle pauses at N seconds")
    pp.add_argument("--no-tmux", action="store_true",
                    help="Replay in the current terminal (no new tmux session)")
    pp.add_argument("--in-tmux", action="store_true",
                    help=argparse.SUPPRESS)  # internal

    # ── hidden sink mode (called by pipe-pane) ──
    p.add_argument("--sink", nargs=3, metavar=("FILE", "W", "H"),
                   help=argparse.SUPPRESS)

    args = p.parse_args()

    # Sink mode
    if args.sink:
        sink(args.sink[0], int(args.sink[1]), int(args.sink[2]))
        return

    if args.command == "record":
        record(target=args.target, outfile=args.output)

    elif args.command == "play":
        if args.in_tmux or args.no_tmux:
            play(args.file, speed=args.speed, max_idle=args.idle_max,
                 in_tmux=args.in_tmux)
        else:
            play_in_tmux(args.file, speed=args.speed, max_idle=args.idle_max)

    else:
        p.print_help()


if __name__ == "__main__":
    main()
