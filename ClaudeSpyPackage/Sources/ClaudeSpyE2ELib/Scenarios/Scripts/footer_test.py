"""
footer_test.py — Fixed header/footer scroll region test.

Tests terminal scroll region support (DECSTBM) by rendering a pinned
header and footer with scrolling content in between.
"""

import os
import sys
import time

ESC = '\033'
CSI = ESC + '['

def write(text):
    """Write text to stdout and flush immediately."""
    sys.stdout.write(text)
    sys.stdout.flush()


def move_cursor(row, col):
    """Move cursor to the given row and column (CUP sequence)."""
    write(f'{CSI}{row};{col}H')


def sgr(code):
    """Apply an SGR (Select Graphic Rendition) style."""
    write(f'{CSI}{code}m')


def reset_style():
    """Reset all text attributes."""
    write(f'{CSI}0m')


def set_scroll_region(top, bottom):
    """Set the scroll region using DECSTBM."""
    write(f'{CSI}{top};{bottom}r')


def reset_scroll_region():
    """Reset scroll region to the full terminal."""
    write(f'{CSI}r')


# Get terminal size
cols, rows = os.get_terminal_size()

# Clear screen
write(f'{CSI}2J{CSI}H')

# ── Fixed header (rows 1-3): white on blue ──
move_cursor(1, 1)
sgr('1;37;44')
write(' ' * cols)
move_cursor(1, 1)
write('  ┌─ FIXED HEADER ─' + '─' * (cols - 21) + '┐')
move_cursor(2, 1)
write(f'  │ This stays pinned while content scrolls below{" " * (cols - 52)}│')
move_cursor(3, 1)
write('  └' + '─' * (cols - 4) + '┘')
reset_style()

# ── Fixed footer (bottom 3 rows): white on green ──
move_cursor(rows - 2, 1)
sgr('1;37;42')
write('  ┌' + '─' * (cols - 4) + '┐')
move_cursor(rows - 1, 1)
write(f'  │ FIXED FOOTER — status bar area{" " * (cols - 36)}│')
move_cursor(rows, 1)
write('  └' + '─' * (cols - 4) + '┘')
reset_style()

# ── Set scroll region to the middle ──
top_margin = 4
bottom_margin = rows - 3
set_scroll_region(top_margin, bottom_margin)

# ── Fill the scroll region with colored content ──
scroll_height = bottom_margin - top_margin + 1
for i in range(1, scroll_height + 20):
    move_cursor(bottom_margin, 1)
    # Cycle through colors using ANSI 256-color
    color = 31 + (i % 6)
    sgr(f'1;{color}')
    write(f'    Scrolling line {i:3d} — content scrolls, header/footer stay fixed')
    reset_style()
    write('\n')
    time.sleep(0.02)

# ── Reset scroll region and position cursor ──
reset_scroll_region()
move_cursor(rows, 1)
