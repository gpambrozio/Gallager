import Foundation
import XCTest

enum ScreenSizeHelper {
    static func getScreenSize() -> CGSize {
        let springboard = XCUIApplication(bundleIdentifier: RunningApp.springboardBundleId)
        return springboard.frame.size
    }
}
