import ApplicationServices
import Foundation
import Logging

/// AXUIElement-based accessibility for the macOS app
/// Uses the same underlying APIs as SimulatorAccessibility but targets the macOS app directly
enum MacOSAccessibility {
    private static let logger = Logger(label: "e2e.macos-accessibility")

    /// Get the UI element tree for the macOS app
    static func describeUI(appPID: pid_t, maxDepth: Int = 10) -> [UIElement] {
        let appElement = AXUIElementCreateApplication(appPID)
        let children = SimulatorAccessibility.getChildren(of: appElement)
        return children.compactMap { child in
            SimulatorAccessibility.parseElement(child, depth: 0, maxDepth: maxDepth)
        }
    }

    /// Find an element by query in the macOS app
    static func findElement(appPID: pid_t, matching query: ElementQuery) -> UIElement? {
        let elements = describeUI(appPID: appPID)
        return query.findFirst(in: elements)
    }
}
