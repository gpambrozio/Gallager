# End-to-End Testing Strategies for ClaudeSpy

**Date:** 2026-02-07  
**Author:** Marvin (AI Assistant)  
**Project:** ClaudeSpy - Multi-Platform Client-Server Architecture

---

## Executive Summary

ClaudeSpy presents a unique E2E testing challenge: coordinating automated tests across three separate applications (macOS app, iOS app, and Vapor server) that communicate via WebSocket connections and encrypted channels. This report evaluates three distinct strategies for implementing comprehensive end-to-end automated testing.

**Key Requirements:**
- Run Vapor server on localhost
- Launch macOS app configured to connect to local server
- Launch iOS app in simulator configured to connect to local server
- Test multi-app scenarios (pairing, reconnection, state synchronization)
- Expandable framework for adding new test flows as features are added

---

## Strategy 1: XCUITest Orchestration with Shared Test Server

### Overview
Use XCUITest as the primary orchestration layer, with a shared test server instance that both macOS and iOS UI tests connect to. Tests coordinate using a shared test plan that sequences operations across platforms.

### Architecture

```
┌─────────────────────────────────────────────────────┐
│            XCTest Test Runner (Host Process)        │
│                                                     │
│  ┌──────────────────┐      ┌──────────────────┐   │
│  │  macOS UI Tests  │      │   iOS UI Tests   │   │
│  │  (XCUITest)      │      │   (XCUITest)     │   │
│  └────────┬─────────┘      └────────┬─────────┘   │
│           │                          │             │
│           │   ┌─────────────────────┘             │
│           │   │                                    │
│           │   │   ┌──────────────────────┐        │
│           │   │   │  Vapor Test Server   │        │
│           │   │   │  (localhost:8080)    │        │
│           │   │   └──────────────────────┘        │
│           │   │                                    │
│           ▼   ▼                                    │
│  ┌─────────────────────────────────┐              │
│  │   ClaudeSpy macOS App (Debug)   │              │
│  └─────────────────────────────────┘              │
│                                                    │
│  ┌─────────────────────────────────┐              │
│  │  ClaudeSpy iOS App (Simulator)  │              │
│  └─────────────────────────────────┘              │
└─────────────────────────────────────────────────────┘
```

### Implementation Details

#### 1. Shared Test Server Setup

Create a test-specific Vapor server configuration:

```swift
// ClaudeSpyPackage/Tests/E2ETestSupport/TestVaporServer.swift

import Vapor
@testable import ClaudeSpyExternalServer

actor TestVaporServer {
    private var app: Application?
    private var serverTask: Task<Void, Error>?
    
    func start() async throws {
        let app = try await Application.make(.testing)
        
        // Configure test-specific settings
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 8765 // Different from production
        
        // Apply standard configuration
        try await configure(app)
        
        // Start server in background
        serverTask = Task {
            try await app.execute()
        }
        
        self.app = app
        
        // Wait for server to be ready
        try await Task.sleep(for: .seconds(1))
    }
    
    func stop() async throws {
        serverTask?.cancel()
        try await app?.asyncShutdown()
    }
    
    // Helper methods for test introspection
    func getPairings() async throws -> [Pair] {
        // Access internal state for verification
    }
    
    func clearDatabase() async throws {
        // Reset state between tests
    }
}
```

#### 2. Test Coordinator Protocol

Define a protocol for coordinating between platform tests:

```swift
// ClaudeSpyPackage/Tests/E2ETestSupport/TestCoordinator.swift

protocol TestCoordinator {
    func waitForMacOSApp(timeout: TimeInterval) async throws
    func waitForIOSApp(timeout: TimeInterval) async throws
    func waitForServerReady(timeout: TimeInterval) async throws
    func syncPoint(named: String) async throws
}

actor SharedTestCoordinator: TestCoordinator {
    private var syncPoints: [String: CheckedContinuation<Void, Never>] = [:]
    
    // Synchronization primitives for coordinated testing
    func syncPoint(named: String) async throws {
        await withCheckedContinuation { continuation in
            syncPoints[named] = continuation
        }
    }
}
```

#### 3. Test Execution Flow

