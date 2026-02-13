#if canImport(AppKit)
    #if DEBUG
        import AppKit
        import Foundation
        import Network

        /// Lightweight HTTP server that exposes the macOS app's accessibility tree for E2E testing.
        ///
        /// When the macOS Accessibility API cannot read window content (broken on Xcode 26.x),
        /// the E2E framework queries this HTTP endpoint to discover UI elements and their positions.
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
                    print("[TestAccessibilityServer-Mac] Failed to start: \(error)")
                }
            }

            private func start() throws {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                listener = try NWListener(using: params, on: 18_081)
                listener?.stateUpdateHandler = { state in
                    if case let .failed(error) = state {
                        print("[TestAccessibilityServer-Mac] Listener failed: \(error)")
                    }
                }
                listener?.newConnectionHandler = { [weak self] connection in
                    self?.handleConnection(connection)
                }
                listener?.start(queue: .main)
                print("[TestAccessibilityServer-Mac] Listening on port 18081")
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
                                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                            var response = Data(header.utf8)
                            response.append(body)
                            connection.send(content: response, completion: .contentProcessed { _ in
                                connection.cancel()
                            })
                        }
                    } else if request.hasPrefix("POST /click") {
                        // Extract the title from query string: POST /click?title=Remote+Access
                        let title = Self.extractQueryParam(from: request, key: "title")
                        Task { @MainActor [weak self] in
                            let success = self?.performClick(titled: title ?? "") ?? false
                            let body = success ? "clicked" : "not_found"
                            let response = Data(
                                "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n\(body)"
                                    .utf8)
                            connection.send(content: response, completion: .contentProcessed { _ in
                                connection.cancel()
                            })
                        }
                    } else if request.hasPrefix("POST /unpair") {
                        Task { @MainActor in
                            NotificationCenter.default.post(
                                name: .init("com.claudespy.e2e.unpairViewer"), object: nil
                            )
                            let response = Data(
                                "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
                                    .utf8)
                            connection.send(content: response, completion: .contentProcessed { _ in
                                connection.cancel()
                            })
                        }
                    } else if request.hasPrefix("POST /resize-window") {
                        let widthStr = Self.extractQueryParam(from: request, key: "width")
                        let heightStr = Self.extractQueryParam(from: request, key: "height")
                        Task { @MainActor in
                            let width = Int(widthStr ?? "") ?? 0
                            let height = Int(heightStr ?? "") ?? 0
                            var resized = false
                            if width > 0, height > 0 {
                                for window in NSApp.windows
                                    where window.isVisible && window.level == .normal {
                                    var frame = window.frame
                                    frame.size = NSSize(width: width, height: height)
                                    window.setFrame(frame, display: true)
                                    resized = true
                                    break
                                }
                            }
                            let body = resized ? "resized" : "not_found"
                            let response = Data(
                                "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n\(body)"
                                    .utf8)
                            connection.send(content: response, completion: .contentProcessed { _ in
                                connection.cancel()
                            })
                        }
                    } else if request.hasPrefix("POST /activate") {
                        Task { @MainActor in
                            NSApp.setActivationPolicy(.regular)
                            NSApp.activate()
                            for window in NSApp.windows
                                where window.isVisible && window.level == .normal {
                                window.orderFrontRegardless()
                            }
                            let response =
                                Data(
                                    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
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

            private func describeUI() -> String {
                var windows: [[String: Any]] = []

                for window in NSApp.windows where window.isVisible && window.level == .normal {
                    let title = window.title
                    let frame = window.frame
                    // Convert from macOS bottom-left origin to top-left origin
                    let screenHeight = NSScreen.main?.frame.height ?? 0
                    let flippedY = screenHeight - frame.origin.y - frame.height

                    var windowInfo: [String: Any] = [
                        "title": title,
                        "frame": [
                            "x": frame.origin.x,
                            "y": flippedY,
                            "width": frame.size.width,
                            "height": frame.size.height,
                        ],
                    ]

                    var elements: [[String: Any]] = []

                    // Walk toolbar items (separate from contentView)
                    if let toolbar = window.toolbar {
                        for item in toolbar.items {
                            let label = item.label
                            guard !label.isEmpty else { continue }
                            // Get the toolbar item's view frame in screen coordinates
                            if let itemView = item.value(forKey: "view") as? NSView {
                                let windowFrame = itemView.convert(itemView.bounds, to: nil)
                                let screenRect = window.convertToScreen(windowFrame)
                                let flippedY = screenHeight - screenRect.origin.y - screenRect.height
                                elements.append([
                                    "role": "AXButton",
                                    "title": label,
                                    "frame": [
                                        "x": screenRect.origin.x,
                                        "y": flippedY,
                                        "width": screenRect.size.width,
                                        "height": screenRect.size.height,
                                    ],
                                ])
                            }
                        }
                    }

                    // Walk the accessibility tree (not the view hierarchy) to capture SwiftUI content
                    if let children = window.accessibilityChildren() {
                        elements.append(
                            contentsOf: walkAccessibilityTree(children, screenHeight: screenHeight))
                    }

                    // Walk the view hierarchy to find NSOutlineView rows (SwiftUI sidebar List)
                    // which aren't exposed through the accessibility tree wrapper
                    if let contentView = window.contentView {
                        elements.append(
                            contentsOf: findSidebarRows(in: contentView, screenHeight: screenHeight))
                    }

                    windowInfo["elements"] = elements

                    windows.append(windowInfo)
                }

                let result: [String: Any] = ["windows": windows]
                if
                    let data = try? JSONSerialization.data(withJSONObject: result),
                    let json = String(data: data, encoding: .utf8) {
                    return json
                }
                return "{\"windows\":[]}"
            }

            /// Perform a click on the first element matching the given title/label/help.
            /// Sends a synthetic mouse-down/up event to the view's center inside the app.
            private func performClick(titled searchTitle: String) -> Bool {
                guard !searchTitle.isEmpty else { return false }
                print("[TestAccessibilityServer-Mac] performClick: searching for '\(searchTitle)'")

                // Include popup windows (SwiftUI Menu creates popup-level windows)
                for window in NSApp.windows where window.isVisible {
                    // Check toolbar items first
                    if let toolbar = window.toolbar {
                        for item in toolbar.items where item.label == searchTitle {
                            if let itemView = item.value(forKey: "view") as? NSView {
                                print("[TestAccessibilityServer-Mac] performClick: found toolbar item '\(searchTitle)'")
                                sendClick(to: itemView, in: window)
                                return true
                            }
                        }
                    }

                    // Try sidebar/outline rows: walk the NSView hierarchy to find the
                    // row, then use accessibilityPerformPress() on the Button inside it.
                    // NSOutlineView doesn't expose rows via accessibilityChildren(), so
                    // the generic tree walker below can't reach them.
                    if let contentView = window.contentView {
                        if let pressed = findAndPressOutlineButton(in: contentView, titled: searchTitle) {
                            print("[TestAccessibilityServer-Mac] performClick: pressed outline button '\(searchTitle)' (\(pressed))")
                            return true
                        }
                    }

                    // Walk the accessibility tree to find the element
                    if let children = window.accessibilityChildren() {
                        if let found = findAccessibleElement(in: children, titled: searchTitle) {
                            print("[TestAccessibilityServer-Mac] performClick: found '\(searchTitle)' via accessibility tree")
                            // If it's an NSView, send a click event
                            if let view = found as? NSView {
                                sendClick(to: view, in: window)
                                return true
                            }
                            // Otherwise try accessibilityPerformPress() via dynamic dispatch
                            if found.accessibilityPerformPress?() == true {
                                return true
                            }
                            // Last resort: use the element's accessibility frame to click at its center
                            let frame = found.accessibilityFrame?() ?? .zero
                            if frame != .zero && !frame.isNull {
                                print("[TestAccessibilityServer-Mac] performClick: clicking via accessibilityFrame for '\(searchTitle)'")
                                sendClickAtScreenPoint(frame, in: window)
                                return true
                            }
                        }
                    }
                }
                // Debug: print all visible windows when element not found
                let visibleWindows = NSApp.windows.filter { $0.isVisible }
                print("[TestAccessibilityServer-Mac] performClick: NOT FOUND '\(searchTitle)' — \(visibleWindows.count) visible windows:")
                for window in visibleWindows {
                    print("  - '\(window.title)' level=\(window.level.rawValue) frame=\(window.frame)")
                }
                return false
            }

            /// Send a synthetic mouse click at the center of an accessibility frame (screen coordinates).
            /// Used when the element is not an NSView (e.g., SwiftUI AccessibilityNode).
            private func sendClickAtScreenPoint(_ screenFrame: CGRect, in window: NSWindow) {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()

                // accessibilityFrame is in screen coordinates (bottom-left origin)
                let screenCenter = CGPoint(x: screenFrame.midX, y: screenFrame.midY)
                // Convert screen coordinates to window coordinates
                let screenRect = NSRect(origin: screenCenter, size: .zero)
                let windowRect = window.convertFromScreen(screenRect)
                let windowPoint = windowRect.origin

                let mouseDown = NSEvent.mouseEvent(
                    with: .leftMouseDown,
                    location: windowPoint,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1
                )
                let mouseUp = NSEvent.mouseEvent(
                    with: .leftMouseUp,
                    location: windowPoint,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 0
                )

                if let mouseDown {
                    NSApp.postEvent(mouseDown, atStart: false)
                }
                if let mouseUp {
                    NSApp.postEvent(mouseUp, atStart: false)
                }
            }

            /// Send a synthetic mouse click to the center of a view.
            /// Posts events to the app event queue to avoid blocking on tracking loops.
            private func sendClick(to view: NSView, in window: NSWindow) {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()

                // Calculate the click point in window coordinates
                let boundsCenter = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
                let windowPoint = view.convert(boundsCenter, to: nil)

                let mouseDown = NSEvent.mouseEvent(
                    with: .leftMouseDown,
                    location: windowPoint,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1
                )
                let mouseUp = NSEvent.mouseEvent(
                    with: .leftMouseUp,
                    location: windowPoint,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 0
                )

                // Post to the event queue (non-blocking) instead of sendEvent (blocking).
                // sendEvent enters a tracking run loop for mouseDown and deadlocks.
                if let mouseDown {
                    NSApp.postEvent(mouseDown, atStart: false)
                }
                if let mouseUp {
                    NSApp.postEvent(mouseUp, atStart: false)
                }
            }

            /// Find an accessible element matching the given title/label/help in the accessibility tree.
            /// Uses AnyObject dynamic dispatch to support SwiftUI's AccessibilityNode types
            /// which don't conform to NSAccessibilityProtocol but respond to accessibility selectors.
            private func findAccessibleElement(
                in elements: [Any],
                titled searchTitle: String,
                depth: Int = 0
            ) -> AnyObject? {
                guard depth < 30 else { return nil }

                for element in elements {
                    let obj = element as AnyObject
                    let label = obj.accessibilityLabel?() ?? ""
                    let title = obj.accessibilityTitle?() ?? ""
                    let value = (obj.accessibilityValue?() as Any?) as? String ?? ""
                    let help = obj.accessibilityHelp?() ?? ""

                    if
                        title.contains(searchTitle) || label.contains(searchTitle)
                        || value.contains(searchTitle) || help == searchTitle {
                        return obj
                    }

                    if let children = obj.accessibilityChildren?() as? [Any], !children.isEmpty {
                        if
                            let found = findAccessibleElement(
                                in: children, titled: searchTitle, depth: depth + 1
                            ) {
                            return found
                        }
                    }
                }
                return nil
            }

            /// Extract a query parameter from a raw HTTP request line.
            /// e.g. "POST /click?title=Remote+Access HTTP/1.1\r\n..." → "Remote Access"
            private nonisolated static func extractQueryParam(from request: String, key: String) -> String? {
                // Get the first line (request line)
                guard let requestLine = request.components(separatedBy: "\r\n").first else { return nil }
                // Find the query string after '?'
                guard let questionMark = requestLine.firstIndex(of: "?") else { return nil }
                let afterQuestion = requestLine[requestLine.index(after: questionMark)...]
                // Remove the " HTTP/1.1" suffix
                let queryString = afterQuestion.components(separatedBy: " ").first ?? String(afterQuestion)
                // Parse key=value pairs
                for pair in queryString.components(separatedBy: "&") {
                    let parts = pair.components(separatedBy: "=")
                    guard parts.count == 2, parts[0] == key else { continue }
                    // Decode URL encoding: + → space, then percent-decode
                    let decoded = parts[1]
                        .replacingOccurrences(of: "+", with: " ")
                        .removingPercentEncoding ?? parts[1]
                    return decoded
                }
                return nil
            }

            /// Walk the accessibility tree (not the view hierarchy) to find all accessible elements.
            /// This correctly discovers SwiftUI content inside Forms, which isn't in the NSView subview tree.
            private func walkAccessibilityTree(
                _ elements: [Any],
                screenHeight: CGFloat,
                depth: Int = 0
            ) -> [[String: Any]] {
                guard depth < 30 else { return [] }

                var results: [[String: Any]] = []

                for element in elements {
                    let obj = element as AnyObject
                    let role = (obj.accessibilityRole?()?.rawValue) ?? ""
                    let label = obj.accessibilityLabel?() ?? ""
                    let title = obj.accessibilityTitle?() ?? ""
                    let value = (obj.accessibilityValue?() as Any?) as? String ?? ""
                    let help = obj.accessibilityHelp?() ?? ""
                    let identifier: String
                    if let view = obj as? NSView {
                        identifier = view.accessibilityIdentifier()
                    } else {
                        identifier = ""
                    }

                    let hasMeaningfulInfo = !label.isEmpty || !title.isEmpty || !identifier.isEmpty
                        || !value.isEmpty || !help.isEmpty

                    if hasMeaningfulInfo {
                        var info: [String: Any] = ["role": role]
                        if !label.isEmpty { info["label"] = label }
                        if !title.isEmpty { info["title"] = title }
                        if !value.isEmpty { info["value"] = value }
                        if !identifier.isEmpty { info["identifier"] = identifier }
                        if !help.isEmpty { info["help"] = help }

                        let frame = obj.accessibilityFrame?() ?? .zero
                        if frame != .zero && !frame.isNull && !frame.isInfinite {
                            let flippedY = screenHeight - frame.origin.y - frame.height
                            info["frame"] = [
                                "x": frame.origin.x,
                                "y": flippedY,
                                "width": frame.size.width,
                                "height": frame.size.height,
                            ]
                        }

                        results.append(info)
                    }

                    // Recurse into accessibility children
                    if let children = obj.accessibilityChildren?() as? [Any], !children.isEmpty {
                        results.append(
                            contentsOf: walkAccessibilityTree(
                                children, screenHeight: screenHeight, depth: depth + 1
                            ))
                    }
                }

                return results
            }

            /// Walk the NSView hierarchy to find an NSOutlineView row matching the title,
            /// then locate the AXButton inside it and call accessibilityPerformPress().
            /// Returns a description of what was pressed, or nil if not found.
            private func findAndPressOutlineButton(in view: NSView, titled searchTitle: String) -> String? {
                if view.accessibilityRole() == .outline {
                    for rowView in view.subviews {
                        let texts = collectAccessibilityTexts(from: rowView)
                        if texts.contains(where: { $0.contains(searchTitle) }) {
                            // Found the row — now find the button in its accessibility children
                            if let button = findPressableElement(in: rowView) {
                                if button.accessibilityPerformPress?() == true {
                                    return "accessibilityPerformPress on button"
                                }
                            }
                        }
                    }
                    return nil
                }
                for subview in view.subviews {
                    if let result = findAndPressOutlineButton(in: subview, titled: searchTitle) {
                        return result
                    }
                }
                return nil
            }

            /// Recursively search a view's accessibility children for a pressable element (AXButton).
            private func findPressableElement(in view: NSView, depth: Int = 0) -> AnyObject? {
                guard depth < 10 else { return nil }
                guard let children = view.accessibilityChildren() as? [AnyObject] else { return nil }
                for child in children {
                    if child.accessibilityRole?() == .button {
                        return child
                    }
                    if let nested = child.accessibilityChildren?() as? [AnyObject], !nested.isEmpty {
                        for nestedChild in nested where nestedChild.accessibilityRole?() == .button {
                            return nestedChild
                        }
                    }
                }
                // Also check subviews if the view has them
                for subview in view.subviews {
                    if let found = findPressableElement(in: subview, depth: depth + 1) {
                        return found
                    }
                }
                return nil
            }

            /// Walk the view hierarchy to find outline list views and extract row content.
            /// SwiftUI sidebar uses ListTableRowView → ListTableCellView → CellHostingView
            /// which renders text via accessibility children, not NSTextField subviews.
            private func findSidebarRows(
                in view: NSView,
                screenHeight: CGFloat
            ) -> [[String: Any]] {
                var results: [[String: Any]] = []

                if view.accessibilityRole() == .outline {
                    // Walk the outline view's subviews (ListTableRowView instances)
                    for rowView in view.subviews {
                        let texts = collectAccessibilityTexts(from: rowView)
                        guard !texts.isEmpty else { continue }
                        let label = texts.joined(separator: " ")

                        let windowRect = rowView.convert(rowView.bounds, to: nil)
                        let screenRect = rowView.window?.convertToScreen(windowRect) ?? windowRect
                        let flippedY = screenHeight - screenRect.origin.y - screenRect.height

                        results.append([
                            "role": "AXRow",
                            "label": label,
                            "frame": [
                                "x": screenRect.origin.x,
                                "y": flippedY,
                                "width": screenRect.size.width,
                                "height": screenRect.size.height,
                            ],
                        ])
                    }
                    return results
                }

                for subview in view.subviews {
                    results.append(contentsOf: findSidebarRows(in: subview, screenHeight: screenHeight))
                }

                return results
            }

            /// Collect unique text from a view's accessibility tree.
            /// SwiftUI cells render text through CellHostingView which exposes text
            /// via accessibility children, not NSTextField subviews.
            /// Uses ordered deduplication since both the accessibility tree and
            /// NSView subview walks can surface the same text.
            private func collectAccessibilityTexts(from view: NSView) -> [String] {
                var seen = Set<String>()
                var texts: [String] = []

                func add(_ text: String) {
                    guard !text.isEmpty, seen.insert(text).inserted else { return }
                    texts.append(text)
                }

                add(view.accessibilityLabel() ?? "")
                if let v = view.accessibilityValue() as? String { add(v) }

                // Walk accessibility children for SwiftUI-hosted content
                if let children = view.accessibilityChildren() {
                    for child in children {
                        let obj = child as AnyObject
                        add(obj.accessibilityLabel?() ?? "")
                        add((obj.accessibilityValue?() as Any?) as? String ?? "")
                        if let grandChildren = obj.accessibilityChildren?() as? [Any] {
                            for gc in grandChildren {
                                let gcObj = gc as AnyObject
                                add(gcObj.accessibilityLabel?() ?? "")
                                add((gcObj.accessibilityValue?() as Any?) as? String ?? "")
                            }
                        }
                    }
                }

                // Also recurse into NSView subviews
                for subview in view.subviews {
                    for text in collectAccessibilityTexts(from: subview) {
                        add(text)
                    }
                }

                return texts
            }
        }
    #endif
#endif
