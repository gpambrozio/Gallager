#!/usr/bin/env python3
"""
term-stress: Terminal rendering stress test suite.

Exercises the escape sequences and rendering edge cases that TUI apps
like Claude Code, vim, htop, and ratatui-based apps use. Useful for:
  - Verifying terminal emulator correctness
  - Stress-testing terminal recording tools (asciinema, script, tmux-rec)
  - Identifying rendering bugs in terminal emulators
  - Benchmarking terminal throughput

Usage:
  term-stress                   Run all tests interactively
  term-stress --auto            Run all tests automatically (no pauses)
  term-stress --auto -s 0.5     Auto mode, 0.5s between tests
  term-stress --list            List available tests
  term-stress --test 5,8,12     Run specific tests by number
  term-stress --bench           Throughput benchmark only
"""

import sys
import os
import time
import random
import argparse
import shutil

# ─── Low-level output ─────────────────────────────────────────────────

def w(s):
    """Write string directly to stdout (no Python buffering)."""
    sys.stdout.buffer.write(s.encode() if isinstance(s, str) else s)
    sys.stdout.buffer.flush()

def wb(b):
    """Write raw bytes."""
    sys.stdout.buffer.write(b)
    sys.stdout.buffer.flush()

# ─── ANSI primitives ─────────────────────────────────────────────────

ESC = "\033"
CSI = f"{ESC}["
OSC = f"{ESC}]"
ST  = f"{ESC}\\"

def csi(code):           w(f"{CSI}{code}")
def sgr(code):           w(f"{CSI}{code}m")
def cup(row, col):       w(f"{CSI}{row};{col}H")
def cuu(n=1):            w(f"{CSI}{n}A")
def cud(n=1):            w(f"{CSI}{n}B")
def cuf(n=1):            w(f"{CSI}{n}C")
def cub(n=1):            w(f"{CSI}{n}D")
def el(n=0):             w(f"{CSI}{n}K")
def ed(n=0):             w(f"{CSI}{n}J")
def dsr():               w(f"{CSI}6n")          # device status report
def decsc():             w(f"{ESC}7")            # save cursor (DEC)
def decrc():             w(f"{ESC}8")            # restore cursor (DEC)
def decstbm(top, bot):   w(f"{CSI}{top};{bot}r") # scroll region
def decstbm_reset():     w(f"{CSI}r")            # reset scroll region
def hide_cursor():       w(f"{CSI}?25l")
def show_cursor():       w(f"{CSI}?25h")
def alt_screen():        w(f"{CSI}?1049h")
def main_screen():       w(f"{CSI}?1049l")
def reset_all():         w(f"{CSI}0m")
def clear():             w(f"{CSI}2J{CSI}H")
def save_cursor():       w(f"{CSI}s")
def restore_cursor():    w(f"{CSI}u")

def fg(r, g, b):         return f"{CSI}38;2;{r};{g};{b}m"
def bg(r, g, b):         return f"{CSI}48;2;{r};{g};{b}m"
def fg256(n):            return f"{CSI}38;5;{n}m"
def bg256(n):            return f"{CSI}48;5;{n}m"
def fg16(n):             return f"{CSI}{n}m"

# ─── Helpers ──────────────────────────────────────────────────────────

def get_term_size():
    return shutil.get_terminal_size((80, 24))

def banner(title, desc=""):
    cols, rows = get_term_size()
    clear()
    sgr("1;36")
    w("─" * cols + "\n")
    w(f"  {title}\n")
    if desc:
        sgr("0;90")
        w(f"  {desc}\n")
    sgr("1;36")
    w("─" * cols + "\n")
    reset_all()
    w("\n")

def pause(auto_mode, delay):
    if auto_mode:
        time.sleep(delay)
    else:
        sgr("90")
        w("\n  Press Enter to continue...")
        reset_all()
        try:
            input()
        except (EOFError, KeyboardInterrupt):
            show_cursor()
            reset_all()
            decstbm_reset()
            w("\n")
            sys.exit(0)

# ─── Test catalog ─────────────────────────────────────────────────────

TESTS = []

def test(name, desc=""):
    def decorator(fn):
        TESTS.append({"name": name, "desc": desc, "fn": fn})
        return fn
    return decorator


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# TEST 1: SGR Text Attributes
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@test("SGR text attributes",
      "Bold, dim, italic, underline, blink, reverse, hidden, strikethrough")
def test_sgr_attributes(auto, delay):
    banner("SGR Text Attributes",
           "Each line should show the named style. 'Hidden' should be invisible.")

    attrs = [
        (1, "Bold"),
        (2, "Dim / faint"),
        (3, "Italic"),
        (4, "Underline"),
        (5, "Blink (slow)"),
        (7, "Reverse video"),
        (8, "Hidden (should be invisible → ) ←"),
        (9, "Strikethrough"),
        (21, "Double underline (if supported)"),
        (53, "Overline (if supported)"),
    ]
    for code, label in attrs:
        w(f"  {CSI}{code}m{label}{CSI}0m\n")

    # Combinations
    w(f"\n  Combined: {CSI}1;3;4m Bold+Italic+Underline {CSI}0m\n")
    w(f"  Combined: {CSI}1;9;38;5;196m Bold+Strike+Red {CSI}0m\n")
    w(f"  Combined: {CSI}2;3;4;7m Dim+Italic+Underline+Reverse {CSI}0m\n")

    # Selective resets
    w(f"\n  Selective reset: {CSI}1;3;4mBold+Italic+Underline")
    w(f" → {CSI}22mremove bold")
    w(f" → {CSI}23mremove italic")
    w(f" → {CSI}24mremove underline{CSI}0m\n")

    pause(auto, delay)


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# TEST 2: 16-color palette
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@test("16-color palette",
      "Standard and bright foreground/background colors (SGR 30-37, 90-97)")
