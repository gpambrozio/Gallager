import ClaudeSpyNetworking
import Testing
@testable import ClaudeSpyServerFeature

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
    if case let .array(methods) = response.result?["methods"] {
        let names = methods.compactMap(\.stringValue)
        #expect(names.contains("system.ping"))
        #expect(names.contains("session.list"))
        #expect(names.contains("session.set_title"))
        #expect(names.contains("input.send_text"))
        #expect(names.contains("pane.capture"))
    } else {
        Issue.record("Expected methods array")
    }
}

// MARK: - session.create + if_missing

@Test
func sessionCreatePassesIfMissingFlagToCallback() async {
    let receivedIfMissing = LockedValue<Bool>(false)
    let router = LiveAPIRequestRouter(
        onSessionCreate: { _, _, _, _, ifMissing in
            await receivedIfMissing.set(ifMissing)
            return LiveAPIRequestRouter.SessionCreateResult(
                info: ["id": .string("foo"), "name": .string("foo")],
                created: false
            )
        }
    )
    let request = JSONRPCRequest(id: "4", method: "session.create", params: [
        "name": .string("foo"),
        "if_missing": .bool(true),
    ])
    let response = await router.handleRequest(request)
    #expect(response.ok == true)
    #expect(response.result?["created"]?.boolValue == false)
    #expect(await receivedIfMissing.get() == true)
}

@Test
func sessionCreateMergesCreatedFlagIntoResponse() async {
    let router = LiveAPIRequestRouter(
        onSessionCreate: { _, _, _, _, _ in
            LiveAPIRequestRouter.SessionCreateResult(
                info: ["id": .string("bar"), "name": .string("bar")],
                created: true
            )
        }
    )
    let request = JSONRPCRequest(id: "5", method: "session.create", params: [
        "name": .string("bar"),
    ])
    let response = await router.handleRequest(request)
    #expect(response.ok == true)
    #expect(response.result?["created"]?.boolValue == true)
    #expect(response.result?["id"]?.stringValue == "bar")
}

@Test
func sessionCreatePassesTitleToCallback() async {
    let receivedTitle = LockedValue<String?>(nil)
    let router = LiveAPIRequestRouter(
        onSessionCreate: { _, _, title, _, _ in
            await receivedTitle.set(title)
            return LiveAPIRequestRouter.SessionCreateResult(
                info: ["id": .string("baz")],
                created: true
            )
        }
    )
    let request = JSONRPCRequest(id: "6", method: "session.create", params: [
        "name": .string("baz"),
        "title": .string("My Session"),
    ])
    _ = await router.handleRequest(request)
    #expect(await receivedTitle.get() == "My Session")
}

// MARK: - session.set_title

@Test
func sessionSetTitleRejectsWhenCallbackMissing() async {
    let router = LiveAPIRequestRouter()
    let request = JSONRPCRequest(id: "7", method: "session.set_title", params: [
        "title": .string("Hello"),
    ])
    let response = await router.handleRequest(request)
    #expect(response.ok == false)
    #expect(response.error?.code == "internal_error")
}

@Test
func sessionSetTitleForwardsParams() async {
    let received = LockedValue<(String?, String?, String?)>((nil, nil, nil))
    let router = LiveAPIRequestRouter(
        onSessionSetTitle: { title, sessionId, paneId in
            await received.set((title, sessionId, paneId))
        }
    )
    let request = JSONRPCRequest(id: "8", method: "session.set_title", params: [
        "title": .string("Workers"),
        "session_id": .string("workers"),
    ])
    let response = await router.handleRequest(request)
    #expect(response.ok == true)
    let (title, sessionId, paneId) = await received.get()
    #expect(title == "Workers")
    #expect(sessionId == "workers")
    #expect(paneId == nil)
}

@Test
func sessionSetTitleAllowsOmittingTitleToClear() async {
    let received = LockedValue<String?>("not-set")
    let router = LiveAPIRequestRouter(
        onSessionSetTitle: { title, _, _ in
            await received.set(title)
        }
    )
    let request = JSONRPCRequest(id: "9", method: "session.set_title", params: [
        "session_id": .string("foo"),
    ])
    let response = await router.handleRequest(request)
    #expect(response.ok == true)
    // The sentinel value "not-set" proves the callback was never invoked if it
    // remains; nil proves it ran with a missing title param.
    #expect(await received.get() == nil)
}

