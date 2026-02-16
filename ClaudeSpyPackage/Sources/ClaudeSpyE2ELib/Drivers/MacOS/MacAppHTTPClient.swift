import CoreGraphics
import Foundation
import Logging

/// Client for the macOS app's test accessibility HTTP endpoint.
///
/// When the macOS Accessibility API cannot read window content (broken on Xcode 26.x),
/// this client queries the macOS app directly via HTTP for its accessibility tree.
enum MacAppHTTPClient {
    private static let logger = Logger(label: "e2e.mac-http")

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
    static func describeUI(port: UInt16) async throws -> [WindowInfo] {
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
    static func findElement(titled: String, port: UInt16) async throws -> MacUIElement? {
        let windows = try await describeUI(port: port)
        for window in windows {
            if let found = window.elements.first(where: { $0.matches(titled: titled) }) {
                return found
            }
        }
        return nil
    }

    /// Bring the app's windows to front
    static func activate(port: UInt16) async throws {
        let url = URL(string: "http://127.0.0.1:\(port)/activate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: request)
    }

    /// Click an element by title/label/help inside the macOS app.
    /// The click is performed by the app itself, bypassing window z-ordering issues.
    /// Returns true if the element was found and clicked.
    @discardableResult
    static func click(titled: String, port: UInt16) async throws -> Bool {
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
    static func unpair(port: UInt16) async throws -> Bool {
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
    static func setSidebarWidth(_ width: Int, port: UInt16) async throws -> Bool {
        let url = URL(string: "http://127.0.0.1:\(port)/set-sidebar-width?width=\(width)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, _) = try await URLSession.shared.data(for: request)
        let body = String(data: data, encoding: .utf8) ?? ""
        logger.info("HTTP set-sidebar-width \(width): \(body)")
        return body == "ok"
    }

    /// Resize the app's frontmost normal-level window
    @discardableResult
    static func resizeWindow(width: Int, height: Int, port: UInt16) async throws -> Bool {
        let url = URL(string: "http://127.0.0.1:\(port)/resize-window?width=\(width)&height=\(height)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, _) = try await URLSession.shared.data(for: request)
        let body = String(data: data, encoding: .utf8) ?? ""
        logger.info("HTTP resize-window \(width)x\(height): \(body)")
        return body == "resized"
    }

    /// Check if a window with the given title exists
    static func windowExists(titled: String, port: UInt16) async -> Bool {
        guard let windows = try? await describeUI(port: port) else { return false }
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

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Invalid response from macOS accessibility server"
        case .serverNotRunning:
            "macOS accessibility server not running (is --e2e-test flag set?)"
        case let .elementNotFound(title):
            "Element not found: \(title)"
        }
    }
}