def test_16_colors(auto, delay):
    banner("16-Color Palette")

    names = ["Black","Red","Green","Yellow","Blue","Magenta","Cyan","White"]

    w("  Foreground (normal):  ")
    for i in range(8):
        w(f"{CSI}{30+i}m {names[i][:3]} ")
    reset_all()

    w("\n  Foreground (bright):  ")
    for i in range(8):
        w(f"{CSI}{90+i}m {names[i][:3]} ")
    reset_all()

    w("\n\n  Background (normal):  ")
    for i in range(8):
        fg_c = "37" if i in (0,1,4,5) else "30"
        w(f"{CSI}{40+i};{fg_c}m {names[i][:3]} ")
    reset_all()

    w("\n  Background (bright):  ")
    for i in range(8):
        fg_c = "30"
        w(f"{CSI}{100+i};{fg_c}m {names[i][:3]} ")
    reset_all()
    w("\n")

    pause(auto, delay)


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# TEST 3: 256-color palette
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@test("256-color palette",
      "Full 256-color table: 16 standard + 216 cube + 24 grayscale")
def test_256_colors(auto, delay):
    banner("256-Color Palette")

    # Standard 16
    w("  Standard 16:\n  ")
    for i in range(16):
        w(f"{bg256(i)}  {CSI}0m")
        if i == 7:
            w("\n  ")
    w("\n\n")

    # 6×6×6 color cube
    w("  6×6×6 Color Cube (indices 16-231):\n")
    for green in range(6):
        w("  ")
        for red in range(6):
            for blue in range(6):
                idx = 16 + red * 36 + green * 6 + blue
                w(f"{bg256(idx)} ")
            w(" ")
        w(f"{CSI}0m\n")
    w("\n")

    # Grayscale ramp
    w("  Grayscale ramp (232-255):\n  ")
    for i in range(232, 256):
        w(f"{bg256(i)}  ")
    w(f"{CSI}0m\n")

    pause(auto, delay)


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# TEST 4: Truecolor (24-bit) gradients
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@test("Truecolor (24-bit) gradients",
      "Smooth gradients using ESC[38;2;R;G;Bm — should show no banding")
def test_truecolor(auto, delay):
    cols, _ = get_term_size()
    banner("Truecolor (24-bit) Gradients",
           f"Each row is {cols} distinct colors. Banding = no truecolor support.")

    width = cols - 4
    # Red → Yellow → Green → Cyan → Blue → Magenta → Red
    w("  Rainbow:\n  ")
    for i in range(width):
        hue = i / width * 360
        # HSV to RGB, S=1, V=1
        h = hue / 60
        x = 1 - abs(h % 2 - 1)
        if   h < 1: r, g, b = 1, x, 0
        elif h < 2: r, g, b = x, 1, 0
        elif h < 3: r, g, b = 0, 1, x
        elif h < 4: r, g, b = 0, x, 1
        elif h < 5: r, g, b = x, 0, 1
        else:       r, g, b = 1, 0, x
        w(f"{bg(int(r*255), int(g*255), int(b*255))} ")
    reset_all()

    # Grayscale
    w("\n\n  Grayscale:\n  ")
    for i in range(width):
        v = int(i / width * 255)
        w(f"{bg(v, v, v)} ")
    reset_all()

    # Red channel
    w("\n\n  Red channel:\n  ")
    for i in range(width):
        v = int(i / width * 255)
        w(f"{bg(v, 0, 0)} ")
    reset_all()

    # Foreground gradient text
    w("\n\n  Foreground gradient text:\n  ")
    text = "The quick brown fox jumps over the lazy dog — ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    for i, ch in enumerate(text):
        t = i / len(text)
        r = int((1-t) * 255)
        g = int(t * 128)
        b = int(t * 255)
        w(f"{fg(r, g, b)}{ch}")
    reset_all()
    w("\n")

    pause(auto, delay)


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# TEST 5: Cursor movement and positioning
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@test("Cursor movement and absolute positioning",
      "CUP, CUU, CUD, CUF, CUB, save/restore, drawing at arbitrary positions")
def test_cursor_movement(auto, delay):
    cols, rows = get_term_size()
    banner("Cursor Movement")

    # Draw a box at specific coordinates using absolute positioning
    w("  Drawing a box using CUP (absolute positioning):\n\n")
    box_r, box_c = 7, 10
    box_w, box_h = 30, 8

    # Top edge
    cup(box_r, box_c)
    sgr("1;33")
    w("┌" + "─" * (box_w - 2) + "┐")
    # Sides + content
    for i in range(1, box_h - 1):
        cup(box_r + i, box_c)
        w("│")
        cup(box_r + i, box_c + box_w - 1)
        w("│")
    # Bottom edge
    cup(box_r + box_h - 1, box_c)
    w("└" + "─" * (box_w - 2) + "┘")

    # Write centered text inside the box
    label = "CUP positioning works!"
    cup(box_r + 3, box_c + (box_w - len(label)) // 2)
    sgr("1;36")
    w(label)
    reset_all()

    # Demonstrate relative movement
    cup(box_r + box_h + 1, 3)
    w("  Relative movement test: START")
    cuu(1)
    cuf(2)
    sgr("32")
    w("↑1 →2")
    cud(2)
    cub(4)
    w("↓2 ←4")
    reset_all()

    # DEC save/restore
    cup(box_r + box_h + 4, 3)
    w("  Save/restore cursor (DEC): ")
    decsc()
    w("SAVED HERE")
    cup(box_r + box_h + 5, 3)
    w("  (wrote on another line)")
    decrc()
    sgr("1;31")
    w(" ← restored!")
    reset_all()

    cup(box_r + box_h + 7, 1)
    pause(auto, delay)


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# TEST 6: Line editing and erasure
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@test("Line editing and erasure",
      "EL (erase in line), ED (erase in display), ICH, DCH, IL, DL")
def test_line_editing(auto, delay):
    banner("Line Editing & Erasure")

    # Erase in line
    w("  EL 0 (erase cursor→end):  XXXX")
    cub(4)
    csi("0K")
    w(" ← should be blank after X\n")

    w("  EL 1 (erase start→cursor): ")
    w("VISIBLE")
    cub(3)
    csi("1K")
    cuf(3)
    w(" ← 'VISI' should be erased\n")

    w("  EL 2 (erase whole line):   ")
    decsc()
    w("THIS SHOULD VANISH")
    csi("2K")
    decrc()
    w("Replaced!\n")

    # Insert/delete characters
    w("\n  ICH (insert characters): abcfgh → ")
    w("abcfgh")
    cub(3)
    csi("3@")  # insert 3 blanks
    w("de ")
    w(" ← should be 'abcde fgh' (shifted right)\n")

    # DCH (delete characters)
    w("  DCH (delete characters): abcXXXfg → ")
    w("abcXXXfg")
    cub(5)
    csi("3P")  # delete 3 chars
    w("   ← should be 'abcfg'\n")

    # Insert line / delete line
    w("\n  IL/DL (insert/delete lines):\n")
    w("  Line A\n  Line B\n  Line C\n  Line D\n")
    cuu(3)
    w("\r")
    csi("1L")  # insert 1 line
    w("  → Inserted line (between A and B)")
    cud(4)
    w("\n")

    pause(auto, delay)


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# TEST 7: Scroll regions (DECSTBM)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@test("Scroll regions (DECSTBM)",
      "Fixed header/footer with independently scrolling content area")
