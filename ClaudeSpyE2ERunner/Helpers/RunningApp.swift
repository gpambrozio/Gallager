import Foundation
import XCTest

enum RunningApp {
    static let springboardBundleId = "com.apple.springboard"

    static func getForegroundApp() -> XCUIApplication? {
        let runningAppIds = XCUIApplication.activeAppsInfo().compactMap { $0["bundleId"] as? String }

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
