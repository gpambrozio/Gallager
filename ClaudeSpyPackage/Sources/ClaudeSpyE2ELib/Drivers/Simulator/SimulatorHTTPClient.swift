import CoreGraphics
import Foundation
import Logging

/// Client for the iOS app's test accessibility HTTP endpoint.
///
/// When the macOS Accessibility API cannot read the Simulator's AX tree,
/// this client queries the iOS app directly via HTTP for its accessibility tree.
enum SimulatorHTTPClient {
    private static let logger = Logger(label: "e2e.sim-http")
    private static let port: UInt16 = 18_080

    struct Response: Sendable {
        let elements: [UIElement]
        let screenSize: CGSize
    }

    /// Fetch the iOS app's accessibility tree via HTTP
    static func describeUI() async throws -> Response {
        let url = URL(string: "http://127.0.0.1:\(port)/describe-ui")!
        let (data, _) = try await URLSession.shared.data(from: url)

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let elementsArray = json["elements"] as? [[String: Any]],
            let sizeDict = json["screenSize"] as? [String: Any]
        else {
            throw SimulatorHTTPError.invalidResponse
        }

        let screenWidth = sizeDict["width"] as? CGFloat ?? 0
        let screenHeight = sizeDict["height"] as? CGFloat ?? 0
        let elements = elementsArray.compactMap { parseElement($0) }

        logger.info("HTTP describe-ui: \(elements.count) elements, screen \(screenWidth)x\(screenHeight)")
        return Response(
            elements: elements,
            screenSize: CGSize(width: screenWidth, height: screenHeight)
        )
    }

    private static func parseElement(_ dict: [String: Any]) -> UIElement? {
        let role = dict["role"] as? String ?? "AXGroup"
        let label = dict["label"] as? String
        let identifier = dict["identifier"] as? String
        let value = dict["value"] as? String

        var frame = CGRect.zero
        if let frameDict = dict["frame"] as? [String: Any] {
            frame = CGRect(
                x: frameDict["x"] as? CGFloat ?? 0,
                y: frameDict["y"] as? CGFloat ?? 0,
                width: frameDict["width"] as? CGFloat ?? 0,
                height: frameDict["height"] as? CGFloat ?? 0
            )
        }

        var children: [UIElement] = []
        if let childrenArray = dict["children"] as? [[String: Any]] {
            children = childrenArray.compactMap { parseElement($0) }
        }

        // Skip elements with no useful information
        if label == nil && identifier == nil && value == nil && children.isEmpty && frame == .zero {
            return nil
        }

        return UIElement(
            role: role,
            subrole: nil,
            label: label,
            value: value,
            title: nil,
            identifier: identifier,
            frame: frame,
            children: children
        )
    }

    /// Type text into the focused text field via the iOS app's HTTP server.
    /// This bypasses hardware keyboard requirements entirely.
    /// Returns true if the text was typed successfully.
    @discardableResult
    static func type(text: String) async throws -> Bool {
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
        let url = URL(string: "http://127.0.0.1:\(port)/type?text=\(encoded)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, _) = try await URLSession.shared.data(for: request)
        let body = String(data: data, encoding: .utf8) ?? ""
        logger.info("HTTP type '\(text)': \(body)")
        return body == "typed"
    }

    /// Tap an accessibility element via the iOS app's HTTP server.
    /// The tap happens inside the app process using accessibilityActivate().
    @discardableResult
    static func tap(query: ElementQuery) async throws -> Bool {
        var params: [String] = []
        switch query {
        case let .label(text):
            params.append("label=\(urlEncode(text))")
        case let .labelContains(text):
            params.append("labelContains=\(urlEncode(text))")
        case let .identifier(id):
            params.append("identifier=\(urlEncode(id))")
        default:
            // For complex queries, extract the most specific param
            if let (key, value) = extractPrimaryParam(from: query) {
                params.append("\(key)=\(urlEncode(value))")
            } else {
                return false
            }
        }

        let url = URL(string: "http://127.0.0.1:\(port)/tap?\(params.joined(separator: "&"))")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, _) = try await URLSession.shared.data(for: request)
        let body = String(data: data, encoding: .utf8) ?? ""
        logger.info("HTTP tap \(query): \(body)")
        return body == "tapped"
    }