def test_scroll_regions(auto, delay):
    cols, rows = get_term_size()
    clear()

    # Fixed header (rows 1-3)
    cup(1, 1)
    sgr("1;37;44")
    w(" " * cols)
    cup(1, 1)
    w("  ┌─ FIXED HEADER ─" + "─" * (cols - 21) + "┐")
    cup(2, 1)
    w(f"  │ This stays pinned while content scrolls below{' ' * (cols - 52)}│")
    cup(3, 1)
    w("  └" + "─" * (cols - 4) + "┘")
    reset_all()

    # Fixed footer (rows rows-2 to rows)
    cup(rows - 2, 1)
    sgr("1;37;42")
    w("  ┌" + "─" * (cols - 4) + "┐")
    cup(rows - 1, 1)
    w(f"  │ FIXED FOOTER — status bar area{' ' * (cols - 36)}│")
    cup(rows, 1)
    w("  └" + "─" * (cols - 4) + "┘")
    reset_all()

    # Set scroll region to the middle
    top_margin = 4
    bot_margin = rows - 3
    decstbm(top_margin, bot_margin)

    # Scroll content through the region
    cup(top_margin, 1)
    for i in range(1, (bot_margin - top_margin) + 20):
        cup(bot_margin, 1)
        hue = (i * 15) % 360
        h = hue / 60
        x = 1 - abs(h % 2 - 1)
        if   h < 1: r, g, b = 1, x, 0
        elif h < 2: r, g, b = x, 1, 0
        elif h < 3: r, g, b = 0, 1, x
        elif h < 4: r, g, b = 0, x, 1
        elif h < 5: r, g, b = x, 0, 1
        else:       r, g, b = 1, 0, x
        w(f"{fg(int(r*255), int(g*255), int(b*255))}")
        w(f"    Scrolling line {i:3d} — content scrolls, header/footer stay fixed")
        reset_all()
        w("\n")
        time.sleep(0.06)

    # Reset scroll region
    decstbm_reset()
    cup(rows, 1)
    pause(auto, delay)


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# TEST 8: Alternate screen buffer
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@test("Alternate screen buffer",
      "Switches to alt screen, draws content, switches back (like vim/less)")
