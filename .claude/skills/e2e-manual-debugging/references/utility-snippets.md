# Utility Snippets for E2E Manual Debugging

## iOS Accessibility Tree — Human-Readable Dump

Pipe the raw XCUITest runner view hierarchy through this python3 script to get a
readable tree with element types, labels, identifiers, and frames:

```bash
curl -s -X POST http://127.0.0.1:22087/viewHierarchy \
  -H "Content-Type: application/json" \
  -d '{"bundleId":"br.eng.gustavo.claudespy"}' | \
  python3 -c "
import json, sys
def walk(el, depth=0):
    t = el.get('elementType', 0)
    label = el.get('label', '')
    ident = el.get('identifier', '')
    value = el.get('value', '')
    frame = el.get('frame', {})
    types = {9:'Button',48:'StaticText',49:'TextField',43:'Image',40:'Switch',75:'Cell',3:'Group',4:'Window',7:'Alert',46:'ScrollView'}
    tname = types.get(t, f'Type({t})')
    parts = [f'{\"  \"*depth}{tname}']
    if label: parts.append(f'label=\"{label}\"')
    if ident: parts.append(f'id=\"{ident}\"')
    if value: parts.append(f'value=\"{value}\"')
    if frame: parts.append(f'({frame.get(\"X\",0):.0f},{frame.get(\"Y\",0):.0f} {frame.get(\"Width\",0):.0f}x{frame.get(\"Height\",0):.0f})')
    print(' '.join(parts))
    for child in el.get('children', []):
        walk(child, depth+1)
data = json.load(sys.stdin)
walk(data.get('axElement', {}))
"
```

### Element Type Reference

Common `elementType` numeric values:

| Type | Name | Description |
|------|------|-------------|
| 3 | Group | Container (HStack, VStack, etc.) |
| 7 | Alert | Alert dialog |
| 9 | Button | Tappable button |
| 40 | Switch | Toggle switch |
| 43 | Image | Image view |
| 46 | ScrollView | Scrollable container |
| 48 | StaticText | Text label |
| 49 | TextField | Text input field |
| 75 | Cell | Table/collection cell |

### Tap Coordinate Calculation

From the `frame` in the view hierarchy, calculate the center point:

```
x = frame.X + frame.Width / 2
y = frame.Y + frame.Height / 2
```

Then tap:
```bash
curl -s -X POST http://127.0.0.1:22087/touch \
  -H "Content-Type: application/json" \
  -d '{"x": <calculated_x>, "y": <calculated_y>}'
```

## macOS Window Screenshot

Find the CGWindowID for the E2E test app, then capture it:

```bash
APP_PID=$(pgrep -f "Gallager.*--e2e-test" | head -1)
WINDOW_ID=$(python3 -c "
import Quartz, sys
windows = Quartz.CGWindowListCopyWindowInfo(
    Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
    Quartz.kCGNullWindowID
)
for w in windows:
    if w.get('kCGWindowOwnerPID') == $APP_PID:
        print(w.get('kCGWindowNumber'))
        sys.exit(0)
print('', end='')
sys.exit(1)
")

screencapture -x -l "$WINDOW_ID" /tmp/mac-debug.png
open /tmp/mac-debug.png
```

If the screenshot appears blank or captures the wrong window, recalculate the window
ID — it changes when windows move between displays or get recreated.

## macOS Accessibility Tree Dump via AppleScript

Dump the macOS app's accessibility tree structure:

```bash
APP_PID=$(pgrep -f "Gallager.*--e2e-test" | head -1)

osascript -e "
tell application \"System Events\"
    tell (first process whose unix id is $APP_PID)
        get entire contents
    end tell
end tell
"
```

**Note:** This produces a large, flat list of AX elements. For targeted inspection,
narrow down to a specific window or UI element first.
