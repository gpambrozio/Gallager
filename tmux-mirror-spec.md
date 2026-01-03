# Tmux Pane Mirror

A macOS application that displays a real-time mirror of any tmux pane in a native window, preserving colors, formatting, and terminal behavior.

## Overview

Tmux Pane Mirror allows users to monitor tmux panes without attaching to the session. Users enter a pane identifier, and the app opens a new window displaying a live, read-only view of that pane's contents with full terminal emulation.

## Use Cases

- Monitoring long-running processes from a native window
- Displaying build output or logs on a secondary monitor
- Observing remote session activity without attaching
- Creating dashboards from multiple tmux panes

## Requirements

### System Requirements

- macOS 26.0 or later
- tmux installed and accessible in PATH
- Active tmux server with at least one session

### Dependencies

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (terminal emulation)

## User Interface

### Main Window

On launch, the app displays a simple interface:

```
┌─────────────────────────────────────────────────────────────┐
│  Available Panes                                      [X]   │
├─────────────────────────────────────────────────────────────┤
│  Target              Command           Directory            │
│  ─────────────────────────────────────────────────────────  │
│  mysession:0.0       vim               ~/projects      [→]  │
│  mysession:0.1       node server.js    ~/app           [→]  │
│  mysession:1.0       htop              ~               [→]  │
│  work:0.0            zsh               ~/work          [→]  │
└─────────────────────────────────────────────────────────────┘
```

Clicking [→] opens a mirror window for that pane.

### Mirror Window

Each mirror window displays the terminal content:

```
┌─────────────────────────────────────────────────────────────┐
│  ● ○ ○   Mirror: %5 (mysession:0.1)              [Pause]    │
├─────────────────────────────────────────────────────────────┤
│  user@host:~/project$ npm run build                         │
│                                                             │
│  > project@1.0.0 build                                      │
│  > webpack --mode production                                │
│                                                             │
│  ████████████████████████░░░░░░░░  70%                      │
│  Building modules...                                        │
│                                                             │
│                                                             │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│  ● Connected │ 80x24 │ Scrollback: 1,542 lines              │
└─────────────────────────────────────────────────────────────┘
```

**Window Features:**

| Feature | Description |
|---------|-------------|
| Title bar | Shows pane ID and session:window.pane target |
| Pause button | Temporarily stops updating (buffers content) |
| Terminal view | SwiftTerm-rendered terminal with full color support |
| Status bar | Connection state, dimensions, scrollback info |

## Architecture

### Components

```
┌──────────────────────────────────────────────────────────────┐
│                        Application                           │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────┐   │
│  │   MainView  │───▶│ MirrorWindow│───▶│ TerminalView    │   │
│  │             │    │  Manager    │    │ (SwiftTerm)     │   │
│  └─────────────┘    └─────────────┘    └─────────────────┘   │
│         │                  │                    ▲            │
│         ▼                  ▼                    │            │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────┐   │
│  │ TmuxService │◀───│ PaneStream  │───▶│  Named Pipe /   │   │
│  │             │    │             │    │  pipe-pane      │   │
│  └─────────────┘    └─────────────┘    └─────────────────┘   │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### TmuxService

Handles all tmux CLI interactions.

**Methods:**

```swift
protocol TmuxService {
    /// List all available panes across all sessions
    func listPanes() async throws -> [PaneInfo]
    
    /// Validate that a pane target exists
    func validatePane(_ target: String) async throws -> Bool
    
    /// Capture current pane content with escape sequences
    func capturePane(_ target: String, scrollback: Bool) async throws -> Data
    
    /// Start pipe-pane to a named pipe, returns pipe path
    func startPipePipe(_ target: String) async throws -> String
    
    /// Stop pipe-pane for a target
    func stopPipePipe(_ target: String) async throws
    