```swift
// ClaudeSpyUITests/E2EPairingTests.swift

@MainActor
class E2EPairingTests: XCTestCase {
    static var server: TestVaporServer!
    static var coordinator: SharedTestCoordinator!
    
    override class func setUp() {
        super.setUp()
        
        // Start shared server once for all tests
        server = TestVaporServer()
        Task {
            try await server.start()
        }
        
        coordinator = SharedTestCoordinator()
    }
    
    override class func tearDown() {
        Task {
            try await server.stop()
        }
        super.tearDown()
    }
    
    func testFreshPairing() async throws {
        // 1. Launch apps with test configuration
        let iosApp = XCUIApplication()
        iosApp.launchEnvironment = [
            "E2E_TEST_MODE": "1",
            "SERVER_URL": "ws://127.0.0.1:8765"
        ]
        iosApp.launch()
        
        // Wait for iOS app to be ready
        try await coordinator.waitForIOSApp(timeout: 5.0)
        
        // 2. Generate pairing code on iOS
        let pairingButton = iosApp.buttons["Generate Pairing Code"]
        XCTAssertTrue(pairingButton.waitForExistence(timeout: 5))
        pairingButton.tap()
        
        // Extract pairing code from UI
        let codeLabel = iosApp.staticTexts.matching(
            NSPredicate(format: "label MATCHES '\\\\d{6}'")
        ).firstMatch
        let pairingCode = codeLabel.label
        
        // 3. Sync point: pairing code generated
        try await coordinator.syncPoint(named: "pairing-code-generated")
        
        // 4. Verify server received pairing request
        let serverPairings = try await server.getPairings()
        XCTAssertEqual(serverPairings.count, 1)
        
        // 5. macOS test would enter this code (separate test file)
        // See ClaudeSpyServerUITests/E2EPairingTests.swift
    }
}
```

#### 4. App Configuration for Testing

Modify apps to detect test mode:

```swift
// ClaudeSpyFeature/Models/IOSSettings.swift

extension IOSSettings {
    static var e2eTestConfiguration: IOSSettings {
        var settings = IOSSettings()
        if ProcessInfo.processInfo.environment["E2E_TEST_MODE"] == "1" {
            if let serverURL = ProcessInfo.processInfo.environment["SERVER_URL"] {
                settings.serverURL = serverURL
            }
            settings.autoConnect = true
            // Disable encryption for test inspection
            settings.testMode = true
        }
        return settings
    }
}
```

### Advantages ✅

1. **Native Apple Tooling**: Leverages XCUITest, which is well-supported and integrated with Xcode
2. **Real App Testing**: Tests actual compiled apps, not mocked components
3. **Visual Debugging**: Xcode's UI testing debugger shows both app UIs simultaneously
4. **Accessibility Integration**: Uses accessibility identifiers, promoting better app design
5. **CI/CD Ready**: Works with Xcode Cloud, GitHub Actions with macOS runners
6. **Shared Vapor Instance**: Single server reduces test complexity and flakiness

### Disadvantages ❌

1. **Coordination Complexity**: Synchronizing two separate XCUITest processes is non-trivial
2. **Slower Execution**: UI tests are inherently slower than unit tests
3. **Flakiness Risk**: UI tests can be flaky due to timing issues and animation
4. **Limited Server Introspection**: Hard to inspect server state without adding test-specific APIs
5. **Sequential Execution**: Can't easily parallelize tests across platforms
6. **Xcode Dependency**: Requires Xcode and macOS for all test runs

### Implementation Effort

- **Initial Setup**: Medium (2-3 days)
- **Per-Test Case**: Low (reusable patterns)
- **Maintenance**: Medium (UI changes require test updates)

### Best For

- Teams already familiar with XCUITest
- Projects prioritizing real-world testing scenarios
- When visual verification is important

---

## Strategy 2: Swift Testing with Process Control

### Overview
Use Swift Testing framework (modern successor to XCTest) to orchestrate all three components as separate processes, with protocol-based communication for verification. Tests launch apps as subprocesses and communicate via dedicated test endpoints.

### Architecture

```
┌──────────────────────────────────────────────────────┐
│        Swift Testing Suite (Process Manager)        │
│                                                      │
│  ┌────────────────────────────────────────────┐    │
│  │           E2ETestOrchestrator               │    │
│  │                                              │    │
│  │  • Spawns Vapor server as subprocess        │    │
│  │  • Spawns macOS app via NSWorkspace         │    │
│  │  • Launches iOS simulator via simctl        │    │
│  │  • Communicates via HTTP test endpoints     │    │
│  └─────┬────────────────────────────────┬──────┘    │
│        │                                 │           │
│        ▼                                 ▼           │
│  ┌─────────────┐  WebSocket  ┌──────────────────┐  │
│  │ Vapor Server│◄───────────►│   macOS App      │  │
│  │ (subprocess)│              │   (NSWorkspace)  │  │
│  │             │  WebSocket  │                  │  │
│  │             │◄────────────┤   iOS Simulator  │  │
│  │             │              │   (simctl)       │  │
│  │             │              └──────────────────┘  │
│  │             │                                    │
│  │ Test APIs:  │                                    │
│  │ /test/state │                                    │
│  │ /test/reset │                                    │
│  └─────────────┘                                    │
└──────────────────────────────────────────────────────┘
```

### Implementation Details

#### 1. Process Orchestrator

