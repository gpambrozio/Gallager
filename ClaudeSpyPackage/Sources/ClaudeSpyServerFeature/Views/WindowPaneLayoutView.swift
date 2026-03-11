import ClaudeSpyCommon
import SwiftUI

/// Renders a tmux window with all its panes according to their layout arrangement
struct WindowPaneLayoutView: View {
    let window: TmuxWindow
    let onPaneStateChange: ((PaneInfo, StreamState, Int, Int) -> Void)?
    let onPaneTitleChange: ((PaneInfo, String) -> Void)?

    @Environment(AppSettings.self) private var settings
    @Environment(MirrorWindowManager.self) private var windowManager

    var body: some View {
        VStack(spacing: 0) {
            if let layoutNode = TmuxLayoutParser.parse(window.windowLayout) {
                LayoutNodeView(
                    node: layoutNode,
                    panes: window.panes,
                    onPaneStateChange: onPaneStateChange,
                    onPaneTitleChange: onPaneTitleChange
                )
            } else {
                // Fallback: show panes in a simple vertical stack
                fallbackLayout
            }

            if settings.showStatusBar {
                statusBar
            }
        }
    }

    @ViewBuilder
    private var fallbackLayout: some View {
        if window.panes.count == 1, let pane = window.panes.first {
            TerminalContainerView(
                paneInfo: pane,
                onStateChange: { state, width, height in
                    onPaneStateChange?(pane, state, width, height)
                },
                onTitleChange: { title in
                    onPaneTitleChange?(pane, title)
                }
            )
        } else {
            VSplitView {
                ForEach(window.panes) { pane in
                    TerminalContainerView(
                        paneInfo: pane,
                        onStateChange: { state, width, height in
                            onPaneStateChange?(pane, state, width, height)
                        },
                        onTitleChange: { title in
                            onPaneTitleChange?(pane, title)
                        }
                    )
                }
            }
        }
    }

    private var statusBar: some View {
        HStack {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                Text("\(window.sessionName):\(window.windowIndex)")
                    .font(.system(.caption, design: .monospaced))
            }

            if !window.windowName.isEmpty {
                Divider()
                    .frame(height: 12)
                Text(window.windowName)
            }

            Divider()
                .frame(height: 12)

            Text("\(window.panes.count) pane\(window.panes.count == 1 ? "" : "s")")

            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

// MARK: - Layout Node View

/// Recursively renders a tmux layout tree as nested split views
private struct LayoutNodeView: View {
    let node: LayoutNode
    let panes: [PaneInfo]
    let onPaneStateChange: ((PaneInfo, StreamState, Int, Int) -> Void)?
    let onPaneTitleChange: ((PaneInfo, String) -> Void)?

    var body: some View {
        switch node {
        case let .pane(id, _, _):
            if let paneInfo = findPane(id: id) {
                TerminalContainerView(
                    paneInfo: paneInfo,
                    onStateChange: { state, width, height in
                        onPaneStateChange?(paneInfo, state, width, height)
                    },
                    onTitleChange: { title in
                        onPaneTitleChange?(paneInfo, title)
                    }
                )
            } else {
                Text("Pane %\(id) not found")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        case let .horizontal(children, totalWidth, _):
            GeometryReader { geometry in
                HStack(spacing: 1) {
                    ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                        LayoutNodeView(
                            node: child,
                            panes: panes,
                            onPaneStateChange: onPaneStateChange,
                            onPaneTitleChange: onPaneTitleChange
                        )
                        .frame(width: proportion(child.width, of: totalWidth, in: geometry.size.width, count: children.count))
                    }
                }
            }

        case let .vertical(children, _, totalHeight):
            GeometryReader { geometry in
                VStack(spacing: 1) {
                    ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                        LayoutNodeView(
                            node: child,
                            panes: panes,
                            onPaneStateChange: onPaneStateChange,
                            onPaneTitleChange: onPaneTitleChange
                        )
                        .frame(height: proportion(child.height, of: totalHeight, in: geometry.size.height, count: children.count))
                    }
                }
            }
        }
    }

    /// Finds a PaneInfo by its tmux pane number (stripping the "%" prefix from paneId)
    private func findPane(id: Int) -> PaneInfo? {
        panes.first { $0.paneId == "%\(id)" }
    }

    /// Calculates proportional size accounting for divider spacing
    private func proportion(_ childSize: Int, of totalSize: Int, in availableSize: CGFloat, count: Int) -> CGFloat {
        let dividerSpace = CGFloat(count - 1) // 1pt per divider
        let usableSpace = availableSize - dividerSpace
        return usableSpace * CGFloat(childSize) / CGFloat(totalSize)
    }
}