    /// Get pane dimensions
    func getPaneDimensions(_ target: String) async throws -> (width: Int, height: Int)
}
```

**PaneInfo Model:**

```swift
struct PaneInfo: Identifiable {
    let id: String          // e.g., "%5"
    let target: String      // e.g., "mysession:0.1"
    let sessionName: String
    let windowIndex: Int
    let paneIndex: Int
    let command: String     // Current running command
    let currentPath: String
    let width: Int
    let height: Int
    let isActive: Bool
}
```

### PaneStream

Manages the connection to a tmux pane and streams data.

**States:**

```
┌────────────┐    connect()    ┌────────────┐
│Disconnected│ ───────────────▶│ Connecting │
└────────────┘                 └────────────┘
      ▲                              │
      │                              │ success
      │ disconnect()                 ▼
      │                        ┌────────────┐
      └────────────────────────│ Connected  │
                               └────────────┘
                                     │
                               error │
                                     ▼
                               ┌────────────┐
                               │   Error    │
                               └────────────┘
```

**Interface:**

```swift
@Observable
class PaneStream {
    let target: String
    var state: StreamState
    var onData: ((Data) -> Void)?
    
    func connect() async throws
    func disconnect()
    func pause()
    func resume()
}
```

### MirrorWindowManager

Manages multiple mirror windows.

```swift
@Observable
class MirrorWindowManager {
    var windows: [String: MirrorWindow]  // Keyed by pane target
    
    func openMirror(for target: String) -> MirrorWindow
    func closeMirror(for target: String)
    func closeAll()
}
```

## Data Flow

### Initial Connection

```
User selects pane
        │
        ▼
┌───────────────────┐
│ Validate pane     │  tmux display-message -t <target> -p "#{pane_id}"
│ exists            │
└───────────────────┘
        │
        ▼
┌───────────────────┐
│ Get pane          │  tmux display-message -t <target> -p "#{pane_width} #{pane_height}"
│ dimensions        │
└───────────────────┘
        │
        ▼
┌───────────────────┐
│ Create mirror     │  New NSWindow with TerminalView sized to pane dimensions
│ window            │
└───────────────────┘
        │
        ▼
┌───────────────────┐
│ Capture existing  │  tmux capture-pane -t <target> -p -e -S -
│ content           │
└───────────────────┘
        │
        ▼
┌───────────────────┐
│ Feed to           │  terminalView.feed(byteArray: data)
│ TerminalView      │
└───────────────────┘
        │
        ▼
┌───────────────────┐
│ Start pipe-pane   │  tmux pipe-pane -t <target> "cat > /tmp/tmux-mirror-<id>.fifo"
│ streaming         │
└───────────────────┘
        │
        ▼
┌───────────────────┐
│ Read from FIFO    │  FileHandle.readabilityHandler
│ and feed terminal │
└───────────────────┘
```

### Streaming Loop

```
tmux pane output
        │
        ▼
┌───────────────────┐
│ pipe-pane         │  Captures PTY output
└───────────────────┘
        │
        ▼
┌───────────────────┐
│ Named pipe (FIFO) │  /tmp/tmux-mirror-<uuid>.fifo
└───────────────────┘
        │
        ▼
┌───────────────────┐
│ FileHandle        │  readabilityHandler callback
└───────────────────┘
        │
        ▼
┌───────────────────┐
│ TerminalView      │  feed(byteArray:) processes ANSI sequences
└───────────────────┘
        │
        ▼
┌───────────────────┐
│ Display           │  Rendered with colors, cursor, etc.
└───────────────────┘
```

## Error Handling

| Error | Cause | User Message | Recovery |
|-------|-------|--------------|----------|
| TmuxNotFound | tmux not in PATH | "tmux is not installed or not in PATH" | Show install instructions |
| NoServer | tmux server not running | "No tmux server running. Start tmux first." | None |
| InvalidPane | Pane target doesn't exist | "Pane '<target>' not found" | Show pane list |
| PipeError | Failed to create/read FIFO | "Connection lost to pane" | Offer reconnect |
| PermissionDenied | Can't access tmux socket | "Permission denied accessing tmux" | Check socket permissions |

## Window Behavior

### Multiple Windows

- Each pane can have at most one mirror window
- Attempting to mirror an already-mirrored pane brings existing window to front
- Windows remember their position and size per pane target
- Main window remains open; closing it hides to dock (Cmd+Q to quit)

### Window Lifecycle

```
Open Mirror
     │
     ▼
