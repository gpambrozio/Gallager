import Foundation
import XCTest

/// Protocol to expose private XCUIApplication class method via ObjC runtime
@objc private protocol XCUIApplicationPrivate {
    @objc static func activeAppsInfo() -> [[String: Any]]
}

enum RunningApp {
    static let springboardBundleId = "com.apple.springboard"

    static func getForegroundApp() -> XCUIApplication? {
        // XCUIApplication.activeAppsInfo() is a private class method.
        // Access it via ObjC runtime.
        guard let cls = NSClassFromString("XCUIApplication") as? XCUIApplicationPrivate.Type else {
            NSLog("[RunningApp] Could not load XCUIApplication via runtime")
            return nil
        }

        let appsInfo = cls.activeAppsInfo()
        let runningAppIds = appsInfo.compactMap { $0["bundleId"] as? String }

        NSLog("[RunningApp] Detected running apps: \(runningAppIds)")

        if runningAppIds.count == 1, let bundleId = runningAppIds.first {
            return XCUIApplication(bundleIdentifier: bundleId)
        } else {
            return runningAppIds
                .map { XCUIApplication(bundleIdentifier: $0) }
                .first { $0.state == .runningForeground }
        }
    }
}
