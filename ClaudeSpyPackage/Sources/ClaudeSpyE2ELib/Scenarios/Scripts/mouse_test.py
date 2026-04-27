import sys, os, re, tty, termios, select, shutil

# Optional --wide flag appends a recognizable ruler line filling the terminal
# width, so visual diffs of horizontal-scroll behavior are unambiguous.
wide = '--wide' in sys.argv

old_settings = termios.tcgetattr(sys.stdin)
tty.setraw(sys.stdin)

try:
    # Enable any-event tracking + SGR encoding
    os.write(1, b'\033[?1003h\033[?1006h\033[2J\033[H')

    scroll = 0
    click = 0
    click_col = 0
    click_row = 0
    drag = 0
    drag_col = 0
    drag_row = 0

    wide_line = ''
    if wide:
        cols = max(40, shutil.get_terminal_size().columns)
        # 'WIDE>' prefix + repeating '0123456789|' chunks + '<END' suffix,
        # padded/truncated so the line exactly fills the terminal width
        # without wrapping. The '|' markers every 10 chars give an obvious
        # visual reference for how far horizontal scrolling has moved.
        body_target = cols - len('WIDE>') - len('<END')
        chunk = '0123456789|'
        body = (chunk * ((body_target // len(chunk)) + 1))[:body_target]
        wide_line = 'WIDE>' + body + '<END'

    def render():
        lines = [
            'MOUSE-TEST-APP',
            'SCROLL:%d' % scroll,
            'CLICK:%d' % click,
            'CLICK-COL:%d' % click_col,
            'CLICK-ROW:%d' % click_row,
            'DRAG:%d' % drag,
            'DRAG-COL:%d' % drag_col,
            'DRAG-ROW:%d' % drag_row,
            'STATUS:READY',
        ]
        if wide_line:
            lines.append(wide_line)
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
            elif btn == 32 and press:
                drag += 1
                drag_col = col
                drag_row = row
                changed = True
        if changed:
            render()
finally:
    termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_settings)
    os.write(1, b'\033[?1003l\033[?1006l')
