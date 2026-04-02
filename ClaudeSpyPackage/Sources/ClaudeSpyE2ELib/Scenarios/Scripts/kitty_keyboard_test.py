"""
kitty_keyboard_test.py — Kitty keyboard protocol test.

Tests that the terminal mirror correctly strips Kitty keyboard protocol
escape sequences while preserving surrounding visible text output.
"""

import sys
import time


def write(text):
    """Write text to stdout and flush immediately."""
    sys.stdout.buffer.write(text.encode() if isinstance(text, str) else text)
    sys.stdout.buffer.flush()


# Phase 1: Individual protocol negotiation sequences
# Each should be completely invisible to the mirror
write("PHASE1_START\n")

write("push1_before ")
write("\x1b[>1u")       # Push mode: enable disambiguate-escape-codes
time.sleep(0.1)
write("push1_after\n")

write("push5_before ")
write("\x1b[>5u")       # Push mode: flags=5
time.sleep(0.1)
write("push5_after\n")

write("query_before ")
write("\x1b[?u")        # Query current mode
time.sleep(0.1)
write("query_after\n")

write("setflags_before ")
write("\x1b[=1;2u")     # Set specific flags
time.sleep(0.1)
write("setflags_after\n")

write("pop_before ")
write("\x1b[<u")        # Pop mode
time.sleep(0.1)
write("pop_after\n")

write("\x1b[<u")        # Pop remaining
time.sleep(0.1)

write("PHASE1_DONE\n")

# Phase 2: Interleaved with normal output (no gaps)
write("PHASE2_START\n")
write("before")
write("\x1b[>1u")       # Should be stripped completely
write("-after")
write("\x1b[<u")        # Should be stripped completely
write("-end\n")
write("PHASE2_DONE\n")

# Phase 3: Rapid push/pop cycling
write("PHASE3_START\n")
for i in range(10):
    write("\x1b[>1u")   # Push
    write(f"[{i}]")
    write("\x1b[<u")    # Pop
    time.sleep(0.02)
write("\n")
write("PHASE3_DONE\n")
