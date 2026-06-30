import ClaudeSpyNetworking
import Testing
@testable import ClaudeSpyServerFeature

// Router-level tests for the Task-16 plugin verbs: plugin.install, plugin.remove,
// plugin.update. Mirrors the style of PluginAPIRequestRouterTests.

// MARK: - system.capabilities advertises the new verbs

@Test
func pluginV2MethodsListedInCapabilities() async {
    let router = LiveAPIRequestRouter()
    let response = await router.handleRequest(
        JSONRPCRequest(id: "cap-v2", method: "system.capabilities", params: [:])
    )
    guard case let .array(methods) = response.result?["methods"] else {
        Issue.record("Expected methods array")
        return
    }
    let names = methods.compactMap(\.stringValue)
    #expect(names.contains("plugin.install"))
    #expect(names.contains("plugin.remove"))
    #expect(names.contains("plugin.update"))
}

// MARK: - plugin.install

@Test
func pluginInstallReturnsTrustDetailsOnFirstCall() async {
    let receivedURL = LockedValueV2<String?>(nil)
    let receivedConfirm = LockedValueV2<Bool?>(nil)
    let router = LiveAPIRequestRouter(
        onPluginInstall: { url, trustConfirmed in
            await receivedURL.set(url)
            await receivedConfirm.set(trustConfirmed)
            return .needsTrust([
                "id": .string("my-plugin"),
                "displayName": .string("My Plugin"),
                "version": .string("1.0.0"),
                "publisher": .string("Acme"),
                "sourceURL": .string("https://example.com/plugin.json"),
                "bundleURL": .null,
                "bundleSHA256": .null,
                "bundleSizeBytes": .null,
            ])
        }
    )
    let response = await router.handleRequest(
        JSONRPCRequest(
            id: "install-trust",
            method: "plugin.install",
            params: [
                "url": .string("https://example.com/plugin.json"),
                "trustConfirmed": .bool(false),
            ]
        )
    )
    #expect(response.ok == true)
    #expect(response.result?["status"]?.stringValue == "needs_trust")
    guard case let .object(trust) = response.result?["trust"] else {
        Issue.record("Expected trust object")
        return
    }
    #expect(trust["id"]?.stringValue == "my-plugin")
    #expect(trust["displayName"]?.stringValue == "My Plugin")
    #expect(trust["publisher"]?.stringValue == "Acme")
    #expect(await receivedURL.get() == "https://example.com/plugin.json")
    #expect(await receivedConfirm.get() == false)
}

@Test
func pluginInstallReturnsInstalledOnConfirmedCall() async {
    let router = LiveAPIRequestRouter(
        onPluginInstall: { _, _ in .installed(id: "my-plugin") }
    )
    let response = await router.handleRequest(
        JSONRPCRequest(
            id: "install-confirm",
            method: "plugin.install",
            params: [
                "url": .string("https://example.com/plugin.json"),
                "trustConfirmed": .bool(true),
            ]
        )
    )
    #expect(response.ok == true)
    #expect(response.result?["status"]?.stringValue == "installed")
    #expect(response.result?["id"]?.stringValue == "my-plugin")
}

@Test
func pluginInstallRequiresURL() async {
    let router = LiveAPIRequestRouter(
        onPluginInstall: { _, _ in .installed(id: "x") }
    )
    let response = await router.handleRequest(
        JSONRPCRequest(id: "install-nourl", method: "plugin.install", params: [:])
    )
    #expect(response.ok == false)
    #expect(response.error?.code == "invalid_params")
}

@Test
func pluginInstallFailedReturnsInternalError() async {
    let router = LiveAPIRequestRouter(
        onPluginInstall: { _, _ in .failed("hash mismatch") }
    )
    let response = await router.handleRequest(
        JSONRPCRequest(
            id: "install-fail",
            method: "plugin.install",
            params: ["url": .string("https://example.com/plugin.json"), "trustConfirmed": .bool(true)]
        )
    )
    #expect(response.ok == false)
    #expect(response.error?.code == "internal_error")
}

@Test
func pluginInstallRejectsWhenCallbackMissing() async {
    let router = LiveAPIRequestRouter()
    let response = await router.handleRequest(
        JSONRPCRequest(
            id: "install-nocb",
            method: "plugin.install",
            params: ["url": .string("https://example.com/plugin.json")]
        )
    )
    #expect(response.ok == false)
    #expect(response.error?.code == "internal_error")
}

// MARK: - plugin.install (local zip via `path`)

