import ClaudeSpyNetworking
import SwiftUI

#if canImport(AppKit)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

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
                        ColorSwatch(color: color)
                    }
                }
                .disabled(isDisabled)
            }
        } label: {
            if let currentColor {
                Label {
                    Text("Color: \(currentColor.displayName)")
                } icon: {
                    ColorSwatch(color: currentColor)
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

/// Renders a colored square swatch that survives the platform menu's template
/// tinting. SwiftUI's `.foregroundStyle` is dropped when a `Label` icon is
/// bridged into an `NSMenuItem` / `UIMenu`, so we build a platform image from
/// the SF Symbol with a palette configuration and force the original
/// rendering mode.
private struct ColorSwatch: View {
    let color: SessionColor

    var body: some View {
        #if canImport(AppKit)
            Image(nsImage: Self.swatchImage(for: color))
        #elseif canImport(UIKit)
            Image(uiImage: Self.swatchImage(for: color))
        #else
            Symbols.squareFill.image
                .foregroundStyle(color.swiftUIColor)
        #endif
    }

    #if canImport(AppKit)
        private static func swatchImage(for color: SessionColor) -> NSImage {
            let config = NSImage.SymbolConfiguration(paletteColors: [NSColor(color.swiftUIColor)])
            let base = NSImage(systemSymbolName: Symbols.squareFill.rawValue, accessibilityDescription: color.displayName)
            let image = base?.withSymbolConfiguration(config) ?? base ?? NSImage()
            image.isTemplate = false
            return image
        }

    #elseif canImport(UIKit)
        /// Renders a flat rounded square into a fresh bitmap. We can't rely on
        /// SF Symbol palette/tint configurations because SwiftUI's iOS `Menu`
        /// re-templates the icon during its own rendering pass — only an image
        /// with no transparent template channel survives.
        private static func swatchImage(for color: SessionColor) -> UIImage {
            let size = CGSize(width: 18, height: 18)
            let renderer = UIGraphicsImageRenderer(size: size)
            let image = renderer.image { _ in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
                let path = UIBezierPath(roundedRect: rect, cornerRadius: 3)
                UIColor(color.swiftUIColor).setFill()
                path.fill()
            }
            return image.withRenderingMode(.alwaysOriginal)
        }
    #endif
}

#Preview("No color set") {
    @Previewable @State var color: SessionColor?
    Form {
        ColorContextMenuButtons(currentColor: color) { color = $0 }
    }
    .frame(width: 280, height: 120)
}

#Preview("With color set") {
    @Previewable @State var color: SessionColor? = .blue
    Form {
        ColorContextMenuButtons(currentColor: color) { color = $0 }
    }
    .frame(width: 280, height: 160)
}

#Preview("Disabled") {
    Form {
        ColorContextMenuButtons(currentColor: .purple, isDisabled: true) { _ in }
    }
    .frame(width: 280, height: 120)
}
