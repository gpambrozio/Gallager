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

    /// Diagnose why a query didn't match — returns info about partial matches.
    /// For `.allOf` queries, checks each sub-query individually.
    static func diagnoseQuery(appPID: pid_t, query: ElementQuery) -> String {
        let elements = describeUI(appPID: appPID)
        switch query {
        case let .allOf(subQueries):
            var parts: [String] = []
            for sub in subQueries {
                if let match = sub.findFirst(in: elements) {
                    let valueSnippet = match.value.map { String($0.prefix(200)) } ?? "nil"
                    parts.append("  \(sub): FOUND (value=\(valueSnippet))")
                } else {
                    parts.append("  \(sub): NOT FOUND")
                }
            }
            return parts.joined(separator: "\n")
        default:
            let totalElements = countElements(elements)
            return "  Total AX elements: \(totalElements), no match for \(query)"
        }
    }

    private static func countElements(_ elements: [UIElement]) -> Int {
        elements.reduce(0) { $0 + 1 + countElements($1.children) }
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

    /// Check if any top-level window has a title that matches exactly.
    /// Used to assert on `navigationTitle` precisely (no substring collisions
    /// with other windows or in-window text).
    static func windowExists(appPID: pid_t, titledExactly title: String) -> Bool {
        windows(appPID: appPID).contains { $0.title == title }
    }

    /// Returns the titles of all top-level windows. Useful for diagnostics.
    static func windowTitles(appPID: pid_t) -> [String] {
        windows(appPID: appPID).map(\.title)
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
    /// Excludes the app menu bar so user-specific entries (Apple menu →
    /// Recent Items, Open Recent, Window list, etc.) can't substring-match
    /// queries intended for window content. Tests that need to interact with
    /// menu bar items use AppleScript or open the menu first — its popup
    /// appears outside the menu bar subtree.
    static func findAllRawElements(appPID: pid_t, matching query: ElementQuery) -> [AXUIElement] {
        let roots = allRootElements(appPID: appPID).filter { roleOf($0) != "AXMenuBar" }
        var results: [AXUIElement] = []
        collectRawElementsInChildren(roots, matching: query, depth: 0, maxDepth: 20, results: &results)
        return results
    }

    /// Perform AXPress on an element matching the query.
    /// Prioritizes AXButton elements to avoid accidentally triggering actions on
    /// non-interactive ancestors (e.g. outline view disclosure toggles on section headers).
    /// Falls back to CGEvent click at the first match with a frame.
    @discardableResult
    static func press(appPID: pid_t, matching query: ElementQuery) -> Bool {
        let matches = findAllRawElements(appPID: appPID, matching: query)
        guard !matches.isEmpty else {
            logger.info("AXPress: element not found for \(query)")
            return false
        }

        // Partition matches: try buttons/checkboxes first, then other elements.
        // This prevents substring matches on section header text (e.g. "Terminals")
        // from triggering outline view disclosure collapse via pressOrWalkParents,
        // when the intended target is a button further down the tree.
        let (buttons, others) = partitionByRole(matches)
        let orderedMatches = buttons + others

        // Try AXPress on each match and its ancestors
        if orderedMatches.first(where: { pressOrWalkParents($0) }) != nil {
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

    /// Post a CGEvent scroll wheel event at the given screen coordinates.
    /// Positive `deltaY` scrolls up; negative scrolls down.
    static func scrollWheel(at point: CGPoint, deltaY: Int32) {
        logger.info("CGEvent scroll wheel at (\(point.x), \(point.y)), deltaY=\(deltaY)")
        guard
            let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .line,
                wheelCount: 1,
                wheel1: deltaY,
                wheel2: 0,
                wheel3: 0
            ) else {
            logger.warning("Failed to create scroll wheel event")
            return
        }
        event.location = point
        event.post(tap: .cghidEventTap)
    }

    /// Post CGEvent drag from one screen coordinate to another.
    /// Generates mouseDown at `from`, intermediate leftMouseDragged events, and mouseUp at `to`.
    static func drag(from start: CGPoint, to end: CGPoint, steps: Int = 20) {
        logger.info("CGEvent drag from (\(start.x), \(start.y)) to (\(end.x), \(end.y)), steps=\(steps)")

        let dx = (end.x - start.x) / CGFloat(steps)
        let dy = (end.y - start.y) / CGFloat(steps)

        let mouseDown = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: start,
            mouseButton: .left
        )
        mouseDown?.post(tap: .cghidEventTap)

        for i in 1...steps {
            let point = CGPoint(
                x: start.x + dx * CGFloat(i),
                y: start.y + dy * CGFloat(i)
            )
            let dragEvent = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDragged,
                mouseCursorPosition: point,
                mouseButton: .left
            )
            dragEvent?.post(tap: .cghidEventTap)
            usleep(16_000) // ~60fps
        }

        let mouseUp = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: end,
            mouseButton: .left
        )
        mouseUp?.post(tap: .cghidEventTap)
    }

    /// CGEvent drag from the center of one matched element to the center of
    /// another. Used by scenarios that exercise SwiftUI's `.draggable` /
    /// `.dropDestination` machinery (e.g. tab strip reorder in issue #510)
    /// since AX has no native "move element" action — the drag has to be
    /// driven through hardware-style mouse events.
    @discardableResult
    static func dragElement(
        appPID: pid_t,
        from fromQuery: ElementQuery,
        to toQuery: ElementQuery
    ) -> Bool {
        let fromMatches = findAllRawElements(appPID: appPID, matching: fromQuery)
        let toMatches = findAllRawElements(appPID: appPID, matching: toQuery)
        guard
            let fromCenter = fromMatches.lazy.compactMap({ centerOfElement($0) }).first,
            let toCenter = toMatches.lazy.compactMap({ centerOfElement($0) }).first
        else {
            logger.info("dragElement: \(fromQuery) → \(toQuery) — at least one element not found")
            return false
        }
        focusApp(appPID: appPID)
        usleep(200_000) // 200ms for focus
        // Use a longer step count so SwiftUI's drag pickup threshold (a few
        // pixels of movement before the operation registers) is comfortably
        // exceeded before the cursor reaches the destination.
        drag(from: fromCenter, to: toCenter, steps: 30)
        return true
    }

    /// CGEvent left-click on an element matching the query.
    /// Unlike `press`, this always uses a real mouse click (no AXPress / parent walking).
    /// Useful for selecting items in SwiftUI List/OutlineGroup where AXPress
    /// on ancestor elements toggles disclosure instead of selecting.
    @discardableResult
    static func cgClick(
        appPID: pid_t,
        matching query: ElementQuery,
        pointInRect: (CGRect) -> CGPoint = { CGPoint(x: $0.midX, y: $0.midY) }
    ) -> Bool {
        let matches = findAllRawElements(appPID: appPID, matching: query)
        guard let frame = matches.lazy.compactMap({ frameOfElement($0) }).first else {
            logger.info("cgClick: element not found for \(query)")
            return false
        }
        focusApp(appPID: appPID)
        usleep(200_000) // 200ms for focus
        clickAtPoint(pointInRect(frame))
        return true
    }

    /// CGEvent left-click on an element matching by "titled" text.
    @discardableResult
    static func cgClick(appPID: pid_t, titled: String) -> Bool {
        cgClick(appPID: appPID, matching: .anyTextMatches(titled))
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

    /// Translate a ``Key`` into its US-keyboard virtual key code.
    /// Returns `nil` only when a `.character` case references a symbol the
    /// table doesn't cover; named keys (Tab, Escape, …) always resolve.
    static func virtualKeyCode(for key: Key) -> UInt16? {
        switch key {
        case .tab: return 48
        case .escape: return 53
        case .return: return 36
        case .space: return 49
        case .downArrow: return 125
        case .upArrow: return 126
        case let .character(character): return virtualKeyCode(forCharacter: character)
        }
    }

    /// Translate a single character to its US-keyboard virtual key code.
    /// Returns `nil` for inputs the table doesn't cover so callers can throw.
    static func virtualKeyCode(forCharacter character: Character) -> UInt16? {
        // `Character.lowercased()` returns a `String` because some scripts (e.g.
        // German `ß` → "ss") expand on lowercasing; ASCII letters are always a
        // single grapheme so the `count == 1` guard simply filters anything we
        // can't map to a virtual key code.
        let loweredString = character.lowercased()
        guard loweredString.count == 1, let lowered = loweredString.first else {
            return nil
        }
        switch lowered {
        case "a": return 0
        case "b": return 11
        case "c": return 8
        case "d": return 2
        case "e": return 14
        case "f": return 3
        case "g": return 5
        case "h": return 4
        case "i": return 34
        case "j": return 38
        case "k": return 40
        case "l": return 37
        case "m": return 46
        case "n": return 45
        case "o": return 31
        case "p": return 35
        case "q": return 12
        case "r": return 15
        case "s": return 1
        case "t": return 17
        case "u": return 32
        case "v": return 9
        case "w": return 13
        case "x": return 7
        case "y": return 16
        case "z": return 6
        case "0": return 29
        case "1": return 18
        case "2": return 19
        case "3": return 20
        case "4": return 21
        case "5": return 23
        case "6": return 22
        case "7": return 26
        case "8": return 28
        case "9": return 25
        case "[": return 33
        case "]": return 30
        case "-": return 27
        case "=": return 24
        case "/": return 44
        case ",": return 43
        case ".": return 47
        case ";": return 41
        case "'": return 39
        default: return nil
        }
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

    // MARK: - Private: Role Partitioning

    /// Interactive AX roles whose elements should be tried before static text/groups.
    private static let interactiveRoles: Set = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXMenuItem",
        "AXPopUpButton", "AXToggle", "AXLink", "AXCell",
    ]

    /// Partition raw AXUIElements into (interactive, other) based on their AX role.
    /// Interactive elements (buttons, checkboxes, etc.) are more likely the intended target
    /// than static text that happens to substring-match.
    private static func partitionByRole(_ elements: [AXUIElement]) -> (interactive: [AXUIElement], other: [AXUIElement]) {
        var interactive: [AXUIElement] = []
        var other: [AXUIElement] = []
        for element in elements {
            if let role = roleOf(element), interactiveRoles.contains(role) {
                interactive.append(element)
            } else {
                other.append(element)
            }
        }
        return (interactive, other)
    }

    /// Get the AX role string of a raw AXUIElement.
    private static func roleOf(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        guard result == .success, let str = value as? String else { return nil }
        return str
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

    /// Get the screen frame of a raw AXUIElement from its position and size attributes.
    private static func frameOfElement(_ element: AXUIElement) -> CGRect? {
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

        return CGRect(origin: position, size: size)
    }

    /// Get the center point of a raw AXUIElement from its position and size attributes.
    private static func centerOfElement(_ element: AXUIElement) -> CGPoint? {
        frameOfElement(element).map { CGPoint(x: $0.midX, y: $0.midY) }
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
