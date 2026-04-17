# Gallager CLI API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement a cmux-compatible CLI API for Gallager, enabling programmatic control of tmux sessions, windows, panes, input, and notifications via JSON-RPC over Unix socket.

**Architecture:** A `gallager` CLI binary (replacing GallagerEditor) sends JSON-RPC requests over a Unix domain socket to an `APISocketServer` inside the macOS app. The server dispatches to an `APIRequestRouter` which calls existing services (TmuxService, MirrorWindowManager, etc.). Both server and router are `@DependencyClient` structs.

**Tech Stack:** Swift 6.1, ArgumentParser, swift-dependencies (@DependencyClient), Unix domain sockets, JSON-RPC (newline-delimited JSON)

**Spec:** `docs/superpowers/specs/2026-04-14-gallager-cli-api-design.md`

---

## File Map

| File | Purpose | Action |
|------|---------|--------|
| `ClaudeSpyPackage/Package.swift` | Rename GallagerEditor → Gallager, add dependencies | Modify |
| `ClaudeSpyPackage/Sources/Gallager/GallagerCLI.swift` | Root CLI command with global options | Create |
| `ClaudeSpyPackage/Sources/Gallager/SocketClient.swift` | Unix socket client for JSON-RPC | Create |
| `ClaudeSpyPackage/Sources/Gallager/Commands/SessionCommands.swift` | list-sessions, new-session, etc. | Create |
| `ClaudeSpyPackage/Sources/Gallager/Commands/WindowCommands.swift` | list-windows, new-window, etc. | Create |
| `ClaudeSpyPackage/Sources/Gallager/Commands/PaneCommands.swift` | list-panes, split-pane, select-pane | Create |
| `ClaudeSpyPackage/Sources/Gallager/Commands/InputCommands.swift` | send, send-key | Create |
| `ClaudeSpyPackage/Sources/Gallager/Commands/NotifyCommand.swift` | notify | Create |
| `ClaudeSpyPackage/Sources/Gallager/Commands/EditCommand.swift` | edit (replaces GallagerEditor) | Create |
| `ClaudeSpyPackage/Sources/Gallager/Commands/UtilityCommands.swift` | ping, capabilities, identify | Create |
| `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/JSONRPC.swift` | JSON-RPC request/response types | Create |
| `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/APIModels.swift` | SessionInfo, WindowInfo, APIPaneInfo, IdentifyInfo | Create |
| `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/APISocketServer.swift` | @DependencyClient socket server | Create |
| `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/APIRequestRouter.swift` | @DependencyClient request dispatcher | Create |
| `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/EditorSocketServer.swift` | Remove (replaced by APISocketServer) | Delete |
| `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Coordinators/AppCoordinator.swift` | Wire APISocketServer, update env vars | Modify |
| `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Managers/EditorSessionManager.swift` | Update to work with APISocketServer | Modify |
| `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/TmuxService.swift` | Update env var names (GALLAGER_SOCKET) | Modify |
| `ClaudeSpyPackage/Sources/GallagerEditor/GallagerEditor.swift` | Remove (replaced by Gallager/Commands/EditCommand.swift) | Delete |
| `ClaudeSpyPackage/Tests/ClaudeSpyNetworkingTests/JSONRPCTests.swift` | JSON-RPC encode/decode tests | Create |
| `ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/APIRequestRouterTests.swift` | Router dispatch tests | Create |
| `docs/gallager-cli-api.md` | API reference documentation | Create |

---

### Task 1: JSON-RPC Types

Shared types used by both CLI and server for the wire protocol.

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/JSONRPC.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyNetworkingTests/JSONRPCTests.swift`

- [ ] **Step 1: Write failing test for JSON-RPC request encoding**

In `ClaudeSpyPackage/Tests/ClaudeSpyNetworkingTests/JSONRPCTests.swift`:

```swift
import Testing
@testable import ClaudeSpyNetworking
import Foundation

@Test
func requestEncodesToJSON() throws {
    let request = JSONRPCRequest(
        id: "test-1",
        method: "session.list",
        params: [:]
    )
    let data = try JSONEncoder().encode(request)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["id"] as? String == "test-1")
    #expect(json["method"] as? String == "session.list")
    #expect(json["params"] is [String: Any])
}

@Test
func successResponseDecodable() throws {
    let json = """
    {"id":"test-1","ok":true,"result":{"pong":true}}
    """.data(using: .utf8)!
    let response = try JSONDecoder().decode(JSONRPCResponse.self, from: json)
    #expect(response.id == "test-1")
    #expect(response.ok == true)
    #expect(response.error == nil)
}

@Test
func errorResponseDecodable() throws {
    let json = """
    {"id":"test-2","ok":false,"error":{"code":"not_found","message":"Session not found"}}
    """.data(using: .utf8)!
    let response = try JSONDecoder().decode(JSONRPCResponse.self, from: json)
    #expect(response.id == "test-2")
    #expect(response.ok == false)
    #expect(response.error?.code == "not_found")
    #expect(response.error?.message == "Session not found")
}

