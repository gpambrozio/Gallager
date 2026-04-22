import Foundation
import Logging

/// Minimal HTTP client for macOS app endpoints that require in-process access.
///
/// Most UI interaction has moved to `MacOSAccessibility` (external AX APIs).
/// This client only handles:
/// - `/set-sidebar-width` — NSSplitView.setPosition() requires in-process access
/// - `/unpair` — Posts a NotificationCenter notification inside the app
/// - Hook server communication (separate port)
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

    /// Send a hook event to the macOS app's real hook server (`/api/hooks`).
    /// Reads the hook server port from the given port file (defaults to `~/.claudespy-port`).
    @discardableResult
    static func sendHook(json: String, tmuxPane: String, projectPath: String?, hookPortFile: String? = nil) async throws -> Bool {
        let hookPort = try readHookServerPort(portFilePath: hookPortFile)

        var components = URLComponents(string: "http://localhost:\(hookPort)/api/hooks")!
        var queryItems = [URLQueryItem(name: "tmux_pane", value: tmuxPane)]
        if let projectPath {
            queryItems.append(URLQueryItem(name: "project_path", value: projectPath))
        }
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(json.utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        logger.info("Hook event sent to server on port \(hookPort), status: \(statusCode)")
        return statusCode == 200
    }

    /// Read the hook server port from the given file path, falling back to `~/.claudespy-port`.
    private static func readHookServerPort(portFilePath: String? = nil) throws -> Int {
        let portFilePath = portFilePath ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claudespy-port").path
        guard
            let contents = try? String(contentsOfFile: portFilePath, encoding: .utf8),
            let port = Int(contents.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            throw MacAppHTTPError.hookServerPortUnavailable
        }
        return port
    }
}

enum MacAppHTTPError: Error, LocalizedError {
    case hookServerPortUnavailable

    var errorDescription: String? {
        switch self {
        case .hookServerPortUnavailable:
            "Hook server port file not found or unreadable"
        }
    }
}
