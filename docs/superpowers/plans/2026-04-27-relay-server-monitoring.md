# Relay Server Monitoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add full observability to the ClaudeSpy relay server on Hetzner — app-level metrics from Vapor, host metrics from `node_exporter`, both pushed to Grafana Cloud, with Discord alerts when something breaks.

**Architecture:**
- Vapor server exposes `GET /metrics` (Prometheus text format), token-protected via `METRICS_TOKEN`. Counters tracked via a new `MetricsService` actor; gauges read live from existing services.
- Two systemd services on the Hetzner VM: `node_exporter` (host CPU/RAM/disk/net) and `alloy` (scrapes relay + node, pushes to Grafana Cloud Prometheus).
- All Grafana resources (datasources, dashboards, alert rules, contact points, notification policy) live in repo as YAML/JSON under `ClaudeSpyPackage/monitoring/`, applied via `grizzly`.
- Alerts route to a Discord channel via a Grafana Discord contact point.

**Tech Stack:** Swift 6.1 / Vapor (server), Grafana Alloy + node_exporter (VM agents), Grafana Cloud (free tier, hosted Prometheus + alerting), grizzly (config-as-code CLI), Discord webhooks.

---

## File Structure

**New / modified Swift files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/MetricsService.swift` — actor holding counters + Prometheus text rendering
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Routes/MetricsController.swift` — `RouteCollection` for `GET /metrics`
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Routes/routes.swift` — register `MetricsController`
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/configure.swift` — instantiate `MetricsService`, read `METRICS_TOKEN`, store in app
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/RelayService.swift` — accept `MetricsService`, increment `messages_relayed_total`
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/APNsService.swift` — accept `MetricsService`, increment `push_notifications_total`
- Create: `ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/MetricsServiceTests.swift` — unit tests for counters + rendering
- Create: `ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/MetricsEndpointTests.swift` — integration tests for `/metrics` route + auth

