"""
emoji_tables.py — Emoji table rendering test.

Draws three tables containing emoji characters to test terminal
handling of wide characters, ANSI color codes inside table cells,
and box-drawing alignment with mixed-width content.
"""

import re
import sys
import time

ESC = "\033"
CSI = ESC + "["


def write(text):
    """Write text to stdout and flush immediately."""
    sys.stdout.write(text)
    sys.stdout.flush()


def display_width(text):
    """Calculate the display width of a string.

    Emoji characters occupy 2 columns; all others occupy 1.
    """
    width = 0
    for char in text:
        code = ord(char)
        if code >= 0x1F000 or code in (0x26BD, 0x26BE):
            width += 2
        else:
            width += 1
    return width


# Box-drawing characters
BOX_TOP_LEFT = "\u250c"
BOX_TOP_RIGHT = "\u2510"
BOX_BOTTOM_LEFT = "\u2514"
BOX_BOTTOM_RIGHT = "\u2518"
BOX_HORIZONTAL = "\u2500"
BOX_VERTICAL = "\u2502"
BOX_T_DOWN = "\u252c"
BOX_T_UP = "\u2534"
BOX_T_RIGHT = "\u251c"
BOX_T_LEFT = "\u2524"
BOX_CROSS = "\u253c"


def table1():
    """Simple emoji table with varying counts per row."""
    write(f"{CSI}1;36mTable 1: Emoji counts{CSI}0m\n\n")

    rows = [
        ("1", "\U0001F355"),
        ("2", "\U0001F389 \U0001F31F"),
        ("3", "\U0001F436 \U0001F98A \U0001F438"),
        ("4", "\U0001F34E \U0001F34B \U0001F347 \U0001F353"),
    ]

    col1_width = 5
    col2_width = 20
    h1 = BOX_HORIZONTAL * col1_width
    h2 = BOX_HORIZONTAL * col2_width

    # Top border
    write(f"{BOX_TOP_LEFT}{BOX_HORIZONTAL}{h1}{BOX_T_DOWN}{BOX_HORIZONTAL}{h2}{BOX_TOP_RIGHT}\n")

    # Header row
    write(f"{BOX_VERTICAL} {'#':<{col1_width}}{BOX_VERTICAL} {'Item':<{col2_width}}{BOX_VERTICAL}\n")

    # Separator
    write(f"{BOX_T_RIGHT}{BOX_HORIZONTAL}{h1}{BOX_CROSS}{BOX_HORIZONTAL}{h2}{BOX_T_LEFT}\n")

    # Data rows
    for number, emojis in rows:
        padding = col2_width - display_width(emojis)
        write(f"{BOX_VERTICAL} {number:<{col1_width}}{BOX_VERTICAL} {emojis}{' ' * padding}{BOX_VERTICAL}\n")

    # Bottom border
    write(f"{BOX_BOTTOM_LEFT}{BOX_HORIZONTAL}{h1}{BOX_T_UP}{BOX_HORIZONTAL}{h2}{BOX_BOTTOM_RIGHT}\n")


def table2():
    """Mixed text and emoji with colored headers."""
    write(f"\n{CSI}1;33mTable 2: Status board{CSI}0m\n\n")

    headers = [("ID", 4), ("Name", 10), ("Status", 12), ("Notes", 16)]

    # Top border
    write(BOX_TOP_LEFT)
    for i, (_, col_width) in enumerate(headers):
        write(BOX_HORIZONTAL * (col_width + 2))
        write(BOX_T_DOWN if i < len(headers) - 1 else BOX_TOP_RIGHT)
    write("\n")

    # Header row
    write(BOX_VERTICAL)
    for name, col_width in headers:
        write(f" {CSI}1;37m{name:<{col_width}}{CSI}0m {BOX_VERTICAL}")
    write("\n")

    # Separator
    write(BOX_T_RIGHT)
    for i, (_, col_width) in enumerate(headers):
        write(BOX_HORIZONTAL * (col_width + 2))
        write(BOX_CROSS if i < len(headers) - 1 else BOX_T_LEFT)
    write("\n")

    # Data rows
    data = [
        ("1", "Alice", f"Active {CSI}32m\U0001F7E2{CSI}0m", "Top performer"),
        ("2", "Bob", f"Away {CSI}31m\U0001F534{CSI}0m", "On vacation"),
        ("3", "Charlie", f"Active {CSI}32m\U0001F7E2{CSI}0m", "New hire"),
        ("4", "Diana", f"Busy {CSI}33m\U0001F7E1{CSI}0m", f"Team lead \U0001F451"),
    ]

    for row in data:
        write(BOX_VERTICAL)
        for value, (_, col_width) in zip(row, headers):
            write(f" {value}")
            # Strip ANSI escape codes to calculate visible width
            visible_text = re.sub(r'\033\[[0-9;]*m', '', value)
            visible_width = display_width(visible_text)
            padding = col_width - visible_width + 1
            write(" " * padding if padding > 0 else " ")
            write(BOX_VERTICAL)
        write("\n")

    # Bottom border
    write(BOX_BOTTOM_LEFT)
    for i, (_, col_width) in enumerate(headers):
        write(BOX_HORIZONTAL * (col_width + 2))
        write(BOX_T_UP if i < len(headers) - 1 else BOX_BOTTOM_RIGHT)
    write("\n")


def table3():
    """Dense emoji grid to stress-test rendering."""
    write(f"\n{CSI}1;35mTable 3: Emoji grid{CSI}0m\n\n")

    grid = [
        ["\U0001F600", "\U0001F60E", "\U0001F914", "\U0001F631"],
        ["\U0001F525", "\U0001F4A7", "\U0001F338", "\U0001F340"],
        ["\U0001F680", "\U0001F682", "\U0001F681", "\U0001F6F8"],
        ["\u26BD", "\U0001F3C0", "\U0001F3BE", "\U0001F3C8"],
    ]

    cell_width = 4
    num_columns = len(grid[0])

    # Top border
    write(BOX_TOP_LEFT)
    for i in range(num_columns):
        write(BOX_HORIZONTAL * (cell_width + 2))
        write(BOX_T_DOWN if i < num_columns - 1 else BOX_TOP_RIGHT)
    write("\n")

    # Grid rows
    for row in grid:
        write(BOX_VERTICAL)
        for emoji in row:
            emoji_width = display_width(emoji)
            padding = cell_width + 2 - 1 - emoji_width
            write(f" {emoji}{' ' * padding}{BOX_VERTICAL}")
        write("\n")

    # Bottom border
    write(BOX_BOTTOM_LEFT)
    for i in range(num_columns):
        write(BOX_HORIZONTAL * (cell_width + 2))
        write(BOX_T_UP if i < num_columns - 1 else BOX_BOTTOM_RIGHT)
    write("\n")


# Run all tables
time.sleep(0.5)
write(f"{CSI}2J{CSI}H")
table1()
table2()
table3()
write(f"\n{CSI}1;32mDone.{CSI}0m\n")
