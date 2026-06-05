import Foundation
import Logging

/// Minimal HTTP client for macOS app endpoints that require in-process access.
///
/// Most UI interaction has moved to `MacOSAccessibility` (external AX APIs).
/// This client only handles the in-process test endpoints on the
/// `TestAccessibilityServer` port:
/// - `/set-sidebar-width` — NSSplitView.setPosition() requires in-process access
/// - `/unpair` — Posts a NotificationCenter notification inside the app
/// - `/reconnect` — runtime version-override changes
/// - `/drop-files` — simulated Finder drop onto a pane
///
/// Hook delivery no longer goes through HTTP: the legacy `HookServerService`
/// was deleted in the plugin-system flip, and hooks now arrive as length-prefixed
/// `IngressFrame`s on the app's ingress socket (see `IngressSocketClient`).
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
}
