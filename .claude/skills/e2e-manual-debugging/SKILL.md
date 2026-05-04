---
name: e2e-manual-debugging
allowed-tools:
  - Bash(./scripts/e2e-test.sh *)
  - Bash(curl *)
  - Bash(osascript *)
  - Bash(open *)
  - Bash(screencapture *)
  - Bash(xcrun simctl *)
  - Bash(pgrep *)
  - Bash(python3 -c *)
description: Use this skill when an e2e scenario can't find a UI element — `iosTap`/`iosWaitForElement`/`macClickButton`/`macWaitForElement` keeps timing out, you don't know the right `ElementQuery` to use, you need to know what `AXLabel` / `AXIdentifier` / `.help()` / `accessibilityLabel` a button actually exposes, or `iosLogUI` output isn't enough. This skill boots an interactive e2e-mode instance of the apps and walks through inspecting the running UI (XCUITest view hierarchy, AppleScript accessibility tree, Xcode's Accessibility Inspector, on-the-fly screenshots) to discover the exact attributes a scenario step needs. Use whenever someone says "I can't find this element", "what's the right query for X", "the test can't see Y", "what label does the macOS button expose", "find the accessibility identifier", or "the button isn't being clicked". Do NOT use this skill for writing new scenarios from scratch (use e2e-for-feature) or running/fixing scenarios when the issue isn't an unknown element (use e2e-testing).
---

# E2E Element Discovery (Manual Inspection)

When `e2e-testing` or `e2e-for-feature` writes a step that can't find its element, the
loop "guess label → run scenario → fail → guess again" is slow and brittle. This
skill is the shortcut: boot an e2e-mode instance of the app, navigate to the state
the scenario expects, and read the actual accessibility tree to discover the exact
label, identifier, role, or `.help()` text the step should target.

## When this skill applies

You're in this skill if any of these are true:

- `iosTap(.label("..."))` / `iosWaitForElement(...)` keeps timing out and you don't know what label/identifier the SwiftUI view actually exposes.
- `macClickButton(titled: "...")` / `macWaitForElement(titled: "...")` can't find a button — could be a `.help()` text, an `accessibilityLabel`, or no exposure at all.
- A scenario worked yesterday and stopped working after a UI change; you need to find the new label.
- You're writing a new scenario and want to discover identifiers up front, before guessing.
- `iosLogUI` dumps the tree but you can't tell which entry corresponds to the on-screen control you care about.

If you're not stuck on element discovery — for example, you're writing a scenario, reproducing a test failure caused by a logic bug, or comparing baselines — go back to `e2e-testing` / `e2e-for-feature` / `baseline-review` instead.

## Workflow at a glance

1. **Boot interactive e2e mode**, optionally landing in the state of an existing scenario.
2. **Drive the apps to the screen you care about** (use the same TestSteps the scenario uses, or your hands).
3. **Inspect** the iOS or macOS accessibility tree to find the element.
4. **Map the AX attribute to the right `ElementQuery`** and update the scenario.
5. **Press Enter** in the orchestrator terminal to shut down — orchestrator handles cleanup.

## Step 1: Boot an interactive e2e instance

`./scripts/e2e-test.sh --interactive` launches the apps in e2e mode and waits for Enter before tearing down. With `--scenario`, it runs the scenario first and then waits — so you land in the exact state that's failing.

```bash
# Start fresh: launch all apps, no pairing, wait for Enter
./scripts/e2e-test.sh --skip-build --interactive

# Run a specific scenario, then pause for inspection
./scripts/e2e-test.sh --skip-build --interactive --scenario "Fresh Pairing"
```

Use `--skip-build` once you have built artifacts so iteration is fast. The script prints the simulator name and the running PIDs; the apps stay live until you press Enter in the script's terminal.

While the apps are paused you can issue any TestStep-equivalent command yourself (curl the XCUITest runner, AppleScript-click a macOS button, send tmux keys) to drive the UI to the screen the failing scenario needs.

## Step 2: Inspect the iOS UI

iOS exposes its accessibility tree via the XCUITest runner's HTTP server on port 22087.

### Dump the iOS view hierarchy as a readable tree

