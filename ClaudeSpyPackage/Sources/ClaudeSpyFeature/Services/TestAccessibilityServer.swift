#if canImport(UIKit)
    import Foundation
    import Network
    import UIKit

    /// Lightweight HTTP server that exposes the app's accessibility tree for E2E testing.
    ///
    /// When the macOS Accessibility API cannot read the Simulator's AX tree (broken
    /// on Xcode 26.3.0 RC), the E2E framework falls back to this HTTP endpoint to
    /// discover iOS UI elements and their positions.
    ///
    /// Only active when the app is launched with `--e2e-test`.
    @MainActor
    final public class TestAccessibilityServer {
        private var listener: NWListener?
        private static var instance: TestAccessibilityServer?

        /// Start the server if running in E2E test mode
        public static func startIfNeeded() {
            guard CommandLine.arguments.contains("--e2e-test") else { return }
            let server = TestAccessibilityServer()
            do {
                try server.start()
                instance = server
            } catch {
                print("[TestAccessibilityServer] Failed to start: \(error)")
            }
        }

        private func start() throws {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            listener = try NWListener(using: params, on: 18_080)
            listener?.stateUpdateHandler = { state in
                if case let .failed(error) = state {
                    print("[TestAccessibilityServer] Listener failed: \(error)")
                }
            }
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            listener?.start(queue: .main)
            print("[TestAccessibilityServer] Listening on port 18080")
        }

        private nonisolated func handleConnection(_ connection: NWConnection) {
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.receiveRequest(connection)
                case .failed:
                    connection.cancel()
                default:
                    break
                }
            }
            connection.start(queue: .main)
        }

        private nonisolated func receiveRequest(_ connection: NWConnection) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { data, _, _, _ in
                guard let data, let request = String(data: data, encoding: .utf8) else {
                    connection.cancel()
                    return
                }

                if request.hasPrefix("GET /describe-ui") {
                    Task { @MainActor [weak self] in
                        let json = self?.describeUI() ?? "{}"
                        let body = Data(json.utf8)
                        let header =
                            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                        var response = Data(header.utf8)
                        response.append(body)
                        connection.send(content: response, completion: .contentProcessed { _ in
                            connection.cancel()
                        })
                    }
                } else if request.hasPrefix("POST /type") {
                    // Extract text from query string: POST /type?text=ABCDEF
                    let text = Self.extractQueryParam(from: request, key: "text")
                    Task { @MainActor [weak self] in
                        let success = self?.performType(text: text ?? "") ?? false
                        let body = success ? "typed" : "no_responder"
                        let response = Data(
                            "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n\(body)"
                                .utf8)
                        connection.send(content: response, completion: .contentProcessed { _ in
                            connection.cancel()
                        })
                    }
                } else if request.hasPrefix("POST /tap") {
                    // Tap an element by query: POST /tap?label=X or ?labelContains=X or ?identifier=X
                    let label = Self.extractQueryParam(from: request, key: "label")
                    let labelContains = Self.extractQueryParam(from: request, key: "labelContains")
                    let identifier = Self.extractQueryParam(from: request, key: "identifier")
                    Task { @MainActor [weak self] in
                        let success = self?.performTap(
                            label: label, labelContains: labelContains, identifier: identifier
                        ) ?? false
                        let body = success ? "tapped" : "not_found"
                        let response = Data(
                            "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n\(body)"
                                .utf8)
                        connection.send(content: response, completion: .contentProcessed { _ in
                            connection.cancel()
                        })
                    }
                } else if request.hasPrefix("POST /custom-action") {
                    // Perform accessibility custom action: POST /custom-action?identifier=X&action=Delete
                    let label = Self.extractQueryParam(from: request, key: "label")
                    let labelContains = Self.extractQueryParam(from: request, key: "labelContains")
                    let identifier = Self.extractQueryParam(from: request, key: "identifier")
                    let action = Self.extractQueryParam(from: request, key: "action")
                    Task { @MainActor [weak self] in
                        let success = self?.performCustomAction(
                            label: label, labelContains: labelContains,
                            identifier: identifier, action: action ?? ""
                        ) ?? false
                        let body = success ? "performed" : "not_found"
                        let response = Data(
                            "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n\(body)"
                                .utf8)
                        connection.send(content: response, completion: .contentProcessed { _ in
                            connection.cancel()
                        })
                    }
                } else {
                    let response = Data("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n".utf8)
                    connection.send(content: response, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }
            }
        }

        // MARK: - Type Text

        /// Type text into the first responder by inserting characters one at a time.
        /// This triggers SwiftUI bindings properly, unlike setting .text directly.
        private func performType(text: String) -> Bool {
            guard !text.isEmpty else { return false }

            guard
                let keyWindow = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .flatMap(\.windows)
                    .first(where: { $0.isKeyWindow }),
                let firstResponder = keyWindow.findFirstResponder()
            else {
                print("[TestAccessibilityServer] No first responder found")
                return false
            }

            guard let textInput = firstResponder as? UIKeyInput else {
                print("[TestAccessibilityServer] First responder is not UIKeyInput")
                return false
            }

            print("[TestAccessibilityServer] Typing '\(text)' into \(type(of: firstResponder))")
            for char in text {
                textInput.insertText(String(char))
            }
            return true
        }

        // MARK: - Tap Element

        /// Find and activate an accessibility element matching the query.
        /// Uses `accessibilityActivate()` which is the accessibility equivalent of a tap.
        private func performTap(
            label: String?,
            labelContains: String?,
            identifier: String?
        ) -> Bool {
            if
                let element = findAccessibilityElement(
                    label: label, labelContains: labelContains, identifier: identifier
                ) {
                return activateElement(element)
            }

            // Accessibility tree didn't find it — try walking presented view controllers
            // (confirmation dialogs, action sheets, alerts). Their views may not appear
            // in the accessibility element tree but are in the UIView subview hierarchy.
            print("[TestAccessibilityServer] Tap: not in accessibility tree, searching UIView hierarchy...")
            if
                let element = findInViewHierarchy(
                    label: label, labelContains: labelContains, identifier: identifier
                ) {
                return activateElement(element)
            }

            print("[TestAccessibilityServer] Tap: element not found (label=\(label ?? "nil"), labelContains=\(labelContains ?? "nil"), id=\(identifier ?? "nil"))")
            return false
        }

        /// Activate an element found by any search method.
        private func activateElement(_ element: NSObject) -> Bool {
            print("[TestAccessibilityServer] Tap: found \(type(of: element)), label=\(element.accessibilityLabel ?? "nil")")

            // Try accessibilityActivate (works for buttons, tabs, etc.)
            if element.accessibilityActivate() {
                print("[TestAccessibilityServer] Tap: accessibilityActivate succeeded")
                return true
            }

            // Fallback: try to find the UIControl and send touch event
            if let view = element as? UIControl {
                print("[TestAccessibilityServer] Tap: sending touchUpInside to UIControl")
                view.sendActions(for: .touchUpInside)
                return true
            }

            // Fallback: simulate a tap at the element's center via hitTest
            let frame = element.accessibilityFrame
            if frame != .zero && !frame.isNull {
                print("[TestAccessibilityServer] Tap: simulating touch at center of frame \(frame)")
                return simulateTap(at: CGPoint(x: frame.midX, y: frame.midY))
            }

            print("[TestAccessibilityServer] Tap: all methods failed")
            return false
        }

        /// Simulate a tap at screen coordinates by finding the view via hitTest
        /// and sending touch events.
        private func simulateTap(at screenPoint: CGPoint) -> Bool {
            guard
                let keyWindow = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .flatMap(\.windows)
                    .first(where: { $0.isKeyWindow })
            else { return false }

            // Convert screen coordinates to window coordinates
            let windowPoint = keyWindow.convert(screenPoint, from: nil)
            guard let hitView = keyWindow.hitTest(windowPoint, with: nil) else {
                print("[TestAccessibilityServer] Tap: hitTest returned nil at \(windowPoint)")
                return false
            }

            print("[TestAccessibilityServer] Tap: hitTest found \(type(of: hitView))")

            // If it's a UIControl, send the action
            if let control = hitView as? UIControl {
                control.sendActions(for: .touchUpInside)
                return true
            }

            // For other views, walk up to find a UIControl ancestor
            var responder: UIResponder? = hitView
            while let r = responder {
                if let control = r as? UIControl {
                    control.sendActions(for: .touchUpInside)
                    return true
                }
                responder = r.next
            }

            return false
        }

        // MARK: - Custom Action

        /// Perform a named accessibility custom action on a matching element.
        /// Used for swipe-to-delete and other custom accessibility actions.
        private func performCustomAction(
            label: String?,
            labelContains: String?,
            identifier: String?,
            action actionName: String
        ) -> Bool {
            guard !actionName.isEmpty else { return false }

            if
                let element = findAccessibilityElement(
                    label: label, labelContains: labelContains, identifier: identifier
                ) {
                print("[TestAccessibilityServer] CustomAction: looking for '\(actionName)' on \(type(of: element))")

                // Check accessibility custom actions on the element itself
                if let result = tryCustomAction(actionName, on: element) {
                    return result
                }

                // Walk UP the view hierarchy (SwiftUI .onDelete may be on a parent List cell)
                if let view = element as? UIView {
                    var current: UIView? = view.superview
                    while let parent = current {
                        if let result = tryCustomAction(actionName, on: parent) {
                            print("[TestAccessibilityServer] CustomAction: found on parent \(type(of: parent))")
                            return result
                        }
                        current = parent.superview
                    }
                }

                // Walk DOWN into accessibility children (the action may be on a child element)
                if let view = element as? UIView {
                    if let result = findCustomActionInSubtree(actionName, root: view) {
                        return result
                    }
                }
            }

            // Fallback: element not found by query (e.g., SwiftUI AccessibilityNode doesn't expose
            // accessibilityIdentifier via ObjC selectors on iOS 26). Walk the entire tree looking
            // for any element that has the named custom action.
            print("[TestAccessibilityServer] CustomAction: element not found by query, searching entire tree for '\(actionName)'")
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene else { continue }
                for window in windowScene.windows where !window.isHidden {
                    if let result = findAndInvokeCustomAction(actionName, in: window) {
                        return result
                    }
                }
            }

            print("[TestAccessibilityServer] CustomAction: '\(actionName)' not found anywhere")
            return false
        }

        /// Try to find and invoke a custom action on a single object.
        /// Handles both handler closure and target/action patterns.
        private func tryCustomAction(_ actionName: String, on obj: NSObject) -> Bool? {
            guard let actions = obj.accessibilityCustomActions else { return nil }

            for action in actions {
                guard action.name.localizedCaseInsensitiveContains(actionName) else { continue }
                print("[TestAccessibilityServer] CustomAction: found '\(action.name)' on \(type(of: obj))")

                // Try handler closure first
                if let handler = action.actionHandler {
                    let result = handler(action)
                    print("[TestAccessibilityServer] CustomAction: handler → \(result)")
                    return result
                }

                // Fall back to target/action (SwiftUI uses this pattern for .onDelete)
                if let target = action.target as? NSObject {
                    _ = target.perform(action.selector, with: action)
                    print("[TestAccessibilityServer] CustomAction: target/action invoked")
                    return true
                }
            }
            return nil
        }

        /// Search accessibility children recursively for a custom action.
        private func findCustomActionInSubtree(_ actionName: String, root: UIView, depth: Int = 0) -> Bool? {
            guard depth < 15 else { return nil }
            for subview in root.subviews {
                if let result = tryCustomAction(actionName, on: subview) {
                    return result
                }
                if let result = findCustomActionInSubtree(actionName, root: subview, depth: depth + 1) {
                    return result
                }
            }
            return nil
        }

        /// Walk the entire UI tree looking for any element with the named custom action.
        /// Searches BOTH the accessibility element tree AND the UIView subview hierarchy,
        /// because SwiftUI `.onDelete` puts custom actions on UIKit cell containers, not
        /// on the SwiftUI AccessibilityNode objects.
        private func findAndInvokeCustomAction(
            _ actionName: String,
            in obj: NSObject,
            depth: Int = 0
        ) -> Bool? {
            guard depth < 30 else { return nil }

            // Check this object for the custom action
            if let result = tryCustomAction(actionName, on: obj) {
                print("[TestAccessibilityServer] CustomAction: found '\(actionName)' on \(type(of: obj)) at depth \(depth)")
                return result
            }

            // Always recurse into UIView subviews first (the custom action is likely on a UIKit cell)
            if let view = obj as? UIView {
                for subview in view.subviews where !subview.isHidden {
                    if let result = findAndInvokeCustomAction(actionName, in: subview, depth: depth + 1) {
                        return result
                    }
                }
            }

            // Also check accessibility children (may be AccessibilityNode objects)
            let elementCount = obj.accessibilityElementCount()
            if elementCount > 0 && elementCount != NSNotFound {
                for i in 0..<elementCount {
                    if
                        let child = obj.accessibilityElement(at: i) as? NSObject,
                        // Skip if it's a UIView (already visited via subviews above)
                        !(child is UIView),
                        let result = findAndInvokeCustomAction(actionName, in: child, depth: depth + 1) {
                        return result
                    }
                }
            }

            return nil
        }

        // MARK: - Element Finding

        /// Walk the raw UIView subview hierarchy to find an element by label.
        /// Unlike `findInAccessibilityTree`, this checks EVERY view's accessibility
        /// label (not just `isAccessibilityElement` ones) and recurses purely through
        /// UIView subviews. Finds buttons in confirmation dialogs and action sheets
        /// that aren't exposed through the accessibility element tree on iOS 26.
        private func findInViewHierarchy(
            label: String?,
            labelContains: String?,
            identifier: String?
        ) -> NSObject? {
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene else { continue }
                for window in windowScene.windows where !window.isHidden {
                    if
                        let found = findInSubviews(
                            window, label: label, labelContains: labelContains,
                            identifier: identifier
                        ) {
                        return found
                    }
                }
            }
            return nil
        }

        private func findInSubviews(
            _ view: UIView,
            label: String?,
            labelContains: String?,
            identifier: String?,
            depth: Int = 0
        ) -> UIView? {
            guard depth < 30 else { return nil }

            // Check this view's accessibility label
            let viewLabel = view.accessibilityLabel ?? ""
            if let label, viewLabel == label { return view }
            if
                let labelContains, !viewLabel.isEmpty,
                viewLabel.localizedCaseInsensitiveContains(labelContains) {
                return view
            }
            if let identifier, view.accessibilityIdentifier == identifier {
                return view
            }

            for subview in view.subviews {
                if
                    let found = findInSubviews(
                        subview, label: label, labelContains: labelContains,
                        identifier: identifier, depth: depth + 1
                    ) {
                    return found
                }
            }
            return nil
        }

        /// Find an accessibility element matching the given criteria.
        /// Searches through all windows and their accessibility trees.
        private func findAccessibilityElement(
            label: String?,
            labelContains: String?,
            identifier: String?
        ) -> NSObject? {
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene else { continue }
                for window in windowScene.windows where !window.isHidden {
                    if
                        let found = findInAccessibilityTree(
                            window,
                            label: label,
                            labelContains: labelContains,
                            identifier: identifier
                        ) {
                        return found
                    }
                }
            }
            return nil
        }

        /// Recursively search the accessibility tree for a matching element.
        /// Searches BOTH accessibility children AND UIView subviews to find
        /// elements in presented controllers (e.g., confirmation dialogs).
        private func findInAccessibilityTree(
            _ obj: NSObject,
            label: String?,
            labelContains: String?,
            identifier: String?,
            depth: Int = 0
        ) -> NSObject? {
            guard depth < 30 else { return nil }

            // Check identifier on ALL NSObjects (not just accessibility elements),
            // because SwiftUI sets .accessibilityIdentifier on internal types that
            // aren't UIView or UIAccessibilityElement.
            // Use responds(to:) guard + KVC since accessibilityIdentifier is from UIAccessibilityIdentification protocol.
            if
                let identifier,
                obj.responds(to: Selector("accessibilityIdentifier")),
                let objId = obj.value(forKey: "accessibilityIdentifier") as? String,
                objId == identifier {
                return obj
            }

            if obj.isAccessibilityElement {
                let objLabel = obj.accessibilityLabel ?? ""

                // Check match criteria
                if let label, objLabel == label { return obj }
                if let labelContains, objLabel.localizedCaseInsensitiveContains(labelContains) { return obj }

                // Don't recurse into accessibility elements (they are leaf nodes)
                return nil
            }

            // Not an accessibility element - recurse into children.
            // Search BOTH accessibility children AND UIView subviews because
            // presented controllers (confirmation dialogs, action sheets) live
            // in the subview tree but may not appear in accessibility children.
            var visited = Set<ObjectIdentifier>()

            let elementCount = obj.accessibilityElementCount()
            if elementCount > 0 && elementCount != NSNotFound {
                for i in 0..<elementCount {
                    if
                        let child = obj.accessibilityElement(at: i) as? NSObject {
                        visited.insert(ObjectIdentifier(child))
                        if
                            let found = findInAccessibilityTree(
                                child, label: label, labelContains: labelContains,
                                identifier: identifier, depth: depth + 1
                            ) {
                            return found
                        }
                    }
                }
            }

            // Also search UIView subviews (skip already-visited accessibility children)
            if let view = obj as? UIView {
                for subview in view.subviews where !subview.isHidden {
                    guard !visited.contains(ObjectIdentifier(subview)) else { continue }
                    if
                        let found = findInAccessibilityTree(
                            subview, label: label, labelContains: labelContains,
                            identifier: identifier, depth: depth + 1
                        ) {
                        return found
                    }
                }
            }

            return nil
        }

        // MARK: - Describe UI

        private func describeUI() -> String {
            var elements: [[String: Any]] = []
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene else { continue }
                for window in windowScene.windows where !window.isHidden {
                    elements.append(contentsOf: walkAccessibility(window))
                }
            }

            let screenSize = UIScreen.main.bounds.size
            let result: [String: Any] = [
                "elements": elements,
                "screenSize": ["width": screenSize.width, "height": screenSize.height],
            ]

            if
                let data = try? JSONSerialization.data(withJSONObject: result),
                let json = String(data: data, encoding: .utf8) {
                return json
            }
            return "{\"elements\":[],\"screenSize\":{\"width\":0,\"height\":0}}"
        }

        private func walkAccessibility(_ obj: NSObject, depth: Int = 0) -> [[String: Any]] {
            guard depth < 30 else { return [] }

            if obj.isAccessibilityElement {
                var info: [String: Any] = ["role": roleString(from: obj.accessibilityTraits)]

                if let label = obj.accessibilityLabel, !label.isEmpty {
                    info["label"] = label
                }
                if
                    obj.responds(to: Selector("accessibilityIdentifier")),
                    let id = obj.value(forKey: "accessibilityIdentifier") as? String, !id.isEmpty {
                    info["identifier"] = id
                }
                if let value = obj.accessibilityValue, !value.isEmpty {
                    info["value"] = value
                }

                let frame = obj.accessibilityFrame
                if frame != .zero && !frame.isNull && !frame.isInfinite {
                    info["frame"] = [
                        "x": frame.origin.x,
                        "y": frame.origin.y,
                        "width": frame.size.width,
                        "height": frame.size.height,
                    ]
                } else if let view = obj as? UIView {
                    let converted = view.convert(view.bounds, to: nil)
                    info["frame"] = [
                        "x": converted.origin.x,
                        "y": converted.origin.y,
                        "width": converted.size.width,
                        "height": converted.size.height,
                    ]
                }

                return [info]
            }

            // Not an accessibility element - recurse into BOTH accessibility children
            // AND UIView subviews. Presented controllers (confirmation dialogs) live
            // in the subview tree but may not appear in accessibility children.
            var results: [[String: Any]] = []
            var visited = Set<ObjectIdentifier>()

            let elementCount = obj.accessibilityElementCount()
            if elementCount > 0 && elementCount != NSNotFound {
                for i in 0..<elementCount {
                    if let child = obj.accessibilityElement(at: i) as? NSObject {
                        visited.insert(ObjectIdentifier(child))
                        results.append(contentsOf: walkAccessibility(child, depth: depth + 1))
                    }
                }
            }

            // Also walk UIView subviews (skip already-visited accessibility children)
            if let view = obj as? UIView {
                for subview in view.subviews where !subview.isHidden {
                    guard !visited.contains(ObjectIdentifier(subview)) else { continue }
                    results.append(contentsOf: walkAccessibility(subview, depth: depth + 1))
                }
            }

            return results
        }

        private func roleString(from traits: UIAccessibilityTraits) -> String {
            if traits.contains(.button) { return "AXButton" }
            if traits.contains(.staticText) { return "AXStaticText" }
            if traits.contains(.image) { return "AXImage" }
            if traits.contains(.link) { return "AXLink" }
            if traits.contains(.searchField) { return "AXTextField" }
            if traits.contains(.tabBar) { return "AXTabGroup" }
            if traits.contains(.adjustable) { return "AXSlider" }
            return "AXGroup"
        }

        // MARK: - URL Parsing

        /// Extract a query parameter from a raw HTTP request line.
        private nonisolated static func extractQueryParam(from request: String, key: String) -> String? {
            guard let requestLine = request.components(separatedBy: "\r\n").first else { return nil }
            guard let questionMark = requestLine.firstIndex(of: "?") else { return nil }
            let afterQuestion = requestLine[requestLine.index(after: questionMark)...]
            let queryString = afterQuestion.components(separatedBy: " ").first ?? String(afterQuestion)
            for pair in queryString.components(separatedBy: "&") {
                let parts = pair.components(separatedBy: "=")
                guard parts.count == 2, parts[0] == key else { continue }
                let decoded = parts[1]
                    .replacingOccurrences(of: "+", with: " ")
                    .removingPercentEncoding ?? parts[1]
                return decoded
            }
            return nil
        }
    }

    // MARK: - UIView Extension

    extension UIView {
        /// Find the first responder in the view hierarchy
        func findFirstResponder() -> UIResponder? {
            if isFirstResponder { return self }
            for subview in subviews {
                if let responder = subview.findFirstResponder() {
                    return responder
                }
            }
            return nil
        }
    }
#endif
