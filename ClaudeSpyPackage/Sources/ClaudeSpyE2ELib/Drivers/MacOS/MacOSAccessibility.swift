import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Logging

/// AXUIElement-based accessibility for the macOS app.
///
/// Reads and interacts with the macOS app's UI through the system Accessibility API
/// from an external process, replacing the in-app HTTP accessibility server.
enum MacOSAccessibility {
    private static let logger = Logger(label: "e2e.macos-accessibility")

    // MARK: - Tree Reading

    /// Get the UI element tree for the macOS app.
    /// Searches both `kAXChildren` and `kAXWindows` to ensure popovers, sheets,
    /// and dialogs are included (they may only appear in `kAXWindows`).
    static func describeUI(appPID: pid_t, maxDepth: Int = 15) -> [UIElement] {
        let roots = allRootElements(appPID: appPID)
        return roots.compactMap { child in
            SimulatorAccessibility.parseElement(child, depth: 0, maxDepth: maxDepth)
        }
    }

    /// Find an element by query in the macOS app
    static func findElement(appPID: pid_t, matching query: ElementQuery) -> UIElement? {
        let elements = describeUI(appPID: appPID)
        return query.findFirst(in: elements)
    }

    /// Find an element matching any text field (title, label, value contains; help exact).
    /// Replicates the old MacAppHTTPClient.MacUIElement.matches(titled:) behavior.
    static func findElement(appPID: pid_t, titled: String) -> UIElement? {
        findElement(appPID: appPID, matching: .anyTextMatches(titled))
    }

    // MARK: - Windows

    /// List visible windows with their titles.
    /// AX windows are exposed via `kAXWindowsAttribute` on the app element.
    static func windows(appPID: pid_t) -> [(title: String, element: AXUIElement)] {
        let appElement = AXUIElementCreateApplication(appPID)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let windowElements = value as? [AXUIElement] else { return [] }

        return windowElements.map { window in
            var titleValue: CFTypeRef?
            let titleResult = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
            let title = (titleResult == .success) ? (titleValue as? String ?? "") : ""
            return (title: title, element: window)
        }
    }

    /// Check if a window with the given title exists
    static func windowExists(appPID: pid_t, titled: String) -> Bool {
        windows(appPID: appPID).contains { $0.title.contains(titled) }
    }