```swift
// ClaudeSpyPackage/Tests/E2ETests/ProcessOrchestrator.swift

import Testing
import Foundation

@Suite("End-to-End Tests")
struct E2ETestSuite {
    static let orchestrator = ProcessOrchestrator()
    
    init() async throws {
        try await Self.orchestrator.setUp()
    }
    
    deinit {
        Task {
            try await Self.orchestrator.tearDown()
        }
    }
}

actor ProcessOrchestrator {
    private var vaporProcess: Process?
    private var macOSAppProcess: Process?
    private var iOSSimulatorUDID: String?
    
    func setUp() async throws {
        // 1. Start Vapor server
        try await startVaporServer()
        
        // 2. Boot iOS Simulator
        iOSSimulatorUDID = try await bootSimulator()
        
        // 3. Install and launch iOS app on simulator
        try await installAndLaunchIOSApp(on: iOSSimulatorUDID!)
        
        // 4. Launch macOS app
        try await launchMacOSApp()
        
        // 5. Wait for all components to be ready
        try await waitForSystemReady()
    }
    
    func tearDown() async throws {
        macOSAppProcess?.terminate()
        vaporProcess?.terminate()
        
        if let udid = iOSSimulatorUDID {
            try await shutdownSimulator(udid: udid)
        }
    }
    
    private func startVaporServer() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "./.build/debug/ClaudeSpyExternalServer")
        process.environment = [
            "PORT": "8765",
            "LOG_LEVEL": "debug",
            "DATABASE": ":memory:", // In-memory for tests
        ]
        
        try process.run()
        vaporProcess = process
        
        // Wait for server to be ready
        try await waitForHTTP(url: "http://127.0.0.1:8765/health", timeout: 10)
    }
    
    private func bootSimulator() async throws -> String {
        // Use simctl to boot simulator
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "boot", "iPhone 16 Pro"]
        
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        
        try process.run()
        process.waitUntilExit()
        
        // Parse output to get UDID
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        // ... parse UDID from output
        
        return "simulator-udid"
    }
    
    private func installAndLaunchIOSApp(on udid: String) async throws {
        // Install app bundle
        let installProcess = Process()
        installProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        installProcess.arguments = [
            "simctl", "install", udid,
            "./Build/Products/Debug-iphonesimulator/ClaudeSpy.app"
        ]
        try installProcess.run()
        installProcess.waitUntilExit()
        
        // Launch with test configuration
        let launchProcess = Process()
        launchProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        launchProcess.arguments = [
            "simctl", "launch", udid,
            "com.example.ClaudeSpy",
            "--args",
            "-E2E_TEST_MODE", "1",
            "-SERVER_URL", "ws://127.0.0.1:8765"
        ]
        try launchProcess.run()
    }
    
    private func launchMacOSApp() async throws {
        let workspace = NSWorkspace.shared
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.environment = [
            "E2E_TEST_MODE": "1",
            "SERVER_URL": "ws://127.0.0.1:8765"
        ]
        
        let appURL = URL(fileURLWithPath: "./Build/Products/Debug/ClaudeSpyServer.app")
        try await workspace.openApplication(at: appURL, configuration: configuration)
    }
    
    private func waitForSystemReady() async throws {
        // Poll test endpoints until all components report ready
        let endpoints = [
            "http://127.0.0.1:8765/test/ready",
            "http://127.0.0.1:8766/test/ready", // macOS app test endpoint
            "http://127.0.0.1:8767/test/ready"  // iOS app test endpoint (via simctl)
        ]
        
        for endpoint in endpoints {
            try await waitForHTTP(url: endpoint, timeout: 30)
        }
    }
}
```

#### 2. Test Endpoint Implementation

Add test-only HTTP endpoints to apps:

```swift
// ClaudeSpyServerFeature/Testing/TestServer.swift

#if DEBUG
import Vapor

class TestHTTPServer {
    private let app: Application
    
    init() {
        app = Application(.development)
        app.http.server.configuration.port = 8766
        
        app.get("test", "ready") { req -> String in
            "OK"
        }
        
        app.get("test", "state") { req -> AppState in
            // Return current app state for verification
            AppState(
                isPaired: /* current state */,
                connectionStatus: /* current status */,
                // ... other relevant state
            )
        }
        
        app.post("test", "action") { req -> HTTPStatus in
            let action = try req.content.decode(TestAction.self)
            // Execute test action
            await performTestAction(action)
            return .ok
        }
    }
    
    func start() async throws {
        try await app.execute()
    }
}

// In AppCoordinator:
#if DEBUG
private var testServer: TestHTTPServer?

init() {
    if ProcessInfo.processInfo.environment["E2E_TEST_MODE"] == "1" {
        testServer = TestHTTPServer()
        Task {
            try await testServer?.start()
        }
    }
}
#endif
#endif
```

#### 3. Test Implementation