@Test
func sessionSetTitleIgnoresWindowIdParam() async {
    // window_id is no longer accepted at the API level — it should be silently
    // dropped (the call still succeeds, applied at session scope using
    // session_id / pane_id only).
    let receivedSessionId = LockedValue<String?>(nil)
    let router = LiveAPIRequestRouter(
        onSessionSetTitle: { _, sessionId, _ in
            await receivedSessionId.set(sessionId)
        }
    )
    let request = JSONRPCRequest(id: "8b", method: "session.set_title", params: [
        "title": .string("Hi"),
        "session_id": .string("foo"),
        "window_id": .string("foo:0"),
    ])
    let response = await router.handleRequest(request)
    #expect(response.ok == true)
    #expect(await receivedSessionId.get() == "foo")
}

// MARK: - session.set_color

@Test
func sessionSetColorListedInCapabilities() async {
    let router = LiveAPIRequestRouter()
    let request = JSONRPCRequest(id: "set-color-cap", method: "system.capabilities", params: [:])
    let response = await router.handleRequest(request)
    if case let .array(methods) = response.result?["methods"] {
        let names = methods.compactMap(\.stringValue)
        #expect(names.contains("session.set_color"))
    } else {
        Issue.record("Expected methods array")
    }
}

@Test
func sessionSetColorRejectsWhenCallbackMissing() async {
    let router = LiveAPIRequestRouter()
    let request = JSONRPCRequest(id: "set-color-1", method: "session.set_color", params: [
        "color": .string("blue"),
    ])
    let response = await router.handleRequest(request)
    #expect(response.ok == false)
    #expect(response.error?.code == "internal_error")
}

@Test
func sessionSetColorParsesAndForwards() async {
    let received = LockedValue<(SessionColor?, String?, String?)>((nil, nil, nil))
    let router = LiveAPIRequestRouter(
        onSessionSetColor: { color, sessionId, paneId in
            await received.set((color, sessionId, paneId))
        }
    )
    let request = JSONRPCRequest(id: "set-color-2", method: "session.set_color", params: [
        "color": .string("blue"),
        "session_id": .string("workers"),
    ])
    let response = await router.handleRequest(request)
    #expect(response.ok == true)
    let (color, sessionId, _) = await received.get()
    #expect(color == .blue)
    #expect(sessionId == "workers")
}

@Test
func sessionSetColorAllowsOmittingColorToClear() async {
    let received = LockedValue<SessionColor?>(.red)
    let router = LiveAPIRequestRouter(
        onSessionSetColor: { color, _, _ in
            await received.set(color)
        }
    )
    let request = JSONRPCRequest(id: "set-color-3", method: "session.set_color", params: [
        "session_id": .string("foo"),
    ])
    let response = await router.handleRequest(request)
    #expect(response.ok == true)
    #expect(await received.get() == nil)
}

@Test
func sessionSetColorRejectsUnknownValue() async {
    let router = LiveAPIRequestRouter(
        onSessionSetColor: { _, _, _ in }
    )
    let request = JSONRPCRequest(id: "set-color-4", method: "session.set_color", params: [
        "color": .string("chartreuse"),
        "session_id": .string("foo"),
    ])
    let response = await router.handleRequest(request)
    #expect(response.ok == false)
    #expect(response.error?.code == "invalid_params")
}

// MARK: - session.set_emoji

@Test
func sessionSetEmojiListedInCapabilities() async {
    let router = LiveAPIRequestRouter()
    let request = JSONRPCRequest(id: "set-emoji-cap", method: "system.capabilities", params: [:])
    let response = await router.handleRequest(request)
    if case let .array(methods) = response.result?["methods"] {
        let names = methods.compactMap(\.stringValue)
        #expect(names.contains("session.set_emoji"))
    } else {
        Issue.record("Expected methods array")
    }
}

@Test
func sessionSetEmojiRejectsWhenCallbackMissing() async {
    let router = LiveAPIRequestRouter()
    let request = JSONRPCRequest(id: "set-emoji-1", method: "session.set_emoji", params: [
        "emoji": .string("🚀"),
    ])
    let response = await router.handleRequest(request)
    #expect(response.ok == false)
    #expect(response.error?.code == "internal_error")
}

