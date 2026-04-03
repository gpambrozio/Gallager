"""
draw_table.py — Box-drawing table rendering test.

Uses DEC Special Graphics character set to draw a three-column table
with box-drawing characters, exercising terminal line-drawing support.
"""

import sys

ESC = '\033'
DEC_ON = ESC + '(0'     # Switch to DEC Special Graphics
DEC_OFF = ESC + '(B'    # Switch back to ASCII
CSI = ESC + '['          # Control Sequence Introducer

# DEC Special Graphics character mappings:
#   l=┌  k=┐  m=└  j=┘  q=─  x=│  w=┬  v=┴  t=├  u=┤  n=┼

# Column widths: 24 + 26 + 24 = 74 content + borders = 80 total
COL1_WIDTH = 24
COL2_WIDTH = 26
COL3_WIDTH = 24


def write(text):
    """Write text to stdout without a newline."""
    sys.stdout.write(text)


def hline(left, mid, right):
    """Draw a horizontal line using DEC box-drawing characters."""
    write(
        DEC_ON
        + left + 'q' * COL1_WIDTH + mid + 'q' * COL2_WIDTH + mid + 'q' * COL3_WIDTH + right
        + DEC_OFF + '\n'
    )


def row(col1, col2, col3):
    """Draw a data row with vertical separators."""
    write(
        DEC_ON + 'x' + DEC_OFF + col1.ljust(COL1_WIDTH)
        + DEC_ON + 'x' + DEC_OFF + col2.ljust(COL2_WIDTH)
        + DEC_ON + 'x' + DEC_OFF + col3.ljust(COL3_WIDTH)
        + DEC_ON + 'x' + DEC_OFF + '\n'
    )


# Clear screen and move cursor to home
write(CSI + '2J' + CSI + 'H')
write(CSI + '1;33m  Box-Drawing Table Rendering Test' + CSI + '0m\n\n')

# Table header
hline('l', 'w', 'k')
row(' Name', ' Description', ' Status')
hline('t', 'n', 'u')

# Authentication Service
row(' Authentication', ' User login and token', ' Active')
row('   Service', ' management system', '')
hline('t', 'n', 'u')

# Database Pool Manager
row(' Database Pool', ' Connection pooling for', ' Warning: 85%')
row('   Manager', ' PostgreSQL with auto-', ' capacity')
row('', ' scaling and failover', '')
hline('t', 'n', 'u')

# WebSocket Relay
row(' WebSocket Relay', ' Real-time bidirectional', ' Active')
row('', ' message routing between', '')
row('', ' paired devices', '')
hline('t', 'n', 'u')

# E2E Test Runner
row(' E2E Test Runner', ' Automated scenario', ' 32/33 passed')
row('', ' execution framework', '')
hline('m', 'v', 'j')

write('\n' + CSI + '1;32m  All services operational.' + CSI + '0m\n')
sys.stdout.flush()
