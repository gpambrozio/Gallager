---
name: e2e-manual-debugging
allowed-tools:
  - Bash(./scripts/e2e-test.sh *)
  - Bash(curl *)
  - Bash(osascript *)
  - Bash(screencapture *)
  - Bash(tmux -S *)
  - Bash(xcrun simctl *)
  - Bash(pbpaste)
  - Bash(pgrep *)
  - Bash(pkill *)
  - Bash(python3 -c *)
description: Use this skill for hands-on, interactive debugging and exploratory testing of the ClaudeSpy apps using the E2E infrastructure — without writing a formal test scenario. This covers launching apps in interactive mode, taking ad-hoc screenshots of the macOS or iOS app, dumping the iOS accessibility tree to find element identifiers, reproducing bugs by manually driving the UI, sending hook events to the macOS app, creating tmux sessions for testing, checking relay server health, verifying a code fix by launching and interacting with the apps, or any task where you need to inspect live app state. Use this skill whenever someone says "launch the app", "take a screenshot", "inspect the accessibility tree", "reproduce this bug", "verify my fix", "drive the app", "send a hook event", "check the relay server", or wants to interactively poke at the running apps. Do NOT use this skill when the user wants to write, modify, or run formal automated e2e test scenarios — use e2e-testing for that instead.
---

# E2E Manual Debugging & Interactive Testing

Launch, drive, inspect, and screenshot the ClaudeSpy apps interactively — without
writing a formal test scenario. Intended for debugging issues, verifying fixes,
and exploratory testing.

## Environment Details

When running in E2E mode, these services are active:

| Service | Port | Purpose |
|---------|------|---------|
| Relay server | 8765 | WebSocket pairing between macOS and iOS |
| macOS TestAccessibilityServer | 18081 | In-app HTTP (sidebar width, unpair) |
| XCUITest runner (iOS) | 22087 | iOS UI inspection, touch, text input |
| macOS hook server | Read from `~/.claudespy-port-test` | Hook event delivery |

**Tmux socket:** `/tmp/claudespy-e2e/claudespy-e2e.sock` (isolated from real sessions)

## Manual Interaction Commands

### iOS App Interaction

All iOS interaction goes through the XCUITest runner HTTP server on port 22087.

#### Check if runner is ready

```bash
curl -s http://127.0.0.1:22087/status
# Expected: {"status":"ok"}
```

#### Get iOS accessibility tree (find elements)

```bash
curl -s -X POST http://127.0.0.1:22087/viewHierarchy \
  -H "Content-Type: application/json" \
  -d '{"bundleId":"br.eng.gustavo.claudespy"}' | python3 -m json.tool
```

The response contains a nested `axElement` with `children`, each having:
- `label` — accessibility label
- `identifier` — accessibility identifier
- `elementType` — numeric type (9=Button, 48=StaticText, 49=TextField, etc.)
- `frame` — `{X, Y, Width, Height}` in iOS points
- `value` — current value (e.g. text field content)
- `children` — nested child elements

For a human-readable tree dump, see **`references/utility-snippets.md`** — it contains
a python3 script that formats the raw JSON into an indented tree with element types,
labels, identifiers, and frames.

#### Tap an iOS element by coordinates

```bash
curl -s -X POST http://127.0.0.1:22087/touch \
  -H "Content-Type: application/json" \
  -d '{"x": 200, "y": 400}'
```

Calculate center from `frame`: `x = frame.X + frame.Width/2`, `y = frame.Y + frame.Height/2`

#### Type text on iOS

```bash
curl -s -X POST http://127.0.0.1:22087/inputText \
  -H "Content-Type: application/json" \
  -d '{"text": "hello world"}'
```

#### Swipe on iOS

```bash
curl -s -X POST http://127.0.0.1:22087/swipe \
  -H "Content-Type: application/json" \
  -d '{"startX": 300, "startY": 400, "endX": 50, "endY": 400, "duration": 0.3}'
```

