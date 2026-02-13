import Foundation
import XCTest

typealias AXFrame = [String: Double]

extension AXFrame {
    static let zero: AXFrame = ["X": 0, "Y": 0, "Width": 0, "Height": 0]
}

struct AXElement: Codable {
    let identifier: String
    let frame: AXFrame
    let value: String?
    let title: String?
    let label: String
    let elementType: Int
    let enabled: Bool
    let horizontalSizeClass: Int
    let verticalSizeClass: Int
    let placeholderValue: String?
    let selected: Bool
    let hasFocus: Bool
    let displayID: Int
    let windowContextID: Double
    var children: [AXElement]?

    init(
        identifier: String = "",
        frame: AXFrame = .zero,
        value: String? = nil,
        title: String? = nil,
        label: String = "",
        elementType: Int = 0,
        enabled: Bool = false,
        horizontalSizeClass: Int = 0,
        verticalSizeClass: Int = 0,
        placeholderValue: String? = nil,
        selected: Bool = false,
        hasFocus: Bool = false,
        displayID: Int = 0,
        windowContextID: Double = 0,
        children: [AXElement]? = nil
    ) {
        self.identifier = identifier
        self.frame = frame
        self.value = value
        self.title = title
        self.label = label
        self.elementType = elementType
        self.enabled = enabled
        self.horizontalSizeClass = horizontalSizeClass
        self.verticalSizeClass = verticalSizeClass
        self.placeholderValue = placeholderValue
        self.selected = selected
        self.hasFocus = hasFocus
        self.displayID = displayID
        self.windowContextID = windowContextID
        self.children = children
    }

    func depth() -> Int {
        guard let children, !children.isEmpty else { return 1 }
        return 1 + (children.map { $0.depth() }.max() ?? 0)
    }
}

// MARK: - XCTest Snapshot Conversion

extension AXElement {
    init(_ dict: [XCUIElement.AttributeName: Any]) {
        func valueFor(_ name: String) -> Any {
            dict[XCUIElement.AttributeName(rawValue: name)] as Any
        }

        let label = valueFor("label") as? String ?? ""
        let elementType = valueFor("elementType") as? Int ?? 0
        let identifier = valueFor("identifier") as? String ?? ""
        let horizontalSizeClass = valueFor("horizontalSizeClass") as? Int ?? 0
        let windowContextID = valueFor("windowContextID") as? Double ?? 0
        let verticalSizeClass = valueFor("verticalSizeClass") as? Int ?? 0
        let selected = valueFor("selected") as? Bool ?? false
        let displayID = valueFor("displayID") as? Int ?? 0
        let hasFocus = valueFor("hasFocus") as? Bool ?? false
        let placeholderValue = valueFor("placeholderValue") as? String
        let value = valueFor("value") as? String
        let frame = valueFor("frame") as? AXFrame ?? .zero
        let enabled = valueFor("enabled") as? Bool ?? false
        let title = valueFor("title") as? String
        let childrenDictionaries = valueFor("children") as? [[XCUIElement.AttributeName: Any]]
        let children = childrenDictionaries?.map { AXElement($0) } ?? []

        self.init(
            identifier: identifier,
            frame: frame,
            value: value,
            title: title,
            label: label,
            elementType: elementType,
            enabled: enabled,
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass,
            placeholderValue: placeholderValue,
            selected: selected,
            hasFocus: hasFocus,
            displayID: displayID,
            windowContextID: windowContextID,
            children: children
        )
    }
}

struct ViewHierarchy: Codable {
    let axElement: AXElement
    let depth: Int
}
