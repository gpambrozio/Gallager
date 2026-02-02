# Terminal Streaming Architecture

This document describes how terminal data flows from a tmux session on the Mac to both the local Mac mirror view and remote iOS devices. The architecture achieves low-latency mirroring with proper UTF-8 handling, data batching, and end-to-end encryption.

## High-Level Overview

```mermaid
graph TB
    subgraph Mac["Mac (ClaudeSpyServer)"]
        TMUX[tmux session]
        TCC[TmuxControlClient]
        PS[PaneStream]
        PSM[PaneStreamManager]
        TSS[TerminalStreamService]
        ESC[ExternalServerClient]
        MV[Mac Mirror View<br/>SwiftTerm]
    end

    subgraph Server["External Relay Server"]
        CH[ConnectionHub]
        RS[RelayService]
    end

    subgraph iOS["iOS (ClaudeSpy)"]
        RC[RelayClient]
        SC[StreamCoordinator]
        TS[TerminalState]
        IV[iOS Terminal View<br/>SwiftTerm]
    end

    TMUX -->|control mode| TCC
    TCC -->|%output events| PS
    PS -->|onData callback| PSM
    PSM -->|subscriber| MV
    PSM -->|subscriber| TSS
    TSS -->|batched + encrypted| ESC
    ESC <-->|WebSocket| CH
    CH <--> RS
    CH <-->|WebSocket| RC
    RC -->|onTerminalStream| SC
    SC --> TS
    TS --> IV
```

## Component Details

### 1. Tmux Capture (Mac)

The Mac app uses **tmux control mode** for real-time event capture instead of polling.

```mermaid
sequenceDiagram
    participant T as tmux
    participant TCC as TmuxControlClient
    participant PS as PaneStream

    TCC->>T: tmux -C attach -t session
    T-->>TCC: (control mode ready)

    loop Output Events
        T->>TCC: %output %0 <escaped data>
        TCC->>TCC: Unescape octal sequences
        TCC->>TCC: Handle UTF-8 buffering
        TCC->>PS: handler(data)
    end

    T->>TCC: %layout-change
    TCC->>TCC: Update cached dimensions
    TCC->>PS: Dimension change callback
```

**Key Files:**
- `ClaudeSpyServerFeature/Services/TmuxControlClient.swift`
- `ClaudeSpyServerFeature/Services/TmuxService.swift`

**TmuxControlClient** is an actor that:
- Maintains a long-lived `tmux -C attach` process
- Parses structured events (`%output`, `%layout-change`, `%session-changed`, `%exit`)
- Handles UTF-8 sequences split across multiple `%output` lines via per-pane buffering
- Unescapes octal sequences (`\033` → ESC byte)

### 2. Local Stream Management (Mac)

**PaneStream** manages a single pane's connection lifecycle:

```mermaid
stateDiagram-v2
    [*] --> disconnected
    disconnected --> connecting: connect()
    connecting --> connected: validation success
    connecting --> error: validation failed
    connected --> disconnected: disconnect()
    error --> disconnected: reset
```

**PaneStreamManager** multiplexes streams to multiple subscribers:

```mermaid
graph LR
    subgraph PaneStreamManager
        PS1[PaneStream<br/>session:0.1]
        PS2[PaneStream<br/>session:0.2]
    end

    PS1 --> S1[Mirror Window]
    PS1 --> S2[TerminalStreamService]
    PS2 --> S3[Mirror Window 2]
    PS2 --> S4[TerminalStreamService]
```

**Key Files:**
- `ClaudeSpyServerFeature/Services/PaneStream.swift`
- `ClaudeSpyServerFeature/Services/PaneStreamManager.swift`

Subscribers share a single stream—when the last subscriber unsubscribes, the stream disconnects.

### 3. Mac Mirror View

The local Mac mirror receives data through a PaneStreamManager subscription:

