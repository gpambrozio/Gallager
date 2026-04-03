"""
truecolor.py — True-color gradient animation test.

Renders animated gradient boxes using 24-bit RGB color sequences,
exercising terminal true-color support and synchronized update protocol.
"""

import sys
import math
import time
import os

VARIANT = int(os.environ.get("V", "0"))

ESC = "\033"
CSI = ESC + "["


def write(text):
    """Write text to stdout and flush immediately."""
    sys.stdout.buffer.write(text.encode())
    sys.stdout.buffer.flush()


def move_cursor(row, col):
    """Move cursor to the given row and column."""
    write(f"{CSI}{row};{col}H")


def background_color(red, green, blue):
    """Return an SGR sequence setting 24-bit background color."""
    return f"{CSI}48;2;{red};{green};{blue}m"


PI = math.pi

# Configuration per variant: (box_width, box_height, num_cols, num_rows, delay_ms, color_shift)
CONFIGS = [
    (50, 5, 2, 3, 30, 0),
    (55, 7, 2, 2, 20, 60),
    (25, 3, 3, 3, 40, 120),
    (100, 3, 1, 6, 25, 180),
    (20, 4, 4, 3, 15, 240),
]

TITLES = [
    "Standard Gradients",
    "Wide Warm Boxes",
    "Small Cool Grid",
    "Full-Width Bars",
    "Dense Rainbow Grid",
]

box_width, box_height, num_cols, num_rows, delay_ms, color_shift = CONFIGS[VARIANT]
num_boxes = num_cols * num_rows


def gradient_color(box_index, t):
    """Compute an RGB color for a gradient animation frame.

    Uses phase-shifted sine waves to produce smoothly cycling colors.
    """
    phase = (box_index * 360 / num_boxes + color_shift) * PI / 180
    red = int(128 + 127 * math.sin(t * PI * 2 + phase))
    green = int(128 + 127 * math.sin(t * PI * 2 + phase + PI * 2 / 3))
    blue = int(128 + 127 * math.sin(t * PI * 2 + phase + PI * 4 / 3))
    return (red, green, blue)


# Compute box positions (top-left corners)
box_positions = []
for row_idx in range(num_rows):
    for col_idx in range(num_cols):
        top = 3 + row_idx * (box_height + 3)
        left = 3 + col_idx * (box_width + 3)
        box_positions.append((top, left))

# Hide cursor and clear screen
write(f"{CSI}?25l{CSI}2J{CSI}H")

# Draw title
move_cursor(1, 3)
write(f"{CSI}38;2;255;255;100m{TITLES[VARIANT]} (variant {VARIANT + 1}/5){CSI}0m")

# Draw box labels
for i, (box_top, box_left) in enumerate(box_positions):
    move_cursor(box_top, box_left)
    write(f"{CSI}38;2;180;180;180m#{i + 1}{CSI}0m")

# Animate gradient frames
for frame in range(41):
    # Begin synchronized update
    write(f"{CSI}?2026h")

    for i, (box_top, box_left) in enumerate(box_positions):
        for row in range(box_height):
            move_cursor(box_top + 1 + row, box_left)
            line = ""
            for col in range(box_width):
                # Calculate gradient position with wave distortion
                t = ((col + (0 if frame == 40 else frame) * 2) % box_width) / box_width
                t = (t + math.sin(row * 0.6 + frame * 0.12) * 0.15) % 1
                red, green, blue = gradient_color(i, t)
                line += background_color(red, green, blue) + " "
            write(line + f"{CSI}0m")

    # End synchronized update
    write(f"{CSI}?2026l")

    if frame < 40:
        time.sleep(delay_ms / 1000)

# Position cursor below all boxes and show it again
final_row = 3 + num_rows * (box_height + 3) + 1
move_cursor(final_row, 1)
write(f"{CSI}?25h{CSI}0mDone.\n")