def test_alt_screen(auto, delay):
    cols, rows = get_term_size()

    # Leave a message on the main screen
    w("  This text is on the MAIN screen. It should reappear after the test.\n")
    w("  Switching to alternate screen in 1 second...\n")
    time.sleep(1)

    # Enter alt screen
    alt_screen()
    clear()
    hide_cursor()

    # Draw a full-screen pattern
    sgr("1;33")
    cup(1, 1)
    w("╔" + "═" * (cols - 2) + "╗")
    for r in range(2, rows):
        cup(r, 1)
        w("║")
        cup(r, cols)
        w("║")
    cup(rows, 1)
    w("╚" + "═" * (cols - 2) + "╝")

    label = " ALTERNATE SCREEN BUFFER "
    cup(rows // 2, (cols - len(label)) // 2)
    sgr("1;37;41")
    w(label)
    reset_all()

    cup(rows // 2 + 2, (cols - 50) // 2)
    sgr("36")
    w("This content exists ONLY in the alternate buffer.")
    cup(rows // 2 + 3, (cols - 50) // 2)
    w("When we exit, the main screen should be restored.")
    reset_all()

    cup(rows - 2, (cols - 40) // 2)
    sgr("90")
    w("Returning to main screen in 2 seconds...")
    reset_all()
    time.sleep(2)

    # Exit alt screen
    show_cursor()
    main_screen()

    w("  ✓ Back on main screen! Previous content should be intact above.\n")
    pause(auto, delay)


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# TEST 9: Unicode and wide characters
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@test("Unicode, wide chars, and grapheme clusters",
      "CJK, emoji, combining marks, ZWJ sequences, RTL")
def test_unicode(auto, delay):
    banner("Unicode & Wide Characters",
           "Tests character width calculation — misalignment = width bug")

    # Box-drawing alignment test
    w("  Box-drawing alignment:\n")
    w("  ┌──────────┬──────────┐\n")
    w("  │ ASCII    │ 12345678 │\n")
    w("  │ CJK      │ 漢字日本語  │\n")
    w("  │ Hiragana  │ あいうえお  │\n")
    w("  │ Hangul   │ 한국어텍스트 │\n")
    w("  └──────────┴──────────┘\n")

    # Emoji (should be double-width)
    w("\n  Emoji (double-width):\n")
    w("  |🎉|🚀|🔥|💻|🎨|🌍|⚡|✨|  ← each should fill 2 columns\n")

    # ZWJ sequences (complex grapheme clusters)
    w("\n  ZWJ sequences (rendered as single glyph if supported):\n")
    w("  👨‍💻 (coder)  👩‍🔬 (scientist)  🏳️‍🌈 (flag)  👨‍👩‍👧‍👦 (family)\n")

    # Skin tone modifiers
    w("\n  Skin tone modifiers:\n")
    w("  👋🏻 👋🏼 👋🏽 👋🏾 👋🏿  ← five skin tones of wave\n")

    # Combining characters
    w("\n  Combining diacritical marks:\n")
    w("  a\u0301 = á    e\u0308 = ë    o\u0303 = õ    n\u0327 = ņ\n")
    w("  Stacked: a\u0301\u0302\u0303\u0304  (a + acute + circumflex + tilde + macron)\n")

    # Variation selectors
    w("\n  Variation selectors (text vs emoji presentation):\n")
    w("  ☺\uFE0E (text)  ☺\uFE0F (emoji)    ♠\uFE0E (text)  ♠\uFE0F (emoji)\n")

    # Right-to-left (if supported)
    w("\n  Bidirectional text:\n")
    w("  English مرحبا English  ← Arabic should flow RTL\n")
    w("  English שלום English   ← Hebrew should flow RTL\n")

    # Zero-width characters
    w("\n  Zero-width chars (should be invisible):\n")
    w("  AB\u200BCD  (zero-width space between B and C)\n")
    w("  AB\uFEFFCD  (BOM / zero-width no-break space)\n")

    pause(auto, delay)


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# TEST 10: Line-drawing and special characters
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@test("Box-drawing and special characters",
      "Line-drawing, block elements, Braille, math symbols")
def test_box_drawing(auto, delay):
    banner("Box Drawing & Special Characters")

    # Light box
    w("  Light box:  ┌─────┐    Double box:  ╔═════╗\n")
    w("              │     │                 ║     ║\n")
    w("              └─────┘                 ╚═════╝\n")

    # Rounded corners (if font supports)
    w("\n  Rounded:    ╭─────╮    Heavy:       ┏━━━━━┓\n")
    w("              │     │                 ┃     ┃\n")
    w("              ╰─────╯                 ┗━━━━━┛\n")

    # Mixed intersections
    w("\n  Intersections: ┬ ┴ ├ ┤ ┼ ╦ ╩ ╠ ╣ ╬ ╥ ╨ ╫ ╪\n")

    # Block elements (progress bars, charts)
    w("\n  Block elements (progress bar):\n")
    w("  ██████████████████░░░░░░░░░░  60%\n")
    w("  ▓▓▓▓▓▓▓▓▓▓▒▒▒▒▒▒▒░░░░░░░░░░  33%\n")

    # Partial blocks
    w("\n  Partial blocks: ▏▎▍▌▋▊▉█  (1/8 to full)\n")
    w("  Upper/lower:    ▀▄  Quadrants: ▘▝▖▗▚▞\n")

    # Braille patterns (used by graphing tools)
    w("\n  Braille sparkline: ")
    braille = "⠀⠁⠂⠃⠄⠅⠆⠇⡀⡁⡂⡃⡄⡅⡆⡇⠈⠉⠊⠋⠌⠍⠎⠏⡈⡉⡊⡋⡌⡍⡎⡏"
    for ch in braille[:30]:
        w(ch)
    w("\n")

    # Powerline / Nerd Font symbols (common in modern prompts)
    w("\n  Powerline/Nerd symbols (need patched font):\n")
    w("  \ue0b0 \ue0b1 \ue0b2 \ue0b3 \ue0a0 \ue0a1 \ue0a2  \n")

    # Mathematical symbols
    w("\n  Math: ∀x∈ℝ: x² ≥ 0  ∑∏∫∂√∞≈≠≤≥±÷×  π≈3.14159  ℕ⊂ℤ⊂ℚ⊂ℝ⊂ℂ\n")

    pause(auto, delay)


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# TEST 11: Rapid cursor movement (animation)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@test("Spinner and progress animation",
      "Tests rapid in-place rewriting at 20+ fps")
def test_animation(auto, delay):
    cols, rows = get_term_size()
    banner("Animation Stress Test")

    hide_cursor()

    # Spinner animation
    spinners = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
    w("  Spinner: ")
    decsc()
    for frame in range(60):
        decrc()
        ch = spinners[frame % len(spinners)]
        sgr("1;36")
        w(f" {ch} ")
        sgr("0;90")
        w(f" frame {frame+1:3d}/60")
        reset_all()
        time.sleep(0.04)
    decrc()
    w(" ✓ done         \n\n")

    # Progress bar animation
    bar_width = min(50, cols - 20)
    w("  Progress: ")
    decsc()
    for pct in range(101):
        decrc()
        filled = int(pct / 100 * bar_width)
        empty  = bar_width - filled
        sgr("32")
        w("█" * filled)
        sgr("90")
        w("░" * empty)
        reset_all()
        w(f" {pct:3d}%")
        time.sleep(0.02)
    w("\n\n")

    # Bouncing ball
    w("  Bouncing ball:\n")
    ball_row_base = 12
    track_width = min(60, cols - 10)
    for frame in range(80):
        pos = frame % (track_width * 2)
        if pos >= track_width:
            pos = track_width * 2 - pos
        cup(ball_row_base, 5)
        el(2)
        w(" " * pos)
        # Color shifts as it moves
        r = int(pos / track_width * 255)
        b = 255 - r
        w(f"{fg(r, 128, b)}●")
        reset_all()
        time.sleep(0.03)

    cup(ball_row_base + 2, 1)
    show_cursor()
    pause(auto, delay)


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# TEST 12: Autowrap and long lines
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@test("Autowrap and edge-of-screen behavior",
      "Tests DECAWM — what happens at column 80/132, long lines, wrap semantics")
def test_autowrap(auto, delay):
    cols, rows = get_term_size()
    banner("Autowrap & Edge Behavior",
           f"Terminal is {cols} columns wide")

    # Fill exactly one row — cursor should be at last column, NOT wrapped yet
    w("  Exact-width fill (should NOT wrap to next line yet):\n")
    w("  ")
    sgr("43;30")
    w("X" * (cols - 2))
    reset_all()
    w("\n  ↑ The Xs should fill exactly one line\n\n")

    # Fill one row + 1 char — should wrap
    w("  One char past edge (should wrap):\n")
    w("  ")
    sgr("44;37")
    w("Y" * (cols - 2))
    sgr("41;37")
    w("Z")  # this one wraps
    reset_all()
    w("\n  ↑ 'Z' (red bg) should be at start of next line\n\n")

    # Very long line
    w("  Long unbroken line (3× terminal width):\n  ")
    sgr("90")
    for i in range(cols * 3):
        w(str(i % 10))
    reset_all()
    w("\n  ↑ Should wrap cleanly across 3 lines\n")

    pause(auto, delay)


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# TEST 13: Tab stops
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@test("Tab stops (HT, HTS, TBC)",
      "Default tab stops at every 8 columns, custom tab stops")
def test_tabs(auto, delay):
    banner("Tab Stops")

    w("  Default tabs (every 8 columns):\n")
    w("  ")
    for i in range(8):
        w(f"{i}\t")
    w("\n")

    # Ruler
    cols = get_term_size()[0]
    w("  ")
    for i in range(min(cols - 4, 80)):
        w(str(i % 10))
    w("\n  ")
    for i in range(min(cols - 4, 80)):
        w("·" if i % 8 == 0 else " ")
    w("  ← tab stops\n")

    # Tab with content alignment
    w("\n  Tab-aligned table:\n")
    w("  Name\tAge\tCity\tScore\n")
    w("  Alice\t28\tNYC\t98.5\n")
    w("  Bob\t35\tSF\t87.2\n")
    w("  Charlie\t22\tLA\t95.0\n")

    pause(auto, delay)


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# TEST 14: Reverse index and scroll down
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@test("Reverse index (RI) and bidirectional scrolling",
      "ESC M scrolls down (inserts line at top) — used by TUI apps for upward scroll")
def test_reverse_index(auto, delay):
    cols, rows = get_term_size()
    clear()
    hide_cursor()

    # Set up a scroll region
    top = 3
    bot = rows - 3
    decstbm(top, bot)

    # Fill the region with numbered lines
    for i in range(bot - top + 1):
        cup(top + i, 1)
        sgr("90")
        w(f"  Line {i+1:3d}")
        reset_all()

    cup(1, 1)
    sgr("1;33")
    w(f"  Reverse Index test — scrolling DOWN (inserting at top of region)")
    reset_all()

    time.sleep(0.5)

    # Reverse-scroll: move cursor to top of region and issue RI
    for i in range(15):
        cup(top, 1)
        w(f"{ESC}M")  # RI: reverse index
        cup(top, 1)
        sgr("1;32")
        w(f"  ↓ Inserted line {i+1:2d} at top ↓")
        reset_all()
        time.sleep(0.12)

    time.sleep(0.3)

    # Now scroll up (normal)
    cup(1, 1)
    el(2)
    sgr("1;33")
    w(f"  Now scrolling UP (normal) through the region")
    reset_all()

    for i in range(15):
        cup(bot, 1)
        sgr("1;36")
        w(f"  ↑ Appended line {i+1:2d} at bottom ↑")
        reset_all()
        w("\n")
        time.sleep(0.12)

    decstbm_reset()
    show_cursor()
    cup(rows, 1)
    pause(auto, delay)


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# TEST 15: Cursor visibility and shapes
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@test("Cursor visibility and shapes",
      "DECTCEM (show/hide) and DECSCUSR (cursor shape: block, underline, bar)")
def test_cursor_shapes(auto, delay):
    banner("Cursor Shapes & Visibility")

    shapes = [
        (1, "Blinking block"),
        (2, "Steady block"),
        (3, "Blinking underline"),
        (4, "Steady underline"),
        (5, "Blinking bar (I-beam)"),
        (6, "Steady bar (I-beam)"),
    ]

    for code, name in shapes:
        w(f"  DECSCUSR {code}: {name}  ")
        w(f"{CSI}{code} q")  # set cursor shape
        time.sleep(1 if not auto else 0.4)
        w("← cursor here\n")

    # Hide/show
    w(f"\n  Hiding cursor for 1.5 seconds...")
    hide_cursor()
    time.sleep(1.5)
    show_cursor()
    w(" visible again!\n")

    # Reset to default
    w(f"{CSI}0 q")  # reset cursor shape
    pause(auto, delay)


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# TEST 16: Synchronized output (DEC mode 2026)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@test("Synchronized output (mode 2026)",
      "Frame buffering to prevent tearing — used by Claude Code, ratatui")
def test_sync_output(auto, delay):
    cols, rows = get_term_size()
    banner("Synchronized Output (Mode 2026)",
           "First WITHOUT sync (may flicker), then WITH sync (should be smooth)")

    hide_cursor()
    time.sleep(0.5)

    # ── Without synchronized output ──
    cup(7, 3)
    sgr("1;33")
    w("Without synchronized output:")
    reset_all()

    for frame in range(40):
        for r in range(9, 14):
            cup(r, 5)
            for c in range(50):
                v = int(128 + 127 * __import__('math').sin((c + frame * 3) / 8))
                w(f"{bg(v, 50, 255-v)} ")
            reset_all()
        time.sleep(0.03)

    # ── With synchronized output ──
    cup(16, 3)
    sgr("1;32")
    w("With synchronized output (mode 2026):")
    reset_all()

    for frame in range(40):
        w(f"{CSI}?2026h")  # begin sync
        for r in range(18, 23):
            cup(r, 5)
            for c in range(50):
                v = int(128 + 127 * __import__('math').sin((c + frame * 3) / 8))
                w(f"{bg(v, 50, 255-v)} ")
            reset_all()
        w(f"{CSI}?2026l")  # end sync
        time.sleep(0.03)

    show_cursor()
    cup(rows - 1, 1)
    pause(auto, delay)


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# TEST 17: Rapid full-screen rewrite (throughput stress)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@test("Full-screen repaint throughput",
      "Repaints the entire screen 30 times — measures byte throughput")
def test_throughput(auto, delay):
    cols, rows = get_term_size()
    hide_cursor()

    total_bytes = 0
    frames = 30
    start = time.monotonic()

    for frame in range(frames):
        # Begin sync
        w(f"{CSI}?2026h")
        cup(1, 1)

        for r in range(1, rows + 1):
            buf = []
            for c in range(1, cols + 1):
                # Animated colored pattern
                rv = int(128 + 127 * __import__('math').sin((c + frame * 4) / 12))
                gv = int(128 + 127 * __import__('math').sin((r + frame * 3) / 8))
                bv = int(128 + 127 * __import__('math').cos((c + r + frame * 5) / 15))
                buf.append(f"\033[48;2;{rv};{gv};{bv}m ")
            line = "".join(buf)
            total_bytes += len(line)
            w(line)

        # Stats overlay
        elapsed = time.monotonic() - start
        fps = (frame + 1) / elapsed if elapsed > 0 else 0
        cup(1, 2)
        sgr("1;37;40")
        w(f" Frame {frame+1}/{frames}  FPS: {fps:.1f}  Bytes: {total_bytes:,} ")
        reset_all()

        # End sync
        w(f"{CSI}?2026l")

    elapsed = time.monotonic() - start
    show_cursor()
    clear()

    banner("Throughput Results")
    fps = frames / elapsed
    mbps = total_bytes / elapsed / 1024 / 1024
    w(f"  Frames:     {frames}\n")
    w(f"  Time:       {elapsed:.2f}s\n")
    w(f"  FPS:        {fps:.1f}\n")
    w(f"  Total data: {total_bytes:,} bytes ({total_bytes/1024/1024:.1f} MB)\n")
    w(f"  Throughput: {mbps:.1f} MB/s\n")
    w(f"  Per frame:  {total_bytes/frames/1024:.0f} KB\n")

    pause(auto, delay)


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# TEST 18: Overwrite and carriage return patterns
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@test("Carriage return overwrite patterns",
      "\\r-based overwriting used by progress bars, pip, cargo, etc.")
def test_cr_overwrite(auto, delay):
    banner("Carriage Return Overwrite",
           "Common pattern: \\r to return to start of line, overwrite in place")

    w("  Countdown: ")
    for i in range(10, 0, -1):
        w(f"\r  Countdown: {CSI}1;33m{i:2d}{CSI}0m ")
        time.sleep(0.3)
    w(f"\r  Countdown: {CSI}1;32mdone!{CSI}0m\n")

    # pip-style download progress
    w("\n  pip-style download:\n")
    for pct in range(0, 101, 5):
        bar_w = 30
        filled = int(pct / 100 * bar_w)
        bar = "━" * filled + "╺" + "─" * (bar_w - filled - 1)
        w(f"\r  Downloading... {bar}  {pct:3d}%  {pct * 1.2:.0f} kB")
        time.sleep(0.08)
    w(f"\r  {CSI}2K\r  Downloaded 120 kB ✓\n")

    # Multi-line overwrite using cursor-up
    w("\n  Multi-line overwrite (cursor-up pattern):\n")
    w("  Status: ...\n  Speed:  ...\n  ETA:    ...\n")
    for i in range(20):
        cuu(3)
        w(f"\r  Status: {CSI}33m{'Processing' if i % 2 else 'Computing '}{CSI}0m {'.' * (i % 4 + 1)}   \n")
        w(f"\r  Speed:  {CSI}36m{random.randint(50,200)} items/s{CSI}0m   \n")
        w(f"\r  ETA:    {CSI}90m{20-i}s remaining{CSI}0m   \n")
        time.sleep(0.15)

    pause(auto, delay)


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# TEST 19: OSC sequences (window title, hyperlinks)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@test("OSC sequences (title, hyperlinks, clipboard)",
      "Operating System Commands for window title and clickable URLs")