```mermaid
flowchart LR
    PSM[PaneStreamManager] -->|onData| ITV[InteractiveTerminalView]
    ITV --> ST[SwiftTerm]
    ITV -->|onInput| TS[TmuxService.sendKeys]
```

**Key File:** `ClaudeSpyServerFeature/Views/InteractiveTerminalView.swift`

### 4. Remote Streaming (Mac → Server)

**TerminalStreamService** bridges local streams to the external server:

```mermaid
sequenceDiagram
    participant PSM as PaneStreamManager
    participant TSS as TerminalStreamService
    participant ESC as ExternalServerClient
    participant E2E as E2EE

    PSM->>TSS: onData (raw bytes)
    TSS->>TSS: Buffer data

    alt Batch ready (8KB or 50ms)
        TSS->>TSS: Create TerminalStreamMessage
        TSS->>E2E: Encrypt message
        E2E-->>TSS: Encrypted payload
        TSS->>ESC: sendTerminalStream()
        ESC->>ESC: WebSocket send
    end
```

**Batching Strategy:**
- Minimum interval: 50ms (max 20 updates/sec)
- Maximum batch size: 8KB
- Prevents network saturation from high-frequency terminal updates

**Message Types:**
```swift
enum StreamUpdateType {
    case initialState(InitialState)     // Full buffer on stream start
    case dataChunk(DataChunk)           // Incremental updates
    case dimensionChange(DimensionChange) // Terminal resized
    case streamEnd                       // Stream closed
}
```

**Key Files:**
- `ClaudeSpyServerFeature/Services/TerminalStreamService.swift`
- `ClaudeSpyServerFeature/Services/ExternalServerClient.swift`

### 5. External Relay Server

The Vapor server routes messages between paired Mac and iOS devices:

```mermaid
flowchart TB
    subgraph WebSocket Connections
        MAC[Mac Client]
        IOS[iOS Client]
    end

    subgraph Server Logic
        WC[WebSocketController]
        RS[RelayService]
        CH[ConnectionHub]
    end

    MAC <-->|/api/ws?pairId=X&deviceType=mac| WC
    IOS <-->|/api/ws?pairId=X&deviceType=ios| WC
    WC <--> RS
    RS <--> CH
```

**ConnectionHub** maintains the connection registry:

```mermaid
graph TB
    subgraph "connections[pairId]"
        subgraph "pair-abc123"
            M1[mac: Connection]
            I1[ios: Connection]
        end
        subgraph "pair-xyz789"
            M2[mac: Connection]
            I2[ios: Connection]
        end
    end
```

**Message Routing:**
1. Mac sends encrypted `WebSocketMessage.terminalStream(...)`
2. RelayService receives message, looks up iOS connection by pairId
3. ConnectionHub forwards to iOS (encrypted payload is pass-through)
4. Server cannot decrypt—true end-to-end encryption

**Key Files:**
- `ClaudeSpyExternalServer/Routes/WebSocketController.swift`
- `ClaudeSpyExternalServer/Services/RelayService.swift`
- `ClaudeSpyExternalServer/Services/ConnectionHub.swift`

### 6. iOS Reception

**RelayClient** receives WebSocket messages and decrypts them:

```mermaid
sequenceDiagram
    participant WS as WebSocket
    participant RC as RelayClient
    participant E2E as E2EE
    participant SC as StreamCoordinator

    WS->>RC: Encrypted message
    RC->>E2E: Decrypt
    E2E-->>RC: TerminalStreamMessage
    RC->>SC: onTerminalStream(message)
```

**Key File:** `ClaudeSpyFeature/Services/RelayClient.swift`

### 7. iOS Display

**StreamCoordinator** manages the streaming session state:

```mermaid
stateDiagram-v2
    [*] --> idle
    idle --> starting: startStreaming()
    starting --> streaming: initialState received
    streaming --> streaming: dataChunk/dimensionChange
    streaming --> ended: streamEnd
    ended --> idle: reset
```

