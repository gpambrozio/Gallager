#if os(iOS)
    import ClaudeSpyCommon
    import ClaudeSpyNetworking
    import SwiftUI

    /// Renders a multi-pane tmux window on iOS.
    ///
    /// Parses the window's layout string using `TmuxLayoutParser` to arrange
    /// `LiveTerminalView` instances in the correct split arrangement,
    /// matching the macOS `WindowPaneLayoutView`.
    struct WindowLayoutView: View {
        let windowId: String
        let hostId: String
        let relayClient: ViewerRelayClient
        let settings: IOSSettings

        @Environment(SessionStore.self) private var sessionStore

        /// The current window data from the session store
        private var window: TmuxWindow? {
            sessionStore.windows(for: hostId).first { $0.id == windowId }
        }

        var body: some View {
            Group {
                if let window {
                    windowContent(window)
                } else {
                    ContentUnavailableView(
                        "Window Not Found",
                        symbol: .exclamationmarkTriangle,
                        description: "This window may have been closed."
                    )
                }
            }
            .navigationTitle(window?.customDescription ?? windowId)
            .navigationBarTitleDisplayMode(.inline)
        }

        @ViewBuilder
        private func windowContent(_ window: TmuxWindow) -> some View {
            if let layout = TmuxLayoutParser.parse(window.windowLayout) {
                VStack(spacing: 0) {
                    tiledLayout(window: window, layout: layout)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    statusBar(window)
                }
            } else {
                // Fallback: list panes vertically if layout parsing fails
                VStack(spacing: 1) {
                    ForEach(window.panes) { pane in
                        paneTerminal(pane: pane)
                    }
                }
            }
        }

        // MARK: - Tiled Layout

        private func tiledLayout(window: TmuxWindow, layout: LayoutNode) -> some View {
            let totalWidth = CGFloat(layout.width)
            let totalHeight = CGFloat(layout.height)
            var positioned: [PositionedPaneState] = []
            flattenNode(
                layout, window: window, origin: .zero,
                totalWidth: totalWidth, totalHeight: totalHeight,
                into: &positioned
            )

            return ProportionalTileLayout(rects: positioned.map(\.rect)) {
                ForEach(positioned) { pane in
                    paneTerminal(pane: pane.paneState)
                        .overlay {
                            if positioned.count > 1 {
                                Rectangle()
                                    .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
                            }
                        }
                }
            }
        }

        private func flattenNode(
            _ node: LayoutNode,
            window: TmuxWindow,
            origin: CGPoint,
            totalWidth: CGFloat,
            totalHeight: CGFloat,
            into result: inout [PositionedPaneState]
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
                    result.append(PositionedPaneState(id: paneIdString, paneState: paneState, rect: rect))
                }

            case let .horizontal(children, _, _):
                var xOffset = origin.x
                for child in children {
                    flattenNode(
                        child, window: window,
                        origin: CGPoint(x: xOffset, y: origin.y),
                        totalWidth: totalWidth, totalHeight: totalHeight,
                        into: &result
                    )
                    xOffset += CGFloat(child.width) / totalWidth
                }

            case let .vertical(children, _, _):
                var yOffset = origin.y
                for child in children {
                    flattenNode(
                        child, window: window,
                        origin: CGPoint(x: origin.x, y: yOffset),
                        totalWidth: totalWidth, totalHeight: totalHeight,
                        into: &result
                    )
                    yOffset += CGFloat(child.height) / totalHeight
                }
            }
        }

        // MARK: - Pane Terminal

        @ViewBuilder
        private func paneTerminal(pane: PaneState) -> some View {
            LiveTerminalView(
                paneId: pane.paneId,
                responseState: .constant(nil),
                terminalTitle: .constant(nil),
                isConnected: relayClient.isHostConnected,
                hideNavigationBar: false,
                settings: settings,
                sendCommand: { command in
                    await sendCommand(command, paneId: pane.paneId)
                }
            )
            .environment(relayClient)
        }

        // MARK: - Status Bar

        private func statusBar(_ window: TmuxWindow) -> some View {
            HStack {
                Text(window.id)
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

        // MARK: - Command Sending

        private func sendCommand(_ command: CommandType, paneId: String) async {
            switch command {
            case let .sendKeystroke(spec):
                _ = await relayClient.sendCommand(spec, paneId: paneId)
            case let .cancelOperation(spec):
                _ = await relayClient.sendCommand(spec, paneId: paneId)
            case let .startTerminalStream(spec):
                _ = await relayClient.sendCommand(spec, paneId: paneId)
            case let .stopTerminalStream(spec):
                _ = await relayClient.sendCommand(spec, paneId: paneId)
            case let .createTmuxSession(spec):
                _ = await relayClient.sendCommand(spec, paneId: "")
            case let .resizeTmuxPane(spec):
                _ = await relayClient.sendCommand(spec, paneId: paneId)
            case let .setYoloMode(spec):
                _ = await relayClient.sendCommand(spec, paneId: paneId)
            case let .setWindowDescription(spec):
                _ = await relayClient.sendCommand(spec, paneId: "")
            }
        }
    }

    // MARK: - Layout Helpers

    /// A positioned pane state within the layout
    private struct PositionedPaneState: Identifiable {
        let id: String
        let paneState: PaneState
        let rect: CGRect
    }

    /// Custom Layout that tiles subviews using proportional rectangles
    private struct ProportionalTileLayout: Layout {
        let rects: [CGRect]

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            proposal.replacingUnspecifiedDimensions()
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            for (index, subview) in subviews.enumerated() {
                guard index < rects.count else { continue }
                let proportional = rects[index]
                let width = proportional.width * bounds.width
                let height = proportional.height * bounds.height
                let x = bounds.minX + proportional.origin.x * bounds.width
                let y = bounds.minY + proportional.origin.y * bounds.height
                subview.place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: width, height: height)
                )
            }
        }
    }
#endif
