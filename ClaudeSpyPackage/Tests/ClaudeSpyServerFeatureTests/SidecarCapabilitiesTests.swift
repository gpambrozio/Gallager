#if os(macOS)
    import ClaudeSpyNetworking
    import Foundation
    import GallagerPluginProtocol
    import Testing
    @testable import ClaudeSpyServerFeature

    // MARK: - Tests

    @Suite("SidecarCapabilities — rich_pane_detection and modal_prompts")
    struct SidecarCapabilitiesTests {
        // MARK: - rich_pane_detection: capability enabled

        @Test("detectPane calls detect_pane when richPaneDetection is true and returns SidecarPaneMatch")
        func detectPane_capabilityEnabled_callsSidecarAndDecodesMatch() async throws {
            let mock = MockSidecarProcess()
            let capturedMethod = ActorBox<String?>(nil)
            await mock.onRequest { method, _ in
                if method == SidecarRPC.initialize { return .success(.object([:])) }
                await capturedMethod.set(method)
                let match = SidecarPaneMatch(matches: true, projectPath: "/my/project", sessionID: "s1")
                return .success(try! JSONValue(encoding: match))
            }

            let core = try await mock.makeCore(
                manifestID: "rich-plugin",
                capabilities: PluginManifest.Capabilities(richPaneDetection: true, modalPrompts: false)
            )
            let host = MockPluginHost()
            try await core.initialize(mock.env, host: host)

            let info = SidecarPaneInfo(paneID: "%3", processNames: ["node"], command: "node index.js", cwd: "/my/project")
            let result = await core.detectPane(info)

            #expect(await capturedMethod.value == SidecarRPC.detectPane)
            #expect(result?.matches == true)
            #expect(result?.projectPath == "/my/project")
            #expect(result?.sessionID == "s1")
        }

        // MARK: - rich_pane_detection: capability disabled

        @Test("detectPane returns nil without calling sidecar when richPaneDetection is false")
        func detectPane_capabilityDisabled_returnsNilWithoutCallingRPC() async throws {
            let mock = MockSidecarProcess()
            let detectPaneCalled = ActorBox<Bool>(false)
            await mock.onRequest { method, _ in
                if method == SidecarRPC.initialize { return .success(.object([:])) }
                if method == SidecarRPC.detectPane { await detectPaneCalled.set(true) }
                return .success(.object([:]))
            }

            let core = try await mock.makeCore(
                manifestID: "basic-plugin",
                capabilities: PluginManifest.Capabilities(richPaneDetection: false, modalPrompts: false)
            )
            let host = MockPluginHost()
            try await core.initialize(mock.env, host: host)

            let info = SidecarPaneInfo(paneID: "%1", processNames: ["claude"])
            let result = await core.detectPane(info)

            #expect(result == nil)
            #expect(await detectPaneCalled.value == false)
        }

        // MARK: - rich_pane_detection: MethodNotFound degrades gracefully

        @Test("detectPane returns nil when sidecar answers detect_pane with MethodNotFound")
        func detectPane_methodNotFound_degradesGracefully() async throws {
            let mock = MockSidecarProcess()
            await mock.onRequest { method, _ in
                if method == SidecarRPC.initialize { return .success(.object([:])) }
                if method == SidecarRPC.detectPane {
                    return .failure(.methodNotFound(method))
                }
                return .success(.object([:]))
            }

            let core = try await mock.makeCore(
                manifestID: "partial-plugin",
                capabilities: PluginManifest.Capabilities(richPaneDetection: true, modalPrompts: false)
            )
            let host = MockPluginHost()
            try await core.initialize(mock.env, host: host)

            let info = SidecarPaneInfo(paneID: "%2", processNames: ["codex"])
            let result = await core.detectPane(info)

            // Must degrade to nil — caller falls back to process_names
            #expect(result == nil)
        }

        // MARK: - modal_prompts: capability disabled — notification ignored

        @Test("prompt_user notification is ignored when modalPrompts is false")
        func promptUser_capabilityDisabled_callbackNotInvoked() async throws {
            let mock = MockSidecarProcess()
            await mock.onRequest { method, _ in
                if method == SidecarRPC.initialize { return .success(.object([:])) }
                return .success(.object([:]))
            }

            let core = try await mock.makeCore(
                manifestID: "no-modal-plugin",
                capabilities: PluginManifest.Capabilities(richPaneDetection: false, modalPrompts: false)
            )
            let host = MockPluginHost()
            try await core.initialize(mock.env, host: host)

            let callbackInvoked = ActorBox<Bool>(false)
            await core.setOnPromptUser { _ in await callbackInvoked.set(true) }

            let req = PromptUserRequest(title: "Hello?", message: "Do something")
            let params = try JSONValue(encoding: req)
            try await mock.pushNotification(HostRPC.promptUser, params)
            try await Task.sleep(for: .milliseconds(200))

            #expect(await callbackInvoked.value == false)
        }

        // MARK: - modal_prompts: capability enabled — callback invoked

        @Test("prompt_user notification triggers onPromptUser callback when modalPrompts is true")
        func promptUser_capabilityEnabled_callbackInvoked() async throws {
            let mock = MockSidecarProcess()
            await mock.onRequest { method, _ in
                if method == SidecarRPC.initialize { return .success(.object([:])) }
                return .success(.object([:]))
            }

            let core = try await mock.makeCore(
                manifestID: "modal-plugin",
                capabilities: PluginManifest.Capabilities(richPaneDetection: false, modalPrompts: true)
            )
            let host = MockPluginHost()
            try await core.initialize(mock.env, host: host)

            let received = ActorBox<PromptUserRequest?>(nil)
            await core.setOnPromptUser { req in await received.set(req) }

            let req = PromptUserRequest(title: "Confirm deploy?", message: "Are you sure?")
            let params = try JSONValue(encoding: req)
            try await mock.pushNotification(HostRPC.promptUser, params)
            try await Task.sleep(for: .milliseconds(200))

            let got = await received.value
            #expect(got?.title == "Confirm deploy?")
            #expect(got?.message == "Are you sure?")
        }
    }

    // MARK: - Helpers

    /// Actor-isolated box for capturing values from @Sendable closures in tests.
    actor ActorBox<T: Sendable> {
        private(set) var value: T
        init(_ initial: T) {
            self.value = initial
        }

        func set(_ v: T) {
            value = v
        }
    }
#endif