```swift
// ClaudeSpyPackage/Tests/E2ETests/PairingTests.swift

import Testing
import Foundation

@Suite("Pairing Flow")
struct PairingTests {
    let orchestrator: ProcessOrchestrator
    
    init() async throws {
        orchestrator = ProcessOrchestrator()
        try await orchestrator.setUp()
    }
    
    @Test("Fresh pairing between iOS and macOS")
    func testFreshPairing() async throws {
        let client = HTTPClient()
        
        // 1. Trigger pairing code generation on iOS
        try await client.post(
            "http://127.0.0.1:8767/test/action",
            body: TestAction.generatePairingCode
        )
        
        // 2. Get generated pairing code from iOS app state
        let iosState = try await client.get(
            "http://127.0.0.1:8767/test/state"
        ).decode(AppState.self)
        
        let pairingCode = try #require(iosState.pairingCode)
        
        // 3. Verify server has the pairing request
        let serverState = try await client.get(
            "http://127.0.0.1:8765/test/state"
        ).decode(ServerState.self)
        
        #expect(serverState.pendingPairings.count == 1)
        #expect(serverState.pendingPairings.first?.code == pairingCode)
        
        // 4. Enter pairing code on macOS
        try await client.post(
            "http://127.0.0.1:8766/test/action",
            body: TestAction.enterPairingCode(pairingCode)
        )
        
        // 5. Wait for pairing to complete
        try await Task.sleep(for: .seconds(2))
        
        // 6. Verify both apps show paired state
        let iosStateAfter = try await client.get(
            "http://127.0.0.1:8767/test/state"
        ).decode(AppState.self)
        
        let macStateAfter = try await client.get(
            "http://127.0.0.1:8766/test/state"
        ).decode(AppState.self)
        
        #expect(iosStateAfter.isPaired == true)
        #expect(macStateAfter.isPaired == true)
        
        // 7. Verify server has completed pairing
        let serverStateAfter = try await client.get(
            "http://127.0.0.1:8765/test/state"
        ).decode(ServerState.self)
        
        #expect(serverStateAfter.activePairings.count == 1)
        #expect(serverStateAfter.pendingPairings.count == 0)
    }
    
    @Test("Apps reconnect after restart")
    func testReconnectAfterRestart() async throws {
        // First establish pairing (could call previous test as setup)
        try await testFreshPairing()
        
        let client = HTTPClient()
        
        // 1. Kill both apps
        try await orchestrator.restartIOSApp()
        try await orchestrator.restartMacOSApp()
        
        // 2. Wait for reconnection
        try await Task.sleep(for: .seconds(3))
        
        // 3. Verify both apps reconnected automatically
        let iosState = try await client.get(
            "http://127.0.0.1:8767/test/state"
        ).decode(AppState.self)
        
        let macState = try await client.get(
            "http://127.0.0.1:8766/test/state"
        ).decode(AppState.self)
        
        #expect(iosState.connectionStatus == .connected)
        #expect(macState.connectionStatus == .connected)
    }
}
```

### Advantages ✅

1. **Modern Testing Framework**: Swift Testing is cleaner, more expressive than XCTest
2. **Full Control**: Complete control over all three processes
3. **Flexible Verification**: Can inspect internal state via test endpoints
4. **Faster Iteration**: No UI interaction delays, direct API calls
5. **Better Error Messages**: Swift Testing provides clearer failure diagnostics
6. **Parallelization**: Can run multiple test suites in parallel
7. **CI-Friendly**: Easier to run in headless CI environments

### Disadvantages ❌

1. **Not Testing Real UI**: Tests HTTP APIs, not actual user interactions
2. **Test Endpoint Maintenance**: Need to maintain test-only code in production apps
3. **Process Management Complexity**: Managing subprocesses, simulators, etc. is tricky
4. **Simulator Reliability**: iOS Simulator can be flaky in automated scenarios
5. **Security Concerns**: Test endpoints must be debug-only, never ship to production
6. **Setup Complexity**: More complex initial setup than XCUITest

### Implementation Effort

- **Initial Setup**: High (1 week)
- **Per-Test Case**: Low (once patterns established)
- **Maintenance**: Medium (test endpoints need updates with app changes)

### Best For

- Teams wanting faster, more reliable tests
- Projects with complex multi-step flows
- When direct state verification is more important than UI testing

---

## Strategy 3: Hybrid Approach with Test Coordinator Service

### Overview
Build a dedicated test coordinator service that orchestrates all three components and provides a DSL for defining test scenarios. This service acts as a "puppet master" controlling all apps and the server through a combination of UI automation and API calls.

### Architecture