@Test
func sessionSetEmojiForwardsValueAndSession() async {
    let received = LockedValue<(String?, String?, String?)>((nil, nil, nil))
    let router = LiveAPIRequestRouter(
        onSessionSetEmoji: { emoji, sessionId, paneId in
            await received.set((emoji, sessionId, paneId))
        }
    )
    let request = JSONRPCRequest(id: "set-emoji-2", method: "session.set_emoji", params: [
        "emoji": .string("🚀"),
        "session_id": .string("workers"),
    ])
    let response = await router.handleRequest(request)
    #expect(response.ok == true)
    let (emoji, sessionId, _) = await received.get()
    #expect(emoji == "🚀")
    #expect(sessionId == "workers")
}

@Test
func sessionSetEmojiAllowsOmittingEmojiToClear() async {
    let received = LockedValue<String?>("🚀")
    let router = LiveAPIRequestRouter(
        onSessionSetEmoji: { emoji, _, _ in
            await received.set(emoji)
        }
    )
    let request = JSONRPCRequest(id: "set-emoji-3", method: "session.set_emoji", params: [
        "session_id": .string("foo"),
    ])
    let response = await router.handleRequest(request)
    #expect(response.ok == true)
    #expect(await received.get() == nil)
}

@Test
func sessionSetEmojiTreatsEmptyStringAsClear() async {
    let received = LockedValue<String?>("🚀")
    let router = LiveAPIRequestRouter(
        onSessionSetEmoji: { emoji, _, _ in
            await received.set(emoji)
        }
    )
    let request = JSONRPCRequest(id: "set-emoji-4", method: "session.set_emoji", params: [
        "emoji": .string(""),
        "session_id": .string("foo"),
    ])
    let response = await router.handleRequest(request)
    #expect(response.ok == true)
    #expect(await received.get() == nil)
}

// MARK: - window.set_name

@Test
func windowSetNameListedInCapabilities() async {
    let router = LiveAPIRequestRouter()
    let request = JSONRPCRequest(id: "set-name-cap", method: "system.capabilities", params: [:])
    let response = await router.handleRequest(request)
    if case let .array(methods) = response.result?["methods"] {
        let names = methods.compactMap(\.stringValue)
        #expect(names.contains("window.set_name"))
    } else {
        Issue.record("Expected methods array")
    }
}

@Test
func windowSetNameRejectsWhenWindowIdMissing() async {
    let router = LiveAPIRequestRouter(
        onWindowSetName: { _, _ in }
    )
    let request = JSONRPCRequest(id: "set-name-1", method: "window.set_name", params: [
        "name": .string("renamed"),
    ])
    let response = await router.handleRequest(request)
    #expect(response.ok == false)
    #expect(response.error?.code == "invalid_params")
}

@Test
func windowSetNameRejectsWhenNameMissing() async {
    let router = LiveAPIRequestRouter(
        onWindowSetName: { _, _ in }
    )
    let request = JSONRPCRequest(id: "set-name-2", method: "window.set_name", params: [
        "window_id": .string("foo:0"),
    ])
    let response = await router.handleRequest(request)
    #expect(response.ok == false)
    #expect(response.error?.code == "invalid_params")
}

@Test
func windowSetNameForwardsParams() async {
    let received = LockedValue<(String?, String?)>((nil, nil))
    let router = LiveAPIRequestRouter(
        onWindowSetName: { windowId, name in
            await received.set((windowId, name))
        }
    )
    let request = JSONRPCRequest(id: "set-name-3", method: "window.set_name", params: [
        "window_id": .string("foo:1"),
        "name": .string("renamed"),
    ])
    let response = await router.handleRequest(request)
    #expect(response.ok == true)
    let (windowId, name) = await received.get()
    #expect(windowId == "foo:1")
    #expect(name == "renamed")
}

@Test
func sessionCreatePassesColorToCallback() async {
    let receivedColor = LockedValue<SessionColor?>(nil)
    let router = LiveAPIRequestRouter(
        onSessionCreate: { _, _, _, color, _ in
            await receivedColor.set(color)
            return LiveAPIRequestRouter.SessionCreateResult(
                info: ["id": .string("bar")],
                created: true
            )
        }
    )
    let request = JSONRPCRequest(id: "create-color", method: "session.create", params: [
        "name": .string("bar"),
        "color": .string("orange"),
    ])
    _ = await router.handleRequest(request)
    #expect(await receivedColor.get() == .orange)
}

