import ClaudeSpyNetworking
import ConcurrencyExtras
import Foundation
import GallagerPluginProtocol
import Testing
@testable import ClaudeSpyPluginRuntime

/// PluginManager exercises a real EchoSidecar subprocess per plugin, so the
/// tests are `.serialized` to keep the runner from spawning a herd of
/// children and to prevent stderr-read timing flake.
@Suite("PluginManager", .serialized)
struct PluginManagerTests {
    // MARK: - Fixtures

    /// Resolve the EchoSidecar binary SPM built for this test bundle. Mirrors
    /// the lookup used by `SidecarSupervisorTests`.
    private func echoSidecarURL() -> URL? {
        let buildDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ClaudeSpyPluginRuntimeTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ClaudeSpyPackage
            .appendingPathComponent(".build")

        let fm = FileManager.default
        guard let configs = try? fm.contentsOfDirectory(atPath: buildDir.path) else {
            return nil
        }
        for config in configs {
            let candidate = buildDir
                .appendingPathComponent(config)
                .appendingPathComponent("EchoSidecar")
            if fm.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Build a tmp directory containing a bundled-plugins layout with a
    /// single "echo" plugin whose manifest points at the EchoSidecar binary
    /// (symlinked into the plugin dir as `sidecar`).
    ///
    /// Returns the `PluginRootLayout`, the gallager root, the bundled
    /// plugins dir, and a cleanup closure the test should invoke.
    private struct Fixture {
        let layout: PluginRootLayout
        let root: URL
        let bundledDir: URL
        let echoPluginDir: URL
        let cleanup: () -> Void
    }

    private func makeFixture(echoURL: URL) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginManager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let bundledDir = root.appendingPathComponent("bundled-plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: bundledDir, withIntermediateDirectories: true)

        // Single bundled plugin: id "echo", manifest references "sidecar"
        // (a symlink to the EchoSidecar binary) and "icon.png" (a tiny
        // 1×1 PNG we generate in place).
        let echoPluginDir = bundledDir.appendingPathComponent("echo", isDirectory: true)
        try FileManager.default.createDirectory(at: echoPluginDir, withIntermediateDirectories: true)

        // Symlink the binary in. Foundation's `Process` follows symlinks
        // on launch so the supervisor can spawn from the plugin dir.
        let sidecarSymlink = echoPluginDir.appendingPathComponent("sidecar")
        try FileManager.default.createSymbolicLink(at: sidecarSymlink, withDestinationURL: echoURL)

        // Minimal 1×1 PNG (red pixel). Just enough for AssetCache to load.
        let pngBytes: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
            0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,
            0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
            0x00, 0x00, 0x03, 0x00, 0x01, 0x5B, 0xCC, 0x18,
            0x89, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
            0x44, 0xAE, 0x42, 0x60, 0x82,
        ]
        try Data(pngBytes).write(
            to: echoPluginDir.appendingPathComponent("icon.png")
        )

        // The on-disk manifest. We hand-write the JSON so it goes through
        // the same `convertFromSnakeCase` decode path as a real bundled
        // plugin.
        let manifestJSON = """
        {
          "schema_version": 1,
          "id": "echo",
          "display_name": "Echo Plugin",
          "short_name": "Echo",
          "version": "1.0.0",
          "publisher": "test",
          "manifest_url": "bundle://echo/plugin.json",
          "bundle_sha256": null,
          "runtime": "sidecar",
          "sidecar": { "executable": "sidecar", "args": [] },
          "capabilities": {
            "pushes_projects": true,
            "translate_event": true,
            "install": false,
            "detect_pane": false,
            "settings_schema": null,
            "requires_rich_detection": false
          },
          "process_names": ["echo"],
          "ui": { "icon": "icon.png", "icon_ios": null }
        }
        """
        try manifestJSON.write(
            to: echoPluginDir.appendingPathComponent("plugin.json"),
            atomically: true,
            encoding: .utf8
        )

        let layout = PluginRootLayout.live(rootOverride: root, bundledOverride: bundledDir)
        return Fixture(
            layout: layout,
            root: root,
            bundledDir: bundledDir,
            echoPluginDir: echoPluginDir,
            cleanup: { try? FileManager.default.removeItem(at: root) }
        )
    }

    // MARK: - Spy sinks

    final class StatusSinkSpy: PluginSessionStatusSink, Sendable {
        let calls = LockIsolated<[String]>([])
        func updateStatus(
            pluginID: String,
            sessionID _: String,
            tmuxPane _: String?,
            projectPath _: String?,
            working _: Bool?,
            attention _: Bool
        ) async {
            calls.withValue { $0.append(pluginID) }
        }
    }

    final class NotificationSinkSpy: PluginNotificationSink, Sendable {
        let titles = LockIsolated<[String]>([])
        func deliverNotification(
            pluginID _: String,
            sessionID _: String?,
            tmuxPane _: String?,
            projectPath _: String?,
            title: String,
            body _: String
        ) async {
            titles.withValue { $0.append(title) }
        }
    }

    final class ResponseSinkSpy: PluginResponseRequestSink, Sendable {
        let deliveries = LockIsolated<[String]>([])
        let dismissals = LockIsolated<[String]>([])
        func deliverRequest(
            pluginID _: String,
            sessionID _: String,
            tmuxPane _: String?,
            projectPath _: String?,
            requestID: String,
            request _: AgentResponseRequest,
            isAutoApprovable _: Bool
        ) async {
            deliveries.withValue { $0.append(requestID) }
        }

        func dismissRequest(
            pluginID _: String,
            sessionID _: String,
            requestID: String
        ) async {
            dismissals.withValue { $0.append(requestID) }
        }
    }

    final class AppActionSinkSpy: PluginAppActionSink, Sendable {
        let actions = LockIsolated<[AppAction]>([])
        func handle(
            pluginID _: String,
            sessionID _: String?,
            tmuxPane _: String?,
            projectPath _: String?,
            action: AppAction
        ) async {
            actions.withValue { $0.append(action) }
        }
    }

    final class AgentDriverSinkSpy: PluginAgentDriverSink, Sendable {
        let sends = LockIsolated<[String]>([])
        func sendText(pluginID _: String, sessionID _: String, text: String) async {
            sends.withValue { $0.append("text:\(text)") }
        }

        func sendKeys(pluginID _: String, sessionID _: String, keys: [PluginTmuxKey]) async {
            sends.withValue { $0.append("keys:\(keys.map(\.rawValue).joined(separator: ","))") }
        }
    }

    final class YoloSpy: YoloModeProvider, Sendable {
        let yoloSessions: LockIsolated<Set<String>>
        init(yoloSessionIDs: Set<String> = []) {
            self.yoloSessions = LockIsolated(yoloSessionIDs)
        }

        func isYolo(forSessionID sessionID: String) async -> Bool {
            yoloSessions.value.contains(sessionID)
        }
    }

    // MARK: - Manager builder

    /// Stand up a `PluginManager` wired to the fixture and the given spies.
    @MainActor
    private func makeManager(
        layout: PluginRootLayout,
        yolo: YoloSpy = YoloSpy()
    ) -> (
        PluginManager,
        StatusSinkSpy,
        NotificationSinkSpy,
        ResponseSinkSpy,
        AppActionSinkSpy,
        AgentDriverSinkSpy
    ) {
        let s = StatusSinkSpy()
        let n = NotificationSinkSpy()
        let r = ResponseSinkSpy()
        let a = AppActionSinkSpy()
        let d = AgentDriverSinkSpy()
        let manager = PluginManager(
            layout: layout,
            statusSink: s,
            notificationSink: n,
            responseRequestSink: r,
            appActionSink: a,
            agentDriverSink: d,
            yoloProvider: yolo,
            appVersion: "test"
        )
        return (manager, s, n, r, a, d)
    }

    /// Wait until `condition` evaluates to true or the deadline expires.
    /// Used to poll for async state — supervisor stderr lines, projects
    /// updates, etc.
    private func waitFor(
        deadline: Duration = .seconds(5),
        _ condition: @MainActor @Sendable @escaping () -> Bool
    ) async -> Bool {
        let totalMs = Int(Double(deadline.components.seconds) * 1_000)
        let stepMs = 50
        let iterations = max(1, totalMs / stepMs)
        for _ in 0..<iterations {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(stepMs))
        }
        return await condition()
    }

