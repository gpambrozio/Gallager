#!/usr/bin/env python3
"""
Diagnostic: Reproduce ClaudeSpy's filterToColorCodesOnly in Python
and compare with raw output to identify what gets corrupted.

This re-implements the Swift function's exact logic to verify H1 and H2.
"""

import re
import sys


def filter_to_color_codes_only(input_str: str) -> str:
    """
    Python re-implementation of TmuxService.filterToColorCodesOnly().
    Keeps only CSI sequences ending with 'm' (SGR).
    Strips all other CSI sequences and non-CSI escape sequences.
    """
    result = []
    i = 0
    leaked_bytes = []  # Track bytes leaked from non-CSI handling (H2 bug)

    while i < len(input_str):
        if input_str[i] == '\x1b' and i + 1 < len(input_str):
            next_char = input_str[i + 1]
            if next_char == '[':
                # CSI sequence - find the end
                end = i + 2
                while end < len(input_str):
                    char = input_str[end]
                    if '@' <= char <= '~':
                        # Found terminating character
                        if char == 'm':
                            result.append(input_str[i:end + 1])
                        i = end + 1
                        break
                    end += 1
                else:
                    # Incomplete sequence, skip the escape
                    i += 1
            else:
                # Non-CSI escape sequence — Swift code does: i = input.index(after: i)
                # This skips ONLY the ESC byte; the next byte becomes regular text!
                leaked_bytes.append((i, next_char))
                i += 1  # Skip just ESC, next iteration will append next_char as text
        else:
            result.append(input_str[i])
            i += 1

    return ''.join(result), leaked_bytes


def categorize_escape_sequences(data: bytes) -> dict:
    """Categorize all escape sequences found in raw bytes."""
    categories = {
        'sgr': [],       # CSI ...m (colors)
        'cursor': [],    # CSI ...H/A/B/C/D/G/d/f
        'erase': [],     # CSI ...J/K/X
        'mode': [],      # CSI ...h/l (including private ?...)
        'scroll': [],    # CSI ...r/S/T
        'other_csi': [], # Other CSI
        'osc': [],       # ESC ] ... BEL/ST
        'non_csi': [],   # ESC + single byte (charset, etc.)
    }

    i = 0
    while i < len(data):
        if data[i] == 0x1b:
            if i + 1 >= len(data):
                break

            if data[i + 1] == ord('['):
                # CSI sequence
                end = i + 2
                while end < len(data) and not (0x40 <= data[end] <= 0x7e):
                    end += 1
                if end < len(data):
                    cmd = chr(data[end])
                    seq = data[i:end + 1]
                    if cmd == 'm':
                        categories['sgr'].append(seq)
                    elif cmd in 'HABCDGdf':
                        categories['cursor'].append(seq)
                    elif cmd in 'JKX':
                        categories['erase'].append(seq)
                    elif cmd in 'hl':
                        categories['mode'].append(seq)
                    elif cmd in 'rST':
                        categories['scroll'].append(seq)
                    else:
                        categories['other_csi'].append(seq)
                    i = end + 1
                else:
                    i += 1
            elif data[i + 1] == ord(']'):
                # OSC sequence
                end = i + 2
                while end < len(data) and data[end] != 0x07:
                    if data[end] == 0x1b and end + 1 < len(data) and data[end + 1] == 0x5c:
                        end += 2
                        break
                    end += 1
                else:
                    end += 1
                categories['osc'].append(data[i:end])
                i = end
            else:
                # Non-CSI: ESC + single char
                categories['non_csi'].append(data[i:i + 2])
                i += 2
        else:
            i += 1

    return categories


