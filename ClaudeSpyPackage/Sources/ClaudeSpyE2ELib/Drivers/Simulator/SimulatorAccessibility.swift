import ApplicationServices
import Foundation
import Logging

/// Traverses the iOS Simulator's AX tree to extract UI elements
enum SimulatorAccessibility {
    private static let logger = Logger(label: "e2e.sim-accessibility")

    /// Get the full UI element tree for the Simulator app's iOS content area
    /// Returns the parsed tree along with the iOS content group's screen origin
    static func describeUI(
        simulatorPID: pid_t,
        maxDepth: Int = 15
    ) -> (elements: [UIElement], contentOrigin: CGPoint?) {
        let appElement = AXUIElementCreateApplication(simulatorPID)

        // Walk the AX tree to find the iOSContentGroup (the actual iOS screen area)
        guard let contentGroup = findIOSContentGroup(in: appElement, depth: 0, maxDepth: 10) else {
            logger.warning("Could not find iOSContentGroup in Simulator AX tree")
            // Fall back to full app tree
            let elements = parseElement(appElement, depth: 0, maxDepth: maxDepth)
            return (elements.map { [$0] } ?? [], nil)
        }

        // Get the content group's frame for coordinate conversion
        let contentFrame = getFrame(of: contentGroup)
        let contentOrigin = contentFrame?.origin

        // Parse the content group's children as the UI tree
        let children = getChildren(of: contentGroup)
        let elements = children.compactMap { child in
            parseElement(child, depth: 0, maxDepth: maxDepth)
        }

        return (elements, contentOrigin)
    }

    /// Find the element with subrole "iOSContentGroup" in the AX tree
    private static func findIOSContentGroup(
        in element: AXUIElement,
        depth: Int,
        maxDepth: Int
    ) -> AXUIElement? {
        guard depth < maxDepth else { return nil }

        if getSubrole(of: element) == "AXiOSContentGroup" {
            return element
        }

        for child in getChildren(of: element) {
            if let found = findIOSContentGroup(in: child, depth: depth + 1, maxDepth: maxDepth) {
                return found
            }
        }

        return nil
    }

    /// Parse an AXUIElement into a UIElement
    static func parseElement(
        _ element: AXUIElement,
        depth: Int,
        maxDepth: Int
    ) -> UIElement? {
        guard depth < maxDepth else { return nil }

        let role = getStringAttribute(of: element, attribute: kAXRoleAttribute as String) ?? "Unknown"
        let subrole = getStringAttribute(of: element, attribute: kAXSubroleAttribute as String)
        let label = getStringAttribute(of: element, attribute: kAXDescriptionAttribute as String)
            ?? getStringAttribute(of: element, attribute: kAXTitleAttribute as String)
        let value = getValueString(of: element)
        let title = getStringAttribute(of: element, attribute: kAXTitleAttribute as String)
        let identifier = getStringAttribute(of: element, attribute: kAXIdentifierAttribute as String)
        let frame = getFrame(of: element) ?? .zero

        let children: [UIElement]
        if depth + 1 < maxDepth {
            children = getChildren(of: element).compactMap { child in
                parseElement(child, depth: depth + 1, maxDepth: maxDepth)
            }
        } else {
            children = []
        }

        return UIElement(
            role: role,
            subrole: subrole,
            label: label,
            value: value,
            title: title,
            identifier: identifier,
            frame: frame,
            children: children
        )
    }

    // MARK: - AX Helpers

    private static func getStringAttribute(of element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let stringValue = value as? String else { return nil }
        return stringValue
    }

    private static func getValueString(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard result == .success else { return nil }
        if let str = value as? String { return str }
        if let num = value as? NSNumber { return num.stringValue }
        return nil
    }

    private static func getSubrole(of element: AXUIElement) -> String? {
        getStringAttribute(of: element, attribute: kAXSubroleAttribute as String)
    }

    private static func getFrame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?

        let posResult = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
        let sizeResult = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)

        guard posResult == .success, sizeResult == .success else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero

        // AXValue wraps CGPoint and CGSize
        if let posValue = positionValue {
            // swiftlint:disable:next force_cast
            AXValueGetValue(posValue as! AXValue, .cgPoint, &position)
        }
        if let szValue = sizeValue {
            // swiftlint:disable:next force_cast
            AXValueGetValue(szValue as! AXValue, .cgSize, &size)
        }

        return CGRect(origin: position, size: size)
    }

    static func getChildren(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        guard result == .success, let children = value as? [AXUIElement] else { return [] }
        return children
    }
}