@Test
func sessionCreateRejectsUnknownColor() async {
    let router = LiveAPIRequestRouter(
        onSessionCreate: { _, _, _, _, _ in
            LiveAPIRequestRouter.SessionCreateResult(
                info: ["id": .string("bar")],
                created: true
            )
        }
    )
    let request = JSONRPCRequest(id: "create-bad-color", method: "session.create", params: [
        "name": .string("bar"),
        "color": .string("not-a-color"),
    ])
    let response = await router.handleRequest(request)
    #expect(response.ok == false)
    #expect(response.error?.code == "invalid_params")
}

// MARK: - input.send_text + enter

@Test
func sendTextDefaultsAppendEnterToFalse() async {
    let receivedAppendEnter = LockedValue<Bool?>(nil)
    let router = LiveAPIRequestRouter(
        onSendText: { _, _, appendEnter in
            await receivedAppendEnter.set(appendEnter)
        }
    )
    let request = JSONRPCRequest(id: "10", method: "input.send_text", params: [
        "text": .string("hello"),
    ])
    let response = await router.handleRequest(request)
    #expect(response.ok == true)
    #expect(await receivedAppendEnter.get() == false)
}

@Test
func sendTextForwardsEnterFlag() async {
    let receivedAppendEnter = LockedValue<Bool?>(nil)
    let router = LiveAPIRequestRouter(
        onSendText: { _, _, appendEnter in
            await receivedAppendEnter.set(appendEnter)
        }
    )
    let request = JSONRPCRequest(id: "11", method: "input.send_text", params: [
        "text": .string("make test"),
        "enter": .bool(true),
    ])
    let response = await router.handleRequest(request)
    #expect(response.ok == true)
    #expect(await receivedAppendEnter.get() == true)
}

// MARK: - pane.capture

@Test
func paneCaptureRejectsWhenCallbackMissing() async {
    let router = LiveAPIRequestRouter()
    let request = JSONRPCRequest(id: "12", method: "pane.capture", params: [:])
    let response = await router.handleRequest(request)
    #expect(response.ok == false)
    #expect(response.error?.code == "internal_error")
}

@Test
func paneCaptureReturnsContent() async {
    let received = LockedValue<(String?, Bool)>((nil, false))
    let router = LiveAPIRequestRouter(
        onPaneCapture: { paneId, scrollback in
            await received.set((paneId, scrollback))
            return "line1\nline2\n"
        }
    )
    let request = JSONRPCRequest(id: "13", method: "pane.capture", params: [
        "pane_id": .string("%5"),
        "scrollback": .bool(true),
    ])
    let response = await router.handleRequest(request)
    #expect(response.ok == true)
    #expect(response.result?["content"]?.stringValue == "line1\nline2\n")
    let (paneId, scrollback) = await received.get()
    #expect(paneId == "%5")
    #expect(scrollback == true)
}

// MARK: - window.create

@Test
func windowCreatePassesNameToCallback() async {
    let receivedName = LockedValue<String?>(nil)
    let router = LiveAPIRequestRouter(
        onWindowCreate: { _, _, _, name in
            await receivedName.set(name)
            return ["id": .string("foo:1")]
        }
    )
    let request = JSONRPCRequest(id: "15", method: "window.create", params: [
        "session_id": .string("foo"),
        "name": .string("editor"),
    ])
    let response = await router.handleRequest(request)
    #expect(response.ok == true)
    #expect(await receivedName.get() == "editor")
}

// MARK: - pane.split shell

@Test
func paneSplitPassesShellToCallback() async {
    let receivedShell = LockedValue<String?>(nil)
    let router = LiveAPIRequestRouter(
        onPaneSplit: { _, _, _, shell in
            await receivedShell.set(shell)
            return ["id": .string("%9")]
        }
    )
    let request = JSONRPCRequest(id: "16", method: "pane.split", params: [
        "pane_id": .string("%3"),
        "shell": .string("/bin/fish"),
    ])
    let response = await router.handleRequest(request)
    #expect(response.ok == true)
    #expect(await receivedShell.get() == "/bin/fish")
}

// MARK: - system.set_env

