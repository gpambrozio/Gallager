import Testing
@testable import ClaudeSpyE2ELib

@Suite("UIElement Tests")
struct UIElementTests {
    @Test("Center point is computed correctly")
    func centerPoint() {
        let element = UIElement(
            role: "AXButton",
            subrole: nil,
            label: "Test",
            value: nil,
            title: nil,
            identifier: nil,
            help: nil,
            frame: .init(x: 100, y: 200, width: 50, height: 30),
            children: []
        )

        #expect(element.center.x == 125)
        #expect(element.center.y == 215)
    }

    @Test("Flattened tree includes all descendants")
    func flattenedTree() {
        let child1 = UIElement(
            role: "AXButton", subrole: nil, label: "A", value: nil,
            title: nil, identifier: nil, help: nil, frame: .zero, children: []
        )
        let child2 = UIElement(
            role: "AXButton", subrole: nil, label: "B", value: nil,
            title: nil, identifier: nil, help: nil, frame: .zero, children: []
        )
        let parent = UIElement(
            role: "AXGroup", subrole: nil, label: "Parent", value: nil,
            title: nil, identifier: nil, help: nil, frame: .zero, children: [child1, child2]
        )

        let flattened = parent.flattened()
        #expect(flattened.count == 3)
        #expect(flattened[0].label == "Parent")
        #expect(flattened[1].label == "A")
        #expect(flattened[2].label == "B")
    }

    @Test("Description includes relevant fields")
    func descriptionFormat() {
        let element = UIElement(
            role: "AXButton",
            subrole: "AXPush",
            label: "Submit",
            value: "clicked",
            title: "Submit Button",
            identifier: "submit-btn",
            help: nil,
            frame: .init(x: 0, y: 0, width: 100, height: 44),
            children: []
        )

        let desc = element.description
        #expect(desc.contains("AXButton"))
        #expect(desc.contains("Submit"))
        #expect(desc.contains("submit-btn"))
    }
}
