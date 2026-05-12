import ClaudeSpyCommon
import SwiftUI

/// Reusable visual shell for a tab in `WindowTabBar` / `RemoteWindowTabBar`.
///
/// Handles the common pattern of a label button paired with a close button,
/// selection highlighting (background + bottom underline), and the hover-driven
/// reveal of the close button. Callers provide their own label content and
/// stack their own context menus around the result.
///
/// Optionally renders a split-toggle button (used by file/browser tabs in
/// `WindowTabBar` to move a tab between the left and right pane of the split
/// layout) and a leading accent stripe (used to mark tabs that live on the
/// right pane while the layout is split).
struct TabBarItem<Label: View>: View {
    let isSelected: Bool
    let onSelect: () -> Void
    let labelAccessibilityLabel: String
    let onClose: () -> Void
    let closeAccessibilityLabel: String
    let closeHelp: String
    let closeDisabled: Bool
    let splitSymbol: Symbols?
    let onSplitToggle: (() -> Void)?
    let splitHelp: String
    let splitAccessibilityLabel: String
    let showLeadingAccent: Bool
    let label: () -> Label

    @State private var isHovered = false

    init(
        isSelected: Bool,
        onSelect: @escaping () -> Void,
        labelAccessibilityLabel: String,
        onClose: @escaping () -> Void,
        closeAccessibilityLabel: String,
        closeHelp: String = "Close",
        closeDisabled: Bool = false,
        splitSymbol: Symbols? = nil,
        onSplitToggle: (() -> Void)? = nil,
        splitHelp: String = "",
        splitAccessibilityLabel: String = "",
        showLeadingAccent: Bool = false,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.isSelected = isSelected
        self.onSelect = onSelect
        self.labelAccessibilityLabel = labelAccessibilityLabel
        self.onClose = onClose
        self.closeAccessibilityLabel = closeAccessibilityLabel
        self.closeHelp = closeHelp
        self.closeDisabled = closeDisabled
        self.splitSymbol = splitSymbol
        self.onSplitToggle = onSplitToggle
        self.splitHelp = splitHelp
        self.splitAccessibilityLabel = splitAccessibilityLabel
        self.showLeadingAccent = showLeadingAccent
        self.label = label
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSelect) {
                label()
                    .padding(.leading, 12)
                    .padding(.trailing, 4)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(labelAccessibilityLabel)
            .accessibilityValue(isSelected ? "selected" : "")

            if let splitSymbol, let onSplitToggle {
                Button(action: onSplitToggle) {
                    splitSymbol.image
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(splitHelp)
                .accessibilityLabel(splitAccessibilityLabel)
            }

            Button(action: onClose) {
                Symbols.xmark.image
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isSelected || isHovered ? 1 : 0)
            .help(closeHelp)
            .padding(.trailing, 6)
            .disabled(closeDisabled)
            .accessibilityLabel(closeAccessibilityLabel)
        }
        .foregroundStyle(isSelected ? .primary : .secondary)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .overlay(alignment: .bottom) {
            if isSelected {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
            }
        }
        .overlay(alignment: .leading) {
            // Subtle vertical accent so the user can tell at a glance which
            // tabs live on the right pane when the layout is split.
            if showLeadingAccent {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.6))
                    .frame(width: 2)
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
