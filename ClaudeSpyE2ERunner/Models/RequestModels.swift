import Foundation

struct TouchRequest: Codable {
    let x: Double
    let y: Double
    let duration: TimeInterval?
}

struct SwipeRequest: Codable {
    let startX: Double
    let startY: Double
    let endX: Double
    let endY: Double
    let duration: TimeInterval
}

struct InputTextRequest: Codable {
    let text: String
}

struct CustomActionRequest: Codable {
    let label: String?
    let labelContains: String?
    let identifier: String?
    let action: String
    let bundleId: String?
}

struct ViewHierarchyRequest: Codable {
    let bundleId: String?

    init(bundleId: String? = nil) {
        self.bundleId = bundleId
    }
}

struct LaunchAppRequest: Codable {
    let bundleId: String
    let arguments: [String]?
}

struct TerminateAppRequest: Codable {
    let bundleId: String
}