    /// Close a window by title via its AXCloseButton attribute.
    @discardableResult
    static func closeWindow(appPID: pid_t, titled: String) -> Bool {
        guard let window = windows(appPID: appPID).first(where: { $0.title.contains(titled) }) else {
            logger.info("No window titled '\(titled)' found for close")
            return false
        }
        var closeButton: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            window.element, kAXCloseButtonAttribute as CFString, &closeButton
        )
        guard result == .success, let button = closeButton else {
            logger.info("No close button found on window '\(titled)'")
            return false
        }
        // swiftlint:disable:next force_cast
        let pressResult = AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        if pressResult == .success {
            logger.info("Closed window '\(titled)'")
            return true
        }
        logger.info("AXPress on close button failed (\(pressResult.rawValue))")
        return false
    }

    // MARK: - Actions

    /// Find all raw AXUIElements matching a query.
    /// Used by `press` to try multiple matches when the first isn't pressable.
    static func findAllRawElements(appPID: pid_t, matching query: ElementQuery) -> [AXUIElement] {
        let roots = allRootElements(appPID: appPID)
        var results: [AXUIElement] = []
        collectRawElementsInChildren(roots, matching: query, depth: 0, maxDepth: 20, results: &results)
        return results
    }

    /// Perform AXPress on an element matching the query.
    /// Tries all matching elements in tree order, walking up parents for each.
    /// This handles cases where the text matches a non-pressable body element
    /// before the actual button (e.g. dialog body text vs the confirm button).
    /// Falls back to CGEvent click at the first match with a frame.
    @discardableResult
    static func press(appPID: pid_t, matching query: ElementQuery) -> Bool {
        let matches = findAllRawElements(appPID: appPID, matching: query)
        guard !matches.isEmpty else {
            logger.info("AXPress: element not found for \(query)")
            return false
        }

        // Try AXPress on each match and its ancestors
        if matches.first(where: { pressOrWalkParents($0) }) != nil {
            logger.info("AXPress succeeded for \(query)")
            return true
        }

        logger.info("AXPress failed for \(query), falling back to CGEvent click")
        // Fall back to CGEvent click — only use element's own frame, not parent frames.
        // Clicking parent frames (like AXSheet center) is unreliable and can miss the button.
        if let center = matches.lazy.compactMap({ centerOfElement($0) }).first {
            focusApp(appPID: appPID)
            usleep(200_000) // 200ms for focus to take effect
            clickAtPoint(center)
            return true
        }
        return false
    }

    /// Perform AXPress or CGEvent click for an element matching by "titled" text.
    @discardableResult
    static func press(appPID: pid_t, titled: String) -> Bool {
        press(appPID: appPID, matching: .anyTextMatches(titled))
    }

    /// Focus a text field by setting kAXFocusedAttribute and falling back to CGEvent click.
    /// Unlike `press`, this gives the element keyboard focus for subsequent typing.
    @discardableResult
    static func focusElement(appPID: pid_t, matching query: ElementQuery) -> Bool {
        let matches = findAllRawElements(appPID: appPID, matching: query)
        guard let element = matches.first else {
            logger.info("focusElement: element not found for \(query)")
            return false
        }

        // Try setting AXFocused attribute first
        let focusResult = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if focusResult == .success {
            logger.info("AXFocused set for \(query)")
            return true
        }

        // Fall back to CGEvent click to give keyboard focus
        if let center = centerOfElement(element) {
            focusApp(appPID: appPID)
            usleep(200_000)
            clickAtPoint(center)
            logger.info("CGEvent click-to-focus for \(query)")
            return true
        }

        logger.info("focusElement failed for \(query)")
        return false
    }

    /// Focus an element matching by "titled" text.
    @discardableResult
    static func focusElement(appPID: pid_t, titled: String) -> Bool {
        focusElement(appPID: appPID, matching: .anyTextMatches(titled))
    }

    /// Post a CGEvent mouse click at the given screen coordinates.
    static func clickAtPoint(_ point: CGPoint) {
        logger.info("CGEvent click at (\(point.x), \(point.y))")
        let mouseDown = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        let mouseUp = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        mouseDown?.post(tap: .cghidEventTap)
        // Small delay between down and up for reliable click registration
        usleep(50_000) // 50ms
        mouseUp?.post(tap: .cghidEventTap)
    }

    /// Post a CGEvent right-click at the given screen coordinates.
    /// Used to trigger context menus on macOS UI elements.
    static func rightClickAtPoint(_ point: CGPoint) {
        logger.info("CGEvent right-click at (\(point.x), \(point.y))")
        let mouseDown = CGEvent(
            mouseEventSource: nil,
            mouseType: .rightMouseDown,
            mouseCursorPosition: point,
            mouseButton: .right
        )
        let mouseUp = CGEvent(
            mouseEventSource: nil,
            mouseType: .rightMouseUp,
            mouseCursorPosition: point,
            mouseButton: .right
        )
        mouseDown?.post(tap: .cghidEventTap)
        usleep(50_000) // 50ms
        mouseUp?.post(tap: .cghidEventTap)
    }

    /// Right-click on an element matching the query to open its context menu.
    /// Returns true if the element was found and right-clicked.
    @discardableResult
    static func rightClick(appPID: pid_t, matching query: ElementQuery) -> Bool {
        let matches = findAllRawElements(appPID: appPID, matching: query)
        guard let center = matches.lazy.compactMap({ centerOfElement($0) }).first else {
            logger.info("rightClick: element not found for \(query)")
            return false
        }
        focusApp(appPID: appPID)
        usleep(200_000) // 200ms for focus
        rightClickAtPoint(center)
        return true
    }

    /// Right-click on an element matching by "titled" text.
    @discardableResult
    static func rightClick(appPID: pid_t, titled: String) -> Bool {
        rightClick(appPID: appPID, matching: .anyTextMatches(titled))
    }

    /// Post a CGEvent key press for the given virtual key code.
    static func pressKey(code: UInt16, modifiers: CGEventFlags = []) {
        let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
        if !modifiers.isEmpty {
            keyDown?.flags = modifiers
            keyUp?.flags = modifiers
        }
        keyDown?.post(tap: .cghidEventTap)
        usleep(50_000)
        keyUp?.post(tap: .cghidEventTap)
    }

    /// Post Cmd+A to select all text in the focused field.
    static func selectAll() {
        // Key code 0 = 'a'
        pressKey(code: 0, modifiers: .maskCommand)
    }

    // MARK: - Window Management

    /// Move the first visible window to a screen position via AX attributes.
    @discardableResult
    static func moveWindow(appPID: pid_t, x: Int, y: Int) -> Bool {
        let allWindows = windows(appPID: appPID)
        guard let firstWindow = allWindows.first else {
            logger.info("No windows found for move")
            return false
        }

        var position = CGPoint(x: x, y: y)
        guard let positionValue = AXValueCreate(.cgPoint, &position) else { return false }
        let result = AXUIElementSetAttributeValue(firstWindow.element, kAXPositionAttribute as CFString, positionValue)
        if result == .success {
            logger.info("Moved window to (\(x), \(y))")
            return true
        }
        logger.info("AX move failed (\(result.rawValue))")
        return false
    }

    /// Resize the first visible window via AX attributes.
    @discardableResult
    static func resizeWindow(appPID: pid_t, width: Int, height: Int) -> Bool {
        let allWindows = windows(appPID: appPID)
        guard let firstWindow = allWindows.first else {
            logger.info("No windows found for resize")
            return false
        }

        var size = CGSize(width: width, height: height)
        guard let sizeValue = AXValueCreate(.cgSize, &size) else { return false }
        let result = AXUIElementSetAttributeValue(firstWindow.element, kAXSizeAttribute as CFString, sizeValue)
        if result == .success {
            logger.info("Resized window to \(width)x\(height)")
            return true
        }
        logger.info("AX resize failed (\(result.rawValue))")
        return false
    }

    /// Bring the app to the foreground.
    static func focusApp(appPID: pid_t) {
        if let app = NSRunningApplication(processIdentifier: appPID) {
            app.activate()
            logger.info("Focused app PID \(appPID)")
        }
    }

    // MARK: - Private: Root Elements

    /// Collect all root-level AXUIElements for the app, combining both
    /// `kAXChildren` and `kAXWindows` to cover popovers, sheets, and dialogs.
    private static func allRootElements(appPID: pid_t) -> [AXUIElement] {
        let appElement = AXUIElementCreateApplication(appPID)
        var roots = SimulatorAccessibility.getChildren(of: appElement)

        // Also include windows that aren't already in children.
        // Popovers and sheets may only appear in kAXWindows.
        var windowsValue: CFTypeRef?
        if
            AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
            let windowElements = windowsValue as? [AXUIElement] {
            for window in windowElements where !roots.contains(where: { CFEqual($0, window) }) {
                roots.append(window)
            }
        }

        return roots
    }

    // MARK: - Private: Parent Walking

    /// Try AXPress on the element, then walk up the parent chain (up to 5 levels)
    /// until we find an element that supports AXPress.
    private static func pressOrWalkParents(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<5 {
            guard let el = current else { return false }
            let result = AXUIElementPerformAction(el, kAXPressAction as CFString)
            if result == .success { return true }
            current = parent(of: el)
        }
        return false
    }

    /// Get the parent AXUIElement via kAXParentAttribute.
    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value)
        guard result == .success else { return nil }
        // AXUIElement is a CFTypeRef, so we need to cast
        return (value as! AXUIElement) // swiftlint:disable:this force_cast
    }

    // MARK: - Private: Element Frame

    /// Get the center point of a raw AXUIElement from its position and size attributes.
    private static func centerOfElement(_ element: AXUIElement) -> CGPoint? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        let posResult = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
        let sizeResult = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
        guard posResult == .success, sizeResult == .success else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        // swiftlint:disable:next force_cast
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        // swiftlint:disable:next force_cast
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)

        return CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
    }

    // MARK: - Private: Raw Element Search

    /// Recursively collect all raw AXUIElements matching the query.
    private static func collectRawElementsInChildren(
        _ children: [AXUIElement],
        matching query: ElementQuery,
        depth: Int,
        maxDepth: Int,
        results: inout [AXUIElement]
    ) {
        guard depth < maxDepth else { return }

        for child in children {
            if let parsed = SimulatorAccessibility.parseElement(child, depth: 0, maxDepth: 1) {
                if query.matches(parsed) {
                    results.append(child)
                }
            }

            let grandchildren = SimulatorAccessibility.getChildren(of: child)
            if !grandchildren.isEmpty {
                collectRawElementsInChildren(grandchildren, matching: query, depth: depth + 1, maxDepth: maxDepth, results: &results)
            }
        }
    }
}
