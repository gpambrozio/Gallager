import Foundation
import Logging

/// Minimal HTTP client for iOS app endpoints that require in-process access.
///
/// The iOS app runs its own `TestAccessibilityServer` on the simulator host
/// (shared with macOS via localhost) when launched with `--e2e-test`.
enum IOSAppHTTPClient {
    private static let logger = Logger(label: "e2e.ios-http")
    static let defaultPort: UInt16 = 18_090

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
            "HTTP iOS reconnect appVersion=\(appVersion ?? "<clear>") minRequiredPartnerVersion=\(minRequiredPartnerVersion ?? "<clear>"): \(body)"
        )
        return body == "ok"
    }

    /// Simulate tapping an action button on the last actionable agent
    /// notification the app received (issue #710). Returns whether the app
    /// reported the action as handled.
    @discardableResult
    static func notificationAction(
        actionIdentifier: String,
        userText: String?,
        reuseLast: Bool,
        port: UInt16 = defaultPort
    ) async throws -> Bool {
        var components = URLComponents(string: "http://127.0.0.1:\(port)/notification-action")!
        components.queryItems = [
            URLQueryItem(name: "actionIdentifier", value: actionIdentifier),
            URLQueryItem(name: "userText", value: userText ?? ""),
            URLQueryItem(name: "reuseLast", value: reuseLast ? "true" : "false"),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        // The app-side handler polls up to ~5s for the notification to arrive;
        // give the request comfortable headroom over that.
        request.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: request)
        let body = String(data: data, encoding: .utf8) ?? ""
        logger.info("HTTP iOS notification-action \(actionIdentifier): \(body)")
        return body == "ok"
    }
}
