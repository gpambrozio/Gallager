# Gallager CLI API Design

Implements a cmux-compatible CLI API for the Gallager macOS app, enabling programmatic control of sessions, windows, panes, input, and notifications via Unix socket IPC.

Reference: [cmux API docs](https://cmux.com/docs/api)
Issue: #343

## Scope

### Included
- Session commands (list, create, select, current, close)
- Window commands (list, create, select, close)
- Pane commands (list, split, select)
- Input commands (send text, send key)
- Notification command (desktop notification via TerminalNotificationService)
- Editor command (absorbs GallagerEditor binary)
- Utility commands (ping, capabilities, identify)

### Excluded (sidebar metadata — deferred)
- Status pills, progress bars, log entries
- `set-status`, `clear-status`, `list-status`, `set-progress`, `clear-progress`, `log`, `clear-log`, `list-log`, `sidebar-state`
- `list-notifications`, `clear-notifications` (no notification storage in Gallager)

## Architecture

### Overview

```
┌─────────────┐    JSON-RPC/Unix Socket    ┌──────────────────┐
│  gallager    │ ◄────────────────────────► │  APISocketServer │
│  CLI binary  │    newline-delimited JSON  │  (@Dependency)   │
└─────────────┘                            └────────┬─────────┘
                                                    │
                                              ┌─────▼──────────┐
                                              │ APIRequestRouter│
                                              │ (@Dependency)   │
                                              └────────┬────────┘
                                                       │
                              ┌─────────────┬──────────┼──────────┬───────────────┐
                              ▼             ▼          ▼          ▼               ▼
                        TmuxService  MirrorWindow  Terminal    EditorSession   (system)
                                     Manager       Notification Manager
                                                   Service
```

### Components

**`gallager` CLI binary** — Swift ArgumentParser executable in `ClaudeSpyPackage/Sources/Gallager/`. Replaces `GallagerEditor`. Serializes subcommands to JSON-RPC, sends over Unix socket, prints responses. Minimal logic — just a transport layer.

**`APISocketServer`** — `@DependencyClient struct` in `ClaudeSpyServerFeature/Services/`. Actor-based live implementation. Manages Unix domain socket lifecycle: bind, listen, accept connections, read newline-delimited JSON requests, dispatch to handler, write JSON responses. Replaces `EditorSocketServer`.

**`APIRequestRouter`** — `@DependencyClient struct` in `ClaudeSpyServerFeature/Services/`. Routes JSON-RPC method strings to service calls. Maps between API models and internal models. Returns typed JSON-RPC responses.

### Dependency Injection

Both `APISocketServer` and `APIRequestRouter` follow the project's `@DependencyClient` pattern:

```swift
@DependencyClient
struct APISocketServer: Sendable {
    var start: @Sendable () async throws -> Void
    var stop: @Sendable () async -> Void
    var setRequestHandler: @Sendable (@escaping @Sendable (JSONRPCRequest) async -> JSONRPCResponse) async -> Void
}

@DependencyClient
struct APIRequestRouter: Sendable {
    var handleRequest: @Sendable (JSONRPCRequest) async -> JSONRPCResponse
}
```

### Integration with AppCoordinator

- Creates and wires `APISocketServer` + `APIRequestRouter` via `@Dependency`
- `setupEditorSocketServer()` becomes `setupAPIServer()`
- Sets env vars on tmux sessions: `GALLAGER_SOCKET` (socket path), `VISUAL` (points to `gallager edit`)
- E2E instances: socket path only via env var (no fixed fallback)

## Wire Protocol

### Transport
Newline-delimited JSON over Unix domain socket (`AF_UNIX, SOCK_STREAM`). Each message is one JSON object terminated by `\n`. Connections are persistent (multiple requests per connection).

### Socket Path Resolution
1. `$GALLAGER_SOCKET` env var (always checked first)
2. Fallback: `$TMPDIR/gallager.sock` (skipped for E2E — E2E only uses env var)

### Request Format
```json
{
  "id": "unique-id",
  "method": "session.list",
  "params": {}
}
```

### Success Response
```json
{
  "id": "unique-id",
  "ok": true,
  "result": { ... }
}
```

### Error Response
```json
{
  "id": "unique-id",
  "ok": false,
  "error": {
    "code": "not_found",
    "message": "Session 'foo' not found"
  }
}
```

### Method Naming
`domain.action` convention:
- `session.*` — session management
- `window.*` — window management
- `pane.*` — pane management
- `input.*` — text/key input
- `notification.*` — desktop notifications
- `editor.*` — prompt editor
- `system.*` — utility commands

## Command Reference

### Session Commands

| Method | CLI | Params | Response |
|--------|-----|--------|----------|
| `session.list` | `gallager list-sessions` | — | `{ sessions: SessionInfo[] }` |
| `session.create` | `gallager new-session` | `{ name?: string }` | `SessionInfo` |
| `session.select` | `gallager select-session <id>` | `{ session_id: string }` | `{ ok: true }` |
| `session.current` | `gallager current-session` | — | `SessionInfo` |
| `session.close` | `gallager close-session <id>` | `{ session_id: string }` | `{ ok: true }` |

### Window Commands

| Method | CLI | Params | Response |
|--------|-----|--------|----------|
| `window.list` | `gallager list-windows` | `{ session_id?: string }` | `{ windows: WindowInfo[] }` |
| `window.create` | `gallager new-window` | `{ session_id?: string }` | `WindowInfo` |
| `window.select` | `gallager select-window <id>` | `{ window_id: string }` | `{ ok: true }` |
| `window.close` | `gallager close-window <id>` | `{ window_id: string }` | `{ ok: true }` |

### Pane Commands

| Method | CLI | Params | Response |
|--------|-----|--------|----------|
| `pane.list` | `gallager list-panes` | `{ window_id?: string }` | `{ panes: PaneInfo[] }` |
| `pane.split` | `gallager split-pane [dir]` | `{ direction?: "left"\|"right"\|"up"\|"down", pane_id?: string }` | `PaneInfo` |
| `pane.select` | `gallager select-pane <id>` | `{ pane_id: string }` | `{ ok: true }` |

### Input Commands

| Method | CLI | Params | Response |
|--------|-----|--------|----------|
| `input.send_text` | `gallager send <text>` | `{ text: string, pane_id?: string }` | `{ ok: true }` |
| `input.send_key` | `gallager send-key <key>` | `{ key: string, pane_id?: string }` | `{ ok: true }` |

Supported keys: `enter`, `tab`, `escape`, `backspace`, `delete`, `up`, `down`, `left`, `right`, `space`.

### Notification Commands

| Method | CLI | Params | Response |
|--------|-----|--------|----------|
| `notification.create` | `gallager notify` | `{ title: string, body: string, subtitle?: string }` | `{ ok: true }` |

Notifications route through `TerminalNotificationService`, appearing identically to terminal-triggered notifications. If `$TMUX_PANE` is set, the notification includes pane context for tap-to-navigate. If called from outside a Gallager-managed session, no pane association.

### Editor Commands

| Method | CLI | Params | Response |
|--------|-----|--------|----------|
| `editor.open` | `gallager edit <file>` | `{ pane_id: string, file_path: string }` | `{ ok: true }` (sent when editing completes) |

The `edit` command blocks until the user submits or cancels in the app, preserving the existing GallagerEditor behavior. The `pane_id` comes from `$TMUX_PANE` env var automatically.

### Utility Commands

| Method | CLI | Params | Response |
|--------|-----|--------|----------|
| `system.ping` | `gallager ping` | — | `{ pong: true }` |
| `system.capabilities` | `gallager capabilities` | — | `{ methods: string[] }` |
| `system.identify` | `gallager identify` | — | `IdentifyInfo` |

`identify` uses `$TMUX_PANE` to determine the calling pane's context (session, window, pane).

## API Response Models

```swift
struct SessionInfo: Codable, Sendable {
    let id: String          // tmux session name
    let name: String        // display name
    let windowCount: Int
    let isAttached: Bool
    let createdAt: Date?
}

struct WindowInfo: Codable, Sendable {
    let id: String          // "sessionName:windowIndex" (colon-separated)
    let index: Int
    let name: String
    let paneCount: Int
    let isActive: Bool
    let sessionId: String
}

struct APIPaneInfo: Codable, Sendable {
    let id: String          // tmux pane ID (e.g., "%5")
    let index: Int
    let isActive: Bool
    let command: String?
    let cwd: String?
    let width: Int
    let height: Int
    let windowId: String
    let hasClaudeSession: Bool
}

struct IdentifyInfo: Codable, Sendable {
    let session: SessionInfo?
    let window: WindowInfo?
    let pane: APIPaneInfo?
}
```

## CLI Surface

```
gallager <command> [options]

Session Commands:
  list-sessions              List all tmux sessions
  new-session [--name <n>]   Create a new session
  select-session <id>        Switch to a session
  current-session            Show active session
  close-session <id>         Close a session

Window Commands:
  list-windows               List windows in current/specified session
  new-window                 Create window in current/specified session
  select-window <id>         Switch to a window
  close-window <id>          Close a window

Pane Commands:
  list-panes                 List panes in current window
  split-pane [direction]     Split pane (left/right/up/down, default: right)
  select-pane <id>           Focus a pane

Input Commands:
  send <text>                Send text to focused/specified pane
  send-key <key>             Send key press (enter/tab/escape/backspace/
                             delete/up/down/left/right/space)

Notification:
  notify --title <t> --body <b> [--subtitle <s>]
                             Send desktop notification

Editor:
  edit <file>                Open file in prompt editor (blocks until done)

Utility:
  ping                       Check if Gallager is running
  capabilities               List available API methods
  identify                   Show current context

Global Options:
  --socket <path>            Custom socket path
  --json                     JSON output
  --pane <id>                Target specific pane
  --session <id>             Target specific session
  --window <id>              Target specific window
```

## Migration from GallagerEditor

1. Rename `GallagerEditor` target to `Gallager` in Package.swift
2. Replace single-purpose editor binary with full ArgumentParser CLI
3. `edit` subcommand preserves exact same behavior (read $TMUX_PANE, connect to socket, send request, block)
4. `EditorSocketServer` replaced by `APISocketServer` (editor.open method handles edit requests)
5. `VISUAL` env var updated to point to `gallager edit` instead of `GallagerEditor`
6. `GALLAGER_EDITOR_SOCKET` env var replaced by `GALLAGER_SOCKET`

## File Locations

| Component | Path |
|-----------|------|
| CLI binary | `ClaudeSpyPackage/Sources/Gallager/` |
| API models | `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/APIModels.swift` |
| JSON-RPC types | `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/JSONRPC.swift` |
| Socket server | `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/APISocketServer.swift` |
| Request router | `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/APIRequestRouter.swift` |
| Integration | `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Coordinators/AppCoordinator.swift` |

## Testing Strategy

- **Unit tests:** APIRequestRouter with mocked dependencies — verify method routing, param parsing, error handling
- **Integration tests:** Full socket round-trip with in-memory server
- **E2E tests:** Scenario using `gallager` CLI commands against running app (per issue #343, use `/e2e-for-feature` skill)
