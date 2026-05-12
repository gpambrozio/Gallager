import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

/// Toolbar items shown to the right of the title bar — connection status,
/// yolo/terminal/resize/close actions for the active session (local or
/// remote), and a refresh button. Lifted out of `MainView` so the main view
/// can focus on cross-cutting state.
///
/// The local/remote yolo bindings and the resize state are created inside
/// this view; the `onPerformResize` and `onRefresh` callbacks reach back to
/// the parent's debounced resize task and tmux refresh, which need to live
/// alongside MainView's selection state.
struct MainToolbarContent: ToolbarContent {
    let selectedWindow: LocalTmuxWindow?
    let selectedRemoteSession: RemoteSessionSelection?
    let selectedRemoteWindow: TmuxWindow?

    @Binding var autoResizeEnabled: Set<String>
    @Binding var autoResizeDisabled: Set<String>

    /// Routes selection-side toolbar actions back to MainView.
    let onAttachTerminal: (PaneInfo) -> Void
    let onCloseLocalSession: (String) -> Void
    let onCloseRemoteSession: (_ sessionName: String, _ hostId: String) -> Void
    let onRefresh: () -> Void
    /// Triggers a resize using the same logic as the auto-resize task. Exactly
    /// one of `localTarget` or `(remoteHostId, remotePaneId)` is non-nil.
    let onPerformResize: (
        _ localTarget: String?,
        _ remoteHostId: String?,
        _ remotePaneId: String?
    ) -> Void

    @Environment(TmuxService.self) private var tmuxService
    @Environment(MirrorWindowManager.self) private var windowManager
    @Environment(AppSettings.self) private var settings
    @Environment(AppCoordinator.self) private var coordinator

    var body: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            MainConnectionStatusView()
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if let window = selectedWindow, selectedRemoteSession == nil {
                localToolbarItems(window: window)
            } else if let remote = selectedRemoteSession, let remoteWindow = selectedRemoteWindow {
                remoteToolbarItems(remote: remote, remoteWindow: remoteWindow)
            }

            Button {
                onRefresh()
            } label: {
                Symbols.arrowClockwise.image
            }
            .help("Refresh pane list")
            .keyboardShortcut("r", modifiers: .command)
            .disabled(tmuxService.isRefreshing)
        }
    }

    @ViewBuilder
    private func localToolbarItems(window: LocalTmuxWindow) -> some View {
        let claudePane = window.panes.first { windowManager.paneStates[$0.paneId]?.claudeSession != nil }
        let activePane = window.activePane

        if let claudePane {
            Toggle(isOn: localYoloModeBinding(for: claudePane.paneId)) {
                Symbols.bolt.image
            }
            .toggleStyle(.button)
            .help(
                windowManager.isYoloModeEnabled(for: claudePane.paneId)
                    ? "Yolo mode: auto-approving permissions (click to disable)"
                    : "Enable yolo mode to auto-approve permissions"
            )
        }

        if let activePane {
            Button {
                onAttachTerminal(activePane)
            } label: {
                Symbols.macwindow.image
            }
            .help("Open session in terminal app")

            resizeToolbarGroup(
                resizeKey: activePane.paneId,
                localTarget: activePane.target,
                isSessionAttached: tmuxService.attachedSessionNames.contains(window.sessionName)
            )
        }

        Button {
            onCloseLocalSession(window.sessionName)
        } label: {
            Symbols.xmark.image
        }
        .help("Close session")
    }

    @ViewBuilder
    private func remoteToolbarItems(
        remote: RemoteSessionSelection,
        remoteWindow: TmuxWindow
    ) -> some View {
        let claudePaneId = remoteWindow.panes.first(where: { $0.claudeSession != nil })?.paneId
        if
            let claudePaneId,
            let sessionStore = coordinator.remoteSessionStore,
            sessionStore.session(for: claudePaneId, hostId: remote.hostId) != nil {
            Toggle(isOn: Binding(
                get: { sessionStore.isYoloModeEnabled(paneId: claudePaneId, hostId: remote.hostId) },
                set: { newValue in
                    Task {
                        guard let manager = coordinator.viewerConnectionManager else { return }
                        _ = await manager.sendCommand(
                            SetYoloMode(enabled: newValue),
                            paneId: claudePaneId,
                            hostId: remote.hostId
                        )
                    }
                }
            )) {
                Symbols.bolt.image
            }
            .toggleStyle(.button)
            .help(
                coordinator.remoteSessionStore?.isYoloModeEnabled(paneId: claudePaneId, hostId: remote.hostId) == true
                    ? "Yolo mode: auto-approving permissions (click to disable)"
                    : "Enable yolo mode to auto-approve permissions"
            )
        }

        if let activePane = remoteWindow.activePane {
            let resizeKey = remote.resizeKey(paneId: activePane.paneId)
            resizeToolbarGroup(
                resizeKey: resizeKey,
                remoteHostId: remote.hostId,
                remotePaneId: activePane.paneId
            )
        }

        Button {
            onCloseRemoteSession(remote.sessionName, remote.hostId)
        } label: {
            Symbols.xmark.image
        }
        .help("Close session")
    }

    private func localYoloModeBinding(for paneId: String) -> Binding<Bool> {
        Binding(
            get: { windowManager.isYoloModeEnabled(for: paneId) },
            set: { newValue in
                windowManager.setYoloMode(enabled: newValue, for: paneId)
                Task {
                    await coordinator.connectedViewerManager?.pushSessionStateToAll()
                }
            }
        )
    }

    @ViewBuilder
    private func resizeToolbarGroup(
        resizeKey: String,
        localTarget: String? = nil,
        remoteHostId: String? = nil,
        remotePaneId: String? = nil,
        isSessionAttached: Bool = false
    ) -> some View {
        let attachedHelp = "Cannot resize: session is attached to a terminal"
        let autoResizeActive = isAutoResizeActive(for: resizeKey)

        // Hide manual resize button when auto-resize is active
        if !autoResizeActive {
            Button {
                onPerformResize(localTarget, remoteHostId, remotePaneId)
            } label: {
                Symbols.arrowUpLeftAndArrowDownRight.image
            }
            .help(isSessionAttached ? attachedHelp : "Resize tmux pane to fit mirror view")
            .disabled(isSessionAttached)
        }

        Toggle(isOn: Binding(
            get: { autoResizeActive },
            set: { enabled in
                if enabled {
                    autoResizeDisabled.remove(resizeKey)
                    autoResizeEnabled.insert(resizeKey)
                    onPerformResize(localTarget, remoteHostId, remotePaneId)
                } else {
                    autoResizeDisabled.insert(resizeKey)
                    autoResizeEnabled.remove(resizeKey)
                }
            }
        )) {
            Symbols.arrowDownRightAndArrowUpLeft.image
        }
        .toggleStyle(.button)
        .help(isSessionAttached ? attachedHelp : "Auto-resize tmux pane when mirror view changes size")
        .disabled(isSessionAttached)
    }

    /// Mirror of `MainView.isAutoResizeActive` so the toolbar can derive the
    /// resize button/toggle state without round-tripping through a callback.
    private func isAutoResizeActive(for key: String) -> Bool {
        if settings.alwaysAutoResize {
            return !autoResizeDisabled.contains(key)
        }
        return autoResizeEnabled.contains(key)
    }
}
