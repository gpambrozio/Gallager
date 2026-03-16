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

        /// The currently selected pane (receives keyboard input)
        @State private var activePaneId: String?

        /// Whether keyboard input is active on the selected pane
        @State private var isKeyboardActive = false

        /// Tracks keyboard visibility for toolbar icon state
        @State private var keyboardVisible = false

        /// Service for the active pane's Claude session (nil if no session)
        @State private var activeService: SessionDetailService?

        /// Whether to show the session info popover
        @State private var showSessionInfo = false

        /// Guards against sending selectTmuxPane on initial pane assignment
        @State private var hasInitializedPane = false

        /// The current window data from the session store
        private var window: TmuxWindow? {
            sessionStore.window(id: windowId, hostId: hostId)
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isKeyboardActive.toggle()
                    } label: {
                        Label(
                            keyboardVisible ? "Hide Keyboard" : "Show Keyboard",
                            symbol: keyboardVisible ? .keyboardChevronCompactDown : .keyboard
                        )
                    }
                    .disabled(!relayClient.isHostConnected)
                }

                if let activeService, activeService.session != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            let newValue = !activeService.isYoloModeEnabled
                            Task {
                                await activeService.sendCommand(.setYoloMode(enabled: newValue))
                            }
                        } label: {
                            Label(
                                activeService.isYoloModeEnabled ? "Disable Yolo Mode" : "Enable Yolo Mode",
                                symbol: .bolt
                            )
                        }
                        .tint(activeService.isYoloModeEnabled ? .red : nil)
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSessionInfo = true
                        } label: {
                            Label("Session Info", symbol: .infoCircle)
                        }
                        .popover(isPresented: $showSessionInfo) {
                            sessionInfoPopover
                        }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                keyboardVisible = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardVisible = false
            }
            .onAppear {
                // Default to the active pane (or first pane) on appear
                if activePaneId == nil, let window {
                    activePaneId = window.activePane?.paneId ?? window.panes.first?.paneId
                }
                updateActiveService()
                hasInitializedPane = true
            }
            .onChange(of: activePaneId) {
                updateActiveService()
                // Sync pane selection to the tmux session on the host
                // Guard: skip the initial assignment from onAppear to avoid
                // redirecting the host's tmux focus when the iOS view loads
                guard hasInitializedPane, let activePaneId else { return }
                Task {
                    await sendCommand(.selectTmuxPane, paneId: activePaneId)
                }
            }
        }

        @ViewBuilder
        private func windowContent(_ window: TmuxWindow) -> some View {
            VStack(spacing: 0) {
                // Response view for active pane's Claude session (full width, above layout)
                if
                    !isKeyboardActive,
                    let activeService,
                    let responseState = activeService.responseState,
                    let responseView = responseState.event.responseView(
                        isYoloMode: activeService.isYoloModeEnabled,
                        isConnected: relayClient.isHostConnected,
                        sendCommand: { command in
                            await activeService.sendCommand(command)
                        },
                        state: responseState
                    ) {
                    responseView
                        .padding()
                        .background(Color(.systemGroupedBackground))

                    Divider()
                }

                if let layout = TmuxLayoutParser.parse(window.windowLayout) {
                    tiledLayout(window: window, layout: layout)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    statusBar(window)
                } else {
                    // Fallback: list panes vertically if layout parsing fails
                    VStack(spacing: 1) {
                        ForEach(window.panes) { pane in
                            paneTerminal(pane: pane)
                        }
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
            let isMultiPane = positioned.count > 1

            return ProportionalTileLayout(rects: positioned.map(\.rect)) {
                ForEach(positioned) { pane in
                    let isSelected = pane.id == activePaneId
                    paneTerminal(pane: pane.paneState)
                        .overlay {
                            if isMultiPane {
                                // Border: accent for selected, subtle for others
                                Rectangle()
                                    .strokeBorder(
                                        isSelected ? Color.accentColor : Color.white.opacity(0.3),
                                        lineWidth: isSelected ? 2 : 1
                                    )
                            }
                            // Transparent tap target for non-active panes.
                            // UIKit terminal views absorb touches, so this overlay
                            // intercepts taps to allow pane selection.
                            if !isSelected && isMultiPane {
                                Color.clear
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        activePaneId = pane.id
                                    }
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
                showKeyboardButton: false,
                isActive: pane.paneId == activePaneId && isKeyboardActive,
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

                tmuxControls
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }

        // MARK: - Tmux Controls

        private var tmuxControls: some View {
            HStack(spacing: 12) {
                // Send tmux prefix key (Ctrl+B)
                Button {
                    guard let activePaneId else { return }
                    Task {
                        await sendCommand(.sendKeystroke([.ctrl("b")]), paneId: activePaneId)
                    }
                } label: {
                    Label("Tmux Prefix", symbol: .terminal)
                }

                // Split pane horizontally (left-right)
                Button {
                    guard let activePaneId else { return }
                    Task {
                        await sendCommand(.splitTmuxPane(direction: .horizontal), paneId: activePaneId)
                    }
                } label: {
                    Label("Split Horizontal", symbol: .rectangleSplit2x1Fill)
                }

                // Split pane vertically (top-bottom)
                Button {
                    guard let activePaneId else { return }
                    Task {
                        await sendCommand(.splitTmuxPane(direction: .vertical), paneId: activePaneId)
                    }
                } label: {
                    Label("Split Vertical", symbol: .rectangleSplit1x2Fill)
                }
            }
            .labelStyle(.iconOnly)
            .disabled(!relayClient.isHostConnected || activePaneId == nil)
        }

        // MARK: - Active Pane Service

        /// Creates or clears the SessionDetailService when the active pane changes
        private func updateActiveService() {
            guard let activePaneId else {
                activeService = nil
                return
            }
            // Only recreate if the pane changed
            if activeService?.paneId != activePaneId {
                activeService = SessionDetailService(
                    paneId: activePaneId,
                    sessionStore: sessionStore,
                    relayClient: relayClient
                )
            }
        }

        @ViewBuilder
        private var sessionInfoPopover: some View {
            if let activeService {
                NavigationStack {
                    SessionInfoView(
                        session: activeService.session,
                        paneId: activeService.paneId,
                        isPaneActive: activeService.isPaneActive
                    )
                    .navigationTitle("Session Info")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                showSessionInfo = false
                            }
                        }
                    }
                }
            }
        }

        // MARK: - Command Sending

        private func sendCommand(_ command: CommandType, paneId: String) async {
            await relayClient.send(command, paneId: paneId)
        }
    }

    // MARK: - Layout Helpers

    /// A positioned pane state within the layout
    private struct PositionedPaneState: Identifiable {
        let id: String
        let paneState: PaneState
        let rect: CGRect
    }

#endif