```
┌────────────────────────────────────────────────────────────┐
│               Test Coordinator Service                     │
│         (Separate Swift Package / Web Server)              │
│                                                            │
│  ┌──────────────────────────────────────────────────┐    │
│  │         Test Scenario Engine                      │    │
│  │  • DSL for defining test flows                    │    │
│  │  • State machine for orchestration                │    │
│  │  • Event-driven coordination                      │    │
│  │  • WebSocket for real-time sync                   │    │
│  └───────┬──────────────┬────────────────┬──────────┘    │
│          │              │                 │               │
│          │              │                 │               │
│          ▼              ▼                 ▼               │
│  ┌──────────────┐ ┌──────────┐  ┌──────────────────┐    │
│  │  XCUITest    │ │  Vapor   │  │   XCUITest       │    │
│  │  Adapter     │ │  Server  │  │   Adapter        │    │
│  │  (macOS)     │ │          │  │   (iOS)          │    │
│  └──────┬───────┘ └────┬─────┘  └────────┬─────────┘    │
│         │              │                   │              │
└─────────┼──────────────┼───────────────────┼──────────────┘
          │              │                   │
          ▼              ▼                   ▼
    ┌──────────┐  ┌──────────┐       ┌──────────┐
    │  macOS   │  │  Vapor   │       │   iOS    │
    │   App    │◄─┤  Server  ├──────►│   App    │
    └──────────┘  └──────────┘       └──────────┘
```

### Implementation Details

#### 1. Test Coordinator Service

Create a separate package for the coordinator:

```swift
// TestCoordinator/Sources/TestCoordinator/ScenarioEngine.swift

import Vapor
import Foundation

@main
struct TestCoordinatorApp {
    static func main() async throws {
        let app = Application(.development)
        defer { app.shutdown() }
        
        // WebSocket endpoint for test clients
        app.webSocket("ws") { req, ws in
            await TestSessionManager.shared.handleConnection(ws)
        }
        
        // REST API for test control
        app.get("scenario", ":id", "status") { req -> ScenarioStatus in
            let id = try req.parameters.require("id", as: UUID.self)
            return await ScenarioEngine.shared.status(for: id)
        }
        
        app.post("scenario", "start") { req -> ScenarioExecution in
            let scenario = try req.content.decode(TestScenario.self)
            return try await ScenarioEngine.shared.execute(scenario)
        }
        
        try await app.execute()
    }
}

actor ScenarioEngine {
    static let shared = ScenarioEngine()
    
    private var executions: [UUID: ScenarioExecution] = [:]
    
    func execute(_ scenario: TestScenario) async throws -> ScenarioExecution {
        let id = UUID()
        let execution = ScenarioExecution(id: id, scenario: scenario)
        executions[id] = execution
        
        // Start execution in background
        Task {
            try await runScenario(execution)
        }
        
        return execution
    }
    
    private func runScenario(_ execution: ScenarioExecution) async throws {
        for step in execution.scenario.steps {
            switch step {
            case .launchApp(let platform, let config):
                try await launchApp(platform: platform, config: config)
                
            case .waitFor(let condition):
                try await waitForCondition(condition)
                
            case .performAction(let target, let action):
                try await performAction(on: target, action: action)
                
            case .verify(let assertion):
                try await verifyAssertion(assertion)
                
            case .syncPoint(let name):
                try await syncPoint(named: name)
            }
            
            // Update execution state
            await execution.updateProgress()
        }
    }
}
```

#### 2. Test Scenario DSL

```swift
// TestCoordinator/Sources/TestCoordinator/ScenarioDSL.swift

struct TestScenario: Codable {
    let name: String
    let steps: [TestStep]
}

enum TestStep: Codable {
    case launchApp(platform: Platform, config: AppConfig)
    case waitFor(condition: Condition)
    case performAction(target: Target, action: Action)
    case verify(assertion: Assertion)
    case syncPoint(name: String)
}

enum Platform: String, Codable {
    case macOS
    case iOS
    case vaporServer
}

struct AppConfig: Codable {
    let serverURL: String?
    let environment: [String: String]
}

enum Target: Codable {
    case macOS(element: String)
    case iOS(element: String)
    case server(endpoint: String)
}

enum Action: Codable {
    case tap
    case enter(text: String)
    case press(key: String)
    case httpRequest(method: String, body: String?)
}

enum Condition: Codable {
    case elementExists(platform: Platform, element: String)
    case serverState(predicate: String)
    case timeout(seconds: Double)
}

enum Assertion: Codable {
    case equals(actual: String, expected: String)
    case contains(haystack: String, needle: String)
    case serverHasState(key: String, value: String)
}
```

#### 3. Scenario Definition (YAML or Swift)

Define test scenarios in a declarative format:

