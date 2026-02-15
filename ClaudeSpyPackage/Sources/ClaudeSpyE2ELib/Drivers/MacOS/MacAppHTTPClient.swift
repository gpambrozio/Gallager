import CoreGraphics
import Foundation
import Logging

/// Client for the macOS app's test accessibility HTTP endpoint.
///
/// When the macOS Accessibility API cannot read window content (broken on Xcode 26.x),
/// this client queries the macOS app directly via HTTP for its accessibility tree.
enum MacAppHTTPClient {
    private static let logger = Logger(label: "e2e.mac-http")
    private static let port: UInt16 = 18_081

    struct WindowInfo: Sendable {
        let title: String
        let frame: CGRect
        let elements: [MacUIElement]
    }

    struct MacUIElement: Sendable {
        let role: String
        let label: String?
        let title: String?
        let value: String?
        let identifier: String?
        let help: String?
        /// Frame in screen coordinates (top-left origin)
        let frame: CGRect

        var center: CGPoint {
            CGPoint(x: frame.midX, y: frame.midY)
        }

        /// Check if this element matches the given search criteria
        func matches(titled: String) -> Bool {
            if let t = title, t.contains(titled) { return true }
            if let l = label, l.contains(titled) { return true }
            if let v = value, v.contains(titled) { return true }
            if let h = help, h == titled { return true }
            return false
        }
    }

    /// Fetch the macOS app's accessibility tree via HTTP
    static func describeUI() async throws -> [WindowInfo] {
        let url = URL(string: "http://127.0.0.1:\(port)/describe-ui")!
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, _) = try await URLSession.shared.data(for: request)

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let windowsArray = json["windows"] as? [[String: Any]]
        else {
            throw MacAppHTTPError.invalidResponse
        }

        let windows = windowsArray.compactMap { parseWindow($0) }
        logger.info("HTTP describe-ui: \(windows.count) windows")
        return windows
    }

    /// Find the first element matching a title/label/help across all windows
    static func findElement(titled: String) async throws -> MacUIElement? {
        let windows = try await describeUI()
        for window in windows {
            if let found = window.elements.first(where: { $0.matches(titled: titled) }) {
                return found
            }
        }
        return nil
    }

    /// Bring the app's windows to front
    static func activate() async throws {
        let url = URL(string: "http://127.0.0.1:\(port)/activate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: request)
    }

    /// Click an element by title/label/help inside the macOS app.
    /// The click is performed by the app itself, bypassing window z-ordering issues.
    /// Returns true if the element was found and clicked.
    @discardableResult
    static func click(titled: String) async throws -> Bool {
        let encoded = titled.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? titled
        let url = URL(string: "http://127.0.0.1:\(port)/click?title=\(encoded)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, _) = try await URLSession.shared.data(for: request)
        let body = String(data: data, encoding: .utf8) ?? ""
        logger.info("HTTP click '\(titled)': \(body)")
        return body == "clicked"
    }

    /// Trigger unpair on the first paired viewer via the test endpoint.
    /// Used because SwiftUI Menu popups create native NSMenu objects
    /// that aren't visible to the accessibility tree.
    @discardableResult
    static func unpair() async throws -> Bool {
        let url = URL(string: "http://127.0.0.1:\(port)/unpair")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, _) = try await URLSession.shared.data(for: request)
        let body = String(data: data, encoding: .utf8) ?? ""
        logger.info("HTTP unpair: \(body)")
        return body == "ok"
    }

    /// Set the sidebar width of the NavigationSplitView
    @discardableResult
    static func setSidebarWidth(_ width: Int) async throws -> Bool {
        let url = URL(string: "http://127.0.0.1:\(port)/set-sidebar-width?width=\(width)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, _) = try await URLSession.shared.data(for: request)
        let body = String(data: data, encoding: .utf8) ?? ""
        logger.info("HTTP set-sidebar-width \(width): \(body)")
        return body == "ok"
    }

    /// Send a hook event to the macOS app's real hook server (`/api/hooks`).
    /// Reads the hook server port from `~/.claudespy-port` (written on startup).
    @discardableResult
    static func sendHook(json: String, tmuxPane: String, projectPath: String?) async throws -> Bool {
        let hookPort = try readHookServerPort()

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
        logger.info("HTTP hook event sent to real server on port \(hookPort), status: \(statusCode)")
        return statusCode == 200
    }

    /// Read the hook server port from `~/.claudespy-port`.
    private static func readHookServerPort() throws -> Int {
        let portFilePath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claudespy-port").path
        guard
            let contents = try? String(contentsOfFile: portFilePath, encoding: .utf8),
            let port = Int(contents.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            throw MacAppHTTPError.hookServerPortUnavailable
        }
        return port
    }

    /// Resize the app's frontmost normal-level window
    @discardableResult
    static func resizeWindow(width: Int, height: Int) async throws -> Bool {
        let url = URL(string: "http://127.0.0.1:\(port)/resize-window?width=\(width)&height=\(height)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, _) = try await URLSession.shared.data(for: request)
        let body = String(data: data, encoding: .utf8) ?? ""
        logger.info("HTTP resize-window \(width)x\(height): \(body)")
        return body == "resized"
    }

    /// Check if a window with the given title exists
    static func windowExists(titled: String) async -> Bool {
        guard let windows = try? await describeUI() else { return false }
        return windows.contains { $0.title.contains(titled) }
    }

    // MARK: - Parsing

    private static func parseWindow(_ dict: [String: Any]) -> WindowInfo? {
        let title = dict["title"] as? String ?? ""
        var frame = CGRect.zero
        if let frameDict = dict["frame"] as? [String: Any] {
            frame = parseFrame(frameDict)
        }
        var elements: [MacUIElement] = []
        if let elementsArray = dict["elements"] as? [[String: Any]] {
            elements = elementsArray.compactMap { parseElement($0) }
        }
        return WindowInfo(title: title, frame: frame, elements: elements)
    }

    private static func parseElement(_ dict: [String: Any]) -> MacUIElement? {
        let role = dict["role"] as? String ?? ""
        let label = dict["label"] as? String
        let title = dict["title"] as? String
        let value = dict["value"] as? String
        let identifier = dict["identifier"] as? String
        let help = dict["help"] as? String

        var frame = CGRect.zero
        if let frameDict = dict["frame"] as? [String: Any] {
            frame = parseFrame(frameDict)
        }

        // Skip elements with no useful information
        if label == nil && title == nil && value == nil && identifier == nil && help == nil && frame == .zero {
            return nil
        }

        return MacUIElement(
            role: role,
            label: label,
            title: title,
            value: value,
            identifier: identifier,
            help: help,
            frame: frame
        )
    }

    private static func parseFrame(_ dict: [String: Any]) -> CGRect {
        CGRect(
            x: dict["x"] as? CGFloat ?? 0,
            y: dict["y"] as? CGFloat ?? 0,
            width: dict["width"] as? CGFloat ?? 0,
            height: dict["height"] as? CGFloat ?? 0
        )
    }
}

enum MacAppHTTPError: Error, LocalizedError {
    case invalidResponse
    case serverNotRunning
    case elementNotFound(String)
    case hookServerPortUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Invalid response from macOS accessibility server"
        case .serverNotRunning:
            "macOS accessibility server not running (is --e2e-test flag set?)"
        case let .elementNotFound(title):
            "Element not found: \(title)"
        case .hookServerPortUnavailable:
            "Hook server port unavailable (is ~/.claudespy-port present?)"
        }
    }
}
