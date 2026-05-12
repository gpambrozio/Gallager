import AppKit
import SwiftUI

// MARK: - Split Layout

/// Layout constants shared by `SplitDetailContent` and `WindowTabBar` so the
/// split-view divider and the tab strip line up horizontally.
enum SplitLayout {
    static let minRatio: CGFloat = 0.15
    static let maxRatio: CGFloat = 0.85
    static let dividerWidth: CGFloat = 4
}

// MARK: - Split Detail Content

/// Side-by-side layout for the split-view feature (issue #498). Renders a
/// left pane, a draggable vertical divider, and a right pane whose width is
/// driven by `sessionTabs.splitRatio`. The divider clamps the ratio to
/// [0.15, 0.85] so neither pane can be made unusably small.
struct SplitDetailContent<Left: View, Right: View>: View {
    @Bindable var sessionTabs: SessionFileTabsState
    @ViewBuilder var left: () -> Left
    @ViewBuilder var right: () -> Right

    @State private var dragInitialRatio: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let totalWidth = proxy.size.width
            let leftWidth = max(0, totalWidth * sessionTabs.splitRatio - SplitLayout.dividerWidth / 2)
            HStack(spacing: 0) {
                left()
                    .frame(width: leftWidth)
                    .frame(maxHeight: .infinity)
                divider(totalWidth: totalWidth)
                right()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func divider(totalWidth: CGFloat) -> some View {
        Color.clear
            .frame(width: SplitLayout.dividerWidth)
            .frame(maxHeight: .infinity)
            .overlay(Divider())
            .contentShape(Rectangle().inset(by: -3))
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        guard totalWidth > 0 else { return }
                        if dragInitialRatio == nil {
                            dragInitialRatio = sessionTabs.splitRatio
                        }
                        let initial = dragInitialRatio ?? sessionTabs.splitRatio
                        let delta = value.translation.width / totalWidth
                        let next = initial + delta
                        sessionTabs.splitRatio = min(max(next, SplitLayout.minRatio), SplitLayout.maxRatio)
                    }
                    .onEnded { _ in
                        dragInitialRatio = nil
                    }
            )
            .accessibilityIdentifier("split-divider")
    }
}
