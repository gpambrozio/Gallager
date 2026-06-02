import ClaudeSpyNetworking
import Testing
@testable import ClaudeSpyServerFeature

// Router-level tests for the `plugin.*` JSON-RPC methods (spec §14). These
// inject stub `onPlugin*` callbacks and assert the JSON shapes + error mapping,
// mirroring the style of APIRequestRouterTests.

// MARK: - capabilities advertise the plugin verbs

@Test
func pluginMethodsListedInCapabilities() async {
    let router = LiveAPIRequestRouter()
    let request = JSONRPCRequest(id: "plg-cap", method: "system.capabilities", params: [:])
    let response = await router.handleRequest(request)
    if case let .array(methods) = response.result?["methods"] {
        let names = methods.compactMap(\.stringValue)
        #expect(names.contains("plugin.list"))
        #expect(names.contains("plugin.info"))
        #expect(names.contains("plugin.enable"))
        #expect(names.contains("plugin.disable"))
        #expect(names.contains("plugin.logs"))
        #expect(names.contains("plugin.call"))
    } else {
        Issue.record("Expected methods array")
    }
}

// MARK: - plugin.list

@Test
func pluginListReturnsEntries() async {
    let router = LiveAPIRequestRouter(
        onPluginList: {
            [
                ["id": .string("claude-code"), "version": .string("1.0.0"), "enabled": .bool(true), "source": .string("bundled")],
                ["id": .string("codex"), "version": .string("0.9.0"), "enabled": .bool(false), "source": .string("bundled")],
            ]
        }
    )
    let response = await router.handleRequest(
        JSONRPCRequest(id: "plg-list", method: "plugin.list", params: [:])
    )
    #expect(response.ok == true)
    guard case let .array(plugins) = response.result?["plugins"] else {
        Issue.record("Expected plugins array")
        return
    }
    #expect(plugins.count == 2)
    guard case let .object(first) = plugins[0] else {
        Issue.record("Expected object entry")
        return
    }
    #expect(first["id"]?.stringValue == "claude-code")
    #expect(first["enabled"]?.boolValue == true)
    #expect(first["source"]?.stringValue == "bundled")
}

@Test
func pluginListEmptyWhenNoCallback() async {
    let router = LiveAPIRequestRouter()
    let response = await router.handleRequest(
        JSONRPCRequest(id: "plg-list-empty", method: "plugin.list", params: [:])
    )
    #expect(response.ok == true)
    if case let .array(plugins) = response.result?["plugins"] {
        #expect(plugins.isEmpty)
    } else {
        Issue.record("Expected plugins array")
    }
}

// MARK: - plugin.info

@Test
func pluginInfoReturnsEnvelope() async {
    let receivedId = LockedValue<String?>(nil)
    let router = LiveAPIRequestRouter(
        onPluginInfo: { id in
            await receivedId.set(id)
            return [
                "id": .string(id),
                "version": .string("1.0.0"),
                "enabled": .bool(true),
                "failedInit": .null,
                "source": .string("bundled"),
                "logPath": .string("/tmp/x/logs/sidecar.log"),
                "stateDirBytes": .int(2_048),
            ]
        }
    )
    let response = await router.handleRequest(
        JSONRPCRequest(id: "plg-info", method: "plugin.info", params: ["id": .string("claude-code")])
    )
    #expect(response.ok == true)
    #expect(response.result?["version"]?.stringValue == "1.0.0")
    #expect(response.result?["stateDirBytes"]?.intValue == 2_048)
    #expect(await receivedId.get() == "claude-code")
}

@Test
func pluginInfoUnknownIdReturnsNotFound() async {
    let router = LiveAPIRequestRouter(
        onPluginInfo: { _ in nil }
    )
    let response = await router.handleRequest(
        JSONRPCRequest(id: "plg-info-404", method: "plugin.info", params: ["id": .string("nope")])
    )
    #expect(response.ok == false)
    #expect(response.error?.code == "not_found")
}

@Test
func pluginInfoRequiresId() async {
    let router = LiveAPIRequestRouter(
        onPluginInfo: { _ in [:] }
    )
    let response = await router.handleRequest(
        JSONRPCRequest(id: "plg-info-noid", method: "plugin.info", params: [:])
    )
    #expect(response.ok == false)
    #expect(response.error?.code == "invalid_params")
}

@Test
func pluginInfoRejectsWhenCallbackMissing() async {
    let router = LiveAPIRequestRouter()
    let response = await router.handleRequest(
        JSONRPCRequest(id: "plg-info-nocb", method: "plugin.info", params: ["id": .string("claude-code")])
    )
    #expect(response.ok == false)
    #expect(response.error?.code == "internal_error")
}