```yaml
# Scenarios/fresh-pairing.yaml
name: Fresh Pairing Flow
steps:
  - launchApp:
      platform: vaporServer
      config:
        port: 8765
        database: ":memory:"
        
  - waitFor:
      condition:
        serverState: "ready"
        timeout: 10
        
  - launchApp:
      platform: iOS
      config:
        serverURL: "ws://127.0.0.1:8765"
        environment:
          E2E_TEST_MODE: "1"
          
  - launchApp:
      platform: macOS
      config:
        serverURL: "ws://127.0.0.1:8765"
        environment:
          E2E_TEST_MODE: "1"
          
  - waitFor:
      condition:
        elementExists:
          platform: iOS
          element: "Generate Pairing Code"
          
  - performAction:
      target:
        iOS: "Generate Pairing Code"
      action: tap
      
  - syncPoint:
      name: "pairing-code-generated"
      
  - verify:
      assertion:
        serverHasState:
          key: "pendingPairings.count"
          value: "1"
          
  - performAction:
      target:
        iOS: "pairingCodeLabel"
      action: copyText
      
  - performAction:
      target:
        macOS: "enterPairingCodeField"
      action:
        enter: "${copiedText}"
        
  - performAction:
      target:
        macOS: "pairButton"
      action: tap
      
  - waitFor:
      condition:
        timeout: 5
        
  - verify:
      assertion:
        serverHasState:
          key: "activePairings.count"
          value: "1"
          
  - verify:
      assertion:
        elementExists:
          platform: iOS
          element: "Paired Indicator"
          
  - verify:
      assertion:
        elementExists:
          platform: macOS
          element: "Paired Indicator"
```

Or in Swift:

```swift
// Scenarios/FreshPairingScenario.swift

extension TestScenario {
    static let freshPairing = TestScenario(name: "Fresh Pairing Flow") {
        LaunchApp(.vaporServer, config: AppConfig(
            serverURL: nil,
            environment: ["PORT": "8765", "DATABASE": ":memory:"]
        ))
        
        WaitFor(.serverState("ready"), timeout: 10)
        
        LaunchApp(.iOS, config: AppConfig(
            serverURL: "ws://127.0.0.1:8765",
            environment: ["E2E_TEST_MODE": "1"]
        ))
        
        LaunchApp(.macOS, config: AppConfig(
            serverURL: "ws://127.0.0.1:8765",
            environment: ["E2E_TEST_MODE": "1"]
        ))
        
        WaitFor(.elementExists(.iOS, "Generate Pairing Code"))
        
        PerformAction(.iOS("Generate Pairing Code"), .tap)
        
        SyncPoint("pairing-code-generated")
        
        Verify(.serverHasState("pendingPairings.count", "1"))
        
        let code = CopyText(.iOS("pairingCodeLabel"))
        
        PerformAction(.macOS("enterPairingCodeField"), .enter(code))
        PerformAction(.macOS("pairButton"), .tap)
        
        WaitFor(.timeout(5))
        
        Verify(.serverHasState("activePairings.count", "1"))
        Verify(.elementExists(.iOS, "Paired Indicator"))
        Verify(.elementExists(.macOS, "Paired Indicator"))
    }
}
```

#### 4. XCUITest Adapter

```swift
// ClaudeSpyUITests/TestCoordinatorAdapter.swift

import XCTest

class TestCoordinatorAdapter: XCTestCase {
    static var coordinator: TestCoordinatorClient!
    
    override class func setUp() {
        super.setUp()
        coordinator = TestCoordinatorClient(url: "http://localhost:9000")
    }
    
    func testExecuteScenario() async throws {
        let execution = try await Self.coordinator.startScenario(.freshPairing)
        
        // Poll for completion
        while !execution.isComplete {
            try await Task.sleep(for: .seconds(1))
            let status = try await Self.coordinator.getStatus(execution.id)
            
            if let error = status.error {
                XCTFail("Scenario failed: \\(error)")
                return
            }
        }
        
        XCTAssertTrue(execution.isSuccess)
    }
}
```

#### 5. Running Tests

```bash
# Terminal 1: Start test coordinator
cd TestCoordinator
swift run TestCoordinatorApp

# Terminal 2: Run XCUITests (which connect to coordinator)
xcodebuild test -scheme ClaudeSpy -destination 'platform=iOS Simulator,name=iPhone 16 Pro'

# Or use the CLI directly
test-coordinator run fresh-pairing.yaml
```

### Advantages ✅

1. **Declarative Test Definition**: Tests are easy to read, write, and maintain
2. **Language Agnostic**: Scenarios can be defined in YAML, JSON, or Swift
3. **Centralized Orchestration**: Single source of truth for test execution
4. **Reusable Components**: Common steps can be shared across scenarios
5. **Visual Dashboard**: Can build a web UI to visualize test execution
6. **Historical Results**: Can store and analyze test results over time
7. **Cross-Platform**: Same DSL works for iOS, macOS, and server tests
8. **Non-Developer Friendly**: QA engineers can write tests without Swift knowledge

### Disadvantages ❌

