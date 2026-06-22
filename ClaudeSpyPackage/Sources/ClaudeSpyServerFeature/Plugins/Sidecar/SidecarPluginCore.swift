#if os(macOS)
    import ClaudeSpyNetworking
    import Foundation
    import GallagerPluginProtocol
    import Logging

    /// Marshals every `PluginCore` method to a JSON-RPC request over the sidecar
    /// transport, and translates inbound notifications/requests into `PluginHost`
    /// callbacks (spec §2 / task 6).
    public actor SidecarPluginCore: PluginCore, SidecarTransportDelegate {
        private let manifest: PluginManifest
        private let layout: PluginRootLayout
        private let supervisor: SidecarSupervisor
        private let logger = Logger(label: "com.claudespy.sidecar.core")

        /// Retained at `initialize`; NEVER marshaled over the wire.
        private var host: (any PluginHost)?
        private var transport: SidecarTransport?

        public init(manifest: PluginManifest, layout: PluginRootLayout, supervisor: SidecarSupervisor) {
            self.manifest = manifest
            self.layout = layout
            self.supervisor = supervisor
        }

        /// Test seam: inject a ready transport so tests skip the real subprocess spawn.
        /// The caller is responsible for having created the transport with this core as its delegate.
        func injectTransport(_ t: SidecarTransport) {
            transport = t
        }

        // MARK: - PluginCore

        public func initialize(_ env: PluginEnv, host: any PluginHost) async throws {
            self.host = host
            if transport == nil {
                transport = try await supervisor.startTransport(delegate: self)
            }
            let wire = try PluginEnvWire(env)
            _ = try await transport!.request(SidecarRPC.initialize, JSONValue(encoding: wire), timeout: .seconds(10))
        }

        public func handleIngress(_ frame: IngressFrame) async -> PluginEvent? {
            guard let transport else { return nil }
            do {
                let wire = IngressFrameWire(frame)
                let result = try await transport.request(SidecarRPC.translateEvent, JSONValue(encoding: wire))
                if case .null = result { return nil }
                return try result.decode(PluginEvent.self)
            } catch {
                logger.debug("translate_event failed: \(error)")
                return nil
            }
        }

        public func deliverResponse(sessionID: String, requestID: String, _ response: AgentResponse) async {
            struct Params: Encodable {
                let sessionID: String
                let requestID: String
                let response: AgentResponse
            }
            _ = try? await transport?.request(
                SidecarRPC.deliverResponse,
                try? JSONValue(encoding: Params(sessionID: sessionID, requestID: requestID, response: response))
            )
        }

        public func refreshProjects() async {
            _ = try? await transport?.request(SidecarRPC.refreshProjects, nil)
        }

        public func commandForLaunch(projectPath: String) async -> LaunchCommand? {
            guard
                let result = try? await transport?.request(
                    SidecarRPC.commandForLaunch,
                    .object(["projectPath": .string(projectPath)])
                ) else { return nil }
            if case .null = result { return nil }
            return try? result.decode(LaunchCommand.self)
        }

        public func install(configRoot: String?) async throws -> InstallResult {
            let result = try await requireTransport().request(SidecarRPC.install, configRootParams(configRoot))
            return try result.decode(InstallResult.self)
        }

        public func uninstall(configRoot: String?) async throws {
            _ = try await requireTransport().request(SidecarRPC.uninstall, configRootParams(configRoot))
        }

        public func installStatus(configRoot: String?) async -> PluginInstallStatus {
            guard
                let result = try? await transport?.request(SidecarRPC.installStatus, configRootParams(configRoot)),
                let status = try? result.decode(PluginInstallStatus.self)
            else { return .agentUnavailable }
            return status
        }

        public func applySettings(_ raw: Data) async -> SettingsResult {
            let settings = (try? JSONDecoder().decode(JSONValue.self, from: raw)) ?? .object([:])
            guard
                let result = try? await transport?.request(SidecarRPC.applySettings, .object(["settings": settings])),
                let settingsResult = try? result.decode(SettingsResult.self)
            else { return .applied }
            return settingsResult
        }

        public func shutdown() async {
            _ = try? await transport?.request(SidecarRPC.shutdown, nil, timeout: .seconds(3))
            await supervisor.stop()
            transport = nil
        }

        // MARK: - SidecarTransportDelegate (inbound notifications and requests)

        public func handleNotification(_ method: String, _ params: JSONValue?) async {
            guard let host else { return }
            switch method {
            case HostRPC.setProjects:
                if
                    let obj = params?.objectValue,
                    let list = try? obj["projects"]?.decode([AgentProject].self) {
                    await host.setProjects(list)
                }
            case HostRPC.emitEvent:
                if let event = try? params?.decode(PluginEvent.self) {
                    await host.emit(event)
                }
            case HostRPC.sendText:
                if
                    let obj = params?.objectValue,
                    let sessionID = obj["sessionID"]?.stringValue,
                    let text = obj["text"]?.stringValue {
                    await host.sendText(sessionID: sessionID, text)
                }
            case HostRPC.sendKeys:
                if
                    let obj = params?.objectValue,
                    let sessionID = obj["sessionID"]?.stringValue,
                    let keys = try? obj["keys"]?.decode([PluginTmuxKey].self) {
                    await host.sendKeys(sessionID: sessionID, keys)
                }
            case HostRPC.log:
                if let line = try? params?.decode(LogLine.self) {
                    await host.log(line)
                }
            default:
                logger.debug("unknown inbound notification: \(method)")
            }
        }

        public func handleInboundRequest(_ method: String, _ params: JSONValue?) async -> Result<JSONValue, RPCError> {
            switch method {
            case HostRPC.agentPanes:
                let panes = await host?.agentPanes() ?? []
                return .success(.array(panes.map { .string($0) }))
            default:
                return .failure(.methodNotFound(method))
            }
        }

        // MARK: - Helpers

        private func requireTransport() throws -> SidecarTransport {
            guard let transport else { throw SupervisorError.notExecutable(manifest.id) }
            return transport
        }

        private func configRootParams(_ root: String?) -> JSONValue {
            .object(["configRoot": root.map { .string($0) } ?? .null])
        }
    }
#endif