@Test
func pluginInstallZipRoutesPathToZipCallback() async {
    let receivedPath = LockedValueV2<String?>(nil)
    let receivedConfirm = LockedValueV2<Bool?>(nil)
    let router = LiveAPIRequestRouter(
        // A `url` callback that would fail the test if the path were misrouted.
        onPluginInstall: { _, _ in .failed("should not be called for a zip path") },
        onPluginInstallZip: { path, trustConfirmed in
            await receivedPath.set(path)
            await receivedConfirm.set(trustConfirmed)
            return .needsTrust([
                "id": .string("zip-plugin"),
                "displayName": .string("Zip Plugin"),
                "version": .string("1.0.0"),
                "sourceURL": .string("/tmp/zip-plugin.zip"),
                "bundleURL": .null,
                "bundleSHA256": .null,
                "bundleSizeBytes": .int(2_048),
            ])
        }
    )
    let response = await router.handleRequest(
        JSONRPCRequest(
            id: "install-zip-trust",
            method: "plugin.install",
            params: ["path": .string("/tmp/zip-plugin.zip"), "trustConfirmed": .bool(false)]
        )
    )
    #expect(response.ok == true)
    #expect(response.result?["status"]?.stringValue == "needs_trust")
    guard case let .object(trust) = response.result?["trust"] else {
        Issue.record("Expected trust object")
        return
    }
    #expect(trust["id"]?.stringValue == "zip-plugin")
    #expect(await receivedPath.get() == "/tmp/zip-plugin.zip")
    #expect(await receivedConfirm.get() == false)
}

@Test
func pluginInstallZipReturnsInstalledOnConfirmedCall() async {
    let router = LiveAPIRequestRouter(
        onPluginInstallZip: { _, _ in .installed(id: "zip-plugin") }
    )
    let response = await router.handleRequest(
        JSONRPCRequest(
            id: "install-zip-confirm",
            method: "plugin.install",
            params: ["path": .string("/tmp/zip-plugin.zip"), "trustConfirmed": .bool(true)]
        )
    )
    #expect(response.ok == true)
    #expect(response.result?["status"]?.stringValue == "installed")
    #expect(response.result?["id"]?.stringValue == "zip-plugin")
}

@Test
func pluginInstallZipRejectsWhenCallbackMissing() async {
    // Only the URL callback is wired; a `path` request must report unavailable.
    let router = LiveAPIRequestRouter(
        onPluginInstall: { _, _ in .installed(id: "x") }
    )
    let response = await router.handleRequest(
        JSONRPCRequest(
            id: "install-zip-nocb",
            method: "plugin.install",
            params: ["path": .string("/tmp/zip-plugin.zip")]
        )
    )
    #expect(response.ok == false)
    #expect(response.error?.code == "internal_error")
}

// MARK: - plugin.remove

@Test
func pluginRemoveReturnsOkOnSuccess() async {
    let receivedID = LockedValueV2<String?>(nil)
    let receivedDelete = LockedValueV2<Bool?>(nil)
    let router = LiveAPIRequestRouter(
        onPluginRemove: { id, deleteState in
            await receivedID.set(id)
            await receivedDelete.set(deleteState)
            return .ok
        }
    )
    let response = await router.handleRequest(
        JSONRPCRequest(
            id: "remove-ok",
            method: "plugin.remove",
            params: ["id": .string("my-plugin"), "deleteState": .bool(true)]
        )
    )
    #expect(response.ok == true)
    #expect(response.result?["id"]?.stringValue == "my-plugin")
    #expect(response.result?["removed"]?.boolValue == true)
    #expect(await receivedID.get() == "my-plugin")
    #expect(await receivedDelete.get() == true)
}

@Test
func pluginRemoveBundledRefusalReturnsDistinctError() async {
    let router = LiveAPIRequestRouter(
        onPluginRemove: { _, _ in .bundledRefusal }
    )
    let response = await router.handleRequest(
        JSONRPCRequest(
            id: "remove-bundled",
            method: "plugin.remove",
            params: ["id": .string("claude-code")]
        )
    )
    #expect(response.ok == false)
    #expect(response.error?.code == "bundled_plugin")
}

@Test
func pluginRemoveFailedReturnsInternalError() async {
    let router = LiveAPIRequestRouter(
        onPluginRemove: { _, _ in .failed("not installed") }
    )
    let response = await router.handleRequest(
        JSONRPCRequest(
            id: "remove-fail",
            method: "plugin.remove",
            params: ["id": .string("my-plugin")]
        )
    )
    #expect(response.ok == false)
    #expect(response.error?.code == "internal_error")
}

