# ClaudeSpy Architecture

ClaudeSpy is a native macOS application that displays real-time mirrors of tmux panes in dedicated windows. It integrates with Claude Code via HTTP hooks to automatically open and close mirror windows when Claude Code sessions start and end.

## Component Overview

### Core Services

| Component | Type | Responsibility |
|-----------|------|----------------|
| **TmuxService** | `@Observable @MainActor` | Abstracts all tmux CLI interactions - pane discovery, content capture, streaming setup |
| **PaneStream** | `@Observable @MainActor` | Manages streaming connection lifecycle for a single tmux pane |
| **MirrorWindowManager** | `@Observable @MainActor` | NSWindow lifecycle management and hook event routing |
| **HookServerService** | `actor` | HTTP server (port 6111) receiving Claude Code hook events |
| **TerminalController** | `@Observable @MainActor` | Bridges SwiftTerm to SwiftUI with fixed terminal dimensions |
| **AppSettings** | `@Observable @MainActor` | Persistent configuration via UserDefaults |

### Utilities

| Component | Type | Responsibility |
|-----------|------|----------------|
| **ProcessRunner** | `actor` | Executes external processes asynchronously |
| **FIFOReader** | `actor` | Manages named pipes for streaming tmux output |
| **FontMetrics** | `enum` | Calculates terminal font metrics matching SwiftTerm |

## Component Relationships

```mermaid
graph TB
    subgraph "App Entry Point"
        App[TmuxPaneMirrorApp]
    end

    subgraph "Services"
        TS[TmuxService]
        HS[HookServerService]
        MWM[MirrorWindowManager]
        AS[AppSettings]
    end

    subgraph "Utilities"
        PR[ProcessRunner]
        FR[FIFOReader]
        FM[FontMetrics]
    end

    subgraph "Views"
        MV[MainView]
        MWV[MirrorWindowView]
        TC[TerminalController]
        PS[PaneStream]
    end

    App -->|creates| TS
    App -->|creates| HS
    App -->|creates| MWM
    App -->|creates| AS

    HS -->|hook events| MWM
    MWM -->|uses| TS
    MWM -->|uses| AS
    MWM -->|creates| MWV

    MV -->|uses| TS
    MV -->|uses| MWM

    MWV -->|creates| PS
    MWV -->|creates| TC
    MWV -->|uses| AS

    PS -->|uses| TS
    TS -->|uses| PR
    TS -->|uses| FR

    TC -->|uses| FM
```

## Service Details

### TmuxService

Central abstraction for all tmux CLI interactions.

```mermaid
graph LR
    subgraph "TmuxService"
        direction TB
        A[checkAvailability]
        B[refreshPanes]
        C[capturePane]
        D[capturePaneWithPositioning]
        E[startPipePipe]
        F[stopPipePipe]
        G[getPaneDimensions]
    end

    PR[ProcessRunner] --> A
    PR --> B
    PR --> C
    PR --> D
    PR --> E
    PR --> F
    PR --> G

    E --> FR[FIFOReader]
```

**Key Operations:**
- **Pane Discovery:** `list-panes -a` to enumerate all panes
- **Content Capture:** `capture-pane -p -e` for ANSI-preserved content
- **Streaming:** `pipe-pane` to FIFO for live output

### PaneStream

Manages the streaming connection lifecycle for a single pane.

```mermaid
stateDiagram-v2
    [*] --> disconnected
    disconnected --> connecting: connect()
    connecting --> connected: success
    connecting --> error: failure
    connected --> paused: pause()
    paused --> connected: resume()
    connected --> disconnected: disconnect()
    paused --> disconnected: disconnect()
    error --> disconnected: disconnect()
```

### MirrorWindowManager

Manages NSWindow instances and handles hook events.

```mermaid
graph TB
    subgraph "Window Tracking"
        OW[openWindows: Dictionary]
        AP[activePanes: Set]
        UC[userClosedPanes: Set]
    end

    subgraph "Operations"
        HE[handleHookEvent]
        OM[openMirror]
        CM[closeMirror]
        BTF[bringToFront]
    end

    HE -->|SessionStart/PreToolUse| AP
    HE -->|if not user-closed| OM
    HE -->|SessionEnd| CM

    OM --> OW
    CM --> OW

    UC -->|prevents auto-reopen| OM
```

### HookServerService

Vapor-based HTTP server receiving Claude Code events.

**Endpoints:**
- `GET /health` - Health check
- `POST /api/hooks` - Hook event receiver

**Query Parameters:**
- `project_path` - Project directory
- `tmux_pane` - Target pane (e.g., `main:0.1`)

## Hook Event Flow

This diagram shows the complete flow from a Claude Code event to a rendered mirror window.

