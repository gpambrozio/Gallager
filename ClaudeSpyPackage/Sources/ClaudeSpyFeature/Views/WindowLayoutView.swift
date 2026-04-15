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
        let sessionName: String
        let hostId: String
        let relayClient: ViewerRelayClient
        let settings: IOSSettings

        @Environment(SessionStore.self) private var sessionStore

        /// The currently selected window within the session
        @State private var selectedWindowId: String?

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

        /// Guards against double-splits from rapid taps
        @State private var isSplitting = false

        /// Terminal titles detected via OSC escape sequences, keyed by pane ID
        @State private var terminalTitles: [String: String] = [:]

        /// All windows in this session
        private var sessionWindows: [TmuxWindow] {
            sessionStore.windows(for: hostId).filter { $0.sessionName == sessionName }
                .sorted { $0.windowIndex < $1.windowIndex }
        }

        /// The current window data from the session store
        private var window: TmuxWindow? {
            if let selectedWindowId {
                return sessionStore.window(id: selectedWindowId, hostId: hostId)
            }
            // Default to the active window in the session
            return sessionWindows.first(where: \.isWindowActive) ?? sessionWindows.first
        }

        /// Navigation title: prefer custom description, then active pane's terminal title, then session name
        private var navigationTitle: String {
            if let desc = window?.customDescription { return desc }
            // Use the locally-captured OSC title first (updates in real-time)
            if let activeId = activePaneId, let title = terminalTitles[activeId] { return title }
            // For single-pane windows, use that pane's title even if not "active" yet
            if
                let panes = window?.panes, panes.count == 1,
                let pane = panes.first {
                if let title = terminalTitles[pane.paneId] { return title }
                // Fall back to the relay-provided terminal title
                if let title = sessionStore.paneStates[pane.paneId]?.terminalTitle { return title }
            }
            return sessionName
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Window switcher as title menu (placement: .principal replaces the title)
                ToolbarItem(placement: .principal) {
                    Menu {
                        let windows = sessionWindows
                        ForEach(windows) { win in
                            Button {
                                selectedWindowId = win.id
                                activePaneId = win.activePane?.paneId ?? win.panes.first?.paneId
                                Task {
                                    await sendCommand(.selectTmuxWindow, paneId: win.id)
                                }
                            } label: {
                                if win.id == (selectedWindowId ?? window?.id) {
                                    Label(windowTabLabel(for: win), symbol: .checkmark)
                                } else {
                                    Text(windowTabLabel(for: win))
                                }
                            }
                        }

                        Divider()

                        Button {
                            Task {
                                let workingDir = window?.activePane?.currentPath
                                let spec = CreateTmuxWindow(sessionName: sessionName, workingDirectory: workingDir)
                                let result = await relayClient.sendCommand(spec, paneId: "")
                                if case let .success(response) = result, let paneId = response.paneId {
                                    await relayClient.requestSessionState()
                                    try? await Task.sleep(for: .milliseconds(500))
                                    if let newWindow = sessionWindows.first(where: { $0.panes.contains(where: { $0.paneId == paneId }) }) {
                                        selectedWindowId = newWindow.id
                                        activePaneId = paneId
                                    }
                                }
                            }
                        } label: {
                            Label("New Window", symbol: .plus)
                        }
                        .disabled(!relayClient.isHostConnected)
                    } label: {
                        HStack(spacing: 4) {
                            Text(navigationTitle)
                                .fontWeight(.semibold)
                            Symbols.chevronDown.image
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            isKeyboardActive.toggle()
                        } label: {
                            Label(
                                keyboardVisible ? "Hide Keyboard" : "Show Keyboard",
                                symbol: keyboardVisible ? .keyboardChevronCompactDown : .keyboard
                            )
                        }
                        .disabled(!relayClient.isHostConnected)

                        if let activeService, activeService.session != nil {
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

                            Button {
                                showSessionInfo = true
                            } label: {
                                Label("Session Info", symbol: .infoCircle)
                            }
                        }
                    } label: {
                        Label("Commands", symbol: .ellipsisCircle)
                    }
                    .popover(isPresented: $showSessionInfo) {
                        sessionInfoPopover
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                keyboardVisible = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardVisible = false
            }
            .task {
                // Default to the active window in the session
                if selectedWindowId == nil {
                    selectedWindowId = window?.id
                }
                // Default to the active pane (or first pane) on appear
                if activePaneId == nil, let window {
                    activePaneId = window.activePane?.paneId ?? window.panes.first?.paneId
                }
                updateActiveService()
                // Mark session as handled when navigating into the view
                await activeService?.markHandledIfNeeded()
            }
            .onChange(of: activeService?.session?.needsAttention) {
                if activeService?.session?.needsAttention == true {
                    Task { await activeService?.markHandledIfNeeded() }
                }
            }
            .onChange(of: activePaneId) { oldValue, newValue in
                updateActiveService()
                // Mark session as handled when switching to a pane with attention
                Task { await activeService?.markHandledIfNeeded() }
                // Sync pane selection to the tmux session on the host.
                // When oldValue is nil, it's the initial assignment from onAppear
                // — skip it to avoid redirecting the host's tmux focus on load.
                guard oldValue != nil, let newValue else { return }
                Task {
                    await sendCommand(.selectTmuxPane, paneId: newValue)
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
                terminalTitle: Binding(
                    get: { terminalTitles[pane.paneId] },
                    set: { terminalTitles[pane.paneId] = $0 }
                ),
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
                Text("\(window.sessionName):\(window.windowIndex)")
                    .font(.system(.caption, design: .monospaced))

                if window.panes.count > 1 {
                    Divider()
                        .frame(height: 12)

                    Text("\(window.panes.count) panes")
                }

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
                    guard let activePaneId, !isSplitting else { return }
                    isSplitting = true
                    Task {
                        await sendCommand(.splitTmuxPane(direction: .horizontal), paneId: activePaneId)
                        isSplitting = false
                    }
                } label: {
                    Label("Split Horizontal", symbol: .rectangleSplit2x1Fill)
                }

                // Split pane vertically (top-bottom)
                Button {
                    guard let activePaneId, !isSplitting else { return }
                    isSplitting = true
                    Task {
                        await sendCommand(.splitTmuxPane(direction: .vertical), paneId: activePaneId)
                        isSplitting = false
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

        // MARK: - Window Tab Label

        private func windowTabLabel(for win: TmuxWindow) -> String {
            if !win.windowName.isEmpty, Int(win.windowName) == nil {
                return "\(win.windowIndex): \(win.windowName)"
            }
            return "Window \(win.windowIndex)"
        }

        // MARK: - Command Sending

        private func sendCommand(_ command: CommandType, paneId: String) async {
            await relayClient.send(command, paneId: paneId)
        }
    }

    // MARK: - Session Info

    struct SessionInfoView: View {
        let session: ClaudeSession?
        let paneId: String
        let isPaneActive: Bool

        var body: some View {
            if let session {
                List {
                    Section("Recent Events") {
                        if session.events.isEmpty {
                            Text("No events yet")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(session.events) { event in
                                EventRowView(event: event)
                            }
                        }
                    }

                    Section("Session Info") {
                        LabeledContent("Pane ID", value: paneId)

                        if let projectPath = session.events.first?.projectPath {
                            LabeledContent("Project") {
                                Text(projectPath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        LabeledContent("Status") {
                            HStack {
                                Circle()
                                    .fill(isPaneActive ? Color.green : Color.gray)
                                    .frame(width: 8, height: 8)
                                Text(isPaneActive ? "Active" : "Inactive")
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "Session Not Found",
                    symbol: .exclamationmarkTriangle,
                    description: "This session may have ended."
                )
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

#endif
