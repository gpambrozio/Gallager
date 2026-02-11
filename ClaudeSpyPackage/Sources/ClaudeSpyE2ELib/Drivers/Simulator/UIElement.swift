import Foundation

/// A parsed accessibility element from the iOS Simulator's AX tree
public struct UIElement: Sendable, CustomStringConvertible {
    public let role: String
    public let subrole: String?
    public let label: String?
    public let value: String?
    public let title: String?
    public let identifier: String?
    public let frame: CGRect
    public let children: [UIElement]

    public var center: CGPoint {
        CGPoint(x: frame.midX, y: frame.midY)
    }

    public var description: String {
        var parts: [String] = [role]
        if let subrole { parts.append("subrole=\(subrole)") }
        if let label { parts.append("label=\"\(label)\"") }
        if let value { parts.append("value=\"\(value)\"") }
        if let title { parts.append("title=\"\(title)\"") }
        if let identifier { parts.append("id=\"\(identifier)\"") }
        parts.append("frame=\(frame)")
        if !children.isEmpty { parts.append("children=\(children.count)") }
        return "UIElement(\(parts.joined(separator: ", ")))"
    }

    /// Recursively flatten the element tree
    public func flattened() -> [UIElement] {
        [self] + children.flatMap { $0.flattened() }
    }

    /// Return a copy with all frames offset by the given origin (iOS → macOS screen coordinates)
    func offsettingFrames(by origin: CGPoint) -> UIElement {
        UIElement(
            role: role,
            subrole: subrole,
            label: label,
            value: value,
            title: title,
            identifier: identifier,
            frame: CGRect(
                x: frame.origin.x + origin.x,
                y: frame.origin.y + origin.y,
                width: frame.size.width,
                height: frame.size.height
            ),
            children: children.map { $0.offsettingFrames(by: origin) }
        )
    }
}