#### Take iOS screenshot

```bash
xcrun simctl io booted screenshot /tmp/ios-debug.png
open /tmp/ios-debug.png
```

### macOS App Interaction

macOS interaction uses a combination of AppleScript (via `osascript`), the AX accessibility
API (built into the E2E framework), and the in-app HTTP server.

#### Find the test app's PID

The E2E test instance runs alongside any production copy. Find it by the `--e2e-test` argument:

```bash
pgrep -f "Gallager.*--e2e-test"
```

#### Click macOS UI elements via AppleScript

Target only the test instance by PID:

```bash
APP_PID=$(pgrep -f "Gallager.*--e2e-test" | head -1)

# Open status bar menu and click a menu item
osascript -e "
tell application \"System Events\"
    tell (first process whose unix id is $APP_PID)
        click menu bar item 1 of menu bar 2
        delay 0.5
        click menu item \"Settings...\" of menu 1 of menu bar item 1 of menu bar 2
    end tell
end tell
"

# Type into the app
osascript -e "
tell application \"System Events\"
    tell (first process whose unix id is $APP_PID)
        set frontmost to true
        keystroke \"hello\"
        keystroke return
    end tell
end tell
"
```

#### macOS in-app HTTP endpoints

```bash
# Trigger unpair
curl -s -X POST http://127.0.0.1:18081/unpair

# Set sidebar width
curl -s -X POST "http://127.0.0.1:18081/set-sidebar-width?width=250"
```

#### Take macOS screenshot

See **`references/utility-snippets.md`** for the full python3/Quartz snippet that finds
the CGWindowID by PID and captures it with `screencapture -x -l`.

Quick version (if the PID is already known):

```bash
APP_PID=$(pgrep -f "Gallager.*--e2e-test" | head -1)
screencapture -x -l "$(python3 -c "
import Quartz, sys
for w in Quartz.CGWindowListCopyWindowInfo(3, 0):
    if w.get('kCGWindowOwnerPID') == $APP_PID:
        print(w['kCGWindowNumber']); sys.exit(0)
sys.exit(1)
")" /tmp/mac-debug.png
open /tmp/mac-debug.png
```

### Tmux Interaction

The E2E tmux uses an isolated socket. Always specify `-S` with the socket path:

```bash
TMUX_SOCKET="/tmp/claudespy-e2e/claudespy-e2e.sock"

# Create a session (always use -f /dev/null to ignore user's tmux.conf)
tmux -S "$TMUX_SOCKET" -f /dev/null new-session -d -s "test-session" -x 80 -y 24

# List sessions
tmux -S "$TMUX_SOCKET" list-sessions

# Send keys to a pane
tmux -S "$TMUX_SOCKET" send-keys -t "test-session:0.0" "echo hello" Enter

# Capture pane content
tmux -S "$TMUX_SOCKET" capture-pane -t "test-session:0.0" -p

# Get pane dimensions
tmux -S "$TMUX_SOCKET" display-message -t "test-session:0.0" -p "#{pane_width}x#{pane_height}"

# Kill the tmux server (cleanup)
tmux -S "$TMUX_SOCKET" kill-server 2>/dev/null
rm -f "$TMUX_SOCKET"
```

**Important:** Always pass `-f /dev/null` when creating sessions to ignore the user's
`tmux.conf` — prevents base-index issues that break the E2E framework.

### Hook Events

Send hook events to the macOS app's hook server:

```bash
# Read the hook server port
HOOK_PORT=$(cat ~/.claudespy-port-test)

# Send a Stop hook event
curl -s -X POST "http://localhost:$HOOK_PORT/api/hooks?tmux_pane=%0" \
  -H "Content-Type: application/json" \
  -d '{"type":"Stop","session_id":"test-123","result":{"result":"task completed"}}'
```

### Relay Server

```bash
# Health check
curl -s http://127.0.0.1:8765/health

# Check active pairings
curl -s http://127.0.0.1:8765/health | python3 -m json.tool
```

