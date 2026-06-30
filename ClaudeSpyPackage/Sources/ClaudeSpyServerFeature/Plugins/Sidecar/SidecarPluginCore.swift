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
        /// The env passed at `initialize`, retained so a post-crash restart can
        /// re-handshake the fresh child with the same environment.
        private var lastEnv: PluginEnv?

        // MARK: - Optional-capability callbacks

        /// Called when the sidecar sends a `prompt_user` notification AND
        /// `manifest.capabilities.modalPrompts == true`. The coordinator sets this
        /// to surface an actual Mac modal; `nil`-safe (ignored when unset).
        public var onPromptUser: (@Sendable (PromptUserRequest) async -> Void)?

        /// Set the `onPromptUser` callback from outside the actor's isolation domain.
        public func setOnPromptUser(_ handler: (@Sendable (PromptUserRequest) async -> Void)?) {
            onPromptUser = handler
        }

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
            lastEnv = env
            // Refresh the cached transport whenever the supervisor restarts the
            // child after a crash — otherwise post-restart RPCs marshal over the
            // dead pipe and silently fail (translate_event → nil).
            await supervisor.setOnRestart { [weak self] newTransport in
                await self?.adoptTransport(newTransport)
            }
            if transport == nil {
                transport = try await supervisor.startTransport(delegate: self)
            }
            let wire = try PluginEnvWire(env)
            _ = try await requireTransport().request(SidecarRPC.initialize, JSONValue(encoding: wire), timeout: .seconds(10))
        }

        /// Replace the cached transport after a supervisor restart and re-send
        /// `initialize` so the fresh child has its env/handshake before any
        /// subsequent `translate_event` arrives. The retained `host` is reused
        /// as-is (it never crosses the wire), so only the env handshake replays.
        private func adoptTransport(_ t: SidecarTransport) async {
            transport = t
            guard
                let env = lastEnv,
                let wire = try? PluginEnvWire(env),
                let payload = try? JSONValue(encoding: wire) else {
                logger.warning("adoptTransport: could not encode env to re-initialize sidecar '\(manifest.id)'")
                return
            }
            do {
                _ = try await t.request(SidecarRPC.initialize, payload, timeout: .seconds(10))
            } catch {
                logger.warning("adoptTransport: re-initialize RPC failed for '\(manifest.id)': \(error)")
            }
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
            let params: JSONValue
            do {
                params = try JSONValue(encoding: Params(sessionID: sessionID, requestID: requestID, response: response))
            } catch {
                // Don't ship a malformed `deliver_response` with nil params and
                // silently drop the user's reply — surface the encode failure.
                logger.error("deliverResponse: failed to encode params for session \(sessionID): \(error) — dropping response")
                return
            }
            _ = try? await transport?.request(SidecarRPC.deliverResponse, params)
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
            case HostRPC.promptUser:
                // Optional capability: modal_prompts. Gate on manifest before decoding.
                guard manifest.capabilities.modalPrompts else {
                    logger.debug("prompt_user ignored: modal_prompts not declared in manifest")
                    return
                }
                if let req = try? params?.decode(PromptUserRequest.self) {
                    await onPromptUser?(req)
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

        // MARK: - Optional capability: rich_pane_detection (spec §Task-17)

        /// Ask the sidecar whether `paneInfo` belongs to its agent.
        ///
        /// Returns `nil` when:
        /// - the manifest does not declare `rich_pane_detection`
        /// - the sidecar answered with a `MethodNotFound` error (not implemented)
        /// - any other transport / decode error
        ///
        /// Callers that receive `nil` MUST fall back to the standard `process_names`
        /// detection path — the `PluginCore` protocol and v1 contract are untouched.
        public func detectPane(_ paneInfo: SidecarPaneInfo) async -> SidecarPaneMatch? {
            guard manifest.capabilities.richPaneDetection else { return nil }
            guard let transport else { return nil }
            do {
                let params = try JSONValue(encoding: paneInfo)
                let result = try await transport.request(SidecarRPC.detectPane, params)
                return try result.decode(SidecarPaneMatch.self)
            } catch {
                logger.debug("detect_pane failed (degrading to nil): \(error)")
                return nil
            }
        }

        // MARK: - Arbitrary sidecar RPC passthrough (spec §10 / Task 16)

        /// Forward an arbitrary `method` string over the sidecar transport.
        /// Used by `PluginRegistry.callCore`'s `default:` path so operator-defined
        /// sidecar methods are reachable via `gallager plugin call`.
        public func callRPC(_ method: String, params: JSONValue?) async throws -> JSONValue {
            let t = try requireTransport()
            return try await t.request(method, params)
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