@Test
func setEnvForwardsAllVarsAndUnsets() async {
    let received = LockedValue<(String, [String: String?])>(("", [:]))
    let router = LiveAPIRequestRouter(
        onSetEnvironment: { sessionId, vars in
            await received.set((sessionId, vars))
        }
    )
    let request = JSONRPCRequest(id: "17", method: "system.set_env", params: [
        "session_id": .string("workers"),
        "vars": .object([
            "FOO": .string("bar"),
            "PATH": .string("/opt/bin"),
            "OLD": .null,
        ]),
    ])
    let response = await router.handleRequest(request)
    #expect(response.ok == true)
    let (sessionId, vars) = await received.get()
    #expect(sessionId == "workers")
    #expect(vars["FOO"] == "bar")
    #expect(vars["PATH"] == "/opt/bin")
    // Explicit `.null` becomes a present-but-nil entry so callbacks can `unset`.
    #expect(vars.keys.contains("OLD"))
    #expect(vars["OLD"] == .some(nil))
}

@Test
func setEnvRejectsMissingSessionId() async {
    let router = LiveAPIRequestRouter(
        onSetEnvironment: { _, _ in }
    )
    let request = JSONRPCRequest(id: "18", method: "system.set_env", params: [
        "vars": .object(["FOO": .string("bar")]),
    ])
    let response = await router.handleRequest(request)
    #expect(response.ok == false)
    #expect(response.error?.code == "invalid_params")
}

// MARK: - pane.set_layout

@Test
func paneSetLayoutForwardsTargetAndLayout() async {
    let received = LockedValue<(String, String)>(("", ""))
    let router = LiveAPIRequestRouter(
        onPaneSetLayout: { target, layout in
            await received.set((target, layout))
        }
    )
    let request = JSONRPCRequest(id: "19", method: "pane.set_layout", params: [
        "target": .string("workers:0"),
        "layout": .string("main-vertical"),
    ])
    let response = await router.handleRequest(request)
    #expect(response.ok == true)
    let (target, layout) = await received.get()
    #expect(target == "workers:0")
    #expect(layout == "main-vertical")
}

// MARK: - pane.set_progress

@Test
func paneSetProgressForwardsNumericValueAndPaneId() async {
    let received = LockedValue<(TerminalProgressState?, String?)>((nil, nil))
    let router = LiveAPIRequestRouter(
        onPaneSetProgress: { state, paneId in
            await received.set((state, paneId))
        }
    )
    let request = JSONRPCRequest(id: "p1", method: "pane.set_progress", params: [
        "value": .string("75"),
        "pane_id": .string("%3"),
    ])
    let response = await router.handleRequest(request)
    #expect(response.ok == true)
    let (state, paneId) = await received.get()
    #expect(state == .normal(75))
    #expect(paneId == "%3")
}

@Test
func paneSetProgressForwardsWarningAndError() async {
    let received = LockedValue<TerminalProgressState?>(nil)
    let router = LiveAPIRequestRouter(
        onPaneSetProgress: { state, _ in
            await received.set(state)
        }
    )

    let warningResponse = await router.handleRequest(JSONRPCRequest(
        id: "p2",
        method: "pane.set_progress",
        params: ["value": .string("warning")]
    ))
    #expect(warningResponse.ok == true)
    #expect(await received.get() == .warning)

    let errorResponse = await router.handleRequest(JSONRPCRequest(
        id: "p3",
        method: "pane.set_progress",
        params: ["value": .string("error")]
    ))
    #expect(errorResponse.ok == true)
    #expect(await received.get() == .error)
}

@Test
func paneSetProgressForwardsIndeterminate() async {
    // Indeterminate is the same state OSC 9;4;3 produces — an animated
    // scanner with no specific percentage. Mirrors the named-state flow
    // alongside `warning` and `error`.
    let received = LockedValue<TerminalProgressState?>(nil)
    let router = LiveAPIRequestRouter(
        onPaneSetProgress: { state, _ in
            await received.set(state)
        }
    )
    let response = await router.handleRequest(JSONRPCRequest(
        id: "p-indet",
        method: "pane.set_progress",
        params: ["value": .string("indeterminate")]
    ))
    #expect(response.ok == true)
    #expect(await received.get() == .indeterminate)
}

