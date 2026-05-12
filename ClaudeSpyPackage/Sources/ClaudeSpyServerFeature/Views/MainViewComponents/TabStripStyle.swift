import ClaudeSpyCommon
import SwiftUI

/// Shared selection/split decoration for tab-strip items. Applies the
/// foreground/background tint plus the bottom accent bar when selected, and the
/// thin left stripe used to indicate the right-side pane in a split layout.
extension View {
    /// Decorates a tab-strip child with consistent selected styling and
    /// (optional) right-split indicator. Centralizes styling that was
    /// previously copy-pasted across every tab variant (window tab, file tab,
    /// browser tab) so they stay visually in sync.
    func tabStripItemStyle(
        isSelected: Bool,
        isOnRightSplit: Bool = false,
        isSplit: Bool = false
    ) -> some View {
        modifier(TabStripItemStyleModifier(
            isSelected: isSelected,
            isOnRightSplit: isOnRightSplit,
            isSplit: isSplit
        ))
    }
}

private struct TabStripItemStyleModifier: ViewModifier {
    let isSelected: Bool
    let isOnRightSplit: Bool
    let isSplit: Bool

    func body(content: Content) -> some View {
        content
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
                if isSplit, isOnRightSplit {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.6))
                        .frame(width: 2)
                }
            }
    }
}

/// Compact close button used by every tab type in the strip. Fades in/out via
/// `isVisible` so it only renders for hovered or selected tabs.
struct TabCloseButton: View {
    let isVisible: Bool
    var isDisabled = false
    let accessibilityLabel: String
    var helpText = "Close tab"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Symbols.xmark.image
                .font(.system(size: 8, weight: .bold))
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(isVisible ? 1 : 0)
        .help(helpText)
        .accessibilityLabel(accessibilityLabel)
        .disabled(isDisabled)
    }
}

/// Toggle button used by file/browser tabs to send the tab to (or back from)
/// the right side of the split layout. The symbol, help text, and AX label all
/// derive from the current `isSplit` / `isOnRight` state so callers only need
/// to provide a display name and the action.
struct TabSplitToggleButton: View {
    let isSplit: Bool
    let isOnRight: Bool
    let tabKind: String
    let tabName: String
    let action: () -> Void

    private var symbol: Symbols {
        !isSplit
            ? .rectangleSplit2x1
            : (isOnRight ? .arrowLeft : .arrowRight)
    }

    private var helpText: String {
        !isSplit
            ? "Open in split view"
            : (isOnRight ? "Move tab to left side" : "Move tab to right side")
    }

    private var accessibility: String {
        if !isSplit {
            return "Open \(tabKind) in split: \(tabName)"
        }
        return isOnRight
            ? "Move \(tabKind) to left: \(tabName)"
            : "Move \(tabKind) to right: \(tabName)"
    }

    var body: some View {
        Button(action: action) {
            symbol.image
                .font(.system(size: 9, weight: .bold))
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(helpText)
        .accessibilityLabel(accessibility)
    }
}