def test_osc(auto, delay):
    banner("OSC Sequences")

    # Set window title
    w(f"  Setting window title to 'term-stress test'...\n")
    w(f"{OSC}0;term-stress test{ST}")
    w(f"  (Check your terminal's title bar)\n\n")

    # OSC 8 hyperlinks
    w(f"  OSC 8 hyperlinks (clickable if your terminal supports it):\n")
    url = "https://github.com"
    w(f"  Click here: {OSC}8;;{url}{ST}{CSI}4;34mGitHub{CSI}0m{OSC}8;;{ST}\n")
    url2 = "https://docs.python.org"
    w(f"  Or here:    {OSC}8;;{url2}{ST}{CSI}4;34mPython Docs{CSI}0m{OSC}8;;{ST}\n")

    # Notification (OSC 9 / OSC 777 in some terminals)
    w(f"\n  OSC 9 notification (if supported):\n")
    w(f"  {OSC}9;Test notification from term-stress{ST}")
    w(f"  (Sent notification — may appear in system tray)\n")

    pause(auto, delay)


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# TEST 20: Color on erase (BCE behavior)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@test("Background Color Erase (BCE)",
      "Do EL/ED/scroll operations preserve the current background color?")
def test_bce(auto, delay):
    banner("Background Color Erase (BCE)",
           "Tests whether cleared regions use the current bg color or default bg")

    # Set a background color and clear the line
    w("  1. Set bg to blue, then EL 2 (erase whole line):\n")
    sgr("44")
    w("  This line has blue background")
    csi("2K")
    w("  ← entire line should be blue (if BCE is on)")
    reset_all()
    w("\n\n")

    # Scroll with background color
    w("  2. Set bg to green, then scroll:\n")
    w("     (New blank lines from scroll should be green if BCE)\n")
    sgr("42")
    for i in range(3):
        w(f"  Green bg scroll line {i+1}\n")
    reset_all()
    w("\n")

    # ED with background color
    w("  3. Set bg to red, then ED 0 (erase to end of screen):\n")
    sgr("41")
    w("  Everything below should be red if BCE is supported")
    csi("0J")
    reset_all()

    # Move down past the cleared area
    w("\n\n\n\n")
    w("  (If you see colored backgrounds above, BCE is working)\n")

    pause(auto, delay)


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# TEST 21: Rapid alternating content (flicker test)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@test("Flicker / tearing detection",
      "Rapidly alternates two patterns — tearing appears as mixed frames")
