import Foundation

/// A node in a parsed tmux layout tree
public enum LayoutNode: Sendable {
    /// A leaf pane with its tmux pane number and dimensions
    case pane(id: Int, width: Int, height: Int)
    /// A horizontal split (panes side by side), represented by `{...}` in tmux layout
    case horizontal(children: [LayoutNode], width: Int, height: Int)
    /// A vertical split (panes stacked), represented by `[...]` in tmux layout
    case vertical(children: [LayoutNode], width: Int, height: Int)

    /// The width of this node
    public var width: Int {
        switch self {
        case let .pane(_, width, _): width
        case let .horizontal(_, width, _): width
        case let .vertical(_, width, _): width
        }
    }

    /// The height of this node
    public var height: Int {
        switch self {
        case let .pane(_, _, height): height
        case let .horizontal(_, _, height): height
        case let .vertical(_, _, height): height
        }
    }

    /// All pane IDs in this layout tree
    public var allPaneIds: [Int] {
        switch self {
        case let .pane(id, _, _):
            [id]
        case let .horizontal(children, _, _),
             let .vertical(children, _, _):
            children.flatMap(\.allPaneIds)
        }
    }
}

/// Parses tmux window layout strings into a tree structure
///
/// Layout format: `checksum,WxH,X,Y{children}` or `checksum,WxH,X,Y[children]` or `checksum,WxH,X,Y,paneId`
/// - `{...}` = horizontal split (panes side by side)
/// - `[...]` = vertical split (panes stacked)
public enum TmuxLayoutParser {
    /// Parses a tmux layout string into a layout node tree
    /// - Parameter layout: The raw tmux layout string (e.g., "d0c6,191x50,0,0{95x50,0,0,5,95x50,96,0,6}")
    /// - Returns: The parsed layout tree, or nil if parsing fails
    public static func parse(_ layout: String) -> LayoutNode? {
        // Strip the checksum prefix (e.g., "d0c6,")
        guard let commaIndex = layout.firstIndex(of: ",") else { return nil }
        let afterChecksum = String(layout[layout.index(after: commaIndex)...])
        return parseNode(afterChecksum).map(\.node)
    }

    // MARK: - Private Parser

    private struct ParseResult {
        let node: LayoutNode
        let remaining: String
    }

    /// Parses a single node from the layout string
    /// Format: WxH,X,Y followed by either {children}, [children], or ,paneId
    private static func parseNode(_ input: String) -> ParseResult? {
        var scanner = Scanner(input)

        // Parse WxH
        guard
            let width = scanner.scanInt(),
            scanner.scanChar("x"),
            let height = scanner.scanInt(),
            scanner.scanChar(","),
            scanner.scanInt() != nil, // X position (unused)
            scanner.scanChar(","),
            scanner.scanInt() != nil // Y position (unused)
        else { return nil }

        let rest = scanner.remaining

        // Check what follows: {, [, or ,paneId
        if rest.hasPrefix("{") {
            // Horizontal split
            guard let result = parseChildren(String(rest.dropFirst()), closing: "}") else { return nil }
            return ParseResult(
                node: .horizontal(children: result.children, width: width, height: height),
                remaining: result.remaining
            )
        } else if rest.hasPrefix("[") {
            // Vertical split
            guard let result = parseChildren(String(rest.dropFirst()), closing: "]") else { return nil }
            return ParseResult(
                node: .vertical(children: result.children, width: width, height: height),
                remaining: result.remaining
            )
        } else if rest.hasPrefix(",") {
            // Leaf pane - parse pane ID
            let afterComma = String(rest.dropFirst())
            var idScanner = Scanner(afterComma)
            guard let paneId = idScanner.scanInt() else { return nil }
            return ParseResult(
                node: .pane(id: paneId, width: width, height: height),
                remaining: idScanner.remaining
            )
        } else if rest.isEmpty {
            // End of string - this shouldn't happen for valid layouts
            return nil
        } else {
            return nil
        }
    }

    private struct ChildrenResult {
        let children: [LayoutNode]
        let remaining: String
    }

    /// Parses a comma-separated list of children enclosed in brackets/braces
    private static func parseChildren(_ input: String, closing: Character) -> ChildrenResult? {
        var remaining = input
        var children: [LayoutNode] = []

        while !remaining.isEmpty {
            if remaining.first == closing {
                remaining = String(remaining.dropFirst())
                return ChildrenResult(children: children, remaining: remaining)
            }

            if !children.isEmpty {
                // Expect a comma separator between children
                guard remaining.first == "," else { return nil }
                remaining = String(remaining.dropFirst())
            }

            guard let result = parseNode(remaining) else { return nil }
            children.append(result.node)
            remaining = result.remaining
        }

        return nil // Missing closing bracket
    }
}

// MARK: - Simple Scanner

private struct Scanner {
    private var string: String
    private var index: String.Index

    init(_ string: String) {
        self.string = string
        self.index = string.startIndex
    }

    var remaining: String {
        String(string[index...])
    }

    mutating func scanInt() -> Int? {
        let start = index
        while index < string.endIndex, string[index].isNumber {
            index = string.index(after: index)
        }
        guard start != index else { return nil }
        return Int(string[start..<index])
    }

    mutating func scanChar(_ char: Character) -> Bool {
        guard index < string.endIndex, string[index] == char else { return false }
        index = string.index(after: index)
        return true
    }
}