1. **Most Complex Setup**: Requires building and maintaining a separate service
2. **Learning Curve**: Team needs to learn the DSL and coordinator architecture
3. **Abstraction Overhead**: Extra layer between tests and actual components
4. **Debugging Difficulty**: Harder to debug failures across multiple layers
5. **Maintenance Burden**: Need to maintain coordinator service alongside apps
6. **Potential Overengineering**: May be overkill for smaller projects

### Implementation Effort

- **Initial Setup**: Very High (2-3 weeks)
- **Per-Test Case**: Very Low (declarative scenarios are quick to write)
- **Maintenance**: Medium-High (coordinator needs updates with app changes)

### Best For

- Large teams with dedicated QA engineers
- Projects with many complex multi-step scenarios
- When test maintainability and readability are top priorities
- Organizations wanting a reusable testing framework across multiple projects

---

## Comparison Matrix

| Criterion | Strategy 1: XCUITest | Strategy 2: Swift Testing | Strategy 3: Test Coordinator |
|-----------|---------------------|---------------------------|------------------------------|
| **Setup Time** | Medium | High | Very High |
| **Per-Test Effort** | Low | Low | Very Low |
| **Test Execution Speed** | Slow (UI-based) | Fast (API-based) | Medium (mixed) |
| **Flakiness Risk** | Medium-High | Low-Medium | Low |
| **Real-World Accuracy** | High (actual UI) | Medium (API-only) | High (mixed approach) |
| **CI/CD Integration** | Good | Excellent | Excellent |
| **Debugging Experience** | Good (Xcode tools) | Good (Swift logs) | Challenging |
| **Maintainability** | Medium | Medium | High (declarative) |
| **Extensibility** | Medium | High | Very High |
| **Learning Curve** | Low (familiar tools) | Medium | High (new DSL) |
| **State Inspection** | Limited | Excellent | Excellent |
| **Parallel Execution** | Difficult | Easy | Easy |

---

## Recommendation

### For Immediate Implementation: **Strategy 2 (Swift Testing with Process Control)**

**Rationale:**
- Provides the best balance of reliability, speed, and maintainability
- Leverages modern Swift Testing framework
- Allows direct state verification via test endpoints
- Easier to run in CI/CD pipelines
- Can evolve toward Strategy 3 if needed

### Migration Path

1. **Phase 1** (Week 1-2): Implement Process Orchestrator + Test Endpoints
   - Build `ProcessOrchestrator` to manage all three processes
   - Add test-only HTTP endpoints to both apps
   - Create basic helper utilities

2. **Phase 2** (Week 3): Implement Core Test Scenarios
   - Fresh pairing flow
   - Reconnection after restart
   - Unpair and re-pair

3. **Phase 3** (Week 4): Expand Test Coverage
   - Terminal streaming
   - Multiple device pairing
   - Error recovery scenarios

4. **Phase 4** (Month 2): Refine and Optimize
   - Add more comprehensive assertions
   - Improve error handling
   - Document patterns for new tests

5. **Future Enhancement**: Consider migrating to Strategy 3
   - If test scenarios become very complex
   - If non-developers need to write tests
   - If you want a reusable framework

---

## Implementation Checklist

### Prerequisites
- [ ] Create `ClaudeSpyPackage/Tests/E2ETests/` directory
- [ ] Add test-only HTTP server to iOS app (debug builds only)
- [ ] Add test-only HTTP server to macOS app (debug builds only)
- [ ] Add test endpoints to Vapor server
- [ ] Create test database configuration (in-memory)

### Core Infrastructure
- [ ] Implement `ProcessOrchestrator` actor
- [ ] Add Vapor server subprocess management
- [ ] Add iOS Simulator control (simctl wrapper)
- [ ] Add macOS app launch control (NSWorkspace)
- [ ] Implement health check polling for all components
- [ ] Add cleanup/teardown logic

### Helper Utilities
- [ ] HTTP client for test endpoint communication
- [ ] WebSocket inspector for connection verification
- [ ] State snapshot/comparison utilities
- [ ] Timing and retry utilities

### Test Cases
- [ ] Fresh pairing (iOS generates, macOS enters)
- [ ] Fresh pairing (macOS generates, iOS enters)
- [ ] Automatic reconnection after app restart
- [ ] Automatic reconnection after server restart
- [ ] Pairing code expiration
- [ ] Invalid pairing code handling
- [ ] Unpairing flow
- [ ] Multiple simultaneous pairings

### CI/CD Integration
- [ ] GitHub Actions workflow for E2E tests
- [ ] Test result reporting
- [ ] Failure screenshot capture
- [ ] Log aggregation

---

## Security Considerations

### Test Endpoints
- **MUST** be wrapped in `#if DEBUG` compiler directives
- **MUST** never be included in release builds
- **SHOULD** require authentication token (even in debug builds)
- **SHOULD** log all test endpoint access for auditing

### Test Data
- **MUST** use separate database for tests (never production data)
- **SHOULD** use random pairing codes to avoid conflicts
- **SHOULD** clean up all test data after each test run