def test_flicker(auto, delay):
    cols, rows = get_term_size()
    clear()
    hide_cursor()

    cup(1, 3)
    sgr("1;33")
    w("Flicker Test — watch for tearing (mixed A/B patterns)")
    reset_all()
    cup(2, 3)
    sgr("90")
    w("With sync output, frames should be clean. Without, you may see tearing.")
    reset_all()

    region_top = 4
    region_h = min(16, rows - 6)
    region_w = min(60, cols - 4)

    for frame in range(60):
        w(f"{CSI}?2026h")  # sync begin
        if frame % 2 == 0:
            ch = "A"
            color = "41;37"  # white on red
        else:
            ch = "B"
            color = "44;37"  # white on blue

        for r in range(region_h):
            cup(region_top + r, 3)
            sgr(color)
            w(ch * region_w)
            reset_all()

        cup(region_top + region_h + 1, 3)
        reset_all()
        w(f"  Frame {frame+1:3d}/60  Pattern: {ch}  ")
        w(f"{CSI}?2026l")  # sync end
        time.sleep(0.03)

    show_cursor()
    cup(rows - 1, 1)
    pause(auto, delay)


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# TEST 22: Edge case — printing at last column/row
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@test("Last column / last row edge cases",
      "Writing at position (rows,cols) — the bottom-right corner problem")