@Test
func requestWithTypedParams() throws {
    let params: [String: JSONValue] = [
        "session_id": .string("my-session"),
        "name": .string("test"),
    ]
    let request = JSONRPCRequest(id: "test-3", method: "session.create", params: params)
    let data = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(JSONRPCRequest.self, from: data)
    #expect(decoded.params["session_id"] == .string("my-session"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `$(cat ${TMPDIR:-/tmp}/claude-sandbox-$(echo $PPID))/bin/swift test --filter JSONRPCTests`
Expected: FAIL — types don't exist yet

- [ ] **Step 3: Implement JSON-RPC types**

In `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/JSONRPC.swift`:

```swift
import Foundation

/// A JSON value that can be used in JSON-RPC params and results.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.typeMismatch(
                JSONValue.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .null: try container.encodeNil()
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }

    /// Convenience accessor for string values.
    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    /// Convenience accessor for bool values.
    public var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    /// Convenience accessor for int values.
    public var intValue: Int? {
        if case .int(let v) = self { return v }
        return nil
    }
}

/// A JSON-RPC request sent from the CLI to the socket server.
public struct JSONRPCRequest: Codable, Sendable {
    public let id: String
    public let method: String
    public let params: [String: JSONValue]

    public init(id: String, method: String, params: [String: JSONValue]) {
        self.id = id
        self.method = method
        self.params = params
    }
}

/// Error detail in a JSON-RPC error response.
public struct JSONRPCError: Codable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// A JSON-RPC response sent from the socket server to the CLI.
public struct JSONRPCResponse: Codable, Sendable {
    public let id: String
    public let ok: Bool
    public let result: [String: JSONValue]?
    public let error: JSONRPCError?

    public init(id: String, result: [String: JSONValue]) {
        self.id = id
        self.ok = true
        self.result = result
        self.error = nil
    }

    public init(id: String, error: JSONRPCError) {
        self.id = id
        self.ok = false
        self.result = nil
        self.error = error
    }

    /// Convenience for simple success with no data.
    public static func ok(id: String) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: ["ok": .bool(true)])
    }

    /// Convenience for not-found errors.
    public static func notFound(id: String, _ message: String) -> JSONRPCResponse {
        JSONRPCResponse(id: id, error: JSONRPCError(code: "not_found", message: message))
    }

    /// Convenience for invalid-params errors.
    public static func invalidParams(id: String, _ message: String) -> JSONRPCResponse {
        JSONRPCResponse(id: id, error: JSONRPCError(code: "invalid_params", message: message))
    }

    /// Convenience for method-not-found errors.
    public static func methodNotFound(id: String, _ method: String) -> JSONRPCResponse {
        JSONRPCResponse(id: id, error: JSONRPCError(code: "method_not_found", message: "Unknown method: \(method)"))
    }

    /// Convenience for internal errors.
    public static func internalError(id: String, _ message: String) -> JSONRPCResponse {
        JSONRPCResponse(id: id, error: JSONRPCError(code: "internal_error", message: message))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `$(cat ${TMPDIR:-/tmp}/claude-sandbox-$(echo $PPID))/bin/swift test --filter JSONRPCTests`
Expected: All 4 tests PASS

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/JSONRPC.swift \
       ClaudeSpyPackage/Tests/ClaudeSpyNetworkingTests/JSONRPCTests.swift
git commit -m "feat: add JSON-RPC wire protocol types (#343)"
```

---

### Task 2: API Response Models

API-facing models for sessions, windows, panes, and identify info.

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/APIModels.swift`

- [ ] **Step 1: Create API models**

In `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/APIModels.swift`:

```swift
import Foundation

/// API representation of a tmux session.
public struct APISessionInfo: Codable, Sendable {
    public let id: String
    public let name: String
    public let windowCount: Int
    public let isAttached: Bool

    public init(id: String, name: String, windowCount: Int, isAttached: Bool) {
        self.id = id
        self.name = name
        self.windowCount = windowCount
        self.isAttached = isAttached
    }

    /// Encode this model into a JSONValue dictionary for JSON-RPC responses.
    public func toJSONValue() -> [String: JSONValue] {
        [
            "id": .string(id),
            "name": .string(name),
            "window_count": .int(windowCount),
            "is_attached": .bool(isAttached),
        ]
    }
}

/// API representation of a tmux window.
public struct APIWindowInfo: Codable, Sendable {
    public let id: String
    public let index: Int
    public let name: String
    public let paneCount: Int
    public let isActive: Bool
    public let sessionId: String

    public init(id: String, index: Int, name: String, paneCount: Int, isActive: Bool, sessionId: String) {
        self.id = id
        self.index = index
        self.name = name
        self.paneCount = paneCount
        self.isActive = isActive
        self.sessionId = sessionId
    }

    public func toJSONValue() -> [String: JSONValue] {
        [
            "id": .string(id),
            "index": .int(index),
            "name": .string(name),
            "pane_count": .int(paneCount),
            "is_active": .bool(isActive),
            "session_id": .string(sessionId),
        ]
    }
}

/// API representation of a tmux pane.
public struct APIPaneInfo: Codable, Sendable {
    public let id: String
    public let index: Int
    public let isActive: Bool
    public let command: String?
    public let cwd: String?
    public let width: Int
    public let height: Int
    public let windowId: String
    public let hasClaudeSession: Bool

    public init(
        id: String,
        index: Int,
        isActive: Bool,
        command: String?,
        cwd: String?,
        width: Int,
        height: Int,
        windowId: String,
        hasClaudeSession: Bool
    ) {
        self.id = id
        self.index = index
        self.isActive = isActive
        self.command = command
        self.cwd = cwd
        self.width = width
        self.height = height
        self.windowId = windowId
        self.hasClaudeSession = hasClaudeSession
    }

    public func toJSONValue() -> [String: JSONValue] {
        [
            "id": .string(id),
            "index": .int(index),
            "is_active": .bool(isActive),
            "command": command.map { .string($0) } ?? .null,
            "cwd": cwd.map { .string($0) } ?? .null,
            "width": .int(width),
            "height": .int(height),
            "window_id": .string(windowId),
            "has_claude_session": .bool(hasClaudeSession),
        ]
    }
}

/// API response for the identify command.
public struct APIIdentifyInfo: Codable, Sendable {
    public let session: APISessionInfo?
    public let window: APIWindowInfo?
    public let pane: APIPaneInfo?

    public init(session: APISessionInfo?, window: APIWindowInfo?, pane: APIPaneInfo?) {
        self.session = session
        self.window = window
        self.pane = pane
    }

    public func toJSONValue() -> [String: JSONValue] {
        [
            "session": session.map { .object($0.toJSONValue()) } ?? .null,
            "window": window.map { .object($0.toJSONValue()) } ?? .null,
            "pane": pane.map { .object($0.toJSONValue()) } ?? .null,
        ]
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `$(cat ${TMPDIR:-/tmp}/claude-sandbox-$(echo $PPID))/bin/swift build --target ClaudeSpyNetworking`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/APIModels.swift
git commit -m "feat: add API response models for CLI (#343)"
```

---

### Task 3: Package.swift Updates

Rename the GallagerEditor target to Gallager and add required dependencies.

**Files:**
- Modify: `ClaudeSpyPackage/Package.swift`
- Delete: `ClaudeSpyPackage/Sources/GallagerEditor/GallagerEditor.swift`
- Create: `ClaudeSpyPackage/Sources/Gallager/` directory

- [ ] **Step 1: Update Package.swift**

In `ClaudeSpyPackage/Package.swift`, make these changes:

1. Rename the product from `GallagerEditor` to `Gallager`:
```swift
// Replace:
.executable(
    name: "GallagerEditor",
    targets: ["GallagerEditor"]
),
// With:
.executable(
    name: "Gallager",
    targets: ["Gallager"]
),
```

2. Replace the target definition:
```swift
// Replace:
.executableTarget(
    name: "GallagerEditor"
),
// With:
.executableTarget(
    name: "Gallager",
    dependencies: [
        .argumentParser,
        .claudeSpyNetworking,
    ]
),
```

- [ ] **Step 2: Create Gallager source directory and placeholder**

```bash
mkdir -p ClaudeSpyPackage/Sources/Gallager/Commands
```

Create a minimal `ClaudeSpyPackage/Sources/Gallager/GallagerCLI.swift` placeholder:

```swift
import ArgumentParser

@main
struct GallagerCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gallager",
        abstract: "Control Gallager from the command line",
        subcommands: [PingCommand.self]
    )
}

struct PingCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ping",
        abstract: "Check if Gallager is running"
    )

    func run() throws {
        print("ping placeholder")
    }
}
```

- [ ] **Step 3: Delete old GallagerEditor source**

```bash
rm -rf ClaudeSpyPackage/Sources/GallagerEditor
```

- [ ] **Step 4: Verify it compiles**

Run: `$(cat ${TMPDIR:-/tmp}/claude-sandbox-$(echo $PPID))/bin/swift build --target Gallager`
Expected: Build succeeds

- [ ] **Step 5: Update Xcode project references**

The Xcode project (ClaudeSpyServer target) embeds GallagerEditor as an auxiliary executable. Search for "GallagerEditor" in the `.xcodeproj` or `.pbxproj` file and update to "Gallager". The relevant setting is the "Copy Files" build phase that copies the binary into the app bundle.

Run: `grep -r "GallagerEditor" ClaudeSpyServer.xcodeproj/ ClaudeSpyPackage/` to find all references, then update them.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: rename GallagerEditor to Gallager CLI (#343)"
```

---

### Task 4: Socket Client (CLI side)

The CLI-side Unix socket client that sends JSON-RPC requests and reads responses.

**Files:**
- Create: `ClaudeSpyPackage/Sources/Gallager/SocketClient.swift`

- [ ] **Step 1: Implement SocketClient**

In `ClaudeSpyPackage/Sources/Gallager/SocketClient.swift`:

```swift
import ClaudeSpyNetworking
import Foundation

/// Connects to the Gallager app's Unix domain socket and sends JSON-RPC requests.
enum SocketClient {
    /// Resolves the socket path from environment or default.
    static var socketPath: String {
        ProcessInfo.processInfo.environment["GALLAGER_SOCKET"]
            ?? NSTemporaryDirectory() + "gallager.sock"
    }

    /// Sends a JSON-RPC request and returns the response.
    /// For most commands this is a simple request-response.
    static func send(_ request: JSONRPCRequest, socketPath: String? = nil) throws -> JSONRPCResponse {
        let path = socketPath ?? self.socketPath
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw CLIError.socketCreationFailed
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
                let raw = UnsafeMutableRawPointer(sunPath)
                raw.copyMemory(from: ptr, byteCount: path.utf8.count + 1)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, addrLen)
            }
        }
        guard connected == 0 else {
            throw CLIError.connectionFailed
        }

        // Encode and send request
        let encoder = JSONEncoder()
        var data = try encoder.encode(request)
        data.append(UInt8(ascii: "\n"))

        let written = data.withUnsafeBytes { ptr in
            Darwin.write(fd, ptr.baseAddress!, ptr.count)
        }
        guard written == data.count else {
            throw CLIError.writeFailed
        }

        // Read response (newline-delimited JSON)
        var responseData = Data()
        var byte: UInt8 = 0
        while Darwin.read(fd, &byte, 1) == 1 {
            if byte == UInt8(ascii: "\n") { break }
            responseData.append(byte)
        }

        guard !responseData.isEmpty else {
            throw CLIError.emptyResponse
        }

        return try JSONDecoder().decode(JSONRPCResponse.self, from: responseData)
    }

    /// Sends a request and blocks until response (used by `edit` command which waits for user action).
    static func sendAndWait(_ request: JSONRPCRequest, socketPath: String? = nil) throws -> JSONRPCResponse {
        // Same as send() — the blocking behavior comes from the server not responding
        // until the user finishes editing. The socket read naturally blocks.
        try send(request, socketPath: socketPath)
    }
}

enum CLIError: Error, CustomStringConvertible {
    case socketCreationFailed
    case connectionFailed
    case writeFailed
    case emptyResponse

    var description: String {
        switch self {
        case .socketCreationFailed: "Failed to create socket"
        case .connectionFailed: "Failed to connect to Gallager (is it running?)"
        case .writeFailed: "Failed to send request"
        case .emptyResponse: "Empty response from server"
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `$(cat ${TMPDIR:-/tmp}/claude-sandbox-$(echo $PPID))/bin/swift build --target Gallager`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add ClaudeSpyPackage/Sources/Gallager/SocketClient.swift
git commit -m "feat: add CLI socket client for JSON-RPC (#343)"
```

---

### Task 5: CLI Commands — Utility (ping, capabilities, identify)

Start with the simplest commands to validate the end-to-end flow.

