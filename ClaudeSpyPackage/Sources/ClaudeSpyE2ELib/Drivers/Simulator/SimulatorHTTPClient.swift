import CoreGraphics
import Foundation
import Logging

/// Client for the XCUITest runner's HTTP accessibility endpoint.
///
/// Queries the XCUITest runner (separate process in the Simulator) via HTTP
/// for UI tree inspection, touch synthesis, text input, and custom actions.
/// The runner uses XCUIElement.snapshot().dictionaryRepresentation for
/// privileged, complete view hierarchy access.
enum SimulatorHTTPClient {
    private static let logger = Logger(label: "e2e.sim-http")
    private static let port: UInt16 = 22_087

    private static var baseURL: String { "http://127.0.0.1:\(port)" }

    struct Response: Sendable {
        let elements: [UIElement]
    }

    // MARK: - Health Check

    /// Check if the XCTest runner is responsive
    static func isRunnerReady() async -> Bool {
        guard let url = URL(string: "\(baseURL)/status") else { return false }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard
                let httpResponse = response as? HTTPURLResponse,
                httpResponse.statusCode == 200
            else { return false }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                return json["status"] == "ok"
            }
            return false
        } catch {
            return false
        }
    }

    // MARK: - UI Inspection

    /// Fetch the iOS app's accessibility tree via the XCTest runner
    static func describeUI(bundleId: String? = nil) async throws -> Response {
        let url = URL(string: "\(baseURL)/viewHierarchy")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["excludeKeyboardElements": false]
        if let bundleId { body["bundleId"] = bundleId }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let axElementDict = json["axElement"] as? [String: Any]
        else {
            throw SimulatorHTTPError.invalidResponse
        }

        let elements = parseAXElement(axElementDict)
        logger.info("HTTP describe-ui: \(elements.count) top-level elements")

        return Response(elements: elements)
    }

    /// Parse an AXElement dictionary (from the XCTest runner) into UIElements.
    /// The root element is a container — we return its children as the top-level elements.
    private static func parseAXElement(_ dict: [String: Any]) -> [UIElement] {
        let element = convertAXElement(dict)

        // The root from the runner is a synthetic container — return its children.
        // The container has elementType 0 (→ "Any") or 1 (→ "Other"), with empty/nil label.
        let isSynthetic = (element.role == "Other" || element.role == "Any")
            && (element.label == nil || element.label?.isEmpty == true)
            && (element.identifier == nil || element.identifier?.isEmpty == true)
        if isSynthetic && !element.children.isEmpty {
            return element.children
        }

        return [element]
    }

    private static func convertAXElement(_ dict: [String: Any]) -> UIElement {
        let label = dict["label"] as? String
        let identifier = dict["identifier"] as? String
        let value = dict["value"] as? String
        let title = dict["title"] as? String
        let elementType = dict["elementType"] as? Int ?? 0

        var frame = CGRect.zero
        if let frameDict = dict["frame"] as? [String: Any] {
            frame = CGRect(
                x: frameDict["X"] as? CGFloat ?? 0,
                y: frameDict["Y"] as? CGFloat ?? 0,
                width: frameDict["Width"] as? CGFloat ?? 0,
                height: frameDict["Height"] as? CGFloat ?? 0
            )
        }

        var children: [UIElement] = []
        if let childrenArray = dict["children"] as? [[String: Any]] {
            children = childrenArray.map { convertAXElement($0) }
        }

        return UIElement(
            role: elementTypeToRole(elementType),
            subrole: nil,
            label: label,
            value: value,
            title: title,
            identifier: identifier,
            help: nil,
            frame: frame,
            children: children
        )
    }

    /// Map XCUIElement.ElementType raw values to role strings
    private static func elementTypeToRole(_ type: Int) -> String {
        switch type {
        case 0: "Any"
        case 1: "Other"
        case 2: "Application"
        case 3: "Group"
        case 4: "Window"
        case 5: "Sheet"
        case 6: "Drawer"
        case 7: "Alert"
        case 8: "Dialog"
        case 9: "Button"
        case 10: "RadioButton"
        case 11: "RadioGroup"
        case 12: "CheckBox"
        case 13: "DisclosureTriangle"
        case 14: "PopUpButton"
        case 15: "ComboBox"
        case 16: "MenuButton"
        case 17: "ToolbarButton"
        case 18: "Popover"
        case 19: "Keyboard"
        case 20: "Key"
        case 21: "NavigationBar"
        case 22: "TabBar"
        case 23: "TabGroup"
        case 24: "Toolbar"
        case 25: "StatusBar"
        case 26: "Table"
        case 27: "TableRow"
        case 28: "TableColumn"
        case 29: "Outline"
        case 30: "OutlineRow"
        case 31: "Browser"
        case 32: "CollectionView"
        case 33: "Slider"
        case 34: "PageIndicator"
        case 35: "ProgressIndicator"
        case 36: "ActivityIndicator"
        case 37: "SegmentedControl"
        case 38: "Picker"
        case 39: "PickerWheel"
        case 40: "Switch"
        case 41: "Toggle"
        case 42: "Link"
        case 43: "Image"
        case 44: "Icon"
        case 45: "SearchField"
        case 46: "ScrollView"
        case 47: "ScrollBar"
        case 48: "StaticText"
        case 49: "TextField"
        case 50: "SecureTextField"
        case 51: "DatePicker"
        case 52: "TextView"
        case 53: "Menu"
        case 54: "MenuItem"
        case 55: "MenuBar"
        case 56: "MenuBarItem"
        case 57: "Map"
        case 58: "WebView"
        case 59: "IncrementArrow"
        case 60: "DecrementArrow"
        case 61: "Timeline"
        case 62: "RatingIndicator"
        case 63: "ValueIndicator"
        case 64: "SplitGroup"
        case 65: "Splitter"
        case 66: "RelevanceIndicator"
        case 67: "ColorWell"
        case 68: "HelpTag"
        case 69: "Matte"
        case 70: "DockItem"
        case 71: "Ruler"
        case 72: "RulerMarker"
        case 73: "Grid"
        case 74: "LevelIndicator"
        case 75: "Cell"
        case 76: "LayoutArea"
        case 77: "LayoutItem"
        case 78: "Handle"
        case 79: "Stepper"
        case 80: "Tab"
        case 81: "TouchBar"
        case 82: "StatusItem"
        default: "Other"
        }
    }

    // MARK: - Touch

    /// Tap at iOS coordinates via the XCTest runner's touch synthesis
    @discardableResult
    static func tap(x: Double, y: Double, duration: TimeInterval? = nil) async throws -> Bool {
        let url = URL(string: "\(baseURL)/touch")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = ["x": x, "y": y]
        if let duration { body["duration"] = duration }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        let success = httpResponse?.statusCode == 200
        logger.info("HTTP touch (\(x), \(y)): \(success ? "ok" : "failed")")
        return success
    }

    /// Tap an element by finding it in the UI tree first, then tapping its center coordinates
    @discardableResult
    static func tap(query: ElementQuery, bundleId: String? = nil, duration: TimeInterval? = nil) async throws -> Bool {
        let response = try await describeUI(bundleId: bundleId)
        guard let element = query.findFirst(in: response.elements) else {
            logger.warning("HTTP tap: element not found for \(query)")
            return false
        }

        let center = element.center
        return try await tap(x: center.x, y: center.y, duration: duration)
    }

    // MARK: - Swipe

    /// Swipe gesture via the XCTest runner's touch synthesis
    @discardableResult
    static func swipe(startX: Double, startY: Double, endX: Double, endY: Double, duration: TimeInterval = 0.3) async throws -> Bool {
        let url = URL(string: "\(baseURL)/swipe")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "startX": startX, "startY": startY,
            "endX": endX, "endY": endY,
            "duration": duration,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        let success = httpResponse?.statusCode == 200
        logger.info("HTTP swipe (\(startX),\(startY))→(\(endX),\(endY)): \(success ? "ok" : "failed")")
        return success
    }

    // MARK: - Text Input

    /// Type text via the XCTest runner's daemon proxy
    @discardableResult
    static func type(text: String) async throws -> Bool {
        let url = URL(string: "\(baseURL)/inputText")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["text": text])

        let (_, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        let success = httpResponse?.statusCode == 200
        logger.info("HTTP type '\(text)': \(success ? "ok" : "failed")")
        return success
    }

    // MARK: - App Lifecycle

    /// Launch (or relaunch) the app under test via the runner's
    /// `XCUIApplication.launch()`. Using the runner instead of `simctl launch`
    /// keeps XCTest's accessibility tracking bound to the new PID — otherwise
    /// `snapshot()` returns stale data from the previous process and every
    /// element query times out after the first scenario.
    @discardableResult
    static func launchApp(bundleId: String, arguments: [String]) async throws -> Bool {
        let url = URL(string: "\(baseURL)/launchApp")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let body: [String: Any] = ["bundleId": bundleId, "arguments": arguments]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        let success = (response as? HTTPURLResponse)?.statusCode == 200
        logger.info("HTTP launch-app \(bundleId): \(success ? "ok" : "failed")")
        return success
    }

    /// Terminate the app under test via the runner so XCTest observes the
    /// process death and clears its accessibility tracking.
    @discardableResult
    static func terminateApp(bundleId: String) async throws -> Bool {
        let url = URL(string: "\(baseURL)/terminateApp")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let body: [String: Any] = ["bundleId": bundleId]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        let success = (response as? HTTPURLResponse)?.statusCode == 200
        logger.info("HTTP terminate-app \(bundleId): \(success ? "ok" : "failed")")
        return success
    }

    // MARK: - Custom Actions

    /// Perform a custom accessibility action on an element via the XCTest runner
    @discardableResult
    static func performCustomAction(
        query: ElementQuery,
        action: String,
        bundleId: String? = nil
    ) async throws -> Bool {
        let url = URL(string: "\(baseURL)/customAction")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: String] = ["action": action]
        if let bundleId { body["bundleId"] = bundleId }
        switch query {
        case let .label(text):
            body["label"] = text
        case let .labelContains(text):
            body["labelContains"] = text
        case let .identifier(id):
            body["identifier"] = id
        default:
            if let (key, value) = extractPrimaryParam(from: query) {
                body[key] = value
            } else {
                return false
            }
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        let success = httpResponse?.statusCode == 200
        logger.info("HTTP custom-action '\(action)' on \(query): \(success ? "ok" : "failed")")
        return success
    }

    // MARK: - Private Helpers

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
            queries.lazy.compactMap { extractPrimaryParam(from: $0) }.first
        default:
            nil
        }
    }
}

enum SimulatorHTTPError: Error, LocalizedError {
    case invalidResponse
    case serverNotRunning

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Invalid response from XCTest runner"
        case .serverNotRunning:
            "XCTest runner not running"
        }
    }
}
