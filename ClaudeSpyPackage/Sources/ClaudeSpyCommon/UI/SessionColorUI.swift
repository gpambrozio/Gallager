import ClaudeSpyNetworking
import SwiftUI

public extension SessionColor {
    /// SwiftUI color used to render the session dot and the color picker swatches.
    var swiftUIColor: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .gray: .gray
        }
    }
}

/// A vertical bar rendering a session's color flush with the cell's leading
/// edge. Sized as a full-height strip when placed inside an `HStack` next to
/// the row content; renders a clear placeholder of the same width when no
/// color is set so colored and uncolored rows align identically.
public struct SessionColorBar: View {
    public let color: SessionColor?
    public var width: CGFloat = 4

    public init(color: SessionColor?, width: CGFloat = 4) {
        self.color = color
        self.width = width
    }

    public var body: some View {
        Capsule()
            .fill(color?.swiftUIColor ?? Color.clear)
            .frame(width: width)
            .accessibilityIdentifier(color.map { "session-color-\($0.rawValue)" } ?? "")
            .accessibilityLabel(color.map { "\($0.displayName) color" } ?? "")
    }
}

/// Context menu items for picking a session color, plus a clear action.
///
/// Designed to live inside another `.contextMenu { }`; renders a "Set Color"
/// submenu with a swatch + name for each color, and a "Clear Color" entry
/// when one is currently set.
public struct ColorContextMenuButtons: View {
    let currentColor: SessionColor?
    let isDisabled: Bool
    let onSetColor: (SessionColor?) -> Void

    public init(
        currentColor: SessionColor?,
        isDisabled: Bool = false,
        onSetColor: @escaping (SessionColor?) -> Void
    ) {
        self.currentColor = currentColor
        self.isDisabled = isDisabled
        self.onSetColor = onSetColor
    }

    public var body: some View {
        Menu {
            ForEach(SessionColor.allCases) { color in
                Button {
                    onSetColor(color)
                } label: {
                    Label {
                        Text(color.displayName)
                    } icon: {
                        Circle()
                            .fill(color.swiftUIColor)
                    }
                }
                .disabled(isDisabled)
            }
        } label: {
            if let currentColor {
                Label {
                    Text("Color: \(currentColor.displayName)")
                } icon: {
                    Circle()
                        .fill(currentColor.swiftUIColor)
                }
            } else {
                Label("Set Color", symbol: .paintpalette)
            }
        }
        .disabled(isDisabled)

        if currentColor != nil {
            Button(role: .destructive) {
                onSetColor(nil)
            } label: {
                Label("Clear Color", symbol: .xmark)
            }
            .disabled(isDisabled)
        }
    }
}