┌─────────────┐
│ Window Open │◀──────────────────┐
└─────────────┘                   │
     │                            │
     │ User closes window         │ User reopens same pane
     ▼                            │
┌─────────────┐                   │
│ Cleanup     │───────────────────┘
│ - Stop pipe │
│ - Remove    │
│   FIFO      │
└─────────────┘
```

### Scrollback

- Mirror maintains its own scrollback buffer (configurable, default 10,000 lines)
- User can scroll up in mirror without affecting live updates
- New content appears at bottom; scroll position preserved if user scrolled up
- "Jump to bottom" button appears when scrolled up and new content arrives

## Menu Bar

```
Tmux Pane Mirror
├── About Tmux Pane Mirror
├── ─────────────────────
├── Settings...              ⌘,
├── ─────────────────────
├── Hide Tmux Pane Mirror    ⌘H
├── Hide Others              ⌥⌘H
├── Show All
├── ─────────────────────
└── Quit Tmux Pane Mirror    ⌘Q

File
├── New Mirror               ⌘N
├── Close Window             ⌘W
└── Close All Mirrors        ⇧⌘W

View
├── Refresh Pane List        ⌘R
├── Toggle Status Bar        ⇧⌘S
└── Toggle Scrollback        ⌘K

Window
├── Minimize                 ⌘M
├── Zoom
├── ─────────────────────
├── Bring All to Front
├── ─────────────────────
└── [List of open mirrors]
```

## Settings

```
┌─────────────────────────────────────────────────────────────┐
│  Settings                                                   │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Terminal                                                   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ Font:        [SF Mono           ▼]  Size: [12  ]    │   │
│  │ Scrollback:  [10000    ] lines                      │   │
│  │ Theme:       [Default Dark      ▼]                  │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  Behavior                                                   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ [✓] Restore windows on launch                       │   │
│  │ [✓] Show status bar                                 │   │
│  │ [ ] Auto-reconnect on connection loss               │   │
│  │ Reconnect delay: [5    ] seconds                    │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  tmux                                                       │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ Path: [/opt/homebrew/bin/tmux    ] [Browse...]      │   │
│  │ Socket: [Default                  ]                 │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## File Structure

```
TmuxPaneMirror/
├── Package.swift
├── README.md
├── Sources/
│   └── TmuxPaneMirror/
│       ├── App/
│       │   ├── TmuxPaneMirrorApp.swift
│       │   └── AppDelegate.swift
│       ├── Views/
│       │   ├── MainView.swift
│       │   ├── PaneListView.swift
│       │   ├── MirrorWindowView.swift
│       │   ├── TerminalContainerView.swift
│       │   └── SettingsView.swift
│       ├── ViewModels/
│       │   ├── MainViewModel.swift
│       │   ├── PaneListViewModel.swift
│       │   └── MirrorViewModel.swift
│       ├── Services/
│       │   ├── TmuxService.swift
│       │   └── PaneStream.swift
│       ├── Models/
│       │   ├── PaneInfo.swift
│       │   └── Settings.swift
│       ├── Managers/
│       │   └── MirrorWindowManager.swift
│       └── Utilities/
│           ├── ProcessRunner.swift
│           └── FIFOReader.swift
└── Tests/
    └── TmuxPaneMirrorTests/
        ├── TmuxServiceTests.swift
        └── PaneStreamTests.swift
```

## Future Enhancements

- **Input forwarding**: Optional mode to send keystrokes to the mirrored pane
- **Multi-pane view**: Tile multiple panes in a single window
- **Search**: Search through scrollback buffer
- **Logging**: Save pane output to file
- **Snapshots**: Capture current terminal state as image
- **Remote tmux**: Connect to tmux over SSH
- **Touch Bar**: Quick access to recent panes
- **Widgets**: macOS widget showing pane status