// MARK: - plugin.enable / plugin.disable

@Test
func pluginEnableReturnsEnabledState() async {
    let receivedId = LockedValue<String?>(nil)
    let router = LiveAPIRequestRouter(
        onPluginEnable: { id in
            await receivedId.set(id)
            return ["id": .string(id), "enabled": .bool(true)]
        }
    )
    let response = await router.handleRequest(
        JSONRPCRequest(id: "plg-enable", method: "plugin.enable", params: ["id": .string("codex")])
    )
    #expect(response.ok == true)
    #expect(response.result?["id"]?.stringValue == "codex")
    #expect(response.result?["enabled"]?.boolValue == true)
    #expect(await receivedId.get() == "codex")
}

@Test
func pluginEnableUnknownIdReturnsNotFound() async {
    let router = LiveAPIRequestRouter(
        onPluginEnable: { _ in nil }
    )
    let response = await router.handleRequest(
        JSONRPCRequest(id: "plg-enable-404", method: "plugin.enable", params: ["id": .string("nope")])
    )
    #expect(response.ok == false)
    #expect(response.error?.code == "not_found")
}

@Test
func pluginEnableRequiresId() async {
    let router = LiveAPIRequestRouter(
        onPluginEnable: { _ in nil }
    )
    let response = await router.handleRequest(
        JSONRPCRequest(id: "plg-enable-noid", method: "plugin.enable", params: [:])
    )
    #expect(response.ok == false)
    #expect(response.error?.code == "invalid_params")
}

@Test
func pluginDisableReturnsDisabledState() async {
    let router = LiveAPIRequestRouter(
        onPluginDisable: { id in
            ["id": .string(id), "enabled": .bool(false)]
        }
    )
    let response = await router.handleRequest(
        JSONRPCRequest(id: "plg-disable", method: "plugin.disable", params: ["id": .string("codex")])
    )
    #expect(response.ok == true)
    #expect(response.result?["enabled"]?.boolValue == false)
}

@Test
func pluginDisableUnknownIdReturnsNotFound() async {
    let router = LiveAPIRequestRouter(
        onPluginDisable: { _ in nil }
    )
    let response = await router.handleRequest(
        JSONRPCRequest(id: "plg-disable-404", method: "plugin.disable", params: ["id": .string("nope")])
    )
    #expect(response.ok == false)
    #expect(response.error?.code == "not_found")
}

// MARK: - plugin.logs

@Test
func pluginLogsReturnsLinesAndPath() async {
    let received = LockedValue<(String?, Int?)>((nil, nil))
    let router = LiveAPIRequestRouter(
        onPluginLogs: { id, lines in
            await received.set((id, lines))
            return [
                "logPath": .string("/tmp/x/logs/sidecar.log"),
                "lines": .array([.string("line1"), .string("line2")]),
            ]
        }
    )
    let response = await router.handleRequest(
        JSONRPCRequest(
            id: "plg-logs",
            method: "plugin.logs",
            params: ["id": .string("claude-code"), "lines": .int(50)]
        )
    )
    #expect(response.ok == true)
    #expect(response.result?["logPath"]?.stringValue == "/tmp/x/logs/sidecar.log")
    if case let .array(lines) = response.result?["lines"] {
        #expect(lines.compactMap(\.stringValue) == ["line1", "line2"])
    } else {
        Issue.record("Expected lines array")
    }
    let (id, lines) = await received.get()
    #expect(id == "claude-code")
    #expect(lines == 50)
}

@Test
func pluginLogsForwardsNilLinesWhenAbsent() async {
    let receivedLines = LockedValue<Int?>(-1)
    let router = LiveAPIRequestRouter(
        onPluginLogs: { _, lines in
            await receivedLines.set(lines)
            return ["logPath": .string(""), "lines": .array([])]
        }
    )
    let response = await router.handleRequest(
        JSONRPCRequest(id: "plg-logs-nolines", method: "plugin.logs", params: ["id": .string("codex")])
    )
    #expect(response.ok == true)
    #expect(await receivedLines.get() == nil)
}

@Test
func pluginLogsUnknownIdReturnsNotFound() async {
    let router = LiveAPIRequestRouter(
        onPluginLogs: { _, _ in nil }
    )
    let response = await router.handleRequest(
        JSONRPCRequest(id: "plg-logs-404", method: "plugin.logs", params: ["id": .string("nope")])
    )
    #expect(response.ok == false)
    #expect(response.error?.code == "not_found")
}

