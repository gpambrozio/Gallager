import Foundation
import Logging

/// Minimal HTTP client for macOS app endpoints that require in-process access.
///
/// Most UI interaction has moved to `MacOSAccessibility` (external AX APIs).
/// This client only handles:
/// - `/set-sidebar-width` — NSSplitView.setPosition() requires in-process access
/// - `/unpair` — Posts a NotificationCenter notification inside the app
/// - `/reconnect` — Updates `VersionCompatibility` overrides
/// - `/drop-files` — Simulates a Finder file drop on a terminal pane
/// - `/plugin/install-hooks` / `/plugin/rescan` — Plugin runtime test hooks (Spec §15.1)
///
/// The legacy `/api/hooks` HTTP path was removed when `HookServerService`
/// went away; the e2e DSL now writes directly to each plugin's
/// `ingress.sock` via `MacAppPluginIngressClient`.
enum MacAppHTTPClient {
    private static let logger = Logger(label: "e2e.mac-http")
    static let defaultPort: UInt16 = 18_081

    /// Trigger unpair on the first paired viewer via the test endpoint.
    /// Posts a NotificationCenter notification inside the app process.
    @discardableResult
    static func unpair(port: UInt16 = defaultPort) async throws -> Bool {
        let url = URL(string: "http://127.0.0.1:\(port)/unpair")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, _) = try await URLSession.shared.data(for: request)
        let body = String(data: data, encoding: .utf8) ?? ""
        logger.info("HTTP unpair: \(body)")
        return body == "ok"
    }

    /// Set the sidebar width of the NavigationSplitView.
    /// Requires in-process access to NSSplitView.setPosition().
    @discardableResult
    static func setSidebarWidth(_ width: Int, port: UInt16 = defaultPort) async throws -> Bool {
        let url = URL(string: "http://127.0.0.1:\(port)/set-sidebar-width?width=\(width)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, _) = try await URLSession.shared.data(for: request)
        let body = String(data: data, encoding: .utf8) ?? ""
        logger.info("HTTP set-sidebar-width \(width): \(body)")
        return body == "ok"
    }

    /// Update the in-process `VersionCompatibility` overrides and kick a reconnect.
    ///
    /// Both parameters are always sent. A `nil` value clears the override so the
    /// app falls back to its bundle version / default minimum. A non-nil value
    /// sets the override to that string.
    @discardableResult
    static func setAppVersion(
        appVersion: String?,
        minRequiredPartnerVersion: String?,
        port: UInt16 = defaultPort
    ) async throws -> Bool {
        var components = URLComponents(string: "http://127.0.0.1:\(port)/reconnect")!
        components.queryItems = [
            URLQueryItem(name: "appVersion", value: appVersion ?? ""),
            URLQueryItem(name: "minRequiredPartnerVersion", value: minRequiredPartnerVersion ?? ""),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        let (data, _) = try await URLSession.shared.data(for: request)
        let body = String(data: data, encoding: .utf8) ?? ""
        logger.info(
            "HTTP reconnect appVersion=\(appVersion ?? "<clear>") minRequiredPartnerVersion=\(minRequiredPartnerVersion ?? "<clear>"): \(body)"
        )
        return body == "ok"
    }

    /// Trigger a simulated Finder file drop on the given tmux pane.
    /// Calls the in-process `/drop-files` test endpoint, which finds the
    /// matching `InteractiveTerminalView` and invokes `simulateFileDrop`.
    /// Body format is `paneId\npath1\npath2…`.
    @discardableResult
    static func dropFilesOnPane(
        paneId: String,
        paths: [String],
        port: UInt16 = defaultPort
    ) async throws -> Bool {
        let url = URL(string: "http://127.0.0.1:\(port)/drop-files")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        let body = ([paneId] + paths).joined(separator: "\n")
        request.httpBody = Data(body.utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        let responseBody = String(data: data, encoding: .utf8) ?? ""
        logger.info("HTTP drop-files paneId=\(paneId) paths=\(paths.count): \(responseBody)")
        return responseBody == "ok"
    }

    /// Trigger `PluginManager.installHooks(pluginID:)` inside the running
    /// app via the `/plugin/install-hooks` test endpoint. Posts a
    /// NotificationCenter notification (`com.claudespy.e2e.installHooks`)
    /// that the AppCoordinator observes and forwards to the live
    /// `PluginManager`.
    @discardableResult
    static func installPluginHooks(pluginID: String, port: UInt16 = defaultPort) async throws -> Bool {
        var components = URLComponents(string: "http://127.0.0.1:\(port)/plugin/install-hooks")!
        components.queryItems = [URLQueryItem(name: "id", value: pluginID)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        let (data, _) = try await URLSession.shared.data(for: request)
        let body = String(data: data, encoding: .utf8) ?? ""
        logger.info("HTTP plugin/install-hooks id=\(pluginID): \(body)")
        return body == "ok"
    }

    /// Ask the running app to rescan its plugin registry + spawn supervisors
    /// for any newly-installed plugins via the `/plugin/rescan` endpoint.
    /// Used after seeding a non-bundled plugin (e.g. EchoPlugin) so the live
    /// `PluginManager` picks it up without a relaunch.
    @discardableResult
    static func rescanPlugins(port: UInt16 = defaultPort) async throws -> Bool {
        let url = URL(string: "http://127.0.0.1:\(port)/plugin/rescan")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, _) = try await URLSession.shared.data(for: request)
        let body = String(data: data, encoding: .utf8) ?? ""
        logger.info("HTTP plugin/rescan: \(body)")
        return body == "ok"
    }
}
