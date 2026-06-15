import Foundation

/// Criteria for matching UI elements in the accessibility tree
public enum ElementQuery: Sendable, CustomStringConvertible {
    /// Match by exact AXLabel
    case label(String)
    /// Match by AXLabel containing substring
    case labelContains(String)
    /// Match by AXRole
    case role(String)
    /// Match by AXIdentifier
    case identifier(String)
    /// Match by AXRole and AXLabel containing substring
    case roleAndLabelContains(role: String, label: String)
    /// Match by AXValue containing substring
    case valueContains(String)
    /// Match by AXHelp exact match
    case help(String)
    /// Match when any text field (title, label, value) contains substring, or help exactly equals
    case anyTextMatches(String)
    /// Match by combining multiple queries (all must match)
    case allOf([ElementQuery])

    public var description: String {
        switch self {
        case let .label(text):
            "label(\"\(text)\")"
        case let .labelContains(text):
            "labelContains(\"\(text)\")"
        case let .role(role):
            "role(\"\(role)\")"
        case let .identifier(id):
            "identifier(\"\(id)\")"
        case let .roleAndLabelContains(role, label):
            "role(\"\(role)\") && labelContains(\"\(label)\")"
        case let .valueContains(text):
            "valueContains(\"\(text)\")"
        case let .help(text):
            "help(\"\(text)\")"
        case let .anyTextMatches(text):
            "anyTextMatches(\"\(text)\")"
        case let .allOf(queries):
            "allOf(\(queries.map(\.description).joined(separator: ", ")))"
        }
    }

    /// Returns a copy with every string field transformed by `resolve`.
    ///
    /// Lets a query reference values captured during execution — e.g.
    /// `.identifier("terminal-${mpPane1}")` resolved against the
    /// `ExecutionContext` — exactly the way the orchestrator already resolves
    /// tmux targets and typed text. Queries with no `${var}` references are
    /// unchanged, so this is a safe no-op for literal queries.
    public func resolved(_ resolve: (String) -> String) -> ElementQuery {
        switch self {
        case let .label(text):
            .label(resolve(text))
        case let .labelContains(text):
            .labelContains(resolve(text))
        case let .role(role):
            .role(resolve(role))
        case let .identifier(id):
            .identifier(resolve(id))
        case let .roleAndLabelContains(role, label):
            .roleAndLabelContains(role: resolve(role), label: resolve(label))
        case let .valueContains(text):
            .valueContains(resolve(text))
        case let .help(text):
            .help(resolve(text))
        case let .anyTextMatches(text):
            .anyTextMatches(resolve(text))
        case let .allOf(queries):
            .allOf(queries.map { $0.resolved(resolve) })
        }
    }

    /// Test whether a UIElement matches this query
    public func matches(_ element: UIElement) -> Bool {
        switch self {
        case let .label(text):
            element.label == text
        case let .labelContains(text):
            element.label?.localizedCaseInsensitiveContains(text) ?? false
        case let .role(role):
            element.role == role
        case let .identifier(id):
            element.identifier == id
        case let .roleAndLabelContains(role, label):
            element.role == role && (element.label?.localizedCaseInsensitiveContains(label) ?? false)
        case let .valueContains(text):
            element.value?.localizedCaseInsensitiveContains(text) ?? false
        case let .help(text):
            element.help == text
        case let .anyTextMatches(text):
            (element.title?.localizedCaseInsensitiveContains(text) ?? false)
                || (element.label?.localizedCaseInsensitiveContains(text) ?? false)
                || (element.value?.localizedCaseInsensitiveContains(text) ?? false)
                || element.help == text
        case let .allOf(queries):
            queries.allSatisfy { $0.matches(element) }
        }
    }

    /// Find the first matching element in a tree (depth-first)
    public func findFirst(in elements: [UIElement]) -> UIElement? {
        for element in elements {
            if matches(element) {
                return element
            }
            if let found = findFirst(in: element.children) {
                return found
            }
        }
        return nil
    }

    /// Find all matching elements in a tree
    public func findAll(in elements: [UIElement]) -> [UIElement] {
        var results: [UIElement] = []
        for element in elements {
            if matches(element) {
                results.append(element)
            }
            results.append(contentsOf: findAll(in: element.children))
        }
        return results
    }
}
