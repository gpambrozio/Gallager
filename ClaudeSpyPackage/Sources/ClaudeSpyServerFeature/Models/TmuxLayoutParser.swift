import Foundation

/// Represents a node in the parsed tmux layout tree
public enum LayoutNode: Sendable, Hashable {
    /// A leaf pane with its tmux pane ID and dimensions
    case pane(id: Int, width: Int, height: Int)
    /// Horizontal split: children are side by side (tmux uses `{...}`)
    indirect case horizontal(children: [LayoutNode], width: Int, height: Int)
    /// Vertical split: children are stacked (tmux uses `[...]`)
    indirect case vertical(children: [LayoutNode], width: Int, height: Int)

    public var width: Int {
        switch self {
        case let .pane(_, width, _): width
        case let .horizontal(_, width, _): width
        case let .vertical(_, width, _): width
        }
    }

    public var height: Int {
        switch self {
        case let .pane(_, _, height): height
        case let .horizontal(_, _, height): height
        case let .vertical(_, _, height): height
        }
    }
}

/// Parses tmux layout strings into a `LayoutNode` tree.
///
/// Tmux layout format: `checksum,WxH,X,Y[,paneId | {children} | [children]]`
/// - `{...}` = horizontal split (children side by side)
/// - `[...]` = vertical split (children stacked)
public enum TmuxLayoutParser {
    /// Parse a tmux layout string into a layout tree.
    /// Returns nil if the string cannot be parsed.
    public static func parse(_ layoutString: String) -> LayoutNode? {
        // Strip the checksum prefix (e.g., "d0c6,")
        let stripped = stripChecksum(layoutString)
        var scanner = LayoutScanner(stripped)
        return parseNode(&scanner)
    }

    // MARK: - Private

    private static func stripChecksum(_ string: String) -> String {
        // Checksum is a 4-hex-digit prefix followed by comma
        guard
            string.count > 5,
            let commaIndex = string.firstIndex(of: ","),
            string.distance(from: string.startIndex, to: commaIndex) == 4
        else {
            return string
        }
        return String(string[string.index(after: commaIndex)...])
    }

    private static func parseNode(_ scanner: inout LayoutScanner) -> LayoutNode? {
        // Parse dimensions: WxH,X,Y
        guard
            let width = scanner.scanInt(),
            scanner.scan("x"),
            let height = scanner.scanInt(),
            scanner.scan(","),
            scanner.scanInt() != nil, // X offset
            scanner.scan(","),
            scanner.scanInt() != nil // Y offset
        else {
            return nil
        }

        // Check what follows: '{', '[', ',paneId', or end
        if scanner.scan("{") {
            // Horizontal split (children side by side)
            var children: [LayoutNode] = []
            while !scanner.scan("}") {
                if !children.isEmpty {
                    _ = scanner.scan(",")
                }
                guard let child = parseNode(&scanner) else { return nil }
                children.append(child)
                if scanner.isAtEnd { break }
            }
            return .horizontal(children: children, width: width, height: height)
        } else if scanner.scan("[") {
            // Vertical split (children stacked)
            var children: [LayoutNode] = []
            while !scanner.scan("]") {
                if !children.isEmpty {
                    _ = scanner.scan(",")
                }
                guard let child = parseNode(&scanner) else { return nil }
                children.append(child)
                if scanner.isAtEnd { break }
            }
            return .vertical(children: children, width: width, height: height)
        } else if scanner.scan(",") {
            // Leaf pane: read the pane ID
            guard let paneId = scanner.scanInt() else { return nil }
            return .pane(id: paneId, width: width, height: height)
        } else {
            // End of string or just a single-pane layout without trailing pane ID
            // Try to read pane ID if there's anything left
            if let paneId = scanner.scanInt() {
                return .pane(id: paneId, width: width, height: height)
            }
            return .pane(id: 0, width: width, height: height)
        }
    }
}

/// Simple string scanner for parsing layout strings
private struct LayoutScanner {
    private let string: String
    private var index: String.Index

    init(_ string: String) {
        self.string = string
        self.index = string.startIndex
    }

    var isAtEnd: Bool { index >= string.endIndex }

    /// Try to scan and consume a specific character
    @discardableResult
    mutating func scan(_ char: Character) -> Bool {
        guard !isAtEnd, string[index] == char else { return false }
        index = string.index(after: index)
        return true
    }

    /// Scan an integer from the current position
    mutating func scanInt() -> Int? {
        let start = index
        while !isAtEnd, string[index].isNumber {
            index = string.index(after: index)
        }
        guard start != index else { return nil }
        return Int(string[start..<index])
    }
}
