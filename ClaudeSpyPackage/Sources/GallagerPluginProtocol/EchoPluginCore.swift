#if DEBUG
    import ClaudeSpyNetworking
    import Foundation

    /// A deterministic reference `PluginCore` conformer used by the contract tests
    /// (spec §17.2) and the E2E ingress path (spec §17.3). It is **not shipped in
    /// Release** — it exists only in Debug/E2E builds.
    ///
    /// `handleIngress` decodes its frame `payload` as a JSON `EchoDirective` and
    /// returns the `PluginEvent` it describes, stamping `pluginID` and (if absent)
    /// `tmuxPane` from the frame. This lets a test drive exactly which status bits,
    /// notification, and response form appear — without depending on real
    /// host-agent hook semantics.
    ///
    /// `deliverResponse` translates the structured `AgentResponse` into
    /// deterministic `host.sendText` / `host.sendKeys` calls so a round-trip test
    /// can assert the response reached the core AND that the core drove delivery.
    public actor EchoPluginCore: PluginCore {
        public static let pluginID = "echo"

        private var host: (any PluginHost)?

        public init() { }

        public func initialize(_: PluginEnv, host: any PluginHost) async throws {
            self.host = host
        }

        public func handleIngress(_ frame: IngressFrame) async -> PluginEvent? {
            guard let directive = try? JSONDecoder().decode(EchoDirective.self, from: frame.payload) else {
                return nil
            }
            // Test hook: an artificial processing delay lets ordering tests make one
            // frame take longer than the next, so a serialized ingress can be told
            // apart from a racing one.
            if let delayMs = directive.delayMs, delayMs > 0 {
                try? await Task.sleep(for: .milliseconds(delayMs))
            }
            return PluginEvent(
                pluginID: frame.pluginID,
                sessionID: directive.sessionID,
                state: directive.state,
                notification: directive.notification,
                appActions: directive.appActions ?? [],
                tmuxPane: directive.tmuxPane ?? frame.tmuxPane,
                projectPath: directive.projectPath
            )
        }

        public func deliverResponse(sessionID: String, requestID _: String, _ response: AgentResponse) async {
            guard let host else { return }
            switch response {
            case let .prompt(text),
                 let .replyAfterStop(text):
                await host.sendText(sessionID: sessionID, text)
            case let .permission(decision, _):
                switch decision {
                case .allow: await host.sendKeys(sessionID: sessionID, [.text("1")])
                case .deny: await host.sendKeys(sessionID: sessionID, [.escape])
                case let .denyWithFeedback(text): await host.sendText(sessionID: sessionID, text)
                }
            case let .askUserQuestion(answers):
                await host.sendText(sessionID: sessionID, answers.map(\.questionID).joined(separator: ","))
            case let .approvePlan(decision, editedPlan):
                switch decision {
                case .approve:
                    if let editedPlan {
                        await host.sendText(sessionID: sessionID, editedPlan)
                    } else {
                        await host.sendKeys(sessionID: sessionID, [.text("3")])
                    }
                case .reject:
                    await host.sendKeys(sessionID: sessionID, [.escape])
                }
            }
            await host.log(LogLine(level: .info, message: "echo deliverResponse \(sessionID)"))
        }

        public func refreshProjects() async {
            await host?.setProjects([
                AgentProject(name: "echo-project", path: "/tmp/echo-project", pluginID: Self.pluginID),
            ])
        }

        public func commandForLaunch(projectPath _: String) async -> LaunchCommand? {
            nil
        }

        public func install(configRoot _: String?) async throws -> InstallResult {
            .alreadyInstalled
        }

        public func uninstall(configRoot _: String?) async throws { }

        public func installStatus(configRoot _: String?) async -> PluginInstallStatus {
            .installed(version: "echo")
        }

        public func applySettings(_: Data) async -> SettingsResult {
            .applied
        }

        public func shutdown() async {
            host = nil
        }
    }

#endif
