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

/// A small filled circle rendering a session's color in the sidebar.
public struct SessionColorDot: View {
    public let color: SessionColor
    public var size: CGFloat = 10

    public init(color: SessionColor, size: CGFloat = 10) {
        self.color = color
        self.size = size
    }

    public var body: some View {
        Circle()
            .fill(color.swiftUIColor)
            .frame(width: size, height: size)
            .accessibilityLabel("\(color.displayName) color")
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