@Test
func pluginLogsRequiresId() async {
    let router = LiveAPIRequestRouter(
        onPluginLogs: { _, _ in [:] }
    )
    let response = await router.handleRequest(
        JSONRPCRequest(id: "plg-logs-noid", method: "plugin.logs", params: [:])
    )
    #expect(response.ok == false)
    #expect(response.error?.code == "invalid_params")
}

// MARK: - plugin.call

@Test
func pluginCallOkReturnsResult() async {
    let received = LockedValue<(String?, String?, String?, String?)>((nil, nil, nil, nil))
    let router = LiveAPIRequestRouter(
        onPluginCall: { id, method, json, configRoot in
            await received.set((id, method, json, configRoot))
            return .ok(result: "installed")
        }
    )
    let response = await router.handleRequest(
        JSONRPCRequest(
            id: "plg-call",
            method: "plugin.call",
            params: ["id": .string("claude-code"), "method": .string("install"), "configRoot": .string("/custom/config")]
        )
    )
    #expect(response.ok == true)
    #expect(response.result?["id"]?.stringValue == "claude-code")
    #expect(response.result?["method"]?.stringValue == "install")
    #expect(response.result?["ok"]?.boolValue == true)
    #expect(response.result?["result"]?.stringValue == "installed")
    let (id, method, _, configRootReceived) = await received.get()
    #expect(id == "claude-code")
    #expect(method == "install")
    #expect(configRootReceived == "/custom/config")
}

@Test
func pluginCallForwardsJsonArgument() async {
    let receivedJson = LockedValue<String?>(nil)
    let router = LiveAPIRequestRouter(
        onPluginCall: { _, _, json, _ in
            await receivedJson.set(json)
            return .ok(result: "done")
        }
    )
    _ = await router.handleRequest(
        JSONRPCRequest(
            id: "plg-call-json",
            method: "plugin.call",
            params: [
                "id": .string("echo"),
                "method": .string("refreshProjects"),
                "json": .string("{\"k\":1}"),
            ]
        )
    )
    #expect(await receivedJson.get() == "{\"k\":1}")
}

@Test
func pluginCallUnknownPluginReturnsNotFound() async {
    let router = LiveAPIRequestRouter(
        onPluginCall: { _, _, _, _ in .unknownPlugin }
    )
    let response = await router.handleRequest(
        JSONRPCRequest(
            id: "plg-call-404",
            method: "plugin.call",
            params: ["id": .string("nope"), "method": .string("install")]
        )
    )
    #expect(response.ok == false)
    #expect(response.error?.code == "not_found")
}

@Test
func pluginCallNotEnabledReturnsError() async {
    let router = LiveAPIRequestRouter(
        onPluginCall: { _, _, _, _ in .notEnabled }
    )
    let response = await router.handleRequest(
        JSONRPCRequest(
            id: "plg-call-disabled",
            method: "plugin.call",
            params: ["id": .string("codex"), "method": .string("refreshProjects")]
        )
    )
    #expect(response.ok == false)
    #expect(response.error?.code == "not_enabled")
}

@Test
func pluginCallUnknownMethodReturnsInvalidParams() async {
    let router = LiveAPIRequestRouter(
        onPluginCall: { _, _, _, _ in .unknownMethod("bogus") }
    )
    let response = await router.handleRequest(
        JSONRPCRequest(
            id: "plg-call-badmethod",
            method: "plugin.call",
            params: ["id": .string("codex"), "method": .string("bogus")]
        )
    )
    #expect(response.ok == false)
    #expect(response.error?.code == "invalid_params")
}

@Test
func pluginCallFailedReturnsInternalError() async {
    let router = LiveAPIRequestRouter(
        onPluginCall: { _, _, _, _ in .failed("boom") }
    )
    let response = await router.handleRequest(
        JSONRPCRequest(
            id: "plg-call-fail",
            method: "plugin.call",
            params: ["id": .string("codex"), "method": .string("install")]
        )
    )
    #expect(response.ok == false)
    #expect(response.error?.code == "internal_error")
}

@Test
func pluginCallRequiresIdAndMethod() async {
    let router = LiveAPIRequestRouter(
        onPluginCall: { _, _, _, _ in .ok(result: "") }
    )
    let missingMethod = await router.handleRequest(
        JSONRPCRequest(id: "plg-call-nomethod", method: "plugin.call", params: ["id": .string("codex")])
    )
    #expect(missingMethod.ok == false)
    #expect(missingMethod.error?.code == "invalid_params")

    let missingId = await router.handleRequest(
        JSONRPCRequest(id: "plg-call-noid", method: "plugin.call", params: ["method": .string("install")])
    )
    #expect(missingId.ok == false)
    #expect(missingId.error?.code == "invalid_params")
}

/// Helper actor for capturing values from `@Sendable` callbacks inside tests.
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
