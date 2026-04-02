import sys, time
E = '\033'
C = E + '['

def w(s):
    sys.stdout.write(s)
    sys.stdout.flush()

def cup(row, col):
    w(f'{C}{row};{col}H')

def sgr(code):
    w(f'{C}{code}m')

def reset():
    w(f'{C}0m')

def decstbm(top, bot):
    w(f'{C}{top};{bot}r')

def decstbm_reset():
    w(f'{C}r')

# Get terminal size
import os
cols, rows = os.get_terminal_size()

# Clear screen
w(f'{C}2J{C}H')

# ── Fixed header (rows 1–3): white on blue ──
cup(1, 1)
sgr('1;37;44')
w(' ' * cols)
cup(1, 1)
w('  ┌─ FIXED HEADER ─' + '─' * (cols - 21) + '┐')
cup(2, 1)
w(f'  │ This stays pinned while content scrolls below{" " * (cols - 52)}│')
cup(3, 1)
w('  └' + '─' * (cols - 4) + '┘')
reset()

# ── Fixed footer (bottom 3 rows): white on green ──
cup(rows - 2, 1)
sgr('1;37;42')
w('  ┌' + '─' * (cols - 4) + '┐')
cup(rows - 1, 1)
w(f'  │ FIXED FOOTER — status bar area{" " * (cols - 36)}│')
cup(rows, 1)
w('  └' + '─' * (cols - 4) + '┘')
reset()

# ── Set scroll region to the middle ──
top_margin = 4
bot_margin = rows - 3
decstbm(top_margin, bot_margin)

# ── Fill the scroll region with colored content ──
scroll_height = bot_margin - top_margin + 1
for i in range(1, scroll_height + 20):
    cup(bot_margin, 1)
    # Cycle through colors using ANSI 256-color
    color = 31 + (i % 6)
    sgr(f'1;{color}')
    w(f'    Scrolling line {i:3d} — content scrolls, header/footer stay fixed')
    reset()
    w('\n')
    time.sleep(0.02)

# ── Reset scroll region and position cursor ──
decstbm_reset()
cup(rows, 1)