    /// Perform a custom accessibility action on an element via the iOS app's HTTP server.
    /// Used for swipe-to-delete and other custom actions.
    @discardableResult
    static func performCustomAction(
        query: ElementQuery,
        action: String
    ) async throws -> Bool {
        var params = ["action=\(urlEncode(action))"]
        switch query {
        case let .label(text):
            params.append("label=\(urlEncode(text))")
        case let .labelContains(text):
            params.append("labelContains=\(urlEncode(text))")
        case let .identifier(id):
            params.append("identifier=\(urlEncode(id))")
        default:
            if let (key, value) = extractPrimaryParam(from: query) {
                params.append("\(key)=\(urlEncode(value))")
            } else {
                return false
            }
        }

        let url = URL(string: "http://127.0.0.1:\(port)/custom-action?\(params.joined(separator: "&"))")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, _) = try await URLSession.shared.data(for: request)
        let body = String(data: data, encoding: .utf8) ?? ""
        logger.info("HTTP custom-action '\(action)' on \(query): \(body)")
        return body == "performed"
    }

    // MARK: - Private Helpers

    private static func urlEncode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
    }

    /// Extract the most specific query parameter from a complex ElementQuery.
    private static func extractPrimaryParam(from query: ElementQuery) -> (key: String, value: String)? {
        switch query {
        case let .label(text):
            ("label", text)
        case let .labelContains(text):
            ("labelContains", text)
        case let .identifier(id):
            ("identifier", id)
        case let .roleAndLabelContains(_, label):
            ("labelContains", label)
        case let .allOf(queries):
            // Find the first label-like query
            queries.lazy.compactMap { extractPrimaryParam(from: $0) }.first
        default:
            nil
        }
    }

    /// Calculate the content origin (macOS screen position of iOS point 0,0)
    /// from the CGWindowList and iOS screen size.
    static func calculateContentOrigin(screenSize: CGSize) -> CGPoint? {
        let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly], kCGNullWindowID
        ) as? [[String: Any]] ?? []

        for window in windowList {
            guard
                (window[kCGWindowOwnerName as String] as? String) == "Simulator",
                let bounds = window[kCGWindowBounds as String] as? [String: Any],
                let winWidth = bounds["Width"] as? CGFloat,
                winWidth > 100
            else { continue }

            let winX = bounds["X"] as? CGFloat ?? 0
            let winY = bounds["Y"] as? CGFloat ?? 0
            let winHeight = bounds["Height"] as? CGFloat ?? 0

            // Calculate chrome (window decorations around the iOS content)
            let horizontalChrome = winWidth - screenSize.width
            let verticalChrome = winHeight - screenSize.height

            // Horizontal: content is centered
            let leftChrome = horizontalChrome / 2

            // Vertical: assume bottom chrome = side chrome, rest is top chrome
            // (title bar + device top bezel)
            let bottomChrome = leftChrome
            let topChrome = verticalChrome - bottomChrome

            let origin = CGPoint(x: winX + leftChrome, y: winY + topChrome)
            logger.info("Calculated content origin: \(origin) (window=\(winX),\(winY) \(winWidth)x\(winHeight), iOS=\(screenSize))")
            return origin
        }

        logger.warning("Could not find Simulator window in CGWindowList")
        return nil
    }
}

enum SimulatorHTTPError: Error, LocalizedError {
    case invalidResponse
    case serverNotRunning

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Invalid response from iOS accessibility server"
        case .serverNotRunning:
            "iOS accessibility server not running (is --e2e-test flag set?)"
        }
    }
}