## Workflow: Debug a Bug

1. **Build with the fix** — make the code change, then build:
   ```bash
   ./scripts/e2e-test.sh  # builds everything
   ```

2. **Launch interactively** with the scenario closest to the bug:
   ```bash
   ./scripts/e2e-test.sh --skip-build --interactive --scenario "Fresh Pairing"
   ```

3. **Reproduce** — drive the app to the buggy state using manual commands above

4. **Inspect** — dump accessibility trees, take screenshots, capture tmux pane content

5. **Verify** — drive through the reproduction steps again to confirm the fix

6. **Shut down** — press Enter in the interactive terminal

## Workflow: Test Without iOS (macOS-Only)

For macOS-only debugging, the full E2E orchestrator is not required. Launch the
macOS app directly with test arguments instead. Note: this uses a different tmux
socket path (`/tmp/claudespy-debug.sock`) than the E2E orchestrator to avoid
conflicts if both are running.

```bash
# Create an isolated tmux session first
TMUX_SOCKET="/tmp/claudespy-debug.sock"
tmux -S "$TMUX_SOCKET" -f /dev/null new-session -d -s "debug" -x 80 -y 24

# Launch the macOS app with E2E test flags (uses in-memory storage)
DERIVED_DATA="build/e2e-derived-data"
open -n "$DERIVED_DATA/Build/Products/Debug/Gallager.app" \
  --args --e2e-test \
  --server-url ws://127.0.0.1:8765 \
  --tmux-socket "$TMUX_SOCKET" \
  --hook-port-file ~/.claudespy-port-test

# Wait for launch, then interact...
sleep 3

# When done, quit and clean up
osascript -e 'quit app "Gallager"'
tmux -S "$TMUX_SOCKET" kill-server 2>/dev/null
rm -f "$TMUX_SOCKET"
```

`--server-url` prevents accidental connection to a production server. The URL does
not need to be reachable for macOS-only testing.

## Key Coexistence Rules

The E2E test instance runs alongside a production copy of the app without interference:

1. **Separate tmux socket** — E2E uses `/tmp/claudespy-e2e/claudespy-e2e.sock`, production uses the default
2. **Separate hook port file** — E2E uses `~/.claudespy-port-test`, production uses `~/.claudespy-port`
3. **In-memory storage** — `--e2e-test` overrides `PreferencesService` and `SecretsService` (no UserDefaults/Keychain pollution)
4. **PID-scoped interaction** — AppleScript targets the test instance by PID (`first process whose unix id is $PID`)
5. **Separate relay server** — E2E relay runs on port 8765, not the production server
6. **New app instance** — launched via `NSWorkspace` with `createsNewApplicationInstance: true`

## Common Issues

### XCUITest runner not responding
If `curl http://127.0.0.1:22087/status` fails, the runner may have crashed or not started.
Check if the runner process is alive:
```bash
pgrep -f "XCTRunner"
```
If dead, restart interactive mode.

### "Accessibility not enabled" errors
The terminal must have Accessibility permissions in System Settings > Privacy & Security > Accessibility.
The E2E script checks this automatically; when running commands manually, ensure it is granted.

### Multiple test instances
If multiple test instances were accidentally launched:
```bash
# Find all test PIDs
pgrep -f "Gallager.*--e2e-test"

# Kill all test instances (pkill -f is appropriate here for test instances;
# use osascript -e 'quit app "Gallager"' for the production app instead)
pkill -f "Gallager.*--e2e-test"
```

### Screenshot appears blank or wrong window
`screencapture -l` captures by CGWindowID. If the window moved or was minimized,
recalculate the window ID — see **`references/utility-snippets.md`**.

## Additional Resources

### Reference Files

For utility scripts and detailed snippets, consult:
- **`references/utility-snippets.md`** — iOS accessibility tree pretty-printer, macOS window screenshot helper, element type reference table