```mermaid
sequenceDiagram
    participant CC as Claude Code
    participant HS as HookServerService
    participant MWM as MirrorWindowManager
    participant TS as TmuxService
    participant MWV as MirrorWindowView
    participant PS as PaneStream
    participant TC as TerminalController
    participant FR as FIFOReader

    CC->>HS: POST /api/hooks?tmux_pane=main:0.1
    Note over HS: Parse JSON body<br/>Extract hook_event_name

    HS->>MWM: handleHookEvent(event)

    alt SessionStart or PreToolUse
        MWM->>MWM: Add to activePanes
        MWM->>MWM: Check userClosedPanes

        opt Not user-closed
            MWM->>TS: refreshPanes()
            TS-->>MWM: [PaneInfo]
            MWM->>MWM: Find pane by ID
            MWM->>MWV: Create MirrorWindowView
            MWM->>MWM: Create NSWindow
            MWM->>MWM: Store in openWindows

            MWV->>PS: Create PaneStream
            MWV->>TC: Create TerminalController

            PS->>TS: validatePane()
            PS->>TS: getPaneDimensions()
            PS->>TS: capturePaneWithPositioning()
            TS-->>PS: Initial content
            PS->>TC: feed(initialContent)

            PS->>TS: startPipePipe()
            TS->>FR: createFIFO()
            TS->>FR: startReading()

            loop Streaming
                FR-->>PS: AsyncStream<Data>
                PS->>TC: feed(data)
                TC->>TC: SwiftTerm renders
            end
        end

    else SessionEnd
        MWM->>MWM: Remove from activePanes
        MWM->>MWM: Clear from userClosedPanes
        MWM->>MWM: closeMirror(target)
        MWM->>PS: disconnect()
        PS->>TS: stopPipePipe()
        TS->>FR: stop()
    end

    HS-->>CC: HookResponse(approve)
```

## Data Flow: Tmux Output to Terminal Display

```mermaid
flowchart LR
    subgraph Tmux
        TP[Tmux Pane]
    end

    subgraph ClaudeSpy
        PP[pipe-pane command]
        FIFO[Named Pipe<br/>/tmp/tmux-mirror-*.fifo]
        FR[FIFOReader]
        PS[PaneStream]
        TC[TerminalController]
        ST[SwiftTerm<br/>TerminalView]
    end

    TP -->|output| PP
    PP -->|cat >| FIFO
    FIFO -->|FileHandle| FR
    FR -->|AsyncStream<Data>| PS
    PS -->|onData callback| TC
    TC -->|feed()| ST
    ST -->|renders| Display[Mirror Window]
```

## Window Lifecycle

```mermaid
stateDiagram-v2
    [*] --> Closed

    Closed --> Opening: Hook event received
    Opening --> Open: Window created

    Open --> Closed: SessionEnd hook
    Open --> UserClosed: User closes window

    UserClosed --> Closed: SessionEnd hook
    UserClosed --> UserClosed: Hook events ignored

    note right of UserClosed
        Window stays closed until
        session ends, then state
        resets for next session
    end note
```

## Concurrency Model

ClaudeSpy uses Swift 6 strict concurrency with a clear isolation strategy:

```mermaid
graph TB
    subgraph "@MainActor (UI Thread)"
        TS[TmuxService]
        PS[PaneStream]
        MWM[MirrorWindowManager]
        TC[TerminalController]
        AS[AppSettings]
        Views[All SwiftUI Views]
    end

    subgraph "Actor-Isolated (Background)"
        PR[ProcessRunner]
        FR[FIFOReader]
        HS[HookServerService]
    end

    PR -.->|async calls| TS
    FR -.->|AsyncStream| PS
    HS -.->|callback on MainActor| MWM
```

**Key Points:**
- All UI-bound services are `@MainActor` isolated
- Background I/O uses dedicated actors
- Hook server runs independently but dispatches to `@MainActor` for UI updates
- All cross-isolation communication uses async/await

## File Structure

```
ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/
├── Hooks/
│   ├── HookModels.swift          # Event types, ToolInput enum
│   └── HookServerService.swift   # Vapor HTTP server
├── Managers/
│   └── MirrorWindowManager.swift # Window lifecycle
├── Models/
│   ├── PaneInfo.swift            # Tmux pane representation
│   └── Settings.swift            # AppSettings
├── Services/
│   ├── PaneStream.swift          # Stream management
│   └── TmuxService.swift         # Tmux abstraction
├── Utilities/
│   ├── FIFOReader.swift          # Named pipe handling
│   ├── FontMetrics.swift         # Terminal sizing
│   └── ProcessRunner.swift       # Process execution
└── Views/
    ├── ContentView.swift         # Root view
    ├── MainView.swift            # Pane list
    ├── MirrorWindowView.swift    # Mirror display
    ├── PaneListView.swift        # Pane list items
    ├── SettingsView.swift        # Settings UI
    └── TerminalContainerView.swift # SwiftTerm bridge
```
