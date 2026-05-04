import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

// MARK: - Proportional Tile Layout

/// A positioned pane within the layout, with proportional coordinates relative to the total window.
struct PositionedPane: Identifiable {
    let id: String // paneId (e.g., "%5")
    let paneInfo: PaneInfo
    /// Proportional rectangle (0..1) within the total layout area
    let rect: CGRect
}

/// Renders a `LocalTmuxWindow` by parsing its layout string and arranging
/// `TerminalContainerView` instances in the correct split arrangement.
struct WindowPaneLayoutView: View {
    let window: LocalTmuxWindow
    var onOpenURL: TerminalOpenURLHandler?

    @Environment(AppSettings.self) private var settings
    @Environment(MirrorWindowManager.self) private var windowManager

    var body: some View {
        if let layout = TmuxLayoutParser.parse(window.windowLayout) {
            VStack(spacing: 0) {
                tiledLayout(from: layout)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if settings.showStatusBar {
                    statusBar
                }
            }
        } else if
            window.isSinglePane, let pane = window.panes.first,
            let paneState = windowManager.paneStates[pane.paneId] {
            // Fallback for unparseable single-pane layout
            MirrorWindowView(paneState: paneState)
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

    // MARK: - Tiled Layout

    /// Flattens the layout tree into positioned rectangles and renders all terminals
    /// using a custom `Layout` that places each subview at its true position.
    /// This ensures hit-testing matches visual placement (unlike ZStack + offset).
    private func tiledLayout(from layout: LayoutNode) -> some View {
        let totalWidth = CGFloat(layout.width)
        let totalHeight = CGFloat(layout.height)
        var positioned: [PositionedPane] = []
        flattenNode(layout, origin: .zero, totalWidth: totalWidth, totalHeight: totalHeight, into: &positioned)

        // Filter to only panes that have valid state — this ensures the Layout's
        // rect count always matches the ForEach's subview count (no conditional gaps).
        let validPanes = positioned.filter { windowManager.paneStates[$0.paneInfo.paneId] != nil }
        let isSingle = validPanes.count == 1
        // Tmux's active pane (with fallback to the first pane). Used to decide
        // which terminal grabs focus when this window first appears so a
        // multi-pane window doesn't open with no pane selected.
        let activePaneId = window.activePane?.paneId

        return ProportionalTileLayout(rects: validPanes.map(\.rect)) {
            ForEach(validPanes) { pane in
                if let paneState = windowManager.paneStates[pane.paneInfo.paneId] {
                    PaneTileView(
                        paneState: paneState,
                        paneInfo: pane.paneInfo,
                        isSingle: isSingle,
                        isActiveInTmux: pane.paneInfo.paneId == activePaneId,
                        onOpenURL: onOpenURL
                    )
                    .id(pane.id)
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

    // MARK: - Pane Tile

    /// Wraps a terminal pane with hover-triggered split buttons.
    private struct PaneTileView: View {
        let paneState: PaneState
        let paneInfo: PaneInfo
        let isSingle: Bool
        /// True when this pane is the one tmux currently marks as active.
        /// Drives initial focus selection when the window appears so a
        /// multi-pane window opens with the tmux-active pane focused.
        let isActiveInTmux: Bool
        var onOpenURL: TerminalOpenURLHandler?

        @Environment(MirrorWindowManager.self) private var windowManager
        @Environment(TmuxService.self) private var tmuxService
        @State private var isHovering = false

        var body: some View {
            TerminalContainerView(
                paneState: paneState,
                autoFocus: isSingle || isActiveInTmux,
                onStateChange: { _, _, _ in },
                onTitleChange: { title in
                    windowManager.updateTerminalTitle(paneId: paneState.paneId, title: title)
                },
                onOpenURL: onOpenURL,
                onFocus: {
                    // Mirror focus back to tmux so external clients attached
                    // to this window land on the same active pane. Idempotent
                    // when the pane is already active (e.g., on initial focus).
                    let target = paneInfo.paneId
                    Task {
                        do {
                            try await tmuxService.selectPane(target)
                        } catch {
                            print("Failed to select tmux pane \(target): \(error)")
                        }
                    }
                }
            )
            .overlay {
                if !isSingle {
                    Rectangle()
                        .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
                }
            }
            .overlay {
                PaneEditorOverlay(paneId: paneState.paneId)
            }
            .overlay(alignment: .topTrailing) {
                PaneSplitButtons { direction in
                    do {
                        _ = try await tmuxService.splitPane(
                            paneInfo.paneId,
                            horizontal: direction == .horizontal
                        )
                    } catch {
                        print("Failed to split pane: \(error)")
                    }
                }
                .opacity(isHovering ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: isHovering)
            }
            .onHover { isHovering = $0 }
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack {
            Text("\(window.sessionName):\(window.windowIndex)")
                .font(.system(.caption, design: .monospaced))

            if window.panes.count > 1 {
                Divider()
                    .frame(height: 12)

                Text("\(window.panes.count) panes")
            }

            if let activePane = window.activePane {
                Divider()
                    .frame(height: 12)

                Text("\(activePane.width)x\(activePane.height)")
            }

            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
