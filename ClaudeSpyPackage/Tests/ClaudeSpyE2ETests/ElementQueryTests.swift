import Testing
@testable import ClaudeSpyE2ELib

@Suite("ElementQuery Tests")
struct ElementQueryTests {
    private let sampleTree: [UIElement] = [
        UIElement(
            role: "AXButton",
            subrole: nil,
            label: "Submit",
            value: nil,
            title: "Submit",
            identifier: "submit-button",
            frame: .init(x: 10, y: 10, width: 100, height: 44),
            children: []
        ),
        UIElement(
            role: "AXStaticText",
            subrole: nil,
            label: "Enter the 6-character pairing code",
            value: nil,
            title: nil,
            identifier: nil,
            frame: .init(x: 10, y: 60, width: 200, height: 20),
            children: []
        ),
        UIElement(
            role: "AXGroup",
            subrole: nil,
            label: nil,
            value: nil,
            title: "Sessions",
            identifier: "sessions-tab",
            frame: .init(x: 0, y: 0, width: 320, height: 600),
            children: [
                UIElement(
                    role: "AXStaticText",
                    subrole: nil,
                    label: "Sessions",
                    value: nil,
                    title: nil,
                    identifier: nil,
                    frame: .init(x: 10, y: 10, width: 100, height: 20),
                    children: []
                ),
                UIElement(
                    role: "AXTextField",
                    subrole: nil,
                    label: "Search",
                    value: "hello",
                    title: nil,
                    identifier: "search-field",
                    frame: .init(x: 10, y: 40, width: 200, height: 30),
                    children: []
                ),
            ]
        ),
    ]

    @Test("Exact label match")
    func exactLabelMatch() {
        let query = ElementQuery.label("Submit")
        let result = query.findFirst(in: sampleTree)
        #expect(result?.role == "AXButton")
    }

    @Test("Label contains match")
    func labelContainsMatch() {
        let query = ElementQuery.labelContains("pairing code")
        let result = query.findFirst(in: sampleTree)
        #expect(result?.role == "AXStaticText")
        #expect(result?.label?.contains("pairing code") == true)
    }

    @Test("Role match")
    func roleMatch() {
        let query = ElementQuery.role("AXTextField")
        let result = query.findFirst(in: sampleTree)
        #expect(result?.identifier == "search-field")
    }

    @Test("Identifier match")
    func identifierMatch() {
        let query = ElementQuery.identifier("sessions-tab")
        let result = query.findFirst(in: sampleTree)
        #expect(result?.role == "AXGroup")
    }

    @Test("Nested element found via depth-first search")
    func nestedElementSearch() {
        let query = ElementQuery.labelContains("Sessions")
        let result = query.findFirst(in: sampleTree)
        // Should find the nested AXStaticText inside the AXGroup
        #expect(result?.role == "AXStaticText")
    }

    @Test("Value contains match")
    func valueContainsMatch() {
        let query = ElementQuery.valueContains("hello")
        let result = query.findFirst(in: sampleTree)
        #expect(result?.identifier == "search-field")
    }

    @Test("No match returns nil")
    func noMatch() {
        let query = ElementQuery.label("NonExistent")
        let result = query.findFirst(in: sampleTree)
        #expect(result == nil)
    }

    @Test("FindAll returns all matches")
    func findAllMatches() {
        // "Sessions" appears both as a group title and as a nested static text label
        let query = ElementQuery.labelContains("Sessions")
        let results = query.findAll(in: sampleTree)
        #expect(results.count == 1) // Only the nested static text has label containing "Sessions"
    }

    @Test("Combined query with allOf")
    func combinedQuery() {
        let query = ElementQuery.allOf([
            .role("AXTextField"),
            .valueContains("hello"),
        ])
        let result = query.findFirst(in: sampleTree)
        #expect(result?.identifier == "search-field")
    }

    @Test("RoleAndLabelContains match")
    func roleAndLabelContains() {
        let query = ElementQuery.roleAndLabelContains(role: "AXStaticText", label: "Sessions")
        let result = query.findFirst(in: sampleTree)
        #expect(result != nil)
        #expect(result?.label == "Sessions")
    }
}
