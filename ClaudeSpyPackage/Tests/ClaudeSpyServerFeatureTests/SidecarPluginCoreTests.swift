#if os(macOS)
    import ClaudeSpyNetworking
    import Foundation
    import GallagerPluginProtocol
    import Testing
    @testable import ClaudeSpyServerFeature

    // MARK: - MockPluginHost (local mirror; cannot import GallagerPluginProtocolTests)

    /// Records every `PluginHost` callback for assertion.
    actor MockPluginHost: PluginHost {
        private(set) var projectsCalls: [[AgentProject]] = []
        private(set) var emittedEvents: [PluginEvent] = []
        private(set) var sentText: [(sessionID: String, text: String)] = []
        private(set) var sentKeys: [(sessionID: String, keys: [PluginTmuxKey])] = []
        private(set) var logLines: [LogLine] = []

        func setProjects(_ projects: [AgentProject]) async {
            projectsCalls.append(projects)
        }

        func emit(_ event: PluginEvent) async {
            emittedEvents.append(event)
        }

        func sendText(sessionID: String, _ text: String) async {
            sentText.append((sessionID, text))
        }

        func sendKeys(sessionID: String, _ keys: [PluginTmuxKey]) async {
            sentKeys.append((sessionID, keys))
        }

        func log(_ line: LogLine) async {
            logLines.append(line)
        }
    }

    /// A host variant that returns fixed pane IDs from `agentPanes()`.
    actor PanesHost: PluginHost {
        private let panes: [String]

        init(panes: [String]) {
            self.panes = panes
        }

        func setProjects(_: [AgentProject]) async { }
        func emit(_: PluginEvent) async { }
        func sendText(sessionID _: String, _: String) async { }
        func sendKeys(sessionID _: String, _: [PluginTmuxKey]) async { }
        func log(_: LogLine) async { }

        func agentPanes() async -> [String] {
            panes
        }
    }

    // MARK: - MockSidecarProcess

    /// An in-memory peer transport wired to a `SidecarPluginCore`'s transport via
    /// two `Pipe()`s. Simulates the sidecar process for unit tests.
    ///
    /// Wire topology:
    ///   core's appTransport writes  → appToPeer  → peerTransport reads
    ///   peerTransport writes        → peerToApp  → core's appTransport reads
    ///
    /// The core is the delegate of appTransport so it handles inbound notifications
    /// and requests from the peer. The peer's scripted handler answers App→Sidecar
    /// requests (e.g. initialize, translate_event).
    actor MockSidecarProcess {
        private let appToPeer = Pipe()
        private let peerToApp = Pipe()

        /// The peer transport (simulates the sidecar process side).
        private let peerTransport: SidecarTransport
        private let peerDelegate: PeerDelegate

        private static func makeManifest(id: String) -> PluginManifest {
            PluginManifest(
                schemaVersion: 1,
                id: id,
                displayName: id,
                shortName: id,
                version: "1.0.0",
                processNames: [],
                ui: PluginManifest.UI(icon: nil, color: nil),
                runtime: .sidecar,
                sidecar: PluginManifest.Sidecar(executable: "/nonexistent/sidecar")
            )
        }

        private static func makeLayout() -> PluginRootLayout {
            PluginRootLayout(
                pluginRoot: URL(fileURLWithPath: "/tmp"),
                stateDir: URL(fileURLWithPath: "/tmp"),
                logDir: URL(fileURLWithPath: "/tmp"),
                ingressSocketPath: "/tmp/test.sock",
                appVersion: "1.0.0"
            )
        }

        init() {
            self.peerDelegate = PeerDelegate()
            // Peer writes to peerToApp pipe (app reads from it).
            self.peerTransport = SidecarTransport(
                writeHandle: peerToApp.fileHandleForWriting,
                delegate: peerDelegate
            )
        }

        /// Register a scripted handler for App→Sidecar requests arriving at the peer.
        func onRequest(_ handler: @escaping @Sendable (String, JSONValue?) async -> Result<JSONValue, RPCError>) {
            peerDelegate.setHandler(handler)
        }

        /// Push a notification from the peer (Sidecar→App direction).
        func pushNotification(_ method: String, _ params: JSONValue?) async throws {
            try await peerTransport.notify(method, params)
        }

        /// Send a request from the peer side (Sidecar→App), e.g. `agent_panes`.
        func request(_ method: String, _ params: JSONValue?) async throws -> JSONValue {
            try await peerTransport.request(method, params)
        }

        /// Create a `SidecarPluginCore` with the app-side transport injected (no real spawn).
        ///
        /// Creates the core first, then creates the app-side transport with the core as its
        /// delegate — so inbound peer→app notifications and requests reach the core directly.
        func makeCore(manifestID: String) async throws -> SidecarPluginCore {
            try await makeCore(manifest: Self.makeManifest(id: manifestID))
        }

        /// Overload that accepts a fully-specified manifest (used by capability tests).
        func makeCore(manifest: PluginManifest) async throws -> SidecarPluginCore {
            let layout = Self.makeLayout()
            let supervisor = SidecarSupervisor(manifest: manifest, layout: layout)
            let core = SidecarPluginCore(manifest: manifest, layout: layout, supervisor: supervisor)

            // App writes to appToPeer (peer reads from it); app reads from peerToApp (peer writes to it).
            let appTransport = SidecarTransport(
                writeHandle: appToPeer.fileHandleForWriting,
                delegate: core
            )

            // Wire read loops: app reads what peer writes and vice versa.
            let peerStream = byteStream(peerToApp.fileHandleForReading)
            let appStream = byteStream(appToPeer.fileHandleForReading)
            await appTransport.start(reading: peerStream)
            await peerTransport.start(reading: appStream)

            await core.injectTransport(appTransport)
            return core
        }

        /// Convenience overload: build a manifest with custom capabilities (Task-17 tests).
        func makeCore(manifestID: String, capabilities: PluginManifest.Capabilities) async throws -> SidecarPluginCore {
            let manifest = PluginManifest(
                schemaVersion: 1,
                id: manifestID,
                displayName: manifestID,
                shortName: manifestID,
                version: "1.0.0",
                processNames: [],
                ui: PluginManifest.UI(icon: nil, color: nil),
                runtime: .sidecar,
                sidecar: PluginManifest.Sidecar(executable: "/nonexistent/sidecar"),
                capabilities: capabilities
            )
            return try await makeCore(manifest: manifest)
        }

        /// A stub `PluginEnv` with minimal data.
        var env: PluginEnv {
            PluginEnv(
                pluginRoot: URL(fileURLWithPath: "/tmp"),
                stateDir: URL(fileURLWithPath: "/tmp"),
                appVersion: "1.0.0",
                settings: Data("{}".utf8),
                marketplaceSource: URL(fileURLWithPath: "/tmp")
            )
        }

        private func byteStream(_ handle: FileHandle) -> AsyncStream<Data> {
            AsyncStream { continuation in
                handle.readabilityHandler = { h in
                    let d = h.availableData
                    if d.isEmpty { continuation.finish() } else { continuation.yield(d) }
                }
                continuation.onTermination = { _ in handle.readabilityHandler = nil }
            }
        }
    }

    /// Delegate for the peer transport — routes inbound requests through the scripted handler.
    final private class PeerDelegate: SidecarTransportDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var _handler: ((String, JSONValue?) async -> Result<JSONValue, RPCError>)?

        func setHandler(_ h: @escaping @Sendable (String, JSONValue?) async -> Result<JSONValue, RPCError>) {
            lock.withLock { _handler = h }
        }

        func handleNotification(_: String, _: JSONValue?) async { }

        func handleInboundRequest(_ method: String, _ params: JSONValue?) async -> Result<JSONValue, RPCError> {
            let h = lock.withLock { _handler }
            if let h { return await h(method, params) }
            return .success(.object([:]))
        }
    }

    // MARK: - Tests

    @Suite("SidecarPluginCore marshalling")
    struct SidecarPluginCoreTests {
        @Test("handleIngress marshals translate_event and decodes the returned PluginEvent")
        func translateEvent() async throws {
            let mock = MockSidecarProcess()
            // Scripted: answer initialize with empty ok, translate_event with a PluginEvent.
            await mock.onRequest { method, _ in
                if method == SidecarRPC.initialize {
                    return .success(.object([:]))
                }
                #expect(method == SidecarRPC.translateEvent)
                let event = PluginEvent(
                    pluginID: "opencode",
                    sessionID: "s1",
                    state: .doneWorking(summary: nil),
                    tmuxPane: "%4"
                )
                return .success((try? JSONValue(encoding: event)) ?? .object([:]))
            }
            let core = try await mock.makeCore(manifestID: "opencode")
            let host = MockPluginHost()
            try await core.initialize(mock.env, host: host)
            let frame = IngressFrame(
                pluginID: "opencode",
                context: ["TMUX_PANE": "%4"],
                payload: Data("{}".utf8)
            )
            let event = await core.handleIngress(frame)
            #expect(event?.pluginID == "opencode")
            #expect(event?.state?.needsAttention == true)
            #expect(event?.tmuxPane == "%4")
        }

        @Test("an inbound set_projects notification reaches host.setProjects")
        func inboundSetProjects() async throws {
            let mock = MockSidecarProcess()
            let core = try await mock.makeCore(manifestID: "opencode")
            let host = MockPluginHost()
            try await core.initialize(mock.env, host: host)
            // The sidecar pushes set_projects autonomously.
            let projects = [AgentProject(name: "Demo", path: "/demo", pluginID: "opencode")]
            let params = try JSONValue(encoding: ["projects": projects])
            try await mock.pushNotification(HostRPC.setProjects, params)
            try await Task.sleep(for: .milliseconds(200))
            #expect(await host.projectsCalls.first?.first?.name == "Demo")
        }

        @Test("an inbound agent_panes request is answered from host.agentPanes()")
        func inboundAgentPanes() async throws {
            let mock = MockSidecarProcess()
            let core = try await mock.makeCore(manifestID: "opencode")
            let host = PanesHost(panes: ["%7", "%8"])
            try await core.initialize(mock.env, host: host)
            let answer = try await mock.request(HostRPC.agentPanes, nil)
            #expect(answer == .array([.string("%7"), .string("%8")]))
        }
    }
#endif