@Test
func paneSetProgressClearsWithSentinels() async {
    // "clear", "none" and the empty string all funnel into `nil`
    // (which the AppCoordinator side translates to `.removed` so that
    // `setPaneProgress` wipes the bar). All three need to behave identically
    // so users don't have to memorise which clear-spelling the CLI accepts.
    for raw in ["clear", "none", ""] {
        let received = LockedValue<TerminalProgressState?>(.normal(50))
        let router = LiveAPIRequestRouter(
            onPaneSetProgress: { state, _ in
                await received.set(state)
            }
        )
        let response = await router.handleRequest(JSONRPCRequest(
            id: "p-clear-\(raw)",
            method: "pane.set_progress",
            params: ["value": .string(raw)]
        ))
        #expect(response.ok == true)
        #expect(await received.get() == nil)
    }
}

@Test
func paneSetProgressAcceptsPercentSuffix() async {
    let received = LockedValue<TerminalProgressState?>(nil)
    let router = LiveAPIRequestRouter(
        onPaneSetProgress: { state, _ in
            await received.set(state)
        }
    )
    let response = await router.handleRequest(JSONRPCRequest(
        id: "p4",
        method: "pane.set_progress",
        params: ["value": .string("42%")]
    ))
    #expect(response.ok == true)
    #expect(await received.get() == .normal(42))
}

@Test
func paneSetProgressRejectsOutOfRangeValues() async {
    let router = LiveAPIRequestRouter(
        onPaneSetProgress: { _, _ in }
    )
    let response = await router.handleRequest(JSONRPCRequest(
        id: "p5",
        method: "pane.set_progress",
        params: ["value": .string("150")]
    ))
    #expect(response.ok == false)
    #expect(response.error?.code == "invalid_params")
}

@Test
func paneSetProgressRejectsUnknownStrings() async {
    let router = LiveAPIRequestRouter(
        onPaneSetProgress: { _, _ in }
    )
    let response = await router.handleRequest(JSONRPCRequest(
        id: "p6",
        method: "pane.set_progress",
        params: ["value": .string("flibbertigibbet")]
    ))
    #expect(response.ok == false)
    #expect(response.error?.code == "invalid_params")
}

@Test
func paneSetProgressRequiresValue() async {
    let router = LiveAPIRequestRouter(
        onPaneSetProgress: { _, _ in }
    )
    let response = await router.handleRequest(JSONRPCRequest(
        id: "p7",
        method: "pane.set_progress",
        params: [:]
    ))
    #expect(response.ok == false)
    #expect(response.error?.code == "invalid_params")
}

// MARK: - layout.apply

@Test
func layoutApplyForwardsParamsAndReturnsResult() async {
    let received = LockedValue<(JSONValue?, Bool, Bool, Bool, Bool, Bool, String?)>(
        (nil, false, false, false, false, false, nil)
    )
    let router = LiveAPIRequestRouter(
        onLayoutApply: { config, rebuild, detach, dryRun, lenient, requireCreate, configPath in
            await received.set((config, rebuild, detach, dryRun, lenient, requireCreate, configPath))
            return [
                "session_name": .string("workers"),
                "created": .bool(true),
                "warnings": .array([]),
                "planned_actions": .array([.string("session.create name=workers")]),
            ]
        }
    )
    let configBody: JSONValue = .object(["session_name": .string("workers")])
    let request = JSONRPCRequest(id: "20", method: "layout.apply", params: [
        "config": configBody,
        "rebuild": .bool(true),
        "dry_run": .bool(true),
        "config_path": .string("/tmp/workers.yaml"),
    ])
    let response = await router.handleRequest(request)
    #expect(response.ok == true)
    #expect(response.result?["session_name"]?.stringValue == "workers")
    #expect(response.result?["created"]?.boolValue == true)
    let (config, rebuild, _, dryRun, _, _, path) = await received.get()
    #expect(config == configBody)
    #expect(rebuild == true)
    #expect(dryRun == true)
    #expect(path == "/tmp/workers.yaml")
}

@Test
func layoutApplyRejectsMissingConfig() async {
    let router = LiveAPIRequestRouter(
        onLayoutApply: { _, _, _, _, _, _, _ in [:] }
    )
    let request = JSONRPCRequest(id: "21", method: "layout.apply", params: [:])
    let response = await router.handleRequest(request)
    #expect(response.ok == false)
    #expect(response.error?.code == "invalid_params")
}

/// Helper actor for capturing values from `@Sendable` callbacks inside tests
/// without crossing isolation boundaries unsafely.
private actor LockedValue<T: Sendable> {
    private var value: T

    init(_ initial: T) {
        self.value = initial
    }

    func get() -> T {
        value
    }

    func set(_ newValue: T) {
        value = newValue
    }
}