**Files:**
- Modify: `ClaudeSpyPackage/Sources/Gallager/GallagerCLI.swift`
- Create: `ClaudeSpyPackage/Sources/Gallager/Commands/UtilityCommands.swift`

- [ ] **Step 1: Add global options and update root command**

Replace `ClaudeSpyPackage/Sources/Gallager/GallagerCLI.swift` with:

```swift
import ArgumentParser
import ClaudeSpyNetworking
import Foundation

@main
struct GallagerCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gallager",
        abstract: "Control Gallager from the command line",
        subcommands: [
            PingCommand.self,
            CapabilitiesCommand.self,
            IdentifyCommand.self,
        ]
    )
}

/// Global options shared across all commands.
struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "Custom socket path")
    var socket: String?

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    @Option(name: .long, help: "Target specific pane")
    var pane: String?

    @Option(name: .long, help: "Target specific session")
    var session: String?

    @Option(name: .long, help: "Target specific window")
    var window: String?
}

/// Helper to send a request and handle common error reporting.
func executeRequest(
    method: String,
    params: [String: JSONValue] = [:],
    options: GlobalOptions
) throws -> JSONRPCResponse {
    let request = JSONRPCRequest(
        id: UUID().uuidString,
        method: method,
        params: params
    )
    let response = try SocketClient.send(request, socketPath: options.socket)
    if !response.ok, let error = response.error {
        throw ValidationError("Error: \(error.message)")
    }
    return response
}

/// Prints a response as JSON or as formatted text.
func printResponse(_ response: JSONRPCResponse, json: Bool) {
    if json {
        if let data = try? JSONEncoder().encode(response),
           let str = String(data: data, encoding: .utf8)
        {
            print(str)
        }
    } else if let result = response.result {
        if let data = try? JSONEncoder().encode(result),
           let str = String(data: data, encoding: .utf8)
        {
            print(str)
        }
    }
}
```

- [ ] **Step 2: Create utility commands**

In `ClaudeSpyPackage/Sources/Gallager/Commands/UtilityCommands.swift`:

```swift
import ArgumentParser
import ClaudeSpyNetworking
import Foundation

struct PingCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ping",
        abstract: "Check if Gallager is running"
    )

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let response = try executeRequest(method: "system.ping", options: options)
        if options.json {
            printResponse(response, json: true)
        } else {
            print("pong")
        }
    }
}

struct CapabilitiesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capabilities",
        abstract: "List available API methods"
    )

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let response = try executeRequest(method: "system.capabilities", options: options)
        if options.json {
            printResponse(response, json: true)
        } else if let result = response.result,
                  case .array(let methods) = result["methods"]
        {
            for method in methods {
                if case .string(let name) = method {
                    print(name)
                }
            }
        }
    }
}

struct IdentifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "identify",
        abstract: "Show current context (session/window/pane)"
    )

    @OptionGroup var options: GlobalOptions

    func run() throws {
        var params: [String: JSONValue] = [:]
        // Pass TMUX_PANE if available for context detection
        if let tmuxPane = ProcessInfo.processInfo.environment["TMUX_PANE"] {
            params["pane_id"] = .string(tmuxPane)
        }
        let response = try executeRequest(method: "system.identify", params: params, options: options)
        printResponse(response, json: options.json)
    }
}
```

- [ ] **Step 3: Verify it compiles**

Run: `$(cat ${TMPDIR:-/tmp}/claude-sandbox-$(echo $PPID))/bin/swift build --target Gallager`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add ClaudeSpyPackage/Sources/Gallager/GallagerCLI.swift \
       ClaudeSpyPackage/Sources/Gallager/Commands/UtilityCommands.swift
git commit -m "feat: add utility CLI commands (ping, capabilities, identify) (#343)"
```

---

### Task 6: CLI Commands — Sessions

**Files:**
- Create: `ClaudeSpyPackage/Sources/Gallager/Commands/SessionCommands.swift`
- Modify: `ClaudeSpyPackage/Sources/Gallager/GallagerCLI.swift` (add to subcommands)

- [ ] **Step 1: Create session commands**

In `ClaudeSpyPackage/Sources/Gallager/Commands/SessionCommands.swift`:

```swift
import ArgumentParser
import ClaudeSpyNetworking
import Foundation

struct ListSessionsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-sessions",
        abstract: "List all tmux sessions"
    )

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let response = try executeRequest(method: "session.list", options: options)
        if options.json {
            printResponse(response, json: true)
        } else if let result = response.result,
                  case .array(let sessions) = result["sessions"]
        {
            for session in sessions {
                if case .object(let obj) = session,
                   case .string(let name) = obj["name"],
                   case .int(let windowCount) = obj["window_count"]
                {
                    let attached = obj["is_attached"]?.boolValue == true ? " (attached)" : ""
                    print("\(name)\t\(windowCount) windows\(attached)")
                }
            }
        }
    }
}

struct NewSessionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "new-session",
        abstract: "Create a new session"
    )

    @Option(name: .long, help: "Session name")
    var name: String?

    @OptionGroup var options: GlobalOptions

    func run() throws {
        var params: [String: JSONValue] = [:]
        if let name { params["name"] = .string(name) }
        let response = try executeRequest(method: "session.create", params: params, options: options)
        if options.json {
            printResponse(response, json: true)
        } else if let result = response.result,
                  case .string(let id) = result["id"]
        {
            print("Created session: \(id)")
        }
    }
}

struct SelectSessionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "select-session",
        abstract: "Switch to a session"
    )

    @Argument(help: "Session ID")
    var id: String

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let response = try executeRequest(
            method: "session.select",
            params: ["session_id": .string(id)],
            options: options
        )
        printResponse(response, json: options.json)
    }
}

struct CurrentSessionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "current-session",
        abstract: "Show active session"
    )

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let response = try executeRequest(method: "session.current", options: options)
        if options.json {
            printResponse(response, json: true)
        } else if let result = response.result,
                  case .string(let name) = result["name"]
        {
            print(name)
        }
    }
}

struct CloseSessionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close-session",
        abstract: "Close a session"
    )

    @Argument(help: "Session ID")
    var id: String

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let response = try executeRequest(
            method: "session.close",
            params: ["session_id": .string(id)],
            options: options
        )
        printResponse(response, json: options.json)
    }
}
```

- [ ] **Step 2: Add session commands to root**

In `GallagerCLI.swift`, add to the `subcommands` array:
```swift
ListSessionsCommand.self,
NewSessionCommand.self,
SelectSessionCommand.self,
CurrentSessionCommand.self,
CloseSessionCommand.self,
```

- [ ] **Step 3: Verify it compiles**

Run: `$(cat ${TMPDIR:-/tmp}/claude-sandbox-$(echo $PPID))/bin/swift build --target Gallager`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add ClaudeSpyPackage/Sources/Gallager/Commands/SessionCommands.swift \
       ClaudeSpyPackage/Sources/Gallager/GallagerCLI.swift
git commit -m "feat: add session CLI commands (#343)"
```

---

### Task 7: CLI Commands — Windows, Panes, Input, Notify, Edit

**Files:**
- Create: `ClaudeSpyPackage/Sources/Gallager/Commands/WindowCommands.swift`
- Create: `ClaudeSpyPackage/Sources/Gallager/Commands/PaneCommands.swift`
- Create: `ClaudeSpyPackage/Sources/Gallager/Commands/InputCommands.swift`
- Create: `ClaudeSpyPackage/Sources/Gallager/Commands/NotifyCommand.swift`
- Create: `ClaudeSpyPackage/Sources/Gallager/Commands/EditCommand.swift`
- Modify: `ClaudeSpyPackage/Sources/Gallager/GallagerCLI.swift`

- [ ] **Step 1: Create window commands**

In `ClaudeSpyPackage/Sources/Gallager/Commands/WindowCommands.swift`:

```swift
import ArgumentParser
import ClaudeSpyNetworking
import Foundation

struct ListWindowsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-windows",
        abstract: "List windows in current/specified session"
    )

    @OptionGroup var options: GlobalOptions

    func run() throws {
        var params: [String: JSONValue] = [:]
        if let session = options.session { params["session_id"] = .string(session) }
        let response = try executeRequest(method: "window.list", params: params, options: options)
        if options.json {
            printResponse(response, json: true)
        } else if let result = response.result,
                  case .array(let windows) = result["windows"]
        {
            for window in windows {
                if case .object(let obj) = window,
                   case .string(let id) = obj["id"],
                   case .string(let name) = obj["name"],
                   case .int(let paneCount) = obj["pane_count"]
                {
                    let active = obj["is_active"]?.boolValue == true ? " *" : ""
                    print("\(id)\t\(name)\t\(paneCount) panes\(active)")
                }
            }
        }
    }
}

struct NewWindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "new-window",
        abstract: "Create window in current/specified session"
    )

    @OptionGroup var options: GlobalOptions

    func run() throws {
        var params: [String: JSONValue] = [:]
        if let session = options.session { params["session_id"] = .string(session) }
        let response = try executeRequest(method: "window.create", params: params, options: options)
        if options.json {
            printResponse(response, json: true)
        } else if let result = response.result,
                  case .string(let id) = result["id"]
        {
            print("Created window: \(id)")
        }
    }
}

struct SelectWindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "select-window",
        abstract: "Switch to a window"
    )

    @Argument(help: "Window ID (session:index)")
    var id: String

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let response = try executeRequest(
            method: "window.select",
            params: ["window_id": .string(id)],
            options: options
        )
        printResponse(response, json: options.json)
    }
}

struct CloseWindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close-window",
        abstract: "Close a window"
    )

    @Argument(help: "Window ID (session:index)")
    var id: String

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let response = try executeRequest(
            method: "window.close",
            params: ["window_id": .string(id)],
            options: options
        )
        printResponse(response, json: options.json)
    }
}
```