**New deployment / config files:**
- Modify: `ClaudeSpyPackage/docker-compose.yml` — bind port 8080 to 127.0.0.1 only, add `METRICS_TOKEN` env var
- Modify: `ClaudeSpyPackage/.env.example` — document `METRICS_TOKEN` (create the file if it doesn't exist)
- Create: `ClaudeSpyPackage/monitoring/agents/node_exporter.service` — systemd unit
- Create: `ClaudeSpyPackage/monitoring/agents/alloy.service` — systemd unit
- Create: `ClaudeSpyPackage/monitoring/agents/config.alloy` — Alloy pipeline config
- Create: `ClaudeSpyPackage/monitoring/agents/install.sh` — idempotent installer for both agents
- Create: `ClaudeSpyPackage/monitoring/grizzly/.env.example` — Grafana stack URL + service-account token
- Create: `ClaudeSpyPackage/monitoring/grizzly/contact-points/discord.yaml`
- Create: `ClaudeSpyPackage/monitoring/grizzly/notification-policies/main.yaml`
- Create: `ClaudeSpyPackage/monitoring/grizzly/alerts/relay-down.yaml`
- Create: `ClaudeSpyPackage/monitoring/grizzly/alerts/high-memory.yaml`
- Create: `ClaudeSpyPackage/monitoring/grizzly/alerts/disk-full.yaml`
- Create: `ClaudeSpyPackage/monitoring/grizzly/alerts/scrape-failed.yaml`
- Create: `ClaudeSpyPackage/monitoring/grizzly/dashboards/relay.json`
- Create: `ClaudeSpyPackage/monitoring/grizzly/Makefile` — `apply`, `pull`, `diff` targets

**Documentation:**
- Modify: `ClaudeSpyPackage/.gitignore` — ignore `monitoring/grizzly/.env`
- Modify: `docs/self-hosting.md` — add "Monitoring" section
- Create: `docs/monitoring.md` — operator runbook

---

## Phase 1 — Server-side `/metrics` endpoint

### Task 1: Branch and worktree setup

**Files:** none (git only)

- [ ] **Step 1:** Create a feature branch from `main`

```bash
git checkout main
git pull --rebase
git checkout -b feature/relay-monitoring
```

- [ ] **Step 2:** Verify clean tree

Run: `git status`
Expected: `nothing to commit, working tree clean`

---

### Task 2: `MetricsService` actor with counters and rendering

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/MetricsService.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/MetricsServiceTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/MetricsServiceTests.swift`:

```swift
import Testing
@testable import ClaudeSpyExternalServerLib

@Suite("MetricsService")
struct MetricsServiceTests {
    @Test("New service has zero counters")
    func zeroOnInit() async {
        let service = MetricsService()
        #expect(await service.messagesRelayedTotal == 0)
        #expect(await service.pushNotificationsTotal == 0)
    }

    @Test("incrementMessagesRelayed increments by one")
    func incrementMessagesRelayed() async {
        let service = MetricsService()
        await service.incrementMessagesRelayed()
        await service.incrementMessagesRelayed()
        #expect(await service.messagesRelayedTotal == 2)
    }

    @Test("incrementPushNotifications increments by one")
    func incrementPushNotifications() async {
        let service = MetricsService()
        await service.incrementPushNotifications()
        #expect(await service.pushNotificationsTotal == 1)
    }

    @Test("render returns Prometheus text format with all metrics")
    func renderFormat() async {
        let service = MetricsService()
        await service.incrementMessagesRelayed()
        await service.incrementPushNotifications()
        let snapshot = MetricsSnapshot(
            activePairs: 3,
            hostsConnected: 2,
            viewersConnected: 1,
            uptimeSeconds: 42
        )
        let body = await service.render(snapshot: snapshot, buildVersion: "test-1.0")

        // Must include HELP and TYPE lines
        #expect(body.contains("# HELP claudespy_messages_relayed_total"))
        #expect(body.contains("# TYPE claudespy_messages_relayed_total counter"))
        // Counter values
        #expect(body.contains("claudespy_messages_relayed_total 1"))
        #expect(body.contains("claudespy_push_notifications_total 1"))
        // Gauges from snapshot
        #expect(body.contains("claudespy_active_pairs 3"))
        #expect(body.contains("claudespy_ws_connections{device_type=\"host\"} 2"))
        #expect(body.contains("claudespy_ws_connections{device_type=\"viewer\"} 1"))
        #expect(body.contains("claudespy_uptime_seconds 42"))
        // Build info
        #expect(body.contains("claudespy_build_info{version=\"test-1.0\"} 1"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Use the `XcodeBuildTools:swift-package` skill to run tests. From `ClaudeSpyPackage/`:
```
swift test --filter MetricsServiceTests
```
Expected: FAIL with "cannot find 'MetricsService' in scope".

- [ ] **Step 3: Implement `MetricsService` and `MetricsSnapshot`**

Create `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/MetricsService.swift`:

```swift
import Foundation

/// Snapshot of live gauge values queried at scrape time.
/// Computed by the route handler from existing services (no caching).
struct MetricsSnapshot: Sendable {
    let activePairs: Int
    let hostsConnected: Int
    let viewersConnected: Int
    let uptimeSeconds: Int
}

/// Tracks monotonically-increasing counters for the relay server.
/// Gauges are not stored here — they're queried live at render time.
actor MetricsService {
    private(set) var messagesRelayedTotal: Int = 0
    private(set) var pushNotificationsTotal: Int = 0

    func incrementMessagesRelayed() {
        messagesRelayedTotal &+= 1
    }

    func incrementPushNotifications() {
        pushNotificationsTotal &+= 1
    }

    /// Render the full Prometheus text exposition for a scrape.
    func render(snapshot: MetricsSnapshot, buildVersion: String) -> String {
        var lines: [String] = []

        lines.append("# HELP claudespy_messages_relayed_total Total encrypted messages relayed since process start.")
        lines.append("# TYPE claudespy_messages_relayed_total counter")
        lines.append("claudespy_messages_relayed_total \(messagesRelayedTotal)")

        lines.append("# HELP claudespy_push_notifications_total Total push notifications sent to APNs since process start.")
        lines.append("# TYPE claudespy_push_notifications_total counter")
        lines.append("claudespy_push_notifications_total \(pushNotificationsTotal)")

        lines.append("# HELP claudespy_active_pairs Number of currently-paired devices.")
        lines.append("# TYPE claudespy_active_pairs gauge")
        lines.append("claudespy_active_pairs \(snapshot.activePairs)")

        lines.append("# HELP claudespy_ws_connections Active WebSocket connections by device type.")
        lines.append("# TYPE claudespy_ws_connections gauge")
        lines.append("claudespy_ws_connections{device_type=\"host\"} \(snapshot.hostsConnected)")
        lines.append("claudespy_ws_connections{device_type=\"viewer\"} \(snapshot.viewersConnected)")

        lines.append("# HELP claudespy_uptime_seconds Process uptime in seconds.")
        lines.append("# TYPE claudespy_uptime_seconds gauge")
        lines.append("claudespy_uptime_seconds \(snapshot.uptimeSeconds)")

        lines.append("# HELP claudespy_build_info Build version (always 1).")
        lines.append("# TYPE claudespy_build_info gauge")
        lines.append("claudespy_build_info{version=\"\(buildVersion)\"} 1")

        // Prometheus exposition requires trailing newline
        return lines.joined(separator: "\n") + "\n"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```
swift test --filter MetricsServiceTests
```
Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/MetricsService.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/MetricsServiceTests.swift
git commit -m "Add MetricsService for Prometheus exposition"
```

---

### Task 3: Add `connectionCounts` query to `ConnectionHub`

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/ConnectionHub.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/MetricsServiceTests.swift` (extend)

The `/metrics` handler needs aggregate per-device-type connection counts across all pairs. `ConnectionHub` only exposes per-pair queries today.

- [ ] **Step 1: Write the failing test**

Append to `MetricsServiceTests.swift`:

```swift
import ClaudeSpyNetworking

@Suite("ConnectionHub aggregate counts")
struct ConnectionHubCountsTests {
    @Test("connectionCounts returns zero for empty hub")
    func emptyHub() async {
        let hub = ConnectionHub()
        let counts = await hub.connectionCounts()
        #expect(counts.host == 0)
        #expect(counts.viewer == 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```
swift test --filter ConnectionHubCountsTests
```
Expected: FAIL — `connectionCounts` undefined.

- [ ] **Step 3: Add `connectionCounts()` to `ConnectionHub`**

In `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/ConnectionHub.swift`, add inside the actor (after `isViewerConnected`):

```swift
    /// Aggregate count of active connections by device type across all pairs.
    func connectionCounts() -> (host: Int, viewer: Int) {
        var host = 0
        var viewer = 0
        for (_, pairConnections) in connections {
            if pairConnections[.host] != nil { host += 1 }
            if pairConnections[.viewer] != nil { viewer += 1 }
        }
        return (host, viewer)
    }
```

- [ ] **Step 4: Run test to verify it passes**

```
swift test --filter ConnectionHubCountsTests
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/ConnectionHub.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/MetricsServiceTests.swift
git commit -m "Expose aggregate connection counts on ConnectionHub"
```

---

### Task 4: Wire `MetricsService` into `RelayService` and `APNsService`

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/RelayService.swift`
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/APNsService.swift`

These services need a reference to `MetricsService` so they can increment counters at message-relay and push-send sites. Use init-injection for both (matches existing pattern).

- [ ] **Step 1: Update `RelayService.init` to accept `MetricsService` and increment on relay**

Edit `RelayService.swift`. Change the property + init:

```swift
actor RelayService {
    private let pairingService: PairingService
    private let connectionHub: ConnectionHub
    private let apnsService: APNsService?
    private let metricsService: MetricsService
    private let logger = Logger(label: "relay-service")

    init(
        pairingService: PairingService,
        connectionHub: ConnectionHub,
        apnsService: APNsService?,
        metricsService: MetricsService
    ) {
        self.pairingService = pairingService
        self.connectionHub = connectionHub
        self.apnsService = apnsService
        self.metricsService = metricsService
    }
```

In `handleHostMessage`, in the `case let .encrypted(encryptedMessage):` branch, before the `await connectionHub.send(...)` call:

```swift
        case let .encrypted(encryptedMessage):
            await metricsService.incrementMessagesRelayed()
            logger.info("Relaying encrypted message to viewer")
            await connectionHub.send(.encrypted(encryptedMessage), to: pairId, deviceType: .viewer)
```

In `handleViewerMessage`, in the `case let .encrypted(encryptedMessage):` branch, inside the `if await connectionHub.isHostConnected(...)` true branch, before the `await connectionHub.send(...)`:

```swift
        case let .encrypted(encryptedMessage):
            if await connectionHub.isHostConnected(pairId: pairId) {
                await metricsService.incrementMessagesRelayed()
                logger.info("Relaying encrypted message to host")
                await connectionHub.send(.encrypted(encryptedMessage), to: pairId, deviceType: .host)
            } else {
                logger.warning("Host not connected, cannot relay encrypted command")
            }
```

- [ ] **Step 2: Update `APNsService` to accept `MetricsService` and increment on send**

Open `APNsService.swift`. Add a `metricsService: MetricsService` stored property and require it in init. Find the existing `sendEncryptedNotificationIfNeeded` method (or wherever an APNs push is actually dispatched) and add `await metricsService.incrementPushNotifications()` immediately after a successful `try await client.sendAlertNotification(...)` call (or equivalent — locate the APNs send call site).

> **Note for executor:** Read `APNsService.swift` first to find the exact send call site. Add the increment only on the success path (after the `try await` returns without throwing). If the file uses `await` on a `Result`, increment in `.success`.

- [ ] **Step 3: Build to confirm compilation**

```
swift build --product ClaudeSpyExternalServer
```
Expected: build fails — `configure.swift` still calls old initializers. We'll fix in next task.

- [ ] **Step 4: Do not commit yet** — Task 5 will land the wiring together.

---

### Task 5: Instantiate `MetricsService` in `configure.swift`

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/configure.swift`

- [ ] **Step 1: Add storage key + accessor**

In `configure.swift`, add a new storage key and Application accessor:

```swift
struct MetricsServiceKey: StorageKey {
    typealias Value = MetricsService
}

extension Application {
    var metricsService: MetricsService {
        guard let service = storage[MetricsServiceKey.self] else {
            fatalError("MetricsService not configured. Call configure(_:) first.")
        }
        return service
    }
}
```

(Place near the other storage keys / accessors.)

Also add a process-start time storage so `/metrics` can compute uptime:

```swift
struct ProcessStartTimeKey: StorageKey {
    typealias Value = Date
}
```

- [ ] **Step 2: Instantiate and inject**

In the body of `configure(_:)`, replace the existing `apnsService` and `relayService` instantiation with:

```swift
    // Initialize core services
    let pairingService = PairingService()
    let connectionHub = ConnectionHub()
    let metricsService = MetricsService()

    let apnsEnvString = ProcessInfo.processInfo.environment["APNS_ENVIRONMENT"] ?? "development"
    let apnsEnvironment: APNSEnvironment = apnsEnvString == "production" ? .production : .development

    let apnsService = await APNsService(
        pairingService: pairingService,
        connectionHub: connectionHub,
        environment: apnsEnvironment,
        metricsService: metricsService
    )

    let relayService = RelayService(
        pairingService: pairingService,
        connectionHub: connectionHub,
        apnsService: apnsService,
        metricsService: metricsService
    )

    // Store services in app storage
    app.storage[PairingServiceKey.self] = pairingService
    app.storage[ConnectionHubKey.self] = connectionHub
    app.storage[APNsServiceKey.self] = apnsService
    app.storage[RelayServiceKey.self] = relayService
    app.storage[MetricsServiceKey.self] = metricsService
    app.storage[ProcessStartTimeKey.self] = Date()
```

- [ ] **Step 3: Build to confirm compilation**

```
swift build --product ClaudeSpyExternalServer
```
Expected: build succeeds.

- [ ] **Step 4: Run full test suite**

```
swift test
```
Expected: all existing tests + new tests pass.

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/RelayService.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/APNsService.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/configure.swift
git commit -m "Wire MetricsService through Relay and APNs services"
```

---

### Task 6: `MetricsController` route with bearer-token auth

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Routes/MetricsController.swift`
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Routes/routes.swift`
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/configure.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/MetricsEndpointTests.swift`

- [ ] **Step 1: Write failing endpoint tests**

Create `ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/MetricsEndpointTests.swift`:

```swift
import Testing
import XCTVapor
@testable import ClaudeSpyExternalServerLib

@Suite("Metrics endpoint", .serialized)
struct MetricsEndpointTests {
    private static let token = "test-metrics-token"

    private func makeApp() async throws -> Application {
        setenv("METRICS_TOKEN", Self.token, 1)
        let app = try await Application.make(.testing)
        try await configure(app)
        return app
    }

    @Test("GET /metrics returns 401 without bearer token")
    func unauthorizedNoHeader() async throws {
        let app = try await makeApp()
        defer { Task { try? await app.asyncShutdown() } }

        try await app.test(.GET, "metrics") { res in
            #expect(res.status == .unauthorized)
        }
    }

    @Test("GET /metrics returns 401 with wrong token")
    func unauthorizedWrongToken() async throws {
        let app = try await makeApp()
        defer { Task { try? await app.asyncShutdown() } }

        try await app.test(.GET, "metrics", headers: ["Authorization": "Bearer wrong"]) { res in
            #expect(res.status == .unauthorized)
        }
    }

    @Test("GET /metrics returns 200 + Prometheus body with valid token")
    func authorizedReturnsBody() async throws {
        let app = try await makeApp()
        defer { Task { try? await app.asyncShutdown() } }

        try await app.test(
            .GET,
            "metrics",
            headers: ["Authorization": "Bearer \(Self.token)"]
        ) { res in
            #expect(res.status == .ok)
            #expect(res.headers.contentType?.description.contains("text/plain") == true)
            let body = res.body.string
            #expect(body.contains("claudespy_active_pairs 0"))
            #expect(body.contains("claudespy_ws_connections{device_type=\"host\"} 0"))
            #expect(body.contains("claudespy_messages_relayed_total 0"))
            #expect(body.contains("claudespy_uptime_seconds"))
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```
swift test --filter MetricsEndpointTests
```
Expected: FAIL — no `/metrics` route registered, currently returns 404.

- [ ] **Step 3: Implement `MetricsController`**

Create `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Routes/MetricsController.swift`:

```swift
import Vapor

/// Build version baked into the binary at compile time.
/// For now, a static string; replace later with git SHA injected via -D flag.
private let buildVersion = "dev"

struct MetricsController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get("metrics", use: handle)
    }

    @Sendable
    private func handle(req: Request) async throws -> Response {
        // Compare bearer token against the one captured at boot.
        let expected = req.application.metricsToken
        guard let header = req.headers.bearerAuthorization?.token,
              !expected.isEmpty,
              header == expected else {
            throw Abort(.unauthorized)
        }

        let metrics = req.application.metricsService
        let pairs = await req.application.pairingService.activePairCount
        let counts = await req.application.connectionHub.connectionCounts()
        let start = req.application.storage[ProcessStartTimeKey.self] ?? Date()
        let uptime = Int(Date().timeIntervalSince(start))

        let snapshot = MetricsSnapshot(
            activePairs: pairs,
            hostsConnected: counts.host,
            viewersConnected: counts.viewer,
            uptimeSeconds: uptime
        )

        let body = await metrics.render(snapshot: snapshot, buildVersion: buildVersion)

        var headers = HTTPHeaders()
        headers.contentType = HTTPMediaType(type: "text", subType: "plain", parameters: ["version": "0.0.4"])
        return Response(status: .ok, headers: headers, body: .init(string: body))
    }
}
```

- [ ] **Step 4: Add `metricsToken` to `Application`**

In `configure.swift`, add a storage key + accessor:

```swift
struct MetricsTokenKey: StorageKey {
    typealias Value = String
}

extension Application {
    var metricsToken: String {
        storage[MetricsTokenKey.self] ?? ""
    }
}
```

In the body of `configure(_:)`, after the existing service wiring, add:

```swift
    let metricsToken = ProcessInfo.processInfo.environment["METRICS_TOKEN"] ?? ""
    if metricsToken.isEmpty {
        app.logger.warning("METRICS_TOKEN not set — /metrics endpoint will reject all requests")
    }
    app.storage[MetricsTokenKey.self] = metricsToken
```

- [ ] **Step 5: Register the controller in `routes.swift`**

Edit `routes.swift`:

```swift
func routes(_ app: Application) throws {
    app.get("health") { _ -> HealthResponse in
        HealthResponse(status: "ok")
    }

    try app.register(collection: MetricsController())

    let api = app.grouped("api")
    try api.register(collection: PairingController())
    try api.register(collection: WebSocketController())
}
```

- [ ] **Step 6: Run tests to verify they pass**

```
swift test --filter MetricsEndpointTests
```
Expected: 3 tests pass.

- [ ] **Step 7: Run full suite**

```
swift test
```
Expected: all green.

- [ ] **Step 8: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Routes/MetricsController.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Routes/routes.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/configure.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/MetricsEndpointTests.swift
git commit -m "Add /metrics endpoint with bearer-token auth"
```

---

### Task 7: Harden docker-compose port binding + document `METRICS_TOKEN`

**Files:**
- Modify: `ClaudeSpyPackage/docker-compose.yml`
- Modify or create: `ClaudeSpyPackage/.env.example`

- [ ] **Step 1: Restrict port binding to loopback**

In `docker-compose.yml`, change:

```yaml
    ports:
      - "8080:8080"
```

to:

```yaml
    ports:
      - "127.0.0.1:8080:8080"
```

This means only the host (and Caddy reverse proxy on the same host) can reach Vapor directly; Alloy on the same host can scrape `localhost:8080/metrics` over the bridge.

- [ ] **Step 2: Add `METRICS_TOKEN` to compose env**

In the `environment:` block of the `relay` service in `docker-compose.yml`, add:

```yaml
      - METRICS_TOKEN=${METRICS_TOKEN:-}
```

- [ ] **Step 3: Document in `.env.example`**

If `ClaudeSpyPackage/.env.example` does not exist, create it with all current env vars documented. If it exists, append:

```bash
# Bearer token required to scrape GET /metrics. Generate with:
#   openssl rand -hex 32
# Must match the token configured in monitoring/agents/config.alloy
METRICS_TOKEN=
```

- [ ] **Step 4: Verify compose still parses**

```bash
cd ClaudeSpyPackage && docker compose config > /dev/null && cd ..
```
Expected: no output, exit 0.

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/docker-compose.yml ClaudeSpyPackage/.env.example
git commit -m "Bind relay port to localhost and add METRICS_TOKEN env"
```

---

## Phase 2 — VM observability agents

### Task 8: `node_exporter` systemd unit

**Files:**
- Create: `ClaudeSpyPackage/monitoring/agents/node_exporter.service`

- [ ] **Step 1: Create the directory and unit**

Create `ClaudeSpyPackage/monitoring/agents/node_exporter.service`:

```ini
[Unit]
Description=Prometheus node_exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter \
  --web.listen-address=127.0.0.1:9100 \
  --collector.disable-defaults \
  --collector.cpu \
  --collector.diskstats \
  --collector.filesystem \
  --collector.loadavg \
  --collector.meminfo \
  --collector.netdev \
  --collector.uname \
  --collector.systemd
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Notes for reviewer: bound to `127.0.0.1` so it's never exposed externally. Defaults disabled then re-enabled per-collector to keep cardinality low.

- [ ] **Step 2: Commit**

```bash
git add ClaudeSpyPackage/monitoring/agents/node_exporter.service
git commit -m "Add node_exporter systemd unit"
```

---

### Task 9: Grafana Alloy systemd unit and config

**Files:**
- Create: `ClaudeSpyPackage/monitoring/agents/alloy.service`
- Create: `ClaudeSpyPackage/monitoring/agents/config.alloy`

- [ ] **Step 1: Write the systemd unit**

Create `ClaudeSpyPackage/monitoring/agents/alloy.service`:

```ini
[Unit]
Description=Grafana Alloy
Wants=network-online.target
After=network-online.target

[Service]
User=alloy
Group=alloy
Type=simple
EnvironmentFile=/etc/alloy/alloy.env
ExecStart=/usr/bin/alloy run /etc/alloy/config.alloy \
  --storage.path=/var/lib/alloy \
  --server.http.listen-addr=127.0.0.1:12345
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 2: Write the Alloy pipeline config**

Create `ClaudeSpyPackage/monitoring/agents/config.alloy`:

```alloy
// Scrape the Vapor relay's /metrics with bearer auth.
prometheus.scrape "relay" {
  targets = [{ __address__ = "127.0.0.1:8080", __metrics_path__ = "/metrics", instance = "relay" }]
  scrape_interval = "30s"

  bearer_token = sys.env("METRICS_TOKEN")
  forward_to = [prometheus.remote_write.grafana_cloud.receiver]

  job_name = "claudespy-relay"
}

// Scrape host metrics from node_exporter.
prometheus.scrape "node" {
  targets = [{ __address__ = "127.0.0.1:9100", instance = "hetzner-1" }]
  scrape_interval = "30s"
  forward_to = [prometheus.remote_write.grafana_cloud.receiver]

  job_name = "node"
}

// Push to Grafana Cloud Prometheus.
prometheus.remote_write "grafana_cloud" {
  endpoint {
    url = sys.env("GRAFANA_PROM_URL")
    basic_auth {
      username = sys.env("GRAFANA_PROM_USER")
      password = sys.env("GRAFANA_PROM_TOKEN")
    }
  }

  external_labels = {
    deployment = "hetzner-prod",
  }
}
```

The `sys.env(...)` calls read variables defined in `/etc/alloy/alloy.env` (managed by `install.sh` next task). All four are mandatory; missing values cause Alloy to refuse to start with a clear error.

- [ ] **Step 3: Commit**

```bash
git add ClaudeSpyPackage/monitoring/agents/alloy.service \
        ClaudeSpyPackage/monitoring/agents/config.alloy
git commit -m "Add Grafana Alloy systemd unit and scrape config"
```

---

### Task 10: Idempotent installer script for both agents

**Files:**
- Create: `ClaudeSpyPackage/monitoring/agents/install.sh`

- [ ] **Step 1: Write the installer**

Create `ClaudeSpyPackage/monitoring/agents/install.sh`:

```bash
#!/usr/bin/env bash
# Install / update node_exporter and Grafana Alloy on the relay VM.
# Idempotent: re-running upgrades and restarts cleanly.
#
# Required env (passed via SSH or sourced):
#   METRICS_TOKEN          - same value as relay's /metrics bearer
#   GRAFANA_PROM_URL       - e.g. https://prometheus-prod-XX-xxx.grafana.net/api/prom/push
#   GRAFANA_PROM_USER      - numeric Grafana Cloud "Hosted Metrics" username
#   GRAFANA_PROM_TOKEN     - access-policy token with metrics:write
set -euo pipefail

NODE_EXPORTER_VERSION=1.8.2
ALLOY_VERSION=1.4.3

require_env() {
  local name=$1
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required env var: $name" >&2
    exit 1
  fi
}

for v in METRICS_TOKEN GRAFANA_PROM_URL GRAFANA_PROM_USER GRAFANA_PROM_TOKEN; do
  require_env "$v"
done

if [[ $EUID -ne 0 ]]; then
  echo "Run as root (or via sudo)." >&2
  exit 1
fi

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

install_node_exporter() {
  if ! id node_exporter &>/dev/null; then
    useradd --no-create-home --shell /usr/sbin/nologin node_exporter
  fi

  local tmp; tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN

  curl -fsSL -o "$tmp/ne.tar.gz" \
    "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
  tar -xzf "$tmp/ne.tar.gz" -C "$tmp"
  install -o root -g root -m 0755 \
    "$tmp/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter" \
    /usr/local/bin/node_exporter

  install -o root -g root -m 0644 \
    "$REPO_DIR/node_exporter.service" /etc/systemd/system/node_exporter.service
}

install_alloy() {
  if ! id alloy &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin alloy
  fi

  if ! command -v alloy &>/dev/null; then
    apt-get update
    apt-get install -y gpg curl
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/grafana.gpg
    echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
      > /etc/apt/sources.list.d/grafana.list
    apt-get update
    apt-get install -y "alloy=${ALLOY_VERSION}*"
  fi

  install -d -o alloy -g alloy -m 0750 /etc/alloy /var/lib/alloy
  install -o root -g alloy -m 0644 "$REPO_DIR/config.alloy" /etc/alloy/config.alloy

  umask 077
  cat > /etc/alloy/alloy.env <<EOF
METRICS_TOKEN=${METRICS_TOKEN}
GRAFANA_PROM_URL=${GRAFANA_PROM_URL}
GRAFANA_PROM_USER=${GRAFANA_PROM_USER}
GRAFANA_PROM_TOKEN=${GRAFANA_PROM_TOKEN}
EOF
  chown root:alloy /etc/alloy/alloy.env
  chmod 0640 /etc/alloy/alloy.env

  install -o root -g root -m 0644 \
    "$REPO_DIR/alloy.service" /etc/systemd/system/alloy.service
}

install_node_exporter
install_alloy

systemctl daemon-reload
systemctl enable --now node_exporter.service
systemctl enable --now alloy.service
systemctl restart node_exporter.service alloy.service

echo "Done. Verify with:"
echo "  systemctl status node_exporter alloy"
echo "  curl -H 'Authorization: Bearer \$METRICS_TOKEN' http://127.0.0.1:8080/metrics | head"
echo "  curl http://127.0.0.1:9100/metrics | head"
```

- [ ] **Step 2: Make it executable and lint**

```bash
chmod +x ClaudeSpyPackage/monitoring/agents/install.sh
shellcheck ClaudeSpyPackage/monitoring/agents/install.sh || true
```

If `shellcheck` is not installed locally, skip the lint — it's a soft check.

- [ ] **Step 3: Commit**

```bash
git add ClaudeSpyPackage/monitoring/agents/install.sh
git commit -m "Add installer script for node_exporter and Alloy"
```

---

## Phase 3 — Grafana Cloud bootstrap (manual, one-time)

> These tasks are not pure code edits. The output is values that flow into later tasks (`config.alloy`, grizzly env). Record each value into a **password manager entry** named "ClaudeSpy Monitoring" before moving on.

### Task 11: Create Grafana Cloud account + stack

- [ ] **Step 1:** Go to <https://grafana.com/auth/sign-up/create-user> and sign up with `gustavo@gustavo.eng.br`. Free tier — no credit card required.

- [ ] **Step 2:** Create a stack. Pick a region close to Hetzner (e.g. `eu-west` if VM is in Falkenstein/Nuremberg). Suggested name: `claudespy`.

- [ ] **Step 3:** From the stack overview, click "Send Metrics" → "Hosted Prometheus metrics". Copy:
  - **Remote Write Endpoint** → save as `GRAFANA_PROM_URL` (looks like `https://prometheus-prod-XX-xxx.grafana.net/api/prom/push`)
  - **Username / Instance ID** (numeric) → save as `GRAFANA_PROM_USER`

- [ ] **Step 4:** Create a Cloud Access Policy:
  - Grafana Cloud Portal → "Access Policies" → "Create access policy"
  - Name: `claudespy-alloy-write`
  - Realms: select your stack
  - Scopes: `metrics:write` only
  - Create token → name `alloy` → no expiry → save token as `GRAFANA_PROM_TOKEN`

- [ ] **Step 5:** Note the stack's Grafana URL (looks like `https://claudespy.grafana.net`) — save as `GRAFANA_URL`.

---

### Task 12: Service account + token for grizzly

- [ ] **Step 1:** Open `${GRAFANA_URL}/org/serviceaccounts`

- [ ] **Step 2:** Name `grizzly`, role `Admin` (needed to manage alert rules + contact points).

- [ ] **Step 3:** Add a token, no expiry → save as `GRAFANA_SA_TOKEN`.

- [ ] **Step 4:** Verify by hitting the API from your laptop:

```bash
curl -fsSL -H "Authorization: Bearer $GRAFANA_SA_TOKEN" \
  "$GRAFANA_URL/api/org" | jq .
```
Expected: JSON describing the org (not 401).

---

### Task 13: Generate `METRICS_TOKEN` and deploy relay with it

- [ ] **Step 1:** Generate the token locally:

```bash
openssl rand -hex 32
```
Save as `METRICS_TOKEN`.

- [ ] **Step 2:** SSH to the Hetzner VM and put it into the relay's `.env`:

```bash
ssh root@$DEPLOY_HOST 'cat >> /opt/claudespy/.env' <<EOF
METRICS_TOKEN=<paste value>
EOF
```

- [ ] **Step 3:** Redeploy the relay so it picks up the new env var (the loopback port binding from Task 7 also lands here):

```bash
cd ClaudeSpyPackage && ./deploy.sh deploy
```

- [ ] **Step 4:** Verify the endpoint from inside the VM:

```bash
ssh root@$DEPLOY_HOST 'curl -fsS -H "Authorization: Bearer $(grep METRICS_TOKEN /opt/claudespy/.env | cut -d= -f2)" http://127.0.0.1:8080/metrics | head -20'
```
Expected: Prometheus text including `claudespy_active_pairs`.

- [ ] **Step 5:** Verify external access is blocked:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' "http://$DEPLOY_HOST:8080/metrics" || true
```
Expected: connection refused / timeout (not `401`). If you get `401`, port 8080 is still publicly bound — re-check `docker-compose.yml`.

---

### Task 14: Run the agents installer on the VM

- [ ] **Step 1:** Copy the agents directory to the VM:

```bash
scp -r ClaudeSpyPackage/monitoring/agents root@$DEPLOY_HOST:/opt/claudespy-monitoring
```

- [ ] **Step 2:** Run the installer with the values gathered in Tasks 11 and 13:

```bash
ssh root@$DEPLOY_HOST \
  METRICS_TOKEN="<from-step-13>" \
  GRAFANA_PROM_URL="<from-task-11>" \
  GRAFANA_PROM_USER="<from-task-11>" \
  GRAFANA_PROM_TOKEN="<from-task-11>" \
  bash /opt/claudespy-monitoring/install.sh
```

- [ ] **Step 3:** Verify both services are running:

```bash
ssh root@$DEPLOY_HOST 'systemctl is-active node_exporter alloy'
```
Expected: `active` × 2.

- [ ] **Step 4:** Tail Alloy logs and confirm successful remote_write:

```bash
ssh root@$DEPLOY_HOST 'journalctl -u alloy -n 50 --no-pager'
```
Expected: no `error` lines for `prometheus.remote_write`. Look for `level=info ... msg="started"`.

- [ ] **Step 5:** In Grafana Cloud UI, open Explore → select your Prometheus datasource → query `claudespy_active_pairs`. Expected: a `0` time series appearing within 1–2 minutes. Also try `node_filesystem_avail_bytes` to confirm node_exporter is flowing.

If no data appears after 5 minutes, run the troubleshooting block in `docs/monitoring.md` (created in Task 22).

---

## Phase 4 — Discord contact point bootstrap

### Task 15: Discord channel + webhook

- [ ] **Step 1:** In Discord, create (or pick) a server you control. Create a private channel `#claudespy-alerts`.

- [ ] **Step 2:** Channel settings → Integrations → Webhooks → "New Webhook" → name `Grafana`. Copy the URL → save as `DISCORD_WEBHOOK_URL`.

- [ ] **Step 3:** Smoke-test the webhook from your laptop:

```bash
curl -fsSL -H 'Content-Type: application/json' -X POST \
  -d '{"content":"hello from the plan"}' "$DISCORD_WEBHOOK_URL"
```
Expected: empty 204 response, message visible in the channel.

---

## Phase 5 — Configuration as code with grizzly

### Task 16: Install grizzly + monitoring directory structure

**Files:**
- Create: `ClaudeSpyPackage/monitoring/grizzly/.env.example`
- Modify: `ClaudeSpyPackage/.gitignore`
- Create: `ClaudeSpyPackage/monitoring/grizzly/Makefile`

- [ ] **Step 1: Install grizzly**

```bash
brew install grafana/grafana/grizzly
grr --version
```
Expected: prints a 0.x version.

- [ ] **Step 2: Create directory structure**

```bash
mkdir -p ClaudeSpyPackage/monitoring/grizzly/{contact-points,notification-policies,alerts,dashboards}
```

- [ ] **Step 3: Write the env example**

Create `ClaudeSpyPackage/monitoring/grizzly/.env.example`:

```bash
# Set these before running `make apply`. Source with `set -a; . .env; set +a`.
export GRAFANA_URL=https://<your-stack>.grafana.net
export GRAFANA_TOKEN=<service-account-token-from-task-12>
export DISCORD_WEBHOOK_URL=<from-task-15>
export ALERT_FOLDER=ClaudeSpy
```

- [ ] **Step 4: Ignore the real `.env`**

Append to `ClaudeSpyPackage/.gitignore`:

```
monitoring/grizzly/.env
```

- [ ] **Step 5: Write the Makefile**

Create `ClaudeSpyPackage/monitoring/grizzly/Makefile`:

```make
.PHONY: apply pull diff lint check-env

GRR := grr -d .

check-env:
	@: $${GRAFANA_URL:?GRAFANA_URL must be set}
	@: $${GRAFANA_TOKEN:?GRAFANA_TOKEN must be set}
	@: $${DISCORD_WEBHOOK_URL:?DISCORD_WEBHOOK_URL must be set}

apply: check-env
	$(GRR) apply

diff: check-env
	$(GRR) diff

pull: check-env
	$(GRR) pull -d ./pulled

lint:
	$(GRR) lint
```

- [ ] **Step 6: Set up your local env**

```bash
cd ClaudeSpyPackage/monitoring/grizzly
cp .env.example .env
# edit .env with real values
set -a; . ./.env; set +a
```

- [ ] **Step 7: Verify grizzly can connect**

```bash
make pull
ls pulled/
```
Expected: at least one `Datasource.*.yaml` (the auto-created Prometheus datasource).

- [ ] **Step 8: Identify the Prometheus datasource UID**

```bash
grep -r "uid:" pulled/Datasource* | head
```

Note the UID for the `grafanacloud-<stack>-prom` datasource — needed in alert rules. Save as `PROM_DS_UID`. Also delete the `pulled/` directory before committing:

```bash
rm -rf pulled
```

- [ ] **Step 9: Commit**

```bash
git add ClaudeSpyPackage/monitoring/grizzly/.env.example \
        ClaudeSpyPackage/monitoring/grizzly/Makefile \
        ClaudeSpyPackage/.gitignore
git commit -m "Add grizzly bootstrap directory and Makefile"
```

---

### Task 17: Discord contact point

**Files:**
- Create: `ClaudeSpyPackage/monitoring/grizzly/contact-points/discord.yaml`

- [ ] **Step 1: Write the contact point**

Create `ClaudeSpyPackage/monitoring/grizzly/contact-points/discord.yaml`:

```yaml
apiVersion: grizzly.grafana.com/v1alpha1
kind: AlertContactPoint
metadata:
  name: discord-alerts
spec:
  name: discord-alerts
  type: discord
  settings:
    url: ${DISCORD_WEBHOOK_URL}
    use_discord_username: false
    avatar_url: ""
  disableResolveMessage: false
```

`grizzly` substitutes `${DISCORD_WEBHOOK_URL}` from the shell at apply time, so the secret never lands in git.

- [ ] **Step 2: Apply just the contact point**

```bash
cd ClaudeSpyPackage/monitoring/grizzly
grr apply -t AlertContactPoint contact-points/discord.yaml
```
Expected: `added` or `updated`.

- [ ] **Step 3: Send a test alert from the UI**

Grafana UI → Alerting → Contact points → `discord-alerts` → "Test". Expected: a test message lands in `#claudespy-alerts`.

- [ ] **Step 4: Commit**

```bash
git add ClaudeSpyPackage/monitoring/grizzly/contact-points/discord.yaml
git commit -m "Define Discord contact point for alerts"
```

---

### Task 18: Notification policy routing all alerts to Discord

**Files:**
- Create: `ClaudeSpyPackage/monitoring/grizzly/notification-policies/main.yaml`

- [ ] **Step 1: Write the policy**

Create `ClaudeSpyPackage/monitoring/grizzly/notification-policies/main.yaml`:

```yaml
apiVersion: grizzly.grafana.com/v1alpha1
kind: AlertNotificationPolicy
metadata:
  name: notification-policy
spec:
  receiver: discord-alerts
  group_by:
    - alertname
    - instance
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
    - receiver: discord-alerts
      matchers:
        - severity = critical
      group_wait: 10s
      repeat_interval: 1h
```

This is the **root** policy: everything goes to Discord. `critical`-severity alerts repeat hourly; everything else every 4h.

- [ ] **Step 2: Apply**

```bash
make apply
```
Expected: notification policy added. Confirm in Grafana UI → Alerting → Notification policies.

- [ ] **Step 3: Commit**

```bash
git add ClaudeSpyPackage/monitoring/grizzly/notification-policies/main.yaml
git commit -m "Route all alerts to Discord contact point"
```

---

### Task 19: Alert rule — relay-down

**Files:**
- Create: `ClaudeSpyPackage/monitoring/grizzly/alerts/relay-down.yaml`

- [ ] **Step 1: Write the rule**

Create `ClaudeSpyPackage/monitoring/grizzly/alerts/relay-down.yaml`. Replace `${PROM_DS_UID}` with the UID captured in Task 16, step 8 — grizzly does **not** substitute non-exported shell vars in YAML, so paste the value directly here, or `export PROM_DS_UID=...` before `make apply`.

```yaml
apiVersion: grizzly.grafana.com/v1alpha1
kind: AlertRuleGroup
metadata:
  folder: ClaudeSpy
  name: relay-availability
spec:
  title: relay-availability
  interval: 1m
  rules:
    - uid: relay-down
      title: Relay down
      condition: B
      data:
        - refId: A
          relativeTimeRange: { from: 300, to: 0 }
          datasourceUid: ${PROM_DS_UID}
          model:
            expr: up{job="claudespy-relay"}
            instant: true
            refId: A
        - refId: B
          datasourceUid: __expr__
          model:
            type: threshold
            refId: B
            expression: A
            conditions:
              - evaluator: { type: lt, params: [1] }
                operator: { type: and }
      noDataState: Alerting
      execErrState: Alerting
      for: 2m
      annotations:
        summary: "Relay scrape failing for 2 minutes"
        description: "Prometheus cannot scrape /metrics on the Hetzner relay. Check `systemctl status alloy` and the Vapor container."
      labels:
        severity: critical
```

> **Why two refs:** Grafana alert rules need a `data` query (A) and a `condition` evaluator (B). `__expr__` is the built-in expression datasource UID (literal).

- [ ] **Step 2: Apply and verify**

```bash
make apply
```

Then in Grafana UI → Alerting → Alert rules, find `Relay down`. Click "Preview" → it should evaluate to `0` (=== healthy).

- [ ] **Step 3: Commit**

```bash
git add ClaudeSpyPackage/monitoring/grizzly/alerts/relay-down.yaml
git commit -m "Add relay-down alert rule"
```

---

### Task 20: Alert rule — high memory

**Files:**
- Create: `ClaudeSpyPackage/monitoring/grizzly/alerts/high-memory.yaml`

- [ ] **Step 1: Write the rule**

Create `ClaudeSpyPackage/monitoring/grizzly/alerts/high-memory.yaml`:

```yaml
apiVersion: grizzly.grafana.com/v1alpha1
kind: AlertRuleGroup
metadata:
  folder: ClaudeSpy
  name: relay-resources
spec:
  title: relay-resources
  interval: 1m
  rules:
    - uid: high-memory
      title: Host memory usage > 85%
      condition: B
      data:
        - refId: A
          relativeTimeRange: { from: 600, to: 0 }
          datasourceUid: ${PROM_DS_UID}
          model:
            expr: |
              100 * (1 - (
                node_memory_MemAvailable_bytes{instance="hetzner-1"}
                /
                node_memory_MemTotal_bytes{instance="hetzner-1"}
              ))
            instant: true
            refId: A
        - refId: B
          datasourceUid: __expr__
          model:
            type: threshold
            refId: B
            expression: A
            conditions:
              - evaluator: { type: gt, params: [85] }
                operator: { type: and }
      noDataState: NoData
      execErrState: Error
      for: 10m
      annotations:
        summary: "Memory usage above 85% for 10 minutes"
        description: "VM memory pressure — investigate via `ssh root@<host> free -m` and `docker stats`."
      labels:
        severity: warning
```

- [ ] **Step 2: Apply**

```bash
make apply
```

- [ ] **Step 3: Commit**

```bash
git add ClaudeSpyPackage/monitoring/grizzly/alerts/high-memory.yaml
git commit -m "Add high-memory alert rule"
```

---

### Task 21: Alert rule — disk full

**Files:**
- Create: `ClaudeSpyPackage/monitoring/grizzly/alerts/disk-full.yaml`

- [ ] **Step 1: Write the rule**

Create `ClaudeSpyPackage/monitoring/grizzly/alerts/disk-full.yaml`:

```yaml
apiVersion: grizzly.grafana.com/v1alpha1
kind: AlertRuleGroup
metadata:
  folder: ClaudeSpy
  name: relay-disk
spec:
  title: relay-disk
  interval: 5m
  rules:
    - uid: disk-full
      title: Root filesystem > 80% used
      condition: B
      data:
        - refId: A
          relativeTimeRange: { from: 600, to: 0 }
          datasourceUid: ${PROM_DS_UID}
          model:
            expr: |
              100 * (1 - (
                node_filesystem_avail_bytes{instance="hetzner-1",mountpoint="/"}
                /
                node_filesystem_size_bytes{instance="hetzner-1",mountpoint="/"}
              ))
            instant: true
            refId: A
        - refId: B
          datasourceUid: __expr__
          model:
            type: threshold
            refId: B
            expression: A
            conditions:
              - evaluator: { type: gt, params: [80] }
                operator: { type: and }
      noDataState: NoData
      execErrState: Error
      for: 30m
      annotations:
        summary: "Root filesystem above 80% used"
        description: "Investigate large files: `du -shx /var/lib/docker/* | sort -h`."
      labels:
        severity: warning
```

- [ ] **Step 2: Apply and commit**

```bash
make apply
git add ClaudeSpyPackage/monitoring/grizzly/alerts/disk-full.yaml
git commit -m "Add disk-full alert rule"
```

---

### Task 22: Alert rule — unusual usage spike

**Files:**
- Create: `ClaudeSpyPackage/monitoring/grizzly/alerts/scrape-failed.yaml`

This catches "high usage" by alerting on a sustained relay rate that's far above baseline. Adjust the threshold after you have a week of data.

- [ ] **Step 1: Write the rule**

Create `ClaudeSpyPackage/monitoring/grizzly/alerts/scrape-failed.yaml`:

```yaml
apiVersion: grizzly.grafana.com/v1alpha1
kind: AlertRuleGroup
metadata:
  folder: ClaudeSpy
  name: relay-usage
spec:
  title: relay-usage
  interval: 1m
  rules:
    - uid: high-relay-rate
      title: Sustained high message rate
      condition: B
      data:
        - refId: A
          relativeTimeRange: { from: 600, to: 0 }
          datasourceUid: ${PROM_DS_UID}
          model:
            # Messages relayed per second over 5m
            expr: rate(claudespy_messages_relayed_total[5m])
            instant: true
            refId: A
        - refId: B
          datasourceUid: __expr__
          model:
            type: threshold
            refId: B
            expression: A
            conditions:
              - evaluator: { type: gt, params: [50] }
                operator: { type: and }
      noDataState: NoData
      execErrState: Error
      for: 15m
      annotations:
        summary: "Relay sustained >50 msg/s for 15 minutes"
        description: "Either legitimate heavy use, a runaway client, or someone abusing the pair. Check `claudespy_active_pairs` and per-pair logs."
      labels:
        severity: warning
```

- [ ] **Step 2: Apply and commit**

```bash
make apply
git add ClaudeSpyPackage/monitoring/grizzly/alerts/scrape-failed.yaml
git commit -m "Add high-relay-rate usage alert"
```

---

### Task 23: Relay overview dashboard

**Files:**
- Create: `ClaudeSpyPackage/monitoring/grizzly/dashboards/relay.json`

- [ ] **Step 1: Build the dashboard in the Grafana UI**

Easier than hand-writing JSON. In Grafana → Dashboards → New → New dashboard:
- Add a **stat panel**: query `claudespy_active_pairs`, title "Active pairs"
- Add a **stat panel**: query `claudespy_ws_connections`, legend `{{device_type}}`, title "Open connections"
- Add a **time-series panel**: query `rate(claudespy_messages_relayed_total[5m])`, title "Messages/sec relayed"
- Add a **time-series panel**: query `rate(claudespy_push_notifications_total[5m])`, title "Push notifications/sec"
- Add a **time-series panel**: query `100 * (1 - node_memory_MemAvailable_bytes{instance="hetzner-1"} / node_memory_MemTotal_bytes{instance="hetzner-1"})`, title "Memory %"
- Add a **time-series panel**: query `100 * (1 - node_filesystem_avail_bytes{instance="hetzner-1",mountpoint="/"} / node_filesystem_size_bytes{instance="hetzner-1",mountpoint="/"})`, title "Disk %"
- Save as `ClaudeSpy / Relay overview` in the `ClaudeSpy` folder.

- [ ] **Step 2: Pull the dashboard JSON via grizzly**

```bash
cd ClaudeSpyPackage/monitoring/grizzly
mkdir -p pulled
grr pull -t Dashboard -d ./pulled
mv ./pulled/dashboards/*.json dashboards/relay.json
rm -rf pulled
```

- [ ] **Step 3: Re-apply to confirm round-trip works**

```bash
make apply
```
Expected: `unchanged` for the dashboard (the pulled JSON matches what's in Grafana).

- [ ] **Step 4: Commit**

```bash
git add ClaudeSpyPackage/monitoring/grizzly/dashboards/relay.json
git commit -m "Add relay overview dashboard"
```

---

### Task 24: End-to-end smoke test

- [ ] **Step 1: Verify all alerts evaluate**

In Grafana → Alerting → Alert rules. All 4 rules should show "Normal" state. None should be "Error" or "NoData" (NoData on the usage alert is OK if there's been no traffic).

- [ ] **Step 2: Trigger relay-down on purpose**

```bash
ssh root@$DEPLOY_HOST 'docker stop claudespy-relay'
```

Wait 3 minutes. Expected: a Discord notification arrives in `#claudespy-alerts`.

- [ ] **Step 3: Restore relay**

```bash
ssh root@$DEPLOY_HOST 'docker start claudespy-relay'
```

Wait 1–2 minutes. Expected: a "resolved" Discord notification arrives.

- [ ] **Step 4: Tag this as a working baseline**

```bash
git checkout main
git merge --no-ff feature/relay-monitoring
git tag -a monitoring-v1 -m "Initial monitoring stack"
```

(Do **not** push the tag without user approval; leave that to the user.)

---

## Phase 6 — Documentation

### Task 25: Update self-hosting guide

**Files:**
- Modify: `docs/self-hosting.md`

- [ ] **Step 1: Add a "Monitoring" section after "API Reference"**

Append to `docs/self-hosting.md`:

```markdown
## Monitoring (Optional)

The relay can push metrics to Grafana Cloud (free tier) for dashboards and Discord alerts. See [docs/monitoring.md](monitoring.md) for the full setup. Quick summary:

1. Set `METRICS_TOKEN` in `.env` (random 32-byte hex).
2. Sign up for Grafana Cloud and grab a metrics-write token.
3. Run `monitoring/agents/install.sh` on the VM (installs `node_exporter` + Grafana Alloy as systemd services).
4. Apply the dashboards/alerts from `monitoring/grizzly/` with `grr apply`.

The `/metrics` endpoint is bound to localhost (via `127.0.0.1:8080:8080`) and gated by a bearer token, so it is not exposed publicly.
```

- [ ] **Step 2: Commit**

```bash
git add docs/self-hosting.md
git commit -m "Reference monitoring stack from self-hosting guide"
```

---

### Task 26: Operator runbook

**Files:**
- Create: `docs/monitoring.md`

- [ ] **Step 1: Write the runbook**

Create `docs/monitoring.md`:

```markdown
# Monitoring Runbook

## Stack
- **Source:** Vapor `/metrics` (token-protected) + `node_exporter` on the VM
- **Collector:** Grafana Alloy (systemd) on the VM, push to Grafana Cloud Prometheus
- **Storage / UI:** Grafana Cloud free tier (`claudespy.grafana.net`)
- **Alerts:** Discord webhook → `#claudespy-alerts`
- **Config-as-code:** `ClaudeSpyPackage/monitoring/grizzly/` applied via `grr apply`

## Daily life

### Re-apply after editing alerts/dashboards
```bash
cd ClaudeSpyPackage/monitoring/grizzly
set -a; . ./.env; set +a
make diff   # see what would change
make apply  # actually apply
```

### Pull current state from Grafana
```bash
make pull
ls pulled/
```
Use this if you've edited something in the UI and want to bring it into git.

## Troubleshooting

### Alloy is not pushing metrics
```bash
ssh root@$DEPLOY_HOST 'systemctl status alloy'
ssh root@$DEPLOY_HOST 'journalctl -u alloy -n 100 --no-pager'
```
Common causes: bad `GRAFANA_PROM_TOKEN`, expired access policy, network egress blocked.

### `/metrics` returns 401 from Alloy
The token in `/etc/alloy/alloy.env` does not match `METRICS_TOKEN` in `/opt/claudespy/.env`. Re-run `install.sh` with the correct value.

### node_exporter shows no data
```bash
ssh root@$DEPLOY_HOST 'curl -fsS http://127.0.0.1:9100/metrics | head'
```
If empty, the binary may have failed — check `journalctl -u node_exporter`.

### Discord notifications stopped arriving
Test the contact point in Grafana UI (Alerting → Contact points → `discord-alerts` → Test). If that fails, regenerate the webhook in Discord and update `DISCORD_WEBHOOK_URL`, then `make apply`.

### A new metric I added isn't visible
1. Confirm the relay actually exposes it: `curl -H "Authorization: Bearer $METRICS_TOKEN" http://127.0.0.1:8080/metrics | grep <name>`
2. Wait one scrape interval (30s).
3. Query in Grafana Explore: `<metric_name>` against the Prometheus datasource.

## Rotating the metrics token

1. Generate a new value: `openssl rand -hex 32`.
2. Update `/opt/claudespy/.env` on the VM and restart relay: `docker compose up -d relay`.
3. Update `/etc/alloy/alloy.env` and restart Alloy: `systemctl restart alloy`.

## Free-tier limits

Grafana Cloud free: 10k active series, 14-day retention, 1 user. Current usage: ~50 series. Plenty of headroom unless we add per-pair labels (which we deliberately avoided).
```

- [ ] **Step 2: Commit**

```bash
git add docs/monitoring.md
git commit -m "Add monitoring runbook"
```

---

## Self-Review Checklist (already applied while writing)

- ✅ Spec coverage: Phase 1 = `/metrics` + counters; Phase 2 = node_exporter + Alloy (covers "B+D"); Phase 3 = Grafana Cloud bootstrap; Phase 4 = Discord; Phase 5 = grizzly config-as-code; Phase 6 = docs.
- ✅ All "high usage" alerting backed by `high-relay-rate` rule (Task 22).
- ✅ Discord (user-chosen) used as the only contact point.
- ✅ Type consistency: `MetricsService.incrementMessagesRelayed`, `connectionCounts()`, `MetricsSnapshot` referenced consistently across Tasks 2, 3, 4, 5, 6.
- ✅ No "TBD"/"add validation"/etc. — every code step has actual code.
- ✅ Frequent commits — 14 commits across the plan.

---

## Open follow-ups (out of scope for this plan)

- Bake `git rev-parse --short HEAD` into `buildVersion` at Docker build time via build arg (currently hard-coded `"dev"`).
- Add a `claudespy_websocket_close_total{reason}` counter once we want to alert on abnormal disconnect rates.
- Move `/metrics` to a separate port if the bearer-token approach proves annoying — see Vapor's secondary HTTP server pattern.
