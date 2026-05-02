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
        onSessionCreate: { _, _, _, ifMissing in
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
        onSessionCreate: { _, _, _, _ in
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
        onSessionCreate: { _, _, title, _ in
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
func sessionSetTitleForwardsParamsAndReturnsScope() async {
    let received = LockedValue<(String?, String?, String?, String?)>((nil, nil, nil, nil))
    let router = LiveAPIRequestRouter(
        onSessionSetTitle: { title, sessionId, windowId, paneId in
            await received.set((title, sessionId, windowId, paneId))
            return "session"
        }
    )
    let request = JSONRPCRequest(id: "8", method: "session.set_title", params: [
        "title": .string("Workers"),
        "session_id": .string("workers"),
    ])
    let response = await router.handleRequest(request)
    #expect(response.ok == true)
    #expect(response.result?["scope"]?.stringValue == "session")
    let (title, sessionId, windowId, paneId) = await received.get()
    #expect(title == "Workers")
    #expect(sessionId == "workers")
    #expect(windowId == nil)
    #expect(paneId == nil)
}

@Test
func sessionSetTitleAllowsOmittingTitleToClear() async {
    let received = LockedValue<String?>("not-set")
    let router = LiveAPIRequestRouter(
        onSessionSetTitle: { title, _, _, _ in
            await received.set(title)
            return "session"
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

// MARK: - window.create title

@Test
func windowCreatePassesTitleToCallback() async {
    let receivedTitle = LockedValue<String?>(nil)
    let router = LiveAPIRequestRouter(
        onWindowCreate: { _, _, _, title in
            await receivedTitle.set(title)
            return ["id": .string("foo:1")]
        }
    )
    let request = JSONRPCRequest(id: "14", method: "window.create", params: [
        "session_id": .string("foo"),
        "title": .string("Builds"),
    ])
    let response = await router.handleRequest(request)
    #expect(response.ok == true)
    #expect(await receivedTitle.get() == "Builds")
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