- [ ] **Step 2: Create pane commands**

In `ClaudeSpyPackage/Sources/Gallager/Commands/PaneCommands.swift`:

```swift
import ArgumentParser
import ClaudeSpyNetworking
import Foundation

struct ListPanesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-panes",
        abstract: "List panes in current window"
    )

    @OptionGroup var options: GlobalOptions

    func run() throws {
        var params: [String: JSONValue] = [:]
        if let window = options.window { params["window_id"] = .string(window) }
        let response = try executeRequest(method: "pane.list", params: params, options: options)
        if options.json {
            printResponse(response, json: true)
        } else if let result = response.result,
                  case .array(let panes) = result["panes"]
        {
            for pane in panes {
                if case .object(let obj) = pane,
                   case .string(let id) = obj["id"],
                   case .int(let width) = obj["width"],
                   case .int(let height) = obj["height"]
                {
                    let active = obj["is_active"]?.boolValue == true ? " *" : ""
                    let cwd = obj["cwd"]?.stringValue ?? ""
                    print("\(id)\t\(width)x\(height)\t\(cwd)\(active)")
                }
            }
        }
    }
}

struct SplitPaneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "split-pane",
        abstract: "Split pane (left/right/up/down, default: right)"
    )

    @Argument(help: "Split direction: left, right, up, down")
    var direction: String = "right"

    @OptionGroup var options: GlobalOptions

    func run() throws {
        var params: [String: JSONValue] = ["direction": .string(direction)]
        if let pane = options.pane { params["pane_id"] = .string(pane) }
        let response = try executeRequest(method: "pane.split", params: params, options: options)
        if options.json {
            printResponse(response, json: true)
        } else if let result = response.result,
                  case .string(let id) = result["id"]
        {
            print("Created pane: \(id)")
        }
    }
}

struct SelectPaneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "select-pane",
        abstract: "Focus a pane"
    )

    @Argument(help: "Pane ID")
    var id: String

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let response = try executeRequest(
            method: "pane.select",
            params: ["pane_id": .string(id)],
            options: options
        )
        printResponse(response, json: options.json)
    }
}
```

- [ ] **Step 3: Create input commands**

In `ClaudeSpyPackage/Sources/Gallager/Commands/InputCommands.swift`:

```swift
import ArgumentParser
import ClaudeSpyNetworking
import Foundation

struct SendCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Send text to focused/specified pane"
    )

    @Argument(help: "Text to send")
    var text: String

    @OptionGroup var options: GlobalOptions

    func run() throws {
        var params: [String: JSONValue] = ["text": .string(text)]
        if let pane = options.pane { params["pane_id"] = .string(pane) }
        let response = try executeRequest(method: "input.send_text", params: params, options: options)
        printResponse(response, json: options.json)
    }
}

struct SendKeyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send-key",
        abstract: "Send a key press"
    )

    @Argument(help: "Key name: enter, tab, escape, backspace, delete, up, down, left, right, space")
    var key: String

    @OptionGroup var options: GlobalOptions

    func run() throws {
        var params: [String: JSONValue] = ["key": .string(key)]
        if let pane = options.pane { params["pane_id"] = .string(pane) }
        let response = try executeRequest(method: "input.send_key", params: params, options: options)
        printResponse(response, json: options.json)
    }
}
```

- [ ] **Step 4: Create notify command**

In `ClaudeSpyPackage/Sources/Gallager/Commands/NotifyCommand.swift`:

```swift
import ArgumentParser
import ClaudeSpyNetworking
import Foundation

struct NotifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notify",
        abstract: "Send a desktop notification"
    )

    @Option(name: .long, help: "Notification title")
    var title: String

    @Option(name: .long, help: "Notification body")
    var body: String

    @Option(name: .long, help: "Notification subtitle")
    var subtitle: String?

    @OptionGroup var options: GlobalOptions

    func run() throws {
        var params: [String: JSONValue] = [
            "title": .string(title),
            "body": .string(body),
        ]
        if let subtitle { params["subtitle"] = .string(subtitle) }
        // Include pane context if available
        if let tmuxPane = ProcessInfo.processInfo.environment["TMUX_PANE"] {
            params["pane_id"] = .string(tmuxPane)
        }
        let response = try executeRequest(method: "notification.create", params: params, options: options)
        printResponse(response, json: options.json)
    }
}
```

- [ ] **Step 5: Create edit command**

In `ClaudeSpyPackage/Sources/Gallager/Commands/EditCommand.swift`:

```swift
import ArgumentParser
import ClaudeSpyNetworking
import Foundation

struct EditCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Open file in prompt editor (blocks until done)"
    )

    @Argument(help: "File path to edit")
    var file: String

    @OptionGroup var options: GlobalOptions

    func run() throws {
        guard let paneId = ProcessInfo.processInfo.environment["TMUX_PANE"], !paneId.isEmpty else {
            throw ValidationError("TMUX_PANE not set")
        }

        let request = JSONRPCRequest(
            id: UUID().uuidString,
            method: "editor.open",
            params: [
                "pane_id": .string(paneId),
                "file_path": .string(file),
            ]
        )

        // This blocks until the user finishes editing in the app
        _ = try SocketClient.sendAndWait(request, socketPath: options.socket)
    }
}
```

- [ ] **Step 6: Update root command with all subcommands**

In `GallagerCLI.swift`, update the subcommands array to include all commands:

```swift
static let configuration = CommandConfiguration(
    commandName: "gallager",
    abstract: "Control Gallager from the command line",
    subcommands: [
        // Sessions
        ListSessionsCommand.self,
        NewSessionCommand.self,
        SelectSessionCommand.self,
        CurrentSessionCommand.self,
        CloseSessionCommand.self,
        // Windows
        ListWindowsCommand.self,
        NewWindowCommand.self,
        SelectWindowCommand.self,
        CloseWindowCommand.self,
        // Panes
        ListPanesCommand.self,
        SplitPaneCommand.self,
        SelectPaneCommand.self,
        // Input
        SendCommand.self,
        SendKeyCommand.self,
        // Notifications
        NotifyCommand.self,
        // Editor
        EditCommand.self,
        // Utility
        PingCommand.self,
        CapabilitiesCommand.self,
        IdentifyCommand.self,
    ]
)
```

- [ ] **Step 7: Verify it compiles**

Run: `$(cat ${TMPDIR:-/tmp}/claude-sandbox-$(echo $PPID))/bin/swift build --target Gallager`
Expected: Build succeeds

- [ ] **Step 8: Commit**

```bash
git add ClaudeSpyPackage/Sources/Gallager/
git commit -m "feat: add all CLI commands (sessions, windows, panes, input, notify, edit) (#343)"
```

---

### Task 8: APISocketServer (@DependencyClient)

The server-side Unix socket server that replaces EditorSocketServer.

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/APISocketServer.swift`
- Delete: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/EditorSocketServer.swift`

- [ ] **Step 1: Create APISocketServer**

In `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/APISocketServer.swift`:

```swift
#if os(macOS)
    import ClaudeSpyNetworking
    import Dependencies
    import DependenciesMacros
    import Foundation
    import Logging

    /// Handler type for incoming JSON-RPC requests.
    /// Returns a response for normal requests.
    /// For editor.open, the handler should block until editing completes, then return.
    public typealias APIRequestHandler = @Sendable (JSONRPCRequest) async -> JSONRPCResponse

    @DependencyClient
    public struct APISocketServer: Sendable {
        public var start: @Sendable (_ socketPath: String) async throws -> Void
        public var stop: @Sendable () async -> Void
        public var setRequestHandler: @Sendable (_ handler: @escaping APIRequestHandler) async -> Void
        /// The socket path the server is listening on (set after start()).
        public var getSocketPath: @Sendable () async -> String? = { nil }
    }

    extension APISocketServer: DependencyKey {
        public static var previewValue: APISocketServer {
            APISocketServer()
        }

        public static var liveValue: APISocketServer {
            let server = LiveAPISocketServer()
            return APISocketServer(
                start: { socketPath in
                    try await server.start(socketPath: socketPath)
                },
                stop: {
                    await server.stop()
                },
                setRequestHandler: { handler in
                    await server.setRequestHandler(handler)
                },
                getSocketPath: {
                    await server.socketPath
                }
            )
        }
    }

    /// Actor-based live implementation of the API socket server.
    actor LiveAPISocketServer {
        private let logger = Logger(label: "com.claudespy.apisocket")
        private(set) var socketPath: String?
        private var serverFd: Int32 = -1
        private var isRunning = false
        private var acceptTask: Task<Void, Never>?
        private var requestHandler: APIRequestHandler?

        func setRequestHandler(_ handler: @escaping APIRequestHandler) {
            requestHandler = handler
        }

        func start(socketPath: String) throws {
            guard !isRunning else { return }

            if isSocketActive(path: socketPath) {
                logger.info("Another instance already owns the API socket, skipping")
                return
            }
            unlink(socketPath)

            serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard serverFd >= 0 else {
                throw APISocketError.socketCreationFailed
            }

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            socketPath.withCString { ptr in
                withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
                    let raw = UnsafeMutableRawPointer(sunPath)
                    raw.copyMemory(from: ptr, byteCount: socketPath.utf8.count + 1)
                }
            }

            let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let bindResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    bind(serverFd, sockPtr, addrLen)
                }
            }
            guard bindResult == 0 else {
                close(serverFd)
                serverFd = -1
                throw APISocketError.bindFailed
            }

            guard listen(serverFd, 5) == 0 else {
                close(serverFd)
                serverFd = -1
                throw APISocketError.listenFailed
            }

            self.socketPath = socketPath
            isRunning = true
            logger.info("API socket server listening at \(socketPath)")

            acceptTask = Task {
                await acceptLoop()
            }
        }

        func stop() {
            guard isRunning else { return }
            isRunning = false
            acceptTask?.cancel()
            acceptTask = nil

            if serverFd >= 0 {
                close(serverFd)
                serverFd = -1
            }
            if let path = socketPath {
                unlink(path)
            }
            logger.info("API socket server stopped")
        }

        // MARK: - Private

        private func isSocketActive(path: String) -> Bool {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return false }
            defer { close(fd) }

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            path.withCString { ptr in
                withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
                    let raw = UnsafeMutableRawPointer(sunPath)
                    raw.copyMemory(from: ptr, byteCount: path.utf8.count + 1)
                }
            }

            let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let connected = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    connect(fd, sockPtr, addrLen)
                }
            }
            return connected == 0
        }

        private func acceptLoop() async {
            while !Task.isCancelled && isRunning {
                let clientFd = await withCheckedContinuation { continuation in
                    DispatchQueue.global().async { [serverFd] in
                        let fd = accept(serverFd, nil, nil)
                        continuation.resume(returning: fd)
                    }
                }

                guard clientFd >= 0 else {
                    if isRunning {
                        logger.error("accept() failed, stopping server")
                    }
                    break
                }

                // Handle each connection in its own task so multiple clients
                // can be served concurrently (important for editor.open which blocks)
                let handler = requestHandler
                let logger = logger
                Task {
                    await Self.handleConnection(clientFd, handler: handler, logger: logger)
                }
            }
        }

        /// Handles a single client connection. Reads newline-delimited JSON-RPC
        /// requests and sends responses until the client disconnects.
        private static func handleConnection(
            _ fd: Int32,
            handler: APIRequestHandler?,
            logger: Logger
        ) async {
            defer { close(fd) }

            // Read messages in a loop (persistent connection)
            while true {
                let data = await withCheckedContinuation { continuation in
                    DispatchQueue.global().async {
                        var data = Data()
                        var byte: UInt8 = 0
                        while Darwin.read(fd, &byte, 1) == 1 {
                            if byte == UInt8(ascii: "\n") { break }
                            data.append(byte)
                        }
                        continuation.resume(returning: data)
                    }
                }

                guard !data.isEmpty else {
                    // Client disconnected
                    break
                }

                // Decode JSON-RPC request
                let response: JSONRPCResponse
                do {
                    let request = try JSONDecoder().decode(JSONRPCRequest.self, from: data)
                    if let handler {
                        response = await handler(request)
                    } else {
                        response = .internalError(id: request.id, "No request handler configured")
                    }
                } catch {
                    // Can't decode request — send error with empty ID
                    response = .internalError(id: "", "Invalid JSON-RPC request: \(error.localizedDescription)")
                }

                // Send response
                do {
                    var responseData = try JSONEncoder().encode(response)
                    responseData.append(UInt8(ascii: "\n"))
                    let written = responseData.withUnsafeBytes { ptr in
                        Darwin.write(fd, ptr.baseAddress!, ptr.count)
                    }
                    if written < 0 {
                        logger.error("Failed to write response")
                        break
                    }
                } catch {
                    logger.error("Failed to encode response: \(error)")
                    break
                }
            }
        }
    }

    enum APISocketError: Error, LocalizedError {
        case socketCreationFailed
        case bindFailed
        case listenFailed

        var errorDescription: String? {
            switch self {
            case .socketCreationFailed: "Failed to create Unix domain socket"
            case .bindFailed: "Failed to bind API socket"
            case .listenFailed: "Failed to listen on socket"
            }
        }
    }
#endif
```

- [ ] **Step 2: Delete EditorSocketServer.swift**

```bash
rm ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/EditorSocketServer.swift
```

- [ ] **Step 3: Verify it compiles**

Run: `$(cat ${TMPDIR:-/tmp}/claude-sandbox-$(echo $PPID))/bin/swift build --target ClaudeSpyServerFeature 2>&1 | head -50`

This will fail because AppCoordinator and EditorSessionManager still reference EditorSocketServer. That's expected — we'll fix those in Tasks 10 and 11.

- [ ] **Step 4: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/APISocketServer.swift
git rm ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/EditorSocketServer.swift
git commit -m "feat: add APISocketServer, remove EditorSocketServer (#343)"
```

---

### Task 9: APIRequestRouter (@DependencyClient)

The router that dispatches JSON-RPC methods to existing services.

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/APIRequestRouter.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/APIRequestRouterTests.swift`

- [ ] **Step 1: Write failing tests for router dispatch**

In `ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/APIRequestRouterTests.swift`:

```swift
import Testing
@testable import ClaudeSpyServerFeature
import ClaudeSpyNetworking

@Test
func pingReturns() async {
    let router = LiveAPIRequestRouter()
    let request = JSONRPCRequest(id: "1", method: "system.ping", params: [:])
    let response = await router.handleRequest(request)
    #expect(response.ok == true)
    #expect(response.result?["pong"]?.boolValue == true)
}

@Test
func unknownMethodReturnsError() async {
    let router = LiveAPIRequestRouter()
    let request = JSONRPCRequest(id: "2", method: "nonexistent.method", params: [:])
    let response = await router.handleRequest(request)
    #expect(response.ok == false)
    #expect(response.error?.code == "method_not_found")
}

@Test
func capabilitiesListsMethods() async {
    let router = LiveAPIRequestRouter()
    let request = JSONRPCRequest(id: "3", method: "system.capabilities", params: [:])
    let response = await router.handleRequest(request)
    #expect(response.ok == true)
    if case .array(let methods) = response.result?["methods"] {
        let names = methods.compactMap(\.stringValue)
        #expect(names.contains("system.ping"))
        #expect(names.contains("session.list"))
        #expect(names.contains("input.send_text"))
    } else {
        Issue.record("Expected methods array")
    }
}
```

- [ ] **Step 2: Create APIRequestRouter**

In `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/APIRequestRouter.swift`:

```swift
#if os(macOS)
    import ClaudeSpyNetworking
    import Dependencies
    import DependenciesMacros
    import Foundation
    import Logging

    @DependencyClient
    public struct APIRequestRouter: Sendable {
        public var handleRequest: @Sendable (JSONRPCRequest) async -> JSONRPCResponse = { request in
            .methodNotFound(id: request.id, request.method)
        }
    }

    extension APIRequestRouter: DependencyKey {
        public static var previewValue: APIRequestRouter {
            APIRequestRouter()
        }

        public static var liveValue: APIRequestRouter {
            let router = LiveAPIRequestRouter()
            return APIRequestRouter(
                handleRequest: { request in
                    await router.handleRequest(request)
                }
            )
        }
    }

    /// All supported API methods.
    private let allMethods: [String] = [
        "system.ping",
        "system.capabilities",
        "system.identify",
        "session.list",
        "session.create",
        "session.select",
        "session.current",
        "session.close",
        "window.list",
        "window.create",
        "window.select",
        "window.close",
        "pane.list",
        "pane.split",
        "pane.select",
        "input.send_text",
        "input.send_key",
        "notification.create",
        "editor.open",
    ]

    /// Live implementation that routes JSON-RPC methods to service calls.
    ///
    /// Service dependencies are injected via callbacks set by AppCoordinator,
    /// since the router needs access to @MainActor services (TmuxService, MirrorWindowManager).
    public final class LiveAPIRequestRouter: Sendable {
        private let logger = Logger(label: "com.claudespy.apirouter")

        // Service callbacks set by AppCoordinator
        nonisolated(unsafe) var onSessionList: (@Sendable () async -> [[String: JSONValue]])?
        nonisolated(unsafe) var onSessionCreate: (@Sendable (String?) async throws -> [String: JSONValue])?
        nonisolated(unsafe) var onSessionSelect: (@Sendable (String) async throws -> Void)?
        nonisolated(unsafe) var onSessionCurrent: (@Sendable () async -> [String: JSONValue]?)?
        nonisolated(unsafe) var onSessionClose: (@Sendable (String) async throws -> Void)?

        nonisolated(unsafe) var onWindowList: (@Sendable (String?) async -> [[String: JSONValue]])?
        nonisolated(unsafe) var onWindowCreate: (@Sendable (String?) async throws -> [String: JSONValue])?
        nonisolated(unsafe) var onWindowSelect: (@Sendable (String) async throws -> Void)?
        nonisolated(unsafe) var onWindowClose: (@Sendable (String) async throws -> Void)?

        nonisolated(unsafe) var onPaneList: (@Sendable (String?) async -> [[String: JSONValue]])?
        nonisolated(unsafe) var onPaneSplit: (@Sendable (String?, String) async throws -> [String: JSONValue])?
        nonisolated(unsafe) var onPaneSelect: (@Sendable (String) async throws -> Void)?

        nonisolated(unsafe) var onSendText: (@Sendable (String, String?) async throws -> Void)?
        nonisolated(unsafe) var onSendKey: (@Sendable (String, String?) async throws -> Void)?

        nonisolated(unsafe) var onNotify: (@Sendable (String, String, String?, String?) async -> Void)?

        nonisolated(unsafe) var onEditorOpen: (@Sendable (String, String) async -> Void)?

        nonisolated(unsafe) var onIdentify: (@Sendable (String?) async -> [String: JSONValue])?

        public init() {}

        public func handleRequest(_ request: JSONRPCRequest) async -> JSONRPCResponse {
            let id = request.id
            let params = request.params

            do {
                switch request.method {
                // MARK: - System

                case "system.ping":
                    return JSONRPCResponse(id: id, result: ["pong": .bool(true)])

                case "system.capabilities":
                    return JSONRPCResponse(id: id, result: [
                        "methods": .array(allMethods.map { .string($0) }),
                    ])

                case "system.identify":
                    let paneId = params["pane_id"]?.stringValue
                    if let info = await onIdentify?(paneId) {
                        return JSONRPCResponse(id: id, result: info)
                    }
                    return .internalError(id: id, "Identify not available")

                // MARK: - Sessions

                case "session.list":
                    let sessions = await onSessionList?() ?? []
                    return JSONRPCResponse(id: id, result: [
                        "sessions": .array(sessions.map { .object($0) }),
                    ])

                case "session.create":
                    let name = params["name"]?.stringValue
                    if let result = try await onSessionCreate?(name) {
                        return JSONRPCResponse(id: id, result: result)
                    }
                    return .internalError(id: id, "Session create not available")

                case "session.select":
                    guard let sessionId = params["session_id"]?.stringValue else {
                        return .invalidParams(id: id, "session_id required")
                    }
                    try await onSessionSelect?(sessionId)
                    return .ok(id: id)

                case "session.current":
                    if let result = await onSessionCurrent?() {
                        return JSONRPCResponse(id: id, result: result)
                    }
                    return .notFound(id: id, "No active session")

                case "session.close":
                    guard let sessionId = params["session_id"]?.stringValue else {
                        return .invalidParams(id: id, "session_id required")
                    }
                    try await onSessionClose?(sessionId)
                    return .ok(id: id)

                // MARK: - Windows

                case "window.list":
                    let sessionId = params["session_id"]?.stringValue
                    let windows = await onWindowList?(sessionId) ?? []
                    return JSONRPCResponse(id: id, result: [
                        "windows": .array(windows.map { .object($0) }),
                    ])

                case "window.create":
                    let sessionId = params["session_id"]?.stringValue
                    if let result = try await onWindowCreate?(sessionId) {
                        return JSONRPCResponse(id: id, result: result)
                    }
                    return .internalError(id: id, "Window create not available")

                case "window.select":
                    guard let windowId = params["window_id"]?.stringValue else {
                        return .invalidParams(id: id, "window_id required")
                    }
                    try await onWindowSelect?(windowId)
                    return .ok(id: id)

                case "window.close":
                    guard let windowId = params["window_id"]?.stringValue else {
                        return .invalidParams(id: id, "window_id required")
                    }
                    try await onWindowClose?(windowId)
                    return .ok(id: id)

                // MARK: - Panes

                case "pane.list":
                    let windowId = params["window_id"]?.stringValue
                    let panes = await onPaneList?(windowId) ?? []
                    return JSONRPCResponse(id: id, result: [
                        "panes": .array(panes.map { .object($0) }),
                    ])

                case "pane.split":
                    let direction = params["direction"]?.stringValue ?? "right"
                    let paneId = params["pane_id"]?.stringValue
                    if let result = try await onPaneSplit?(paneId, direction) {
                        return JSONRPCResponse(id: id, result: result)
                    }
                    return .internalError(id: id, "Pane split not available")

                case "pane.select":
                    guard let paneId = params["pane_id"]?.stringValue else {
                        return .invalidParams(id: id, "pane_id required")
                    }
                    try await onPaneSelect?(paneId)
                    return .ok(id: id)

                // MARK: - Input

                case "input.send_text":
                    guard let text = params["text"]?.stringValue else {
                        return .invalidParams(id: id, "text required")
                    }
                    let paneId = params["pane_id"]?.stringValue
                    try await onSendText?(text, paneId)
                    return .ok(id: id)

                case "input.send_key":
                    guard let key = params["key"]?.stringValue else {
                        return .invalidParams(id: id, "key required")
                    }
                    let paneId = params["pane_id"]?.stringValue
                    try await onSendKey?(key, paneId)
                    return .ok(id: id)

                // MARK: - Notifications

                case "notification.create":
                    guard let title = params["title"]?.stringValue else {
                        return .invalidParams(id: id, "title required")
                    }
                    guard let body = params["body"]?.stringValue else {
                        return .invalidParams(id: id, "body required")
                    }
                    let subtitle = params["subtitle"]?.stringValue
                    let paneId = params["pane_id"]?.stringValue
                    await onNotify?(title, body, subtitle, paneId)
                    return .ok(id: id)

                // MARK: - Editor

                case "editor.open":
                    guard let paneId = params["pane_id"]?.stringValue else {
                        return .invalidParams(id: id, "pane_id required")
                    }
                    guard let filePath = params["file_path"]?.stringValue else {
                        return .invalidParams(id: id, "file_path required")
                    }
                    // This blocks until editing is done
                    await onEditorOpen?(paneId, filePath)
                    return .ok(id: id)

                default:
                    return .methodNotFound(id: id, request.method)
                }
            } catch {
                return .internalError(id: id, error.localizedDescription)
            }
        }
    }
#endif
```

- [ ] **Step 3: Run tests**

Run: `$(cat ${TMPDIR:-/tmp}/claude-sandbox-$(echo $PPID))/bin/swift test --filter APIRequestRouterTests`
Expected: All 3 tests PASS (ping, unknown method, capabilities)

- [ ] **Step 4: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/APIRequestRouter.swift \
       ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/APIRequestRouterTests.swift
git commit -m "feat: add APIRequestRouter with method dispatch (#343)"
```

---

### Task 10: Update EditorSessionManager

Remove its direct dependency on EditorSocketServer — it now works through the API router.

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Managers/EditorSessionManager.swift`

- [ ] **Step 1: Read current EditorSessionManager**

Read the full file to understand all references to `EditorSocketServer` and `EditorRequest`.

- [ ] **Step 2: Update EditorSessionManager**

The manager no longer takes `EditorSocketServer` in its init. Instead:
- It receives edit requests via a method call (from the API router)
- It signals completion via an async continuation (instead of calling `completeSession` on the socket server)
- The `EditorRequest` type stays the same but moves to this file (or a shared location) since `EditorSocketServer.swift` is gone

Key changes:
1. Remove `EditorSocketServer` from init
2. Replace `socketServer.completeSession(sessionId)` calls with a stored continuation pattern
3. Add a `handleEditRequest(paneId:filePath:)` method that returns when editing completes (async)
4. Keep existing `registerSession`, `submitSession`, `cancelSession` logic

The router's `onEditorOpen` callback will call `handleEditRequest(paneId:filePath:)` — this blocks until the user submits/cancels, which is exactly what the CLI expects (the socket connection stays open and the response is only sent when this async method returns).

