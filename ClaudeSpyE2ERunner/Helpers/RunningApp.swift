import Foundation
import ObjectiveC
import XCTest

enum RunningApp {
    static let springboardBundleId = "com.apple.springboard"
    static let e2eHostBundleId = "br.eng.gustavo.claudespy.e2ehost"

    /// Get an XCUIApplication for a known bundle ID
    static func getApp(bundleId: String) -> XCUIApplication {
        NSLog("[RunningApp] Using explicit bundleId: \(bundleId)")
        return XCUIApplication(bundleIdentifier: bundleId)
    }

    /// Try to detect the foreground app via the private activeAppsInfo class method
    static func getForegroundApp() -> XCUIApplication? {
        let selector = NSSelectorFromString("activeAppsInfo")

        // Use ObjC runtime to check for the class method directly.
        // Swift's `(XCUIApplication.self as AnyObject).responds(to:)` doesn't
        // reliably find class methods — we must use class_getClassMethod instead.
        guard class_getClassMethod(XCUIApplication.self, selector) != nil else {
            NSLog("[RunningApp] activeAppsInfo class method not found via ObjC runtime")
            return nil
        }

        let cls: AnyObject = XCUIApplication.self
        guard let result = cls.perform(selector)?.takeUnretainedValue() as? [[String: Any]] else {
            NSLog("[RunningApp] activeAppsInfo returned unexpected type")
            return nil
        }

        let runningAppIds = result.compactMap { $0["bundleId"] as? String }
        NSLog("[RunningApp] Detected running apps: \(runningAppIds)")

        // Filter out springboard and the E2E host app
        let appIds = runningAppIds.filter {
            $0 != springboardBundleId && $0 != e2eHostBundleId
        }

        if let bundleId = appIds.first {
            NSLog("[RunningApp] Using foreground app: \(bundleId)")
            return XCUIApplication(bundleIdentifier: bundleId)
        }

        // Fallback: check state of all running apps
        NSLog("[RunningApp] No filtered app, checking state of all \(runningAppIds.count) apps")
        return runningAppIds
            .map { XCUIApplication(bundleIdentifier: $0) }
            .first { $0.state == .runningForeground }
    }
}