    /// Wait for a stderr-recorded line in the plugin's sidecar log. The
    /// EchoSidecar logs every received method as `[echo-rpc] <method>`; this
    /// helper polls the on-disk log file until the requested substring
    /// appears or the deadline lapses.
    private func waitForLogContains(
        substring: String,
        logsDir: URL,
        deadline: Duration = .seconds(5)
    ) async -> Bool {
        let logURL = logsDir.appendingPathComponent("sidecar.log")
        let totalMs = Int(Double(deadline.components.seconds) * 1_000)
        let stepMs = 50
        let iterations = max(1, totalMs / stepMs)
        for _ in 0..<iterations {
            if
                let data = try? Data(contentsOf: logURL),
                let text = String(data: data, encoding: .utf8),
                text.contains(substring) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(stepMs))
        }
        return false
    }

    // MARK: - Tests

    @Test("start() discovers the bundled plugin and spawns its supervisor")
    @MainActor
    func startDiscoversAndSpawns() async throws {
        guard let echoURL = echoSidecarURL() else {
            Issue.record("EchoSidecar binary missing — run `swift build` first")
            return
        }

        let fixture = try makeFixture(echoURL: echoURL)
        defer { fixture.cleanup() }

        let (manager, _, _, _, _, _) = makeManager(layout: fixture.layout)
        try await manager.start()
        defer {
            Task { await manager.stop() }
        }

        // Registry got merged.
        let registry = PluginRegistry(layout: fixture.layout)
        let entries = try await registry.entries()
        #expect(entries.contains { $0.id == "echo" && $0.enabled })

        // Presentation loaded.
        #expect(manager.presentations.count == 1)
        #expect(manager.presentations.first?.id == "echo")
        #expect(manager.presentations.first?.displayName == "Echo Plugin")
        #expect(manager.presentations.first?.shortName == "Echo")
        #expect(manager.presentations.first?.color == AssetCache.defaultColor)
        #expect(manager.presentations.first?.iconPNGData.isEmpty == false)

        // Process name buckets reflect the manifest.
        #expect(manager.processNamesByPlugin == ["echo": ["echo"]])

        // Supervisor's `initialize` should have logged on the EchoSidecar.
        // (Echo writes every RPC method to its stderr, captured in
        // sidecar.log.) Use the layout's logs dir for the echo plugin.
        let logsDir = fixture.layout.logsDir("echo")
        let sawInitialize = await waitForLogContains(
            substring: "[echo-rpc] initialize",
            logsDir: logsDir
        )
        #expect(sawInitialize, "expected initialize RPC in echo sidecar log")
    }

    @Test("refreshProjects fans out to every running sidecar")
    @MainActor
    func refreshProjectsFansOut() async throws {
        guard let echoURL = echoSidecarURL() else {
            Issue.record("EchoSidecar binary missing — run `swift build` first")
            return
        }

        let fixture = try makeFixture(echoURL: echoURL)
        defer { fixture.cleanup() }

        let (manager, _, _, _, _, _) = makeManager(layout: fixture.layout)
        try await manager.start()
        defer { Task { await manager.stop() } }

        await manager.refreshProjects()

        let logsDir = fixture.layout.logsDir("echo")
        let saw = await waitForLogContains(
            substring: "[echo-rpc] refresh_projects",
            logsDir: logsDir
        )
        #expect(saw, "expected refresh_projects RPC in echo sidecar log")
    }

    @Test("set_projects notification updates the manager's project mirror")
    @MainActor
    func setProjectsUpdatesProjects() async throws {
        guard let echoURL = echoSidecarURL() else {
            Issue.record("EchoSidecar binary missing — run `swift build` first")
            return
        }

        let fixture = try makeFixture(echoURL: echoURL)
        defer { fixture.cleanup() }

        let (manager, _, _, _, _, _) = makeManager(layout: fixture.layout)
        try await manager.start()
        defer { Task { await manager.stop() } }

        // Trigger the test-only path: the echo sidecar will emit a
        // `set_projects` notification before responding. We poke it via
        // `translate(rawIngressPayload:...)` — that routes through
        // `translate_event`, but the echo sidecar treats every request the
        // same. To keep the test surface narrow we call the sidecar
        // directly through `translate` with method-rewrite: actually the
        // simplest way is via the supervisor, but the supervisors are
        // private. We round-trip via `commandForLaunch` (which is just a
        // typed RPC); but we need the echo binary to push the notification
        // FIRST. We added the `_test_push_set_projects` carve-out — so
        // dispatch a `commandForLaunch` and the echo will both push the
        // notification AND echo the result. The result-decode will fail
        // (we don't care) but the notification arrives.
        do {
            // Use the public API: settingsSchema indirectly drives a request
            // on the supervisor, but a cleaner path is to call into the
            // supervisor directly via a small re-export. Since we only have
            // public API surface, dispatch a `commandForLaunch` and ignore
            // its decoded result; the echo sidecar gets the method name
            // and pushes the notification side-effect. We swap the method
            // name by issuing a `translate(rawIngressPayload:...)` which
            // uses `translate_event` — too broad. Instead, expose a thin
            // hook on the manager? No — keep it self-contained via the
            // supervisor extension. We use `applySettings` against a
            // method the echo will pattern-match against.
            // Cleanest: bypass via `translate`, which forwards a custom
            // payload through `translate_event`. The echo doesn't recognise
            // the method name — but we want a different method. Take the
            // workaround: invoke through reflection isn't available.
            //
            // Solution: expose a single test-only entry point that calls
            // the sidecar by name. The public test surface adds a small
            // RPC pass-through.
            //
            // Simpler still: we already documented `_test_push_set_projects`
            // in the EchoSidecar — call it via a private test hook on the
            // manager by using `__rpcForTests(...)`. We add this in the
            // manager file as `internal` for testability.
            _ = try await manager.__rpcForTests(
                pluginID: "echo",
                method: "_test_push_set_projects"
            )
        } catch {
            // Decode of the echo result into `JSONValue` may throw — we
            // don't care about the response body, only the side-effect.
        }

        // Wait for the manager's projects mirror to reflect the pushed list.
        let ok = await waitFor { manager.projects(for: "echo").count == 2 }
        #expect(ok, "manager.projects(for: \"echo\") never reached 2 entries")
        let projects = manager.projects(for: "echo")
        #expect(projects.map(\.name) == ["alpha", "beta"])
    }

    @Test("deliverResponse routes the RPC to the right sidecar")
    @MainActor
    func deliverResponseHitsSidecar() async throws {
        guard let echoURL = echoSidecarURL() else {
            Issue.record("EchoSidecar binary missing — run `swift build` first")
            return
        }

        let fixture = try makeFixture(echoURL: echoURL)
        defer { fixture.cleanup() }

        let (manager, _, _, _, _, _) = makeManager(layout: fixture.layout)
        try await manager.start()
        defer { Task { await manager.stop() } }

        let response = AgentResponse.permission(
            PermissionResponse(decision: .allow, appliedSuggestionId: nil)
        )
        await manager.deliverResponse(
            pluginID: "echo",
            sessionID: "S1",
            requestID: "req-1",
            response: response
        )

        let logsDir = fixture.layout.logsDir("echo")
        let saw = await waitForLogContains(
            substring: "[echo-rpc] deliver_response",
            logsDir: logsDir
        )
        #expect(saw, "expected deliver_response RPC in echo sidecar log")
    }

    @Test("disable stops the supervisor and clears its presentation")
    @MainActor
    func disableStopsSupervisor() async throws {
        guard let echoURL = echoSidecarURL() else {
            Issue.record("EchoSidecar binary missing — run `swift build` first")
            return
        }

        let fixture = try makeFixture(echoURL: echoURL)
        defer { fixture.cleanup() }

        let (manager, _, _, _, _, _) = makeManager(layout: fixture.layout)
        try await manager.start()
        defer { Task { await manager.stop() } }

        try await manager.disable(pluginID: "echo")

        #expect(manager.presentations.contains { $0.id == "echo" } == false)
        let registry = PluginRegistry(layout: fixture.layout)
        let entries = try await registry.entries()
        #expect(entries.contains { $0.id == "echo" && $0.enabled == false })
    }

    // MARK: - CLI façade

    @Test("listEntries returns the registry contents")
    @MainActor
    func listEntriesReturnsRegistry() async throws {
        guard let echoURL = echoSidecarURL() else {
            Issue.record("EchoSidecar binary missing — run `swift build` first")
            return
        }

        let fixture = try makeFixture(echoURL: echoURL)
        defer { fixture.cleanup() }

        let (manager, _, _, _, _, _) = makeManager(layout: fixture.layout)
        try await manager.start()
        defer { Task { await manager.stop() } }

        let entries = try await manager.listEntries()
        #expect(entries.contains { $0.id == "echo" && $0.enabled })
    }

    @Test("info returns manifest fields, paths, and the running bit")
    @MainActor
    func infoReturnsManifestAndPaths() async throws {
        guard let echoURL = echoSidecarURL() else {
            Issue.record("EchoSidecar binary missing — run `swift build` first")
            return
        }

        let fixture = try makeFixture(echoURL: echoURL)
        defer { fixture.cleanup() }

        let (manager, _, _, _, _, _) = makeManager(layout: fixture.layout)
        try await manager.start()
        defer { Task { await manager.stop() } }

        let info = try await manager.info(pluginID: "echo")
        #expect(info.entry.id == "echo")
        #expect(info.manifest?.displayName == "Echo Plugin")
        // logFile sits under the per-plugin logs dir.
        #expect(info.logFile.lastPathComponent == "sidecar.log")
        #expect(info.running)
    }

    @Test("checkForUpdates returns an empty list in v1")
    @MainActor
    func checkForUpdatesEmptyInV1() async throws {
        guard let echoURL = echoSidecarURL() else {
            Issue.record("EchoSidecar binary missing — run `swift build` first")
            return
        }

        let fixture = try makeFixture(echoURL: echoURL)
        defer { fixture.cleanup() }

        let (manager, _, _, _, _, _) = makeManager(layout: fixture.layout)
        try await manager.start()
        defer { Task { await manager.stop() } }

        let updates = try await manager.checkForUpdates()
        #expect(updates.isEmpty)
    }

    @Test("tailLogs returns the trailing N lines of sidecar.log")
    @MainActor
    func tailLogsReturnsTrailingLines() async throws {
        guard let echoURL = echoSidecarURL() else {
            Issue.record("EchoSidecar binary missing — run `swift build` first")
            return
        }

        let fixture = try makeFixture(echoURL: echoURL)
        defer { fixture.cleanup() }

        let (manager, _, _, _, _, _) = makeManager(layout: fixture.layout)
        try await manager.start()
        defer { Task { await manager.stop() } }

        // Seed the log file with a deterministic sequence so we can assert
        // a specific tail. SidecarLogFile appends newlines per line.
        let logFile = SidecarLogFile(
            logsDir: fixture.layout.logsDir("echo"),
            pluginID: "echo"
        )
        for i in 1...10 {
            await logFile.append("entry-\(i)")
        }
        await logFile.close()

        // Last 3 lines should be entries 8/9/10. The log already contains
        // sidecar-banner lines from the live supervisor; the test seeds
        // run AFTER those so the suffix is deterministic regardless.
        let tail = try await manager.tailLogs(pluginID: "echo", lines: 3)
        let lines = tail.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines.contains("entry-10"))
    }

    @Test("yolo + auto-approvable permission auto-approves into deliver_response")
    @MainActor
    func yoloAutoApproveFiresDeliverResponse() async throws {
        guard let echoURL = echoSidecarURL() else {
            Issue.record("EchoSidecar binary missing — run `swift build` first")
            return
        }

        let fixture = try makeFixture(echoURL: echoURL)
        defer { fixture.cleanup() }

        let yolo = YoloSpy(yoloSessionIDs: ["S1"])
        let (manager, _, _, r, _, _) = makeManager(layout: fixture.layout, yolo: yolo)
        try await manager.start()
        defer { Task { await manager.stop() } }

        // Build a permission request flagged auto-approvable and feed it
        // through the dispatcher path the same way an `emit_event` would.
        let event = PluginEvent(
            pluginID: "echo",
            sessionID: "S1",
            working: nil,
            attention: false,
            notification: nil,
            responseRequest: .init(
                requestID: "req-yolo",
                request: .permission(PermissionRequest(
                    toolName: "Bash",
                    description: "ls",
                    suggestions: [],
                    isAutoApprovable: true
                ))
            ),
            appActions: []
        )

        // Push the event via the manager's internal dispatch-equivalent
        // test hook. The same hook is `internal` so the test bundle can
        // reach it via `@testable import`.
        await manager.__dispatchEventForTests(event)

        // Response sink should NOT see the request — yolo bypassed iOS.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(r.deliveries.value.isEmpty)

        // The sidecar should have received the `deliver_response` RPC.
        let logsDir = fixture.layout.logsDir("echo")
        let saw = await waitForLogContains(
            substring: "[echo-rpc] deliver_response",
            logsDir: logsDir
        )
        #expect(saw, "expected deliver_response after yolo auto-approve")
    }
}