### Network Configuration
- **MUST** use localhost-only server binding for tests
- **SHOULD** use non-standard ports to avoid conflicts
- **SHOULD** disable external network access during tests

---

## Performance Benchmarks (Estimated)

### Test Execution Times

| Test Scenario | Strategy 1 | Strategy 2 | Strategy 3 |
|---------------|-----------|-----------|-----------|
| Fresh Pairing | 15-20s | 3-5s | 8-10s |
| Reconnection | 20-25s | 5-7s | 10-12s |
| Full Suite (10 tests) | 4-5 min | 1-2 min | 2-3 min |

### CI/CD Impact

| Aspect | Strategy 1 | Strategy 2 | Strategy 3 |
|--------|-----------|-----------|-----------|
| Setup Overhead | 2-3 min | 1 min | 2 min |
| Parallel Execution | No | Yes | Yes |
| Total CI Time | 10-15 min | 3-5 min | 5-8 min |

---

## Resources and References

### XCUITest Documentation
- [Apple XCTest Framework](https://developer.apple.com/documentation/xctest)
- [UI Testing in Xcode](https://developer.apple.com/documentation/xctest/user_interface_tests)

### Swift Testing
- [Swift Testing Package](https://github.com/apple/swift-testing)
- [Migrating from XCTest to Swift Testing](https://developer.apple.com/videos/play/wwdc2023/10179/)

### Process Management
- [NSWorkspace Documentation](https://developer.apple.com/documentation/appkit/nsworkspace)
- [simctl Command Reference](https://developer.apple.com/documentation/xcode/running-your-app-in-simulator-or-on-a-device)

### Vapor Testing
- [Vapor Testing Guide](https://docs.vapor.codes/testing/)
- [Vapor Application Lifecycle](https://docs.vapor.codes/basics/lifecycle/)

### E2E Testing Best Practices
- [iOS Testing Best Practices](https://testingwithdave.com/ios-testing-best-practices/)
- [The Practical Test Pyramid](https://martinfowler.com/articles/practical-test-pyramid.html)

---

## Appendix: Example Test Output

### Successful Test Run
```
Test Suite 'E2ETests' started at 2026-02-07 16:37:00.000
Test Case '-[E2ETests.PairingTests testFreshPairing]' started.
[16:37:01] ✓ Vapor server started (port 8765)
[16:37:02] ✓ iOS Simulator booted (iPhone 16 Pro)
[16:37:04] ✓ iOS app installed and launched
[16:37:05] ✓ macOS app launched
[16:37:06] ✓ All components ready
[16:37:06] → Generating pairing code on iOS...
[16:37:07] ✓ Pairing code generated: 123456
[16:37:07] ✓ Server registered pairing request
[16:37:08] → Entering pairing code on macOS...
[16:37:09] ✓ Pairing code entered
[16:37:10] ✓ Pairing completed successfully
[16:37:10] ✓ iOS app shows paired state
[16:37:10] ✓ macOS app shows paired state
[16:37:10] ✓ Server confirms active pairing
Test Case '-[E2ETests.PairingTests testFreshPairing]' passed (10.234 seconds).
```

### Failed Test Run
```
Test Suite 'E2ETests' started at 2026-02-07 16:40:00.000
Test Case '-[E2ETests.PairingTests testFreshPairing]' started.
[16:40:01] ✓ Vapor server started (port 8765)
[16:40:02] ✓ iOS Simulator booted (iPhone 16 Pro)
[16:40:04] ✓ iOS app installed and launched
[16:40:05] ✓ macOS app launched
[16:40:06] ✓ All components ready
[16:40:06] → Generating pairing code on iOS...
[16:40:07] ✓ Pairing code generated: 789012
[16:40:07] ✗ Server did not register pairing request (timeout after 5s)
[16:40:12] ✗ Expected: pendingPairings.count == 1, Actual: 0

Server logs:
[2026-02-07 16:40:07] [ERROR] Failed to process pairing request: Connection refused

Test Case '-[E2ETests.PairingTests testFreshPairing]' failed (12.451 seconds).
```

---

## Conclusion

All three strategies are viable for implementing E2E testing in ClaudeSpy, each with distinct trade-offs:

- **Strategy 1 (XCUITest)** is the most familiar and provides real UI testing but can be slower and flakier
- **Strategy 2 (Swift Testing)** offers the best balance of speed, reliability, and modern practices (**Recommended**)
- **Strategy 3 (Test Coordinator)** provides the most sophisticated testing infrastructure but requires significant upfront investment

Choose Strategy 2 for immediate implementation and consider evolving toward Strategy 3 as test complexity grows.

The estimated timeline for full implementation of Strategy 2 is **3-4 weeks** for a complete E2E test suite covering the major user flows.

---

**Report End**
