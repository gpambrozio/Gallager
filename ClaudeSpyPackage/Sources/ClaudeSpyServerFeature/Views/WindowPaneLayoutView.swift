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
                layoutView(for: layout)
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

    // MARK: - Layout Rendering

    /// Recursively renders a layout tree. Uses `AnyView` to break the recursive opaque type cycle.
    private func layoutView(for node: LayoutNode) -> AnyView {
        switch node {
        case let .pane(id, _, _):
            AnyView(terminalView(forTmuxPaneId: id))

        case let .horizontal(children, totalWidth, _):
            AnyView(
                GeometryReader { geometry in
                    HStack(spacing: 1) {
                        ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                            layoutView(for: child)
                                .frame(width: proportionalWidth(child.width, total: totalWidth, available: geometry.size.width, childCount: children.count))
                        }
                    }
                }
            )

        case let .vertical(children, _, totalHeight):
            AnyView(
                GeometryReader { geometry in
                    VStack(spacing: 1) {
                        ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                            layoutView(for: child)
                                .frame(height: proportionalHeight(child.height, total: totalHeight, available: geometry.size.height, childCount: children.count))
                        }
                    }
                }
            )
        }
    }

    @ViewBuilder
    private func terminalView(forTmuxPaneId tmuxId: Int) -> some View {
        let paneIdString = "%\(tmuxId)"
        if
            let pane = window.panes.first(where: { $0.paneId == paneIdString }),
            let paneState = windowManager.paneStates[pane.paneId] {
            TerminalContainerView(
                paneState: paneState,
                onStateChange: { _, _, _ in },
                onTitleChange: { title in
                    windowManager.updateTerminalTitle(paneId: paneState.paneId, title: title)
                }
            )
        } else {
            Color.black
        }
    }

    private func proportionalWidth(_ childWidth: Int, total: Int, available: CGFloat, childCount: Int) -> CGFloat {
        let dividerSpace = CGFloat(childCount - 1) // 1pt dividers
        let usable = max(0, available - dividerSpace)
        return usable * CGFloat(childWidth) / CGFloat(max(1, total))
    }

    private func proportionalHeight(_ childHeight: Int, total: Int, available: CGFloat, childCount: Int) -> CGFloat {
        let dividerSpace = CGFloat(childCount - 1)
        let usable = max(0, available - dividerSpace)
        return usable * CGFloat(childHeight) / CGFloat(max(1, total))
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