The raw `/viewHierarchy` JSON is huge; pipe it through this pretty-printer (also stored in `references/utility-snippets.md` if you need to copy-paste it):

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

This is the same data `iosLogUI` produces — but you can grep, scroll, and re-run it without re-running the scenario.

### Take an iOS screenshot to correlate

If the tree has multiple plausible candidates, capture a screenshot and visually align element frames with what's on screen:

```bash
xcrun simctl io booted screenshot /tmp/ios-debug.png && open /tmp/ios-debug.png
```

The `frame` field in the dump (`X, Y, Width, Height` in iOS points) tells you which entry corresponds to the visible control.

### Map iOS attributes to ElementQuery

| Tree attribute | Use in scenario |
|---|---|
| `label="New Session"` | `.label("New Session")` (exact) or `.labelContains("Session")` |
| `id="host-row"` | `.identifier("host-row")` |
| `Type(9)` (Button) + label | `.allOf([.role("Button"), .labelContains("...")])` or `.roleAndLabelContains(role: "Button", label: "...")` |
| `value="Connected"` | `.valueContains("Connected")` |
| Element exists in tree but no useful attributes | Add `.accessibilityLabel(...)` / `.accessibilityIdentifier(...)` to the SwiftUI source |

Element-type numeric values (the orchestrator translates these to role names): `3=Group, 4=Window, 7=Alert, 9=Button, 40=Switch, 43=Image, 46=ScrollView, 48=StaticText, 49=TextField, 75=Cell`.

## Step 3: Inspect the macOS UI

macOS doesn't have an HTTP tree-dump endpoint (the in-app `TestAccessibilityServer` on port 18081 only exposes `/unpair`, `/reconnect`, and `/set-sidebar-width`). Use one of three approaches, in order of preference:

### A. Xcode's Accessibility Inspector (best for ambiguous elements)

```bash
open "/Applications/Xcode.app/Contents/Applications/Accessibility Inspector.app"
```

In the Inspector, set the target to the running e2e Gallager process (find its PID with `pgrep -f "Gallager.*--e2e-test"`), enable "Inspection Pointer", then hover any element to see its full attribute set in real time: `AXRole`, `AXTitle`, `AXLabel` (`accessibilityLabel`), `AXValue`, `AXHelp` (`.help()`), `AXIdentifier`, `AXFrame`. This is by far the fastest way to discover what to put in `macClickButton(titled:)` or `.help(...)`.

The Inspector also shows whether the element responds to `AXPress` — if it doesn't, that's why `macClickButton` isn't working and you need `macCGClick` instead.

### B. AppleScript "entire contents" dump (scriptable, flat list)

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

Produces a flat list of every AX element. Useful for grepping (`| grep -i "pairing"`) but lacks structure. Narrow to a specific window first if it's overwhelming:

```bash
osascript -e "
tell application \"System Events\"
    tell (first process whose unix id is $APP_PID)
        properties of every UI element of window \"Gallager\"
    end tell
end tell
"
```

### C. Screenshot of the e2e instance

When you need to confirm visually which window/control you're targeting:

```bash
APP_PID=$(pgrep -f "Gallager.*--e2e-test" | head -1)
WINDOW_ID=$(python3 -c "
import Quartz, sys
for w in Quartz.CGWindowListCopyWindowInfo(3, 0):
    if w.get('kCGWindowOwnerPID') == $APP_PID:
        print(w['kCGWindowNumber']); sys.exit(0)
sys.exit(1)
")
screencapture -x -l "$WINDOW_ID" /tmp/mac-debug.png && open /tmp/mac-debug.png
```

This targets the e2e Gallager window specifically (not your normal one). The full snippet is in `references/utility-snippets.md`.

### Map macOS attributes to scenario steps

