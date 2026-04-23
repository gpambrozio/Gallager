import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

// MARK: - Proportional Tile Layout

/// A positioned remote pane within the layout, with proportional coordinates.
private struct PositionedRemotePane: Identifiable {
    let id: String // paneId (e.g., "%5")
    let paneState: PaneState
    /// Proportional rectangle (0..1) within the total layout area
    let rect: CGRect
}

/// Renders a remote `TmuxWindow` by parsing its layout string and arranging
/// `RemoteTerminalContainerView` instances in the correct split arrangement,
/// matching the local `WindowPaneLayoutView`.
struct RemoteWindowPaneLayoutView: View {
    let window: TmuxWindow
    let connection: ViewerConnection
    let settings: AppSettings

    var body: some View {
        if let layout = TmuxLayoutParser.parse(window.windowLayout) {
            VStack(spacing: 0) {
                tiledLayout(from: layout)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if settings.showStatusBar {
                    statusBar
                }
            }
        } else if window.isSinglePane, let pane = window.panes.first {
            // Fallback for unparseable single-pane layout
            singlePaneView(pane: pane)
        } else {
            // Fallback: stack panes vertically if layout parsing fails
            VStack(spacing: 1) {
                ForEach(window.panes) { pane in
                    singlePaneView(pane: pane)
                }
            }
        }
    }

    // MARK: - Tiled Layout

    private func tiledLayout(from layout: LayoutNode) -> some View {
        let totalWidth = CGFloat(layout.width)
        let totalHeight = CGFloat(layout.height)
        var positioned: [PositionedRemotePane] = []
        flattenNode(layout, origin: .zero, totalWidth: totalWidth, totalHeight: totalHeight, into: &positioned)

        let isSingle = positioned.count == 1

        return ProportionalTileLayout(rects: positioned.map(\.rect)) {
            ForEach(positioned) { pane in
                RemotePaneTileView(
                    paneState: pane.paneState,
                    connection: connection,
                    settings: settings,
                    isSingle: isSingle
                )
                .id(pane.id)
            }
        }
    }

    private func flattenNode(
        _ node: LayoutNode,
        origin: CGPoint,
        totalWidth: CGFloat,
        totalHeight: CGFloat,
        into result: inout [PositionedRemotePane]
    ) {
        switch node {
        case let .pane(id, width, height):
            let paneIdString = "%\(id)"
            if let paneState = window.panes.first(where: { $0.paneId == paneIdString }) {
                let rect = CGRect(
                    x: origin.x,
                    y: origin.y,
                    width: CGFloat(width) / totalWidth,
                    height: CGFloat(height) / totalHeight
                )
                result.append(PositionedRemotePane(id: paneIdString, paneState: paneState, rect: rect))
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

    // MARK: - Single Pane Fallback

    private func singlePaneView(pane: PaneState) -> some View {
        RemoteTerminalContainerView(
            paneId: pane.paneId,
            hostName: connection.hostName,
            connection: connection,
            settings: settings,
            showStatusBar: false,
            isEditorActive: pane.editorSession != nil
        )
        .overlay {
            if let editorInfo = pane.editorSession {
                RemotePaneEditorOverlay(
                    sessionId: editorInfo.sessionId,
                    initialContent: editorInfo.content,
                    connection: connection,
                    paneId: pane.paneId
                )
            }
        }
    }

    // MARK: - Pane Tile

    /// Wraps a remote terminal pane with hover-triggered split buttons,
    /// mirroring the local `PaneTileView` so remote panes get the same
    /// top-right split controls as local panes.
    private struct RemotePaneTileView: View {
        let paneState: PaneState
        let connection: ViewerConnection
        let settings: AppSettings
        let isSingle: Bool

        @State private var isHovering = false

        var body: some View {
            RemoteTerminalContainerView(
                paneId: paneState.paneId,
                hostName: connection.hostName,
                connection: connection,
                settings: settings,
                showStatusBar: false,
                isEditorActive: paneState.editorSession != nil
            )
            .overlay {
                if !isSingle {
                    Rectangle()
                        .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
                }
            }
            .overlay {
                if let editorInfo = paneState.editorSession {
                    RemotePaneEditorOverlay(
                        sessionId: editorInfo.sessionId,
                        initialContent: editorInfo.content,
                        connection: connection,
                        paneId: paneState.paneId
                    )
                }
            }
            .overlay(alignment: .topTrailing) {
                PaneSplitButtons { direction in
                    _ = await connection.sendCommand(
                        SplitTmuxPane(direction: direction),
                        paneId: paneState.paneId
                    )
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

/// Wrapper for `PromptEditorOverlay` in remote viewer contexts.
///
/// Edits are persisted in `RemoteEditorContentStore` keyed by `sessionId`, so they
/// survive SwiftUI view teardown/recreation (tab switch, window tab rebuild) just
/// like the host-side overlay persists via `EditorSessionManager.editedContents`.
private struct RemotePaneEditorOverlay: View {
    let sessionId: UUID
    let initialContent: String
    let connection: ViewerConnection
    let paneId: String

    @Environment(RemoteEditorContentStore.self) private var store

    var body: some View {
        PromptEditorOverlay(
            content: Binding(
                get: { store.editedContents[sessionId] ?? initialContent },
                set: { store.editedContents[sessionId] = $0 }
            ),
            onSubmit: { content in
                Task {
                    // Only clear on success — on a transient relay failure the host's
                    // session stays open and the overlay remains visible, so keeping
                    // the edit in the store lets the user retry without retyping.
                    if
                        case .success = await connection.sendCommand(
                            SubmitEditorContent(content: content),
                            paneId: paneId
                        ) {
                        store.clear(sessionId: sessionId)
                    }
                }
            },
            onCancel: {
                Task {
                    if
                        case .success = await connection.sendCommand(
                            CancelEditorSession(),
                            paneId: paneId
                        ) {
                        store.clear(sessionId: sessionId)
                    }
                }
            }
        )
    }
}
