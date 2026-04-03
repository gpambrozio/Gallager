import sys, os, re, tty, termios, select

old_settings = termios.tcgetattr(sys.stdin)
tty.setraw(sys.stdin)

try:
    # Enable any-event tracking + SGR encoding
    os.write(1, b'\033[?1003h\033[?1006h\033[2J\033[H')

    scroll = 0
    click = 0
    click_col = 0
    click_row = 0

    def render():
        lines = [
            'MOUSE-TEST-APP',
            'SCROLL:%d' % scroll,
            'CLICK:%d' % click,
            'CLICK-COL:%d' % click_col,
            'CLICK-ROW:%d' % click_row,
            'STATUS:READY',
        ]
        os.write(1, b'\033[H')
        for line in lines:
            os.write(1, (line + '\033[K\r\n').encode())

    render()

    buf = b''
    while True:
        r, _, _ = select.select([sys.stdin], [], [], 0.1)
        if not r:
            continue
        data = os.read(sys.stdin.fileno(), 4096)
        if not data:
            break
        buf += data
        changed = False
        while True:
            m = re.search(rb'\x1b\[<(\d+);(\d+);(\d+)([Mm])', buf)
            if not m:
                esc = buf.find(b'\x1b')
                if esc > 0:
                    buf = buf[esc:]
                elif esc == -1:
                    buf = b''
                break
            btn = int(m.group(1))
            col = int(m.group(2))
            row = int(m.group(3))
            press = m.group(4) == b'M'
            buf = buf[m.end():]
            if btn == 64:
                scroll += 1
                changed = True
            elif btn == 65:
                scroll -= 1
                changed = True
            elif btn == 0 and press:
                click += 1
                click_col = col
                click_row = row
                changed = True
        if changed:
            render()
finally:
    termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_settings)
    os.write(1, b'\033[?1003l\033[?1006l')