| Inspector attribute | Use in scenario |
|---|---|
| `AXTitle="Generate Pairing Code"` | `macClickButton(titled: "Generate Pairing Code")` |
| `AXLabel="..."` (from `.accessibilityLabel`) | `macClickButton(titled: "...")` (matches label too) |
| `AXHelp="..."` (from `.help`) | `macClickButton(titled: "...")` works; for precise match use `.help("...")` in `macWaitForElementQuery` |
| `AXIdentifier="..."` | `.identifier("...")` in `macWaitForElementQuery` |
| `AXValue` (e.g. toggle state "1") | `.allOf([.help("..."), .valueContains("1")])` |
| Toolbar Label has no exposed title | Add `.help("Action Name")` to the SwiftUI Button |
| Element is in a `List` and `macClickButton` doesn't update selection | Switch the step to `macCGClick(titled:)` |
| `.contextMenu` action you can't reach | Use `macContextMenuClick(elementTitle:menuItem:)` |

## Step 4: Update the scenario

Take the discovered attributes back to the scenario file. Most fixes fall into one of:

- **Wrong query type** — change `.label(...)` to `.labelContains(...)`, or pivot to `.identifier(...)` when the visible label is generic.
- **Wrong click step** — switch `macClickButton` ↔ `macCGClick` based on whether the element responds to AXPress.
- **Missing accessibility hook** — add `.accessibilityLabel`/`.accessibilityIdentifier`/`.help` in the SwiftUI source; rebuild before re-running.
- **Element only appears after some action** — add a `*WaitForElement*` step or use a longer timeout before the failing step.

Then go run the scenario through `e2e-testing` (existing scenario) or `e2e-for-feature` (new scenario) again.

## Step 5: Shut down

Press Enter in the terminal where `./scripts/e2e-test.sh --interactive` is running. The orchestrator terminates the apps, stops the relay server, kills the isolated tmux server, and clears blocked-device state. No manual cleanup needed.

If something hung, kill leftover e2e instances explicitly (this matches what the script does on its next run):

```bash
pkill -f "Gallager.*--e2e-test" || true
```

`pkill -f` is safe here because it only matches processes launched with `--e2e-test`, never your real Gallager instance.

## Driving the UI yourself (when --interactive isn't enough)

Sometimes the failing scenario gets close but the bug is in a state the scenario doesn't quite reach. While the orchestrator is paused, drive the apps directly:

**iOS taps / type / swipes** (XCUITest runner on 22087):

```bash
# Tap at coordinates derived from a tree dump frame
curl -s -X POST http://127.0.0.1:22087/touch -H "Content-Type: application/json" \
  -d '{"x": 200, "y": 400}'

# Type into focused field
curl -s -X POST http://127.0.0.1:22087/inputText -H "Content-Type: application/json" \
  -d '{"text": "hello"}'

# Swipe (left swipe to reveal row actions)
curl -s -X POST http://127.0.0.1:22087/swipe -H "Content-Type: application/json" \
  -d '{"startX": 300, "startY": 400, "endX": 50, "endY": 400, "duration": 0.3}'
```

**macOS click / type via AppleScript** (PID-scoped to the e2e instance):

```bash
APP_PID=$(pgrep -f "Gallager.*--e2e-test" | head -1)
osascript -e "
tell application \"System Events\"
    tell (first process whose unix id is $APP_PID)
        set frontmost to true
        click button \"Generate Pairing Code\" of window 1
    end tell
end tell
"
```

**Tmux** (isolated socket — never your real sessions):

```bash
SOCK="/tmp/claudespy-e2e/claudespy-e2e.sock"
tmux -S "$SOCK" list-sessions
tmux -S "$SOCK" send-keys -t "session:0.0" "echo hi" Enter
tmux -S "$SOCK" capture-pane -t "session:0.0" -p
```

## Coexistence with the production app

The e2e instance runs alongside your real Gallager without interference: it has its own tmux socket (`/tmp/claudespy-e2e/claudespy-e2e.sock`), its own hook port file (`~/.claudespy-port-test`), in-memory PreferencesService and SecretsService (no UserDefaults/Keychain pollution), and a separate process you target by `--e2e-test` PID. Your normal Gallager is safe; AppleScript/`pkill -f "Gallager.*--e2e-test"` never touches it.

## Reference

- **`references/utility-snippets.md`** — full iOS tree pretty-printer (copy-paste form), macOS window-screenshot helper, element type table.
- **`references/element-queries.md`** of the e2e-testing skill — the full ElementQuery syntax mapping for what you discover.
