import CoreGraphics
import Foundation
import Logging

/// Finds and manages the Simulator window for coordinate conversion
enum SimulatorWindow {
    private static let logger = Logger(label: "e2e.sim-window")

    /// Information about the Simulator window
    struct WindowInfo: Sendable {
        let windowID: CGWindowID
        let bounds: CGRect
        let ownerPID: pid_t
    }

    /// Find the main Simulator window
    static func findSimulatorWindow(pid: pid_t) -> WindowInfo? {
        guard
            let windowList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]] else {
            return nil
        }

        for windowInfo in windowList {
            guard
                let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                ownerPID == pid,
                let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID,
                let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: Any],
                let x = boundsDict["X"] as? CGFloat,
                let y = boundsDict["Y"] as? CGFloat,
                let width = boundsDict["Width"] as? CGFloat,
                let height = boundsDict["Height"] as? CGFloat
            else {
                continue
            }

            // Skip small windows (toolbars, etc.)
            guard width > 200, height > 200 else { continue }

            return WindowInfo(
                windowID: windowID,
                bounds: CGRect(x: x, y: y, width: width, height: height),
                ownerPID: ownerPID
            )
        }

        return nil
    }

    /// Convert an iOS-content-relative point to absolute screen coordinates
    /// - Parameters:
    ///   - point: Point relative to the iOS content group origin
    ///   - contentOrigin: The screen origin of the iOSContentGroup
    /// - Returns: Absolute screen coordinates suitable for CGEvent
    static func toScreenCoordinates(point: CGPoint, contentOrigin: CGPoint) -> CGPoint {
        CGPoint(
            x: contentOrigin.x + point.x,
            y: contentOrigin.y + point.y
        )
    }
}
