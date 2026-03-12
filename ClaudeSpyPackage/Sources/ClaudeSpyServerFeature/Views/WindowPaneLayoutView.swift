import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

/// Renders a `TmuxWindow` by parsing its layout string and arranging
/// `TerminalContainerView` instances in the correct split arrangement.
struct WindowPaneLayoutView: View {
    let window: TmuxWindow

    @Environment(AppSettings.self) private var settings
    @Environment(MirrorWindowManager.self) private var windowManager

    var body: some View {
        if
            window.isSinglePane, let pane = window.panes.first,
            let paneState = windowManager.paneStates[pane.paneId] {
            // Single pane — render directly as before
            MirrorWindowView(paneState: paneState)
        } else if let layout = TmuxLayoutParser.parse(window.windowLayout) {
            VStack(spacing: 0) {
                flattenedLayout(from: layout)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if settings.showStatusBar {
                    multiPaneStatusBar
                }
            }
        } else {
            // Fallback: stack panes vertically if layout parsing fails
            VStack(spacing: 1) {
                ForEach(window.panes) { pane in
                    if let paneState = windowManager.paneStates[pane.paneId] {
                        MirrorWindowView(paneState: paneState)
                    }
                }
            }
        }
    }

    // MARK: - Flattened Layout

    /// A positioned pane within the layout, with proportional coordinates relative to the total window.
    private struct PositionedPane: Identifiable {
        let id: String // paneId (e.g., "%5")
        let paneInfo: PaneInfo
        /// Proportional rectangle (0..1) within the total layout area
        let rect: CGRect
    }

    /// Flattens the layout tree into positioned rectangles and renders all terminals
    /// in a single GeometryReader + ZStack. This avoids recursive `AnyView` and
    /// ensures each TerminalContainerView has a stable `.id()`.
    private func flattenedLayout(from layout: LayoutNode) -> some View {
        let totalWidth = CGFloat(layout.width)
        let totalHeight = CGFloat(layout.height)
        var positioned: [PositionedPane] = []
        flattenNode(layout, origin: .zero, totalWidth: totalWidth, totalHeight: totalHeight, into: &positioned)

        return GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(positioned) { pane in
                    if let paneState = windowManager.paneStates[pane.paneInfo.paneId] {
                        TerminalContainerView(
                            paneState: paneState,
                            autoFocus: false,
                            onStateChange: { _, _, _ in },
                            onTitleChange: { title in
                                windowManager.updateTerminalTitle(paneId: paneState.paneId, title: title)
                            }
                        )
                        .frame(
                            width: pane.rect.width * geometry.size.width,
                            height: pane.rect.height * geometry.size.height
                        )
                        .offset(
                            x: pane.rect.origin.x * geometry.size.width,
                            y: pane.rect.origin.y * geometry.size.height
                        )
                        .id(pane.id)
                    }
                }
            }
        }
    }

    /// Recursively walks the layout tree, computing proportional rectangles for each leaf pane.
    private func flattenNode(
        _ node: LayoutNode,
        origin: CGPoint,
        totalWidth: CGFloat,
        totalHeight: CGFloat,
        into result: inout [PositionedPane]
    ) {
        switch node {
        case let .pane(id, width, height):
            let paneIdString = "%\(id)"
            if let paneInfo = window.panes.first(where: { $0.paneId == paneIdString }) {
                let rect = CGRect(
                    x: origin.x,
                    y: origin.y,
                    width: CGFloat(width) / totalWidth,
                    height: CGFloat(height) / totalHeight
                )
                result.append(PositionedPane(id: paneIdString, paneInfo: paneInfo, rect: rect))
            }

        case let .horizontal(children, _, _):
            var xOffset = origin.x
            for child in children {
                flattenNode(child, origin: CGPoint(x: xOffset, y: origin.y), totalWidth: totalWidth, totalHeight: totalHeight, into: &result)
                xOffset += CGFloat(child.width) / totalWidth
            }

        case let .vertical(children, _, _):
            var yOffset = origin.y
            for child in children {
                flattenNode(child, origin: CGPoint(x: origin.x, y: yOffset), totalWidth: totalWidth, totalHeight: totalHeight, into: &result)
                yOffset += CGFloat(child.height) / totalHeight
            }
        }
    }

    // MARK: - Status Bar

    private var multiPaneStatusBar: some View {
        HStack {
            Text("\(window.sessionName):\(window.windowIndex)")
                .font(.system(.caption, design: .monospaced))

            Divider()
                .frame(height: 12)

            Text("\(window.panes.count) panes")

            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