def main():
    import json
    import base64

    recording_file = 'tmux-recording-20260219-170417.tmrec'

    with open(recording_file) as f:
        lines = f.readlines()

    header = json.loads(lines[0])
    width, height = header['width'], header['height']
    print(f"Session: {width}x{height}")
    print()

    # === PART 1: Analyze initial capture ===
    print("=" * 70)
    print("PART 1: Initial capture analysis (what capture-pane -e -p outputs)")
    print("=" * 70)

    evt = json.loads(lines[1])
    initial_raw = base64.b64decode(evt[1])
    initial_str = initial_raw.decode('utf-8', errors='replace')

    cats = categorize_escape_sequences(initial_raw)
    print(f"\nEscape sequences in initial capture:")
    for name, seqs in cats.items():
        if seqs:
            print(f"  {name}: {len(seqs)} sequences")
            for s in seqs[:3]:
                print(f"    e.g. {repr(s)}")

    # Run through filter
    filtered, leaked = filter_to_color_codes_only(initial_str)
    print(f"\nAfter filterToColorCodesOnly:")
    print(f"  Input length:  {len(initial_str)} chars")
    print(f"  Output length: {len(filtered)} chars")
    print(f"  Leaked bytes from non-CSI handling: {len(leaked)}")
    if leaked:
        print(f"  Leaked characters (H2 bug):")
        for pos, char in leaked[:10]:
            print(f"    Position {pos}: char '{char}' (0x{ord(char):02x}) leaked as literal text")

    # === PART 2: Analyze live stream chunks ===
    print()
    print("=" * 70)
    print("PART 2: Live stream analysis (what %output events contain)")
    print("=" * 70)

    total_sgr = 0
    total_cursor = 0
    total_erase = 0
    total_mode = 0
    total_osc = 0
    total_non_csi = 0
    total_bytes = 0

    # Sample first 2000 events
    for i in range(2, min(len(lines), 2002)):
        evt = json.loads(lines[i])
        raw = base64.b64decode(evt[1])
        total_bytes += len(raw)
        cats = categorize_escape_sequences(raw)
        total_sgr += len(cats['sgr'])
        total_cursor += len(cats['cursor'])
        total_erase += len(cats['erase'])
        total_mode += len(cats['mode'])
        total_osc += len(cats['osc'])
        total_non_csi += len(cats['non_csi'])

    print(f"\nFirst 2000 events ({total_bytes} bytes):")
    print(f"  SGR (colors):        {total_sgr}")
    print(f"  Cursor positioning:  {total_cursor}")
    print(f"  Erase (line/screen): {total_erase}")
    print(f"  Mode set/reset:      {total_mode}")
    print(f"  OSC sequences:       {total_osc}")
    print(f"  Non-CSI escapes:     {total_non_csi}")

    # === PART 3: Simulate what ClaudeSpy does vs raw replay ===
    print()
    print("=" * 70)
    print("PART 3: Simulate initial state processing")
    print("=" * 70)

    # ClaudeSpy splits the initial capture by newlines, filters each line
    initial_lines = initial_str.rstrip('\n').split('\n')
    print(f"\nInitial capture has {len(initial_lines)} lines (terminal height: {height})")

    # Check for non-SGR escape sequences in visible area lines
    visible_lines = initial_lines[-height:] if len(initial_lines) > height else initial_lines
    print(f"Visible area: {len(visible_lines)} lines")

    problem_lines = []
    for idx, line in enumerate(visible_lines):
        filtered_line, leaked = filter_to_color_codes_only(line)
        if leaked:
            problem_lines.append((idx, line, leaked))

    if problem_lines:
        print(f"\n!!! Found {len(problem_lines)} lines with leaked bytes (H2 bug) !!!")
        for idx, line, leaked in problem_lines[:5]:
            print(f"  Line {idx}: {len(leaked)} leaked chars")
            for pos, char in leaked:
                print(f"    '{char}' (0x{ord(char):02x})")
    else:
        print(f"\nNo leaked bytes in initial capture visible area (initial capture is clean)")

    # === PART 4: Check if live stream uses patterns that conflict with initial state ===
    print()
    print("=" * 70)
    print("PART 4: Live stream cursor movement pattern analysis")
    print("=" * 70)

    # Analyze a window of live stream to understand the typical drawing pattern
    cr_count = 0
    cursor_up_counts = {}
    cursor_down_counts = {}

    for i in range(2, min(len(lines), 502)):
        evt = json.loads(lines[i])
        raw = base64.b64decode(evt[1])

        cr_count += raw.count(b'\r')

        for m in re.finditer(rb'\x1b\[(\d*)A', raw):
            n = int(m.group(1) or b'1')
            cursor_up_counts[n] = cursor_up_counts.get(n, 0) + 1

        for m in re.finditer(rb'\x1b\[(\d*)B', raw):
            n = int(m.group(1) or b'1')
            cursor_down_counts[n] = cursor_down_counts.get(n, 0) + 1

    print(f"\nFirst 500 events:")
    print(f"  CR (\\r) count: {cr_count}")
    print(f"  Cursor Up amounts: {dict(sorted(cursor_up_counts.items()))}")
    print(f"  Cursor Down amounts: {dict(sorted(cursor_down_counts.items()))}")

    # The key insight: Claude Code uses CR+CursorUp to redraw from a fixed position
    # If initial state puts the cursor at the wrong row, ALL subsequent redraws are offset

    print()
    print("=" * 70)
    print("PART 5: Key findings")
    print("=" * 70)
    print()
    print("The live stream heavily relies on:")
    print("  1. CR (carriage return) to go to column 0")
    print("  2. CursorUp/CursorDown for relative vertical positioning")
    print("  3. CursorRight for horizontal positioning within lines")
    print()
    print("These cursor movements are RELATIVE to the current cursor position.")
    print("If the initial state places the cursor at the WRONG position,")
    print("every subsequent redraw will be offset by that error.")
    print()

    # Check: where does ClaudeSpy put the cursor after initial state?
    # It uses: ESC[cursorY+1;cursorX+1H
    # But if the terminal has fewer rows, this position may not match

    print("ClaudeSpy initial state ends with cursor at the tmux cursor position.")
    print(f"If mirror terminal has fewer than {height} rows, cursor Y is clamped,")
    print("causing all relative CursorUp/CursorDown to be offset.")
    print()

    # === PART 6: The synchronized output pattern ===
    print("=" * 70)
    print("PART 6: Synchronized output (?2026h/l) analysis")
    print("=" * 70)

    # Count how many events contain synchronized output markers
    sync_events = 0
    for i in range(2, min(len(lines), 2002)):
        evt = json.loads(lines[i])
        raw = base64.b64decode(evt[1])
        if b'\x1b[?2026h' in raw:
            sync_events += 1

    print(f"\n{sync_events} out of 2000 events use synchronized output")
    print("This means most updates are wrapped in ?2026h ... ?2026l")
    print()
    print("If SwiftTerm doesn't support synchronized output (DEC private mode 2026),")
    print("each partial update within a sync block becomes immediately visible,")
    print("causing visible flicker and partial-state rendering artifacts.")


if __name__ == '__main__':
    main()
