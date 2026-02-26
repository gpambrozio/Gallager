#!/usr/bin/env python3
"""Replay captured frames from claudespy-frames.bin in a real terminal.

Usage:
    python3 terminal-debug/replay-frames.py [/path/to/claudespy-frames.bin]

Each frame is preceded by a 4-byte little-endian length.
Frames are replayed with a pause between them so you can observe rendering.
"""

import struct
import sys
import time
import os

def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/claudespy-frames.bin"

    if not os.path.exists(path):
        print(f"File not found: {path}")
        print("Run the stress test with ClaudeSpy connected to capture frames.")
        sys.exit(1)

    with open(path, "rb") as f:
        data = f.read()

    offset = 0
    frame_num = 0

    while offset < len(data):
        if offset + 4 > len(data):
            break

        length = struct.unpack("<I", data[offset:offset+4])[0]
        offset += 4

        if offset + length > len(data):
            print(f"  Frame {frame_num}: truncated (expected {length} bytes, got {len(data) - offset})")
            break

        frame = data[offset:offset+length]
        offset += length
        frame_num += 1

        # Print frame info to stderr
        first = frame[0] if frame else 0
        last = frame[-1] if frame else 0
        print(f"  Frame {frame_num}: {length} bytes, first=0x{first:02x}, last=0x{last:02x}", file=sys.stderr)

        # Hex dump first 100 bytes
        hex_preview = " ".join(f"{b:02x}" for b in frame[:100])
        print(f"    Hex: {hex_preview}...", file=sys.stderr)

        # ASCII preview (escape sequences shown as <ESC>)
        ascii_preview = ""
        for b in frame[:200]:
            if b == 0x1b:
                ascii_preview += "<ESC>"
            elif 0x20 <= b < 0x7f:
                ascii_preview += chr(b)
            else:
                ascii_preview += f"<{b:02x}>"
        print(f"    ASCII: {ascii_preview}...", file=sys.stderr)

        # Count ESC[0m occurrences (reset sequences)
        reset_count = frame.count(b"\x1b[0m")
        sync_begin = frame.count(b"\x1b[?2026h")
        sync_end = frame.count(b"\x1b[?2026l")
        cup_count = frame.count(b"\x1b[")  # rough count of CSI sequences
        print(f"    Resets: {reset_count}, Syncs: {sync_begin}h/{sync_end}l, CSI~: {cup_count}", file=sys.stderr)

        print(f"\n--- Replaying frame {frame_num} ({length} bytes) ---", file=sys.stderr)
        input("Press Enter to replay this frame...")

        # Write raw bytes to stdout (the terminal)
        sys.stdout.buffer.write(frame)
        sys.stdout.buffer.flush()

        time.sleep(0.5)

    print(f"\nDone. Replayed {frame_num} frames.", file=sys.stderr)


if __name__ == "__main__":
    main()