Store a per-session `CheckedContinuation` that `submitSession`/`cancelSession` resumes:

```swift
private var completionContinuations: [UUID: CheckedContinuation<Void, Never>] = [:]

/// Called by the API router. Blocks until the user submits or cancels.
public func handleAPIEditRequest(paneId: String, filePath: String) async {
    let sessionId = UUID()
    let request = EditorRequest(paneId: paneId, filePath: filePath, sessionId: sessionId)
    
    // Register the session (reads file, shows UI)
    handleEditRequest(request)
    
    // Block until submit/cancel
    await withCheckedContinuation { continuation in
        completionContinuations[sessionId] = continuation
    }
}
```

In `submitSession` and `cancelSession`, after existing logic, resume the continuation:
```swift
completionContinuations.removeValue(forKey: session.id)?.resume()
```

- [ ] **Step 3: Verify it compiles (may still fail due to AppCoordinator — that's OK)**

The goal is to verify EditorSessionManager itself compiles without EditorSocketServer. AppCoordinator fixes come in Task 11.

- [ ] **Step 4: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Managers/EditorSessionManager.swift
git commit -m "refactor: decouple EditorSessionManager from socket server (#343)"
```

---

### Task 11: Wire Up AppCoordinator

Connect APISocketServer + APIRequestRouter in AppCoordinator, replacing the old EditorSocketServer setup.

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Coordinators/AppCoordinator.swift`
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/TmuxService.swift`

- [ ] **Step 1: Read current AppCoordinator references**

Read the sections around `editorSocketServer`, `setupEditorSocketServer()`, and the init where services are created.

- [ ] **Step 2: Update AppCoordinator**

Key changes:

1. Replace `editorSocketServer: EditorSocketServer` property with `@Dependency`:
```swift
@ObservationIgnored
@Dependency(APISocketServer.self) private var apiSocketServer

@ObservationIgnored
@Dependency(APIRequestRouter.self) private var apiRequestRouter
```

2. Remove `EditorSocketServer()` creation from init. Update `EditorSessionManager` init to no longer take a socket server.

3. Create the `LiveAPIRequestRouter` instance in init and store it for callback wiring:
```swift
private let liveRouter = LiveAPIRequestRouter()
```

4. Replace `setupEditorSocketServer()` with `setupAPIServer()`:

```swift
private func setupAPIServer() async {
    let manager = editorSessionManager
    
    // Wire editor session change notifications (same as before)
    manager.onSessionChanged = { [weak self] in
        await self?.pushStateToViewers()
    }
    
    // Wire router callbacks to services
    wireRouterCallbacks()
    
    // Set the router as the request handler
    await apiSocketServer.setRequestHandler { [liveRouter] request in
        await liveRouter.handleRequest(request)
    }
    
    // Start the socket server
    let socketPath = NSTemporaryDirectory() + "gallager.sock"
    try? await apiSocketServer.start(socketPath)
    
    // Configure tmux env vars
    if let cliURL = Bundle.main.url(forAuxiliaryExecutable: "Gallager") {
        tmuxService.editorCLIPath = cliURL.path
        tmuxService.apiSocketPath = socketPath
        logger.info("Gallager CLI path: \(cliURL.path)")
    } else {
        logger.warning("Gallager CLI not found in app bundle")
    }
}
```

5. Implement `wireRouterCallbacks()` that connects each router callback to the appropriate service. This is where internal models (PaneInfo, LocalTmuxSession, etc.) are mapped to API models:

```swift
private func wireRouterCallbacks() {
    let tmux = tmuxService
    let winManager = mirrorWindowManager
    let editorMgr = editorSessionManager
    let notifService = terminalNotificationService
    
    liveRouter.onSessionList = { [tmux] in
        await MainActor.run {
            tmux.sessions.map { session in
                APISessionInfo(
                    id: session.sessionName,
                    name: session.sessionName,
                    windowCount: session.windows.count,
                    isAttached: true
                ).toJSONValue()
            }
        }
    }
    
    liveRouter.onSessionCreate = { [tmux] name in
        let baseName = name ?? "session"
        let (sessionName, _) = try await tmux.createSession(baseName: baseName, width: 120, height: 40)
        return APISessionInfo(
            id: sessionName,
            name: sessionName,
            windowCount: 1,
            isAttached: true
        ).toJSONValue()
    }
    
    liveRouter.onSessionSelect = { [tmux] sessionId in
        // Select the active window in the session
        let sessions = await MainActor.run { tmux.sessions }
        guard let session = sessions.first(where: { $0.sessionName == sessionId }) else {
            throw APIError.notFound("Session '\(sessionId)' not found")
        }
        if let window = session.activeWindow {
            try await tmux.selectWindow(window.id)
        }
    }
    
    liveRouter.onSessionCurrent = { [tmux] in
        // The "current" session is determined by the selected sidebar item
        // For API, return the first session with an active window
        await MainActor.run {
            if let session = tmux.sessions.first(where: { $0.windows.contains(where: \.isWindowActive) }) {
                return APISessionInfo(
                    id: session.sessionName,
                    name: session.sessionName,
                    windowCount: session.windows.count,
                    isAttached: true
                ).toJSONValue()
            }
            return nil
        }
    }
    
    liveRouter.onSessionClose = { [tmux] sessionId in
        try await tmux.killSession(sessionId)
    }
    
    liveRouter.onWindowList = { [tmux] sessionId in
        await MainActor.run {
            let allWindows = tmux.sessions.flatMap(\.windows)
            let filtered = sessionId.map { sid in
                allWindows.filter { $0.sessionName == sid }
            } ?? allWindows
            return filtered.map { window in
                APIWindowInfo(
                    id: window.id,
                    index: window.windowIndex,
                    name: window.windowName,
                    paneCount: window.panes.count,
                    isActive: window.isWindowActive,
                    sessionId: window.sessionName
                ).toJSONValue()
            }
        }
    }
    
    liveRouter.onWindowCreate = { [tmux] sessionId in
        let session = sessionId ?? await MainActor.run {
            tmux.sessions.first(where: { $0.windows.contains(where: \.isWindowActive) })?.sessionName
                ?? tmux.sessions.first?.sessionName
        }
        guard let session else {
            throw APIError.notFound("No session found")
        }
        let windowTarget = try await tmux.newWindow(sessionName: session)
        // Refresh panes to pick up the new window
        await tmux.refreshPanes()
        return APIWindowInfo(
            id: windowTarget,
            index: 0,
            name: "",
            paneCount: 1,
            isActive: true,
            sessionId: session
        ).toJSONValue()
    }
    
    liveRouter.onWindowSelect = { [tmux] windowId in
        try await tmux.selectWindow(windowId)
    }
    
    liveRouter.onWindowClose = { [tmux] windowId in
        try await tmux.killWindow(windowId)
    }
    
    liveRouter.onPaneList = { [tmux, winManager] windowId in
        await MainActor.run {
            let allWindows = tmux.sessions.flatMap(\.windows)
            let window = windowId.flatMap { wid in allWindows.first { $0.id == wid } }
                ?? allWindows.first(where: \.isWindowActive)
            guard let window else { return [] }
            return window.panes.map { pane in
                let hasClaudeSession = winManager.paneStates[pane.paneId]?.claudeSession != nil
                return APIPaneInfo(
                    id: pane.paneId,
                    index: pane.paneIndex,
                    isActive: pane.isActive,
                    command: pane.command,
                    cwd: pane.currentPath,
                    width: pane.width,
                    height: pane.height,
                    windowId: pane.windowId,
                    hasClaudeSession: hasClaudeSession
                ).toJSONValue()
            }
        }
    }
    
    liveRouter.onPaneSplit = { [tmux] paneId, direction in
        let horizontal = direction == "left" || direction == "right"
        let target = paneId ?? await MainActor.run {
            tmux.sessions.flatMap(\.windows)
                .first(where: \.isWindowActive)?.activePane?.paneId
        }
        guard let target else {
            throw APIError.notFound("No active pane")
        }
        let newPaneId = try await tmux.splitPane(target, horizontal: horizontal)
        return APIPaneInfo(
            id: newPaneId,
            index: 0,
            isActive: true,
            command: nil,
            cwd: nil,
            width: 0,
            height: 0,
            windowId: "",
            hasClaudeSession: false
        ).toJSONValue()
    }
    
    liveRouter.onPaneSelect = { [tmux] paneId in
        try await tmux.selectPane(paneId)
    }
    
    liveRouter.onSendText = { [tmux] text, paneId in
        let target = paneId ?? await MainActor.run {
            tmux.sessions.flatMap(\.windows)
                .first(where: \.isWindowActive)?.activePane?.paneId
        }
        guard let target else {
            throw APIError.notFound("No active pane")
        }
        try await tmux.sendKeys(target, keys: text, literal: true)
    }
    
    liveRouter.onSendKey = { [tmux] key, paneId in
        let target = paneId ?? await MainActor.run {
            tmux.sessions.flatMap(\.windows)
                .first(where: \.isWindowActive)?.activePane?.paneId
        }
        guard let target else {
            throw APIError.notFound("No active pane")
        }
        // Map key names to tmux key names
        let tmuxKey: String
        switch key.lowercased() {
        case "enter": tmuxKey = "Enter"
        case "tab": tmuxKey = "Tab"
        case "escape": tmuxKey = "Escape"
        case "backspace": tmuxKey = "BSpace"
        case "delete": tmuxKey = "DC"
        case "up": tmuxKey = "Up"
        case "down": tmuxKey = "Down"
        case "left": tmuxKey = "Left"
        case "right": tmuxKey = "Right"
        case "space": tmuxKey = "Space"
        default: tmuxKey = key
        }
        try await tmux.sendBatchKeys(target, keys: [tmuxKey])
    }
    
    liveRouter.onNotify = { [notifService] title, body, subtitle, paneId in
        let notification = TerminalStreamMessage.TerminalNotification(
            title: title,
            body: body
        )
        notifService.showNotification(paneId ?? "", notification)
    }
    
    liveRouter.onEditorOpen = { [editorMgr] paneId, filePath in
        await editorMgr.handleAPIEditRequest(paneId: paneId, filePath: filePath)
    }
    
    liveRouter.onIdentify = { [tmux, winManager] paneId in
        await MainActor.run {
            // Find the pane in current state
            let allWindows = tmux.sessions.flatMap(\.windows)
            var foundSession: LocalTmuxSession?
            var foundWindow: LocalTmuxWindow?
            var foundPane: PaneInfo?
            
            if let paneId {
                for session in tmux.sessions {
                    for window in session.windows {
                        if let pane = window.panes.first(where: { $0.paneId == paneId }) {
                            foundSession = session
                            foundWindow = window
                            foundPane = pane
                            break
                        }
                    }
                    if foundPane != nil { break }
                }
            } else {
                // No pane specified — return active context
                foundSession = tmux.sessions.first(where: { $0.windows.contains(where: \.isWindowActive) })
                foundWindow = foundSession?.windows.first(where: \.isWindowActive)
                foundPane = foundWindow?.activePane
            }
            
            let sessionInfo = foundSession.map {
                APISessionInfo(
                    id: $0.sessionName,
                    name: $0.sessionName,
                    windowCount: $0.windows.count,
                    isAttached: true
                )
            }
            let windowInfo = foundWindow.map {
                APIWindowInfo(
                    id: $0.id,
                    index: $0.windowIndex,
                    name: $0.windowName,
                    paneCount: $0.panes.count,
                    isActive: $0.isWindowActive,
                    sessionId: $0.sessionName
                )
            }
            let paneInfo = foundPane.map {
                let hasClaudeSession = winManager.paneStates[$0.paneId]?.claudeSession != nil
                return APIPaneInfo(
                    id: $0.paneId,
                    index: $0.paneIndex,
                    isActive: $0.isActive,
                    command: $0.command,
                    cwd: $0.currentPath,
                    width: $0.width,
                    height: $0.height,
                    windowId: $0.windowId,
                    hasClaudeSession: hasClaudeSession
                )
            }
            
            return APIIdentifyInfo(
                session: sessionInfo,
                window: windowInfo,
                pane: paneInfo
            ).toJSONValue()
        }
    }
}
```

Add a simple error type for the router callbacks:

```swift
enum APIError: Error, LocalizedError {
    case notFound(String)
    
    var errorDescription: String? {
        switch self {
        case .notFound(let msg): msg
        }
    }
}
```

- [ ] **Step 3: Update TmuxService env var names**

In `TmuxService.swift`, update the env var properties and `terminalEnvironmentVars`:

Replace `editorSocketPath` with `apiSocketPath`.
Replace `GALLAGER_EDITOR_SOCKET` with `GALLAGER_SOCKET`.
Update `VISUAL` to use `gallager edit` wrapper:

```swift
// Replace:
if let editorCLIPath {
    vars.append("VISUAL=\(editorCLIPath)")
}
if let editorSocketPath {
    vars.append("GALLAGER_EDITOR_SOCKET=\(editorSocketPath)")
}

// With:
if let editorCLIPath {
    vars.append("VISUAL=\(editorCLIPath) edit")
}
if let apiSocketPath {
    vars.append("GALLAGER_SOCKET=\(apiSocketPath)")
}
```

Also rename the property:
```swift
// Replace:
public var editorSocketPath: String?
// With:
public var apiSocketPath: String?
```

- [ ] **Step 4: Update setupAllServices call**

In `setupAllServices()`, replace `await setupEditorSocketServer()` with `await setupAPIServer()`.

- [ ] **Step 5: Fix any remaining compilation errors**

Build the full ClaudeSpyServerFeature target and fix any remaining references to `EditorSocketServer`, `editorSocketPath`, or `GALLAGER_EDITOR_SOCKET`.

Run: `$(cat ${TMPDIR:-/tmp}/claude-sandbox-$(echo $PPID))/bin/swift build --target ClaudeSpyServerFeature 2>&1 | head -80`

Iterate until it compiles clean.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: wire APISocketServer + APIRequestRouter into AppCoordinator (#343)"
```

---

### Task 12: Full Build Verification

Build everything and fix any remaining issues.

**Files:**
- Various (fix any remaining compilation errors)

- [ ] **Step 1: Build all targets**

Run: `$(cat ${TMPDIR:-/tmp}/claude-sandbox-$(echo $PPID))/bin/swift build 2>&1 | tail -20`

If there are errors, fix them. Common issues:
- References to `GallagerEditor` in Xcode project `.pbxproj` file
- References to `EditorSocketServer` in any file we missed
- Missing imports for new types
- `TerminalStreamMessage.TerminalNotification` init signature may differ — check the actual type

- [ ] **Step 2: Build the Xcode project (macOS scheme)**

Use the `xcodebuild` skill to build the `ClaudeSpyServer` scheme for macOS.

This catches issues the SPM build misses (Xcode project references, Copy Files phases, auxiliary executable embedding).

- [ ] **Step 3: Run existing tests**

Run: `$(cat ${TMPDIR:-/tmp}/claude-sandbox-$(echo $PPID))/bin/swift test 2>&1 | tail -30`

All existing tests must still pass.

- [ ] **Step 4: Commit any fixes**

```bash
git add -A
git commit -m "fix: resolve remaining build issues from CLI API migration (#343)"
```

---

### Task 13: API Documentation

Create the user-facing API reference.

**Files:**
- Create: `docs/gallager-cli-api.md`

- [ ] **Step 1: Write API documentation**

Create `docs/gallager-cli-api.md` with:
- Overview and installation
- Socket path configuration
- CLI usage with examples for every command
- JSON-RPC wire protocol reference
- All methods with params and response schemas
- Error codes

Use the spec as the source of truth but write it as user-facing documentation with examples:

```markdown
# Gallager CLI API

Control Gallager programmatically from the command line or via JSON-RPC over Unix socket.

## Quick Start

```bash
# Check if Gallager is running
gallager ping

# List sessions
gallager list-sessions

# Send text to the focused pane
gallager send "echo hello"
gallager send-key enter

# Get current context
gallager identify --json
```

## Configuration

### Socket Path

The CLI connects to Gallager via a Unix domain socket. The path is resolved:
1. `$GALLAGER_SOCKET` environment variable (set automatically inside Gallager-managed sessions)
2. Default: `$TMPDIR/gallager.sock`

Override with `--socket <path>`.

## Commands
...
```

- [ ] **Step 2: Commit**

```bash
git add docs/gallager-cli-api.md
git commit -m "docs: add Gallager CLI API reference (#343)"
```

---

### Task 14: E2E Test Scenario

Create an E2E test that exercises the API commands against a running app.

**Files:**
- Create E2E scenario file (use `/e2e-for-feature` skill as specified in #343)

- [ ] **Step 1: Create E2E test scenario**

Use the `/e2e-for-feature` skill to generate an E2E scenario that:
1. Launches the app
2. Runs `gallager ping` and verifies response
3. Runs `gallager list-sessions --json` and verifies session data
4. Runs `gallager identify --json` and verifies context
5. Runs `gallager send "echo hello"` followed by `gallager send-key enter`
6. Runs `gallager split-pane right` and verifies new pane
7. Runs `gallager list-panes --json` and verifies pane count increased
8. Runs `gallager notify --title "Test" --body "Hello"` and verifies notification
9. Takes screenshots at key points

The E2E framework can invoke the `gallager` binary from the app bundle. The `GALLAGER_SOCKET` env var is set on the tmux sessions managed by the app.

- [ ] **Step 2: Run E2E test locally**

Run the E2E scenario 2-3 times to verify stability. Visually inspect all screenshots.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "test: add E2E scenario for Gallager CLI API (#343)"
```