def test_corners(auto, delay):
    cols, rows = get_term_size()
    clear()

    cup(1, 1)
    sgr("1;36")
    w(f"Corner/edge tests ({cols}×{rows} terminal)")
    reset_all()

    # Mark all four corners
    cup(1, 1)
    sgr("1;31")
    w("TL")
    cup(1, cols - 1)
    w("TR")
    cup(rows, 1)
    w("BL")

    # Bottom-right corner — the tricky one
    # Writing here might scroll the screen if not careful
    cup(rows, cols - 1)
    w("BR")  # Some terminals scroll here, some don't

    # Draw border
    sgr("33")
    for c in range(3, cols - 2):
        cup(1, c)
        w("─")
        cup(rows, c)
        w("─")
    for r in range(2, rows):
        cup(r, 1)
        w("│")
        cup(r, cols)
        w("│")  # writing at last column — tricky
    reset_all()

    cup(rows // 2, (cols - 40) // 2)
    w("All 4 corners should show TL/TR/BL/BR")
    cup(rows // 2 + 1, (cols - 40) // 2)
    w("Border should be complete around edges")

    cup(rows - 2, 3)
    show_cursor()
    pause(auto, delay)


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# TEST 23: Kitty keyboard protocol sequences
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@test("Kitty keyboard protocol",
      "Progressive enhancement enable/disable and CSI u key encoding")
def test_kitty_keyboard_protocol(auto, delay):
    banner("Kitty Keyboard Protocol",
           "Tests protocol negotiation sequences and CSI u key encoding.\n"
           "  In a terminal mirror, these sequences caused garbage text (e.g. '7418u')\n"
           "  and phantom escape key events before being properly filtered.")
    cols, _ = get_term_size()

    # ── Part 1: Protocol negotiation sequences ──
    # These are sent by apps like Claude Code to enable the kitty keyboard
    # protocol. A mirror must strip them or its terminal enters an unsupported
    # mode where keypresses generate unrecognized CSI u sequences.

    sgr("1;33")
    w("  Part 1: Protocol negotiation (should be invisible to mirrors)\n")
    reset_all()
    w("\n")

    # Push mode: ESC [ > 1 u  (enable disambiguate-escape-codes)
    w("  Sending push mode (ESC[>1u)... ")
    wb(b"\x1b[>1u")
    time.sleep(0.1)
    w("sent\n")

    # Push with higher flags: ESC [ > 5 u (disambiguate + report-event-types)
    w("  Sending push mode flags=5 (ESC[>5u)... ")
    wb(b"\x1b[>5u")
    time.sleep(0.1)
    w("sent\n")

    # Query mode: ESC [ ? u (ask terminal what mode is active)
    w("  Sending query (ESC[?u)... ")
    wb(b"\x1b[?u")
    time.sleep(0.1)
    w("sent\n")

    # Set flags: ESC [ = 1;2 u
    w("  Sending set flags (ESC[=1;2u)... ")
    wb(b"\x1b[=1;2u")
    time.sleep(0.1)
    w("sent\n")

    # Pop mode: ESC [ < u (disable / pop one level)
    w("  Sending pop mode (ESC[<u)... ")
    wb(b"\x1b[<u")
    time.sleep(0.1)
    w("sent\n")

    # Pop remaining
    wb(b"\x1b[<u")
    time.sleep(0.1)

    w("\n")
    sgr("32")
    w("  ✓ If the mirror shows 'sent' after each line without garbage, filtering works.\n")
    sgr("31")
    w("  ✗ If the mirror shows garbled text or enters a broken keyboard mode, it's broken.\n")
    reset_all()

    w("\n")

    # ── Part 2: Interleaved with normal content ──
    # Real apps send these negotiation sequences mixed in with regular output.
    # The mirror must strip them without disturbing surrounding text.

    sgr("1;33")
    w("  Part 2: Protocol sequences interleaved with normal output\n")
    reset_all()
    w("\n")

    w("  Before")
    wb(b"\x1b[>1u")          # push mode (should be stripped)
    w(" — After")
    wb(b"\x1b[<u")           # pop mode (should be stripped)
    w(" — End\n")
    w("  Expected: 'Before — After — End' with no gaps or garbage\n")

    w("\n")

    # ── Part 3: Rapid push/pop cycling ──
    # Some apps push/pop the protocol around each input prompt.

    sgr("1;33")
    w("  Part 3: Rapid push/pop cycling (10 iterations)\n")
    reset_all()
    w("\n  ")
    for i in range(10):
        wb(b"\x1b[>1u")       # push
        w(f"[{i}]")
        wb(b"\x1b[<u")        # pop
        time.sleep(0.05)
    w("\n  Expected: [0][1][2][3][4][5][6][7][8][9]\n")

    pause(auto, delay)


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# TEST 24: CSI u key event encoding (kitty protocol output)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@test("CSI u key event simulation",
      "Simulates what SwiftTerm would emit if kitty keyboard mode leaked through")
def test_csi_u_key_events(auto, delay):
    banner("CSI u Key Event Simulation",
           "When kitty keyboard protocol leaks to a mirror terminal, keypresses\n"
           "  get encoded as CSI u sequences instead of classic escape sequences.\n"
           "  This test writes those raw sequences to show what the mirror would see.")
    cols, _ = get_term_size()

    # ── Part 1: Show the raw bytes that would appear as garbage ──
    sgr("1;33")
    w("  Part 1: Raw CSI u sequences (what the user sees as garbage)\n")
    reset_all()
    w("\n")

    # These are the actual byte sequences that SwiftTerm would generate
    # when in kitty keyboard mode. Without proper parsing, the TmuxKey
    # parser would emit .escape + literal text.
    cases = [
        (b"\x1b[97u",       "a",        "ESC[97u",      "codepoint 97 = 'a'"),
        (b"\x1b[65u",       "A",        "ESC[65u",      "codepoint 65 = 'A'"),
        (b"\x1b[13u",       "Enter",    "ESC[13u",      "codepoint 13"),
        (b"\x1b[27u",       "Escape",   "ESC[27u",      "codepoint 27"),
        (b"\x1b[9u",        "Tab",      "ESC[9u",       "codepoint 9"),
        (b"\x1b[127u",      "Backspace","ESC[127u",     "codepoint 127"),
        (b"\x1b[32u",       "Space",    "ESC[32u",      "codepoint 32"),
        (b"\x1b[97;5u",     "Ctrl+A",   "ESC[97;5u",    "codepoint 97, modifier 5"),
        (b"\x1b[98;3u",     "Alt+B",    "ESC[98;3u",    "codepoint 98, modifier 3"),
        (b"\x1b[99;7u",     "Ctrl+Alt+C","ESC[99;7u",   "codepoint 99, modifier 7"),
    ]

    for raw_bytes, key_name, seq_repr, description in cases:
        w(f"  {key_name:<12} {seq_repr:<14} ({description})\n")

    w("\n")
    sgr("90")
    w("  Without CSI u parsing, each of these would produce:\n")
    w("  .escape + text(\"digits + u\") → phantom esc + garbage like '97u'\n")
    reset_all()

    w("\n")

    # ── Part 2: Modified arrow keys (parameterized CSI) ──
    sgr("1;33")
    w("  Part 2: Modified arrow keys (CSI with parameters)\n")
    reset_all()
    w("\n")

    arrow_cases = [
        (b"\x1b[1;5C",  "Ctrl+Right",  "ESC[1;5C",  "param 1, modifier 5, final C"),
        (b"\x1b[1;5D",  "Ctrl+Left",   "ESC[1;5D",  "param 1, modifier 5, final D"),
        (b"\x1b[1;2A",  "Shift+Up",    "ESC[1;2A",  "param 1, modifier 2, final A"),
        (b"\x1b[1;3B",  "Alt+Down",    "ESC[1;3B",  "param 1, modifier 3, final B"),
        (b"\x1b[1;2H",  "Shift+Home",  "ESC[1;2H",  "param 1, modifier 2, final H"),
        (b"\x1b[1;2F",  "Shift+End",   "ESC[1;2F",  "param 1, modifier 2, final F"),
    ]

    for raw_bytes, key_name, seq_repr, description in arrow_cases:
        w(f"  {key_name:<14} {seq_repr:<12} ({description})\n")

    w("\n")
    sgr("90")
    w("  Without parameterized CSI parsing, ESC[1;5C would produce:\n")
    w("  .escape + text(\"1;5C\") instead of .right\n")
    reset_all()

    w("\n")

    # ── Part 3: Live demonstration — write sequences into the terminal ──
    sgr("1;33")
    w("  Part 3: Live output — writing actual CSI u bytes\n")
    reset_all()
    w("\n")

    w("  Writing ESC[>1u (enable kitty mode) then typing 'hello':\n  → ")
    wb(b"\x1b[>1u")           # Enable kitty mode
    time.sleep(0.1)
    w("hello")
    wb(b"\x1b[<u")            # Disable kitty mode
    w("\n  Expected: 'hello' (no garbage before or after)\n")

    w("\n")

    # Show what the "7418u" garbage the user reported might look like.
    # The exact bytes depend on what key was pressed, but here's a plausible
    # sequence that could produce "7418u"-like output:
    w("  Simulating the '7418u' garbage pattern:\n")
    w("  If a mirror sees ESC[55;52;49;56u and doesn't parse CSI u:\n")
    w("  → ESC triggers 'esc again to cancel'\n")
    w("  → Remaining '55;52;49;56u' appears as literal text\n")

    pause(auto, delay)


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# RUNNER
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

def run_tests(test_nums=None, auto=False, delay=1.5):
    if test_nums is None:
        selected = TESTS
    else:
        selected = [TESTS[i-1] for i in test_nums if 1 <= i <= len(TESTS)]

    total = len(selected)

    for i, t in enumerate(selected, 1):
        idx = TESTS.index(t) + 1
        try:
            t["fn"](auto, delay)
        except (KeyboardInterrupt, EOFError):
            break

    # Cleanup
    reset_all()
    decstbm_reset()
    show_cursor()
    clear()
    sgr("1;32")
    w(f"\n  ✓ All {total} tests complete.\n\n")
    reset_all()


def list_tests():
    print(f"\n  {'#':>3}  {'Test Name':<45} Description")
    print(f"  {'─'*3}  {'─'*45} {'─'*40}")
    for i, t in enumerate(TESTS, 1):
        print(f"  {i:3d}  {t['name']:<45} {t['desc'][:60]}")
    print()


def main():
    p = argparse.ArgumentParser(
        prog="term-stress",
        description="Terminal rendering stress test suite.",
    )
    p.add_argument("--auto", action="store_true",
                   help="Run without pauses (auto-advance)")
    p.add_argument("-s", "--delay", type=float, default=1.5,
                   help="Delay between tests in auto mode (default: 1.5s)")
    p.add_argument("--list", action="store_true",
                   help="List available tests")
    p.add_argument("--test", type=str, default=None,
                   help="Run specific tests (comma-separated numbers, e.g. 1,5,8)")
    p.add_argument("--bench", action="store_true",
                   help="Run only the throughput benchmark")

    args = p.parse_args()

    if args.list:
        list_tests()
        return

    if args.bench:
        # Find the throughput test
        for t in TESTS:
            if "throughput" in t["name"].lower():
                t["fn"](True, 0.5)
                reset_all()
                show_cursor()
                return
        return

    test_nums = None
    if args.test:
        test_nums = [int(x) for x in args.test.split(",")]

    try:
        run_tests(test_nums=test_nums, auto=args.auto, delay=args.delay)
    except (KeyboardInterrupt, EOFError):
        reset_all()
        decstbm_reset()
        show_cursor()
        print("\n  Interrupted.\n")


if __name__ == "__main__":
    main()