**Data flow to terminal:**

```mermaid
flowchart LR
    SC[StreamCoordinator] --> TS[TerminalState]
    TS -->|onData| STV[SwiftTerm]
    TS -->|onResize| STV
```

**Key Files:**
- `ClaudeSpyFeature/Views/LiveTerminalView.swift`
- `ClaudeSpyFeature/Views/TerminalStreamContainerView.swift`

## Complete Data Flow

```mermaid
sequenceDiagram
    participant TMUX as tmux
    participant TCC as TmuxControlClient
    participant PS as PaneStream
    participant PSM as PaneStreamManager
    participant MV as Mac Mirror
    participant TSS as TerminalStreamService
    participant ESC as ExternalServerClient
    participant SRV as Relay Server
    participant RC as RelayClient
    participant SC as StreamCoordinator
    participant IV as iOS Terminal

    Note over TMUX,IV: Initial Stream Setup

    RC->>SRV: StartTerminalStream command
    SRV->>ESC: Forward command
    ESC->>TSS: Start stream for pane
    TSS->>PSM: subscribe(paneId)
    PSM->>PS: connect()
    PS->>TCC: registerPaneHandler()
    TCC->>TMUX: (already in control mode)
    PS->>PS: capturePaneWithScrollbackForStreaming()
    PS-->>PSM: onData(initial content)
    PSM-->>TSS: subscriber callback
    TSS->>ESC: sendTerminalStream(initialState)
    ESC->>SRV: Encrypted message
    SRV->>RC: Forward to iOS
    RC->>SC: onTerminalStream(initialState)
    SC->>IV: feed(content)

    Note over TMUX,IV: Live Updates

    loop Terminal Output
        TMUX->>TCC: %output %0 <data>
        TCC->>PS: handler(data)
        PS-->>PSM: onData(data)
        PSM-->>MV: subscriber callback (immediate)
        PSM-->>TSS: subscriber callback
        TSS->>TSS: Buffer (batch)
        TSS->>ESC: sendTerminalStream(dataChunk)
        ESC->>SRV: Encrypted
        SRV->>RC: Forward
        RC->>SC: onTerminalStream(dataChunk)
        SC->>IV: feed(data)
    end
```

## Key Architectural Decisions

| Decision | Rationale |
|----------|-----------|
| **Control mode over polling** | Real-time events with sub-frame latency vs periodic `capture-pane` |
| **Per-pane UTF-8 buffering** | Handles UTF-8 sequences split across `%output` lines |
| **Stream manager decoupling** | Streaming works without mirror window open, only needs iOS connection |
| **Data batching (8KB/50ms)** | Prevents network saturation from high-frequency output |
| **Subscription model** | Multiple consumers (UI + remote) share one stream efficiently |
| **E2EE encryption** | Server cannot decrypt terminal content—true end-to-end security |
| **Session ID validation** | Prevents stale callbacks from old sessions affecting new ones |
| **Fail-closed E2EE** | Refuses to send sensitive data if encryption session not established |

## Key Types Reference

| Type | Location | Purpose |
|------|----------|---------|
| `TmuxControlClient` | ServerFeature | Long-lived tmux control mode, parses `%output` |
| `PaneStream` | ServerFeature | Single pane stream with lifecycle |
| `PaneStreamManager` | ServerFeature | Multiplexes streams to subscribers |
| `TerminalStreamService` | ServerFeature | Batches and sends to remote |
| `ExternalServerClient` | ServerFeature | Mac's WebSocket client |
| `ConnectionHub` | ExternalServer | Server-side routing |
| `RelayService` | ExternalServer | Message handling |
| `RelayClient` | Feature (iOS) | iOS WebSocket client |
| `StreamCoordinator` | Feature (iOS) | iOS streaming state |
| `TerminalState` | Feature (iOS) | Bridge to SwiftTerm |
| `TerminalStreamMessage` | Networking | Shared message model |