@Test
func pluginRemoveRequiresId() async {
    let router = LiveAPIRequestRouter(
        onPluginRemove: { _, _ in .ok }
    )
    let response = await router.handleRequest(
        JSONRPCRequest(id: "remove-noid", method: "plugin.remove", params: [:])
    )
    #expect(response.ok == false)
    #expect(response.error?.code == "invalid_params")
}

@Test
func pluginRemoveRejectsWhenCallbackMissing() async {
    let router = LiveAPIRequestRouter()
    let response = await router.handleRequest(
        JSONRPCRequest(
            id: "remove-nocb",
            method: "plugin.remove",
            params: ["id": .string("my-plugin")]
        )
    )
    #expect(response.ok == false)
    #expect(response.error?.code == "internal_error")
}

// MARK: - plugin.update

@Test
func pluginUpdateReturnsUpdatesList() async {
    let receivedID = LockedValueV2<String?>("sentinel")
    let router = LiveAPIRequestRouter(
        onPluginUpdate: { id, _ in
            await receivedID.set(id)
            return [
                [
                    "id": .string("my-plugin"),
                    "currentVersion": .string("1.0.0"),
                    "newVersion": .string("1.1.0"),
                    "sourceChanged": .bool(false),
                ],
            ]
        }
    )
    let response = await router.handleRequest(
        JSONRPCRequest(id: "update-list", method: "plugin.update", params: [:])
    )
    #expect(response.ok == true)
    guard case let .array(updates) = response.result?["updates"] else {
        Issue.record("Expected updates array")
        return
    }
    #expect(updates.count == 1)
    guard case let .object(first) = updates[0] else {
        Issue.record("Expected object entry")
        return
    }
    #expect(first["id"]?.stringValue == "my-plugin")
    #expect(first["currentVersion"]?.stringValue == "1.0.0")
    #expect(first["newVersion"]?.stringValue == "1.1.0")
    #expect(first["sourceChanged"]?.boolValue == false)
    // No id param → callback receives nil
    #expect(await receivedID.get() == nil)
}

@Test
func pluginUpdateForwardsIdWhenProvided() async {
    let receivedID = LockedValueV2<String?>(nil)
    let router = LiveAPIRequestRouter(
        onPluginUpdate: { id, _ in
            await receivedID.set(id)
            return []
        }
    )
    _ = await router.handleRequest(
        JSONRPCRequest(
            id: "update-id",
            method: "plugin.update",
            params: ["id": .string("my-plugin"), "apply": .bool(true)]
        )
    )
    #expect(await receivedID.get() == "my-plugin")
}

@Test
func pluginUpdateEmptyListWhenUpToDate() async {
    let router = LiveAPIRequestRouter(
        onPluginUpdate: { _, _ in [] }
    )
    let response = await router.handleRequest(
        JSONRPCRequest(id: "update-empty", method: "plugin.update", params: [:])
    )
    #expect(response.ok == true)
    if case let .array(updates) = response.result?["updates"] {
        #expect(updates.isEmpty)
    } else {
        Issue.record("Expected updates array")
    }
}

@Test
func pluginUpdateRejectsWhenCallbackMissing() async {
    let router = LiveAPIRequestRouter()
    let response = await router.handleRequest(
        JSONRPCRequest(id: "update-nocb", method: "plugin.update", params: [:])
    )
    #expect(response.ok == false)
    #expect(response.error?.code == "internal_error")
}

@Test
func pluginUpdateApplyTrueReachesCallback() async {
    let receivedApply = LockedValueV2<Bool?>(nil)
    let router = LiveAPIRequestRouter(
        onPluginUpdate: { _, apply in
            await receivedApply.set(apply)
            return []
        }
    )
    _ = await router.handleRequest(
        JSONRPCRequest(
            id: "update-apply-true",
            method: "plugin.update",
            params: ["apply": .bool(true)]
        )
    )
    #expect(await receivedApply.get() == true)
}

@Test
func pluginUpdateApplyFalseReachesCallback() async {
    let receivedApply = LockedValueV2<Bool?>(nil)
    let router = LiveAPIRequestRouter(
        onPluginUpdate: { _, apply in
            await receivedApply.set(apply)
            return []
        }
    )
    _ = await router.handleRequest(
        JSONRPCRequest(
            id: "update-apply-false",
            method: "plugin.update",
            params: ["apply": .bool(false)]
        )
    )
    #expect(await receivedApply.get() == false)
}

// MARK: - Helper

/// Actor for capturing values from `@Sendable` callbacks inside tests.
/// Named `LockedValueV2` to avoid collision with the identical helper in
/// `PluginAPIRequestRouterTests` (both are in the same test module).
private actor LockedValueV2<T: Sendable> {
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
