import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

/// The content view displayed in the menu bar dropdown
public struct MenuBarExtraView: View {
    @Environment(MirrorWindowManager.self) private var windowManager
    @Environment(AppSettings.self) private var settings
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    public init() { }

    /// Local tmux sessions in the exact order the sidebar shows them: the
    /// same inputs (`tmuxService.sessions` + tracked pane states), the same
    /// per-session sort data (`SessionSortData.forLocalSession`), and the same
    /// user-configured `sidebarSortMode`.
    private var localTmuxSessions: [LocalTmuxSession] {
        settings.sidebarSortMode.sorted(coordinator.tmuxService.sessions) { session in
            SessionSortData.forLocalSession(
                session,
                paneStates: windowManager.paneStates,
                lastActivity: { windowManager.lastActivity(for: $0) },
                sidebarFields: settings.sidebarFields,
                sidebarTerminalFields: settings.sidebarTerminalFields
            )
        }
    }

    /// Remote sessions per host, in the sidebar's order — mirrors
    /// `RemoteHostSidebarSection.sortedSessions` exactly. A host section
    /// appears when the host has ANY sessions, agent-owning or terminal-only.
    private var remoteSessionsByHost: [(host: PairedHost, sessions: [TmuxSession])] {
        guard let sessionStore = coordinator.remoteSessionStore else { return [] }
        return settings.pairedHosts.compactMap { host in
            let sessions = settings.sidebarSortMode.sorted(sessionStore.sessions(for: host.id)) { session in
                SessionSortData.forRemoteSession(
                    session,
                    sidebarFields: settings.sidebarFields,
                    sidebarTerminalFields: settings.sidebarTerminalFields,
                    homeDirectory: sessionStore.homeDirectoryByHost[host.id]
                )
            }
            guard !sessions.isEmpty else { return nil }
            return (host: host, sessions: sessions)
        }
    }

    public var body: some View {
        let local = localTmuxSessions
        let remote = remoteSessionsByHost
        let hasAny = !local.isEmpty || !remote.isEmpty

        // Cross-session usage rollup (issue #598): today's total across active
        // sessions, plus the top projects. In the dropdown — the dock badge
        // only carries the needs-attention count.
        if let overview = coordinator.usageOverview, !overview.isEmpty {
            Text("Today — \(usageTodayLine(overview))")
            ForEach(overview.projects.prefix(3)) { project in
                Text("\(project.projectName): \(project.costUSD.usdCostString)")
            }
            Divider()
        }

        Group {
            if !hasAny {
                Text("No active sessions")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(local) { session in
                    localSessionRows(for: session)
                }

                ForEach(remote, id: \.host.id) { entry in
                    Divider()
                    Text(entry.host.displayName(showUsername: settings.hasDuplicateHostName(for: entry.host)))
                        .foregroundStyle(.secondary)

                    ForEach(entry.sessions) { session in
                        remoteSessionRows(for: session, host: entry.host)
                    }
                }
            }
        }

        Divider()

        Button {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "panes")
            Self.bringAppToFront()
        } label: {
            Label("Show Sessions", symbol: .terminal)
        }
        .keyboardShortcut("p", modifiers: [.command, .shift])

        Button {
            NSApp.setActivationPolicy(.regular)
            openSettings()
            Self.bringAppToFront()
        } label: {
            Label("Settings...", symbol: .gearshape)
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit Gallager") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    // MARK: - Helpers

    /// Pre-rendered accent-tinted attention icon for use in NSMenuItem rows.
    /// `Color.accentColor` resolves to the system accent inside an NSMenu
    /// context, so we load the asset-catalog color via `Bundle.main`.
    @MainActor
    private static let attentionIconImage: NSImage? = {
        let renderer = ImageRenderer(
            content:
            Symbols.handsAndSparklesFill.image
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color("AccentColor", bundle: .main))
        )
        renderer.scale = 2
        let image = renderer.nsImage
        image?.isTemplate = false
        return image
    }()

    /// Activates the app and forces all visible windows to the front.
    /// SwiftUI's openWindow/openSettings defer window creation, so we
    /// schedule a delayed force-front to catch windows after they appear.
    public static func bringAppToFront() {
        NSApp.activate()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            NSApp.activate()
            for window in NSApp.windows where window.isVisible && window.level == .normal {
                window.orderFrontRegardless()
            }
        }
    }

    // MARK: - Session Rows

    /// Rows for one local tmux session, emitted in the session's sidebar
    /// position: one row per agent pane (window/pane order), or the session's
    /// single terminal-only row when no pane owns an agent.
    @ViewBuilder
    private func localSessionRows(for session: LocalTmuxSession) -> some View {
        let panes = session.windows.flatMap(\.panes).compactMap { windowManager.paneStates[$0.paneId] }
        let agents = panes.compactMap(\.agentSession)
        if agents.isEmpty {
            if let terminal = panes.terminalOnlySessions().first {
                localTerminalSessionButton(for: terminal)
            }
        } else {
            ForEach(agents, id: \.paneId) { agent in
                localSessionButton(for: agent)
            }
        }
    }

    /// Rows for one remote tmux session — same shape as `localSessionRows`,
    /// built from the pane states the host pushed.
    @ViewBuilder
    private func remoteSessionRows(for session: TmuxSession, host: PairedHost) -> some View {
        let panes = session.windows.flatMap(\.panes)
        let agents = panes.compactMap(\.agentSession)
        if agents.isEmpty {
            if let terminal = panes.terminalOnlySessions().first {
                remoteTerminalSessionButton(for: terminal, host: host)
            }
        } else {
            ForEach(agents, id: \.paneId) { agent in
                remoteSessionButton(for: agent, host: host)
            }
        }
    }

    // MARK: - Session Buttons

    private func localSessionButton(for session: AgentSession) -> some View {
        Button {
            coordinator.pendingMenuBarSelection = .local(paneId: session.paneId)
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "panes")
            Self.bringAppToFront()
        } label: {
            // An agent row always owns an agent session, so displayedState is
            // non-nil; fall back to idle (moon) defensively rather than the
            // terminal glyph.
            rowLabel(
                title: localTitle(for: session),
                displayedState: localDisplayedState(for: session) ?? .idle
            )
        }
    }

    private func remoteSessionButton(for session: AgentSession, host: PairedHost) -> some View {
        Button {
            coordinator.pendingMenuBarSelection = .remote(
                hostId: host.id,
                hostName: host.displayName,
                paneId: session.paneId
            )
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "panes")
            Self.bringAppToFront()
        } label: {
            rowLabel(
                title: remoteTitle(for: session, host: host),
                displayedState: remoteDisplayedState(for: session, host: host) ?? .idle
            )
        }
    }

    private func localTerminalSessionButton(for session: TerminalOnlySession) -> some View {
        Button {
            coordinator.pendingMenuBarSelection = .local(paneId: session.representativePaneId)
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "panes")
            Self.bringAppToFront()
        } label: {
            rowLabel(
                title: session.displayTitle(homeDirectory: nil),
                displayedState: session.displayedState
            )
        }
    }

    private func remoteTerminalSessionButton(for session: TerminalOnlySession, host: PairedHost) -> some View {
        Button {
            coordinator.pendingMenuBarSelection = .remote(
                hostId: host.id,
                hostName: host.displayName,
                paneId: session.representativePaneId
            )
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "panes")
            Self.bringAppToFront()
        } label: {
            // `~` must mean the HOST's home for remote paths, so abbreviate
            // against the home directory the host pushed with its snapshot.
            rowLabel(
                title: session.displayTitle(
                    homeDirectory: coordinator.remoteSessionStore?.homeDirectoryByHost[host.id]
                ),
                displayedState: session.displayedState
            )
        }
    }

    /// Row title for a local agent session: the user's session description
    /// when one is set, else the agent's project-derived name. Falls back to
    /// the agent's name if the pane isn't tracked.
    private func localTitle(for session: AgentSession) -> String {
        windowManager.paneStates[session.paneId]?.agentRowTitle ?? session.displayName
    }

    /// Row title for a remote agent session, honoring the session description
    /// the host pushed with its pane state.
    private func remoteTitle(for session: AgentSession, host: PairedHost) -> String {
        coordinator.remoteSessionStore?.paneState(for: session.paneId, hostId: host.id)?.agentRowTitle
            ?? session.displayName
    }

    /// Displayed state for a local session, honoring any manual "Set State"
    /// override on its pane (issue #702) so the menu row matches the sidebar's
    /// indicator. Falls back to the agent's own state if the pane isn't tracked.
    private func localDisplayedState(for session: AgentSession) -> CLISessionState? {
        windowManager.paneStates[session.paneId]?.displayedState
            ?? CLISessionState.displayed(override: nil, agentState: session.state)
    }

    /// Displayed state for a remote session, honoring the override the host
    /// pushed into the pane state (issue #702).
    private func remoteDisplayedState(for session: AgentSession, host: PairedHost) -> CLISessionState? {
        coordinator.remoteSessionStore?.paneState(for: session.paneId, hostId: host.id)?.displayedState
            ?? CLISessionState.displayed(override: nil, agentState: session.state)
    }

    /// Shared menu-row label. Menu items can't render ProgressView, so every
    /// state maps to an SF Symbol. The state honors the manual "Set State"
    /// override (issue #702) so rows match the sidebar's indicator; `nil` is
    /// the plain terminal glyph for an unpinned terminal-only session.
    @ViewBuilder
    private func rowLabel(title: String, displayedState: CLISessionState?) -> some View {
        switch displayedState {
        case .waiting:
            Label {
                Text(title)
            } icon: {
                // NSMenuItem renders SF Symbols as template images, stripping
                // foregroundStyle. Pre-render through ImageRenderer with
                // isTemplate=false so the accent color survives.
                if let image = Self.attentionIconImage {
                    Image(nsImage: image)
                } else {
                    Symbols.handsAndSparklesFill.image
                }
            }
        case .working:
            Label(title, symbol: .figureRun)
        case .idle:
            Label(title, symbol: .moonFill)
        case nil:
            Label(title, symbol: .terminal)
        }
    }
}

// MARK: - Menu Bar Label

/// The label shown in the menu bar itself (sparkles icon with optional badge)
/// Uses ImageRenderer to bypass SwiftUI's limitation where menu bar icons
/// don't respect color modifiers directly.
public struct MenuBarLabel: View {
    let pendingCount: Int
    @Environment(\.openWindow) private var openWindow

    public init(pendingCount: Int) {
        self.pendingCount = pendingCount
    }

    /// The icon view with color and badge - rendered to NSImage (only used when pendingCount > 0)
    private var iconView: some View {
        HStack(spacing: 4) {
            Symbols.handsAndSparklesFill.image
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)

            Text("\(pendingCount)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(Color("AccentColor", bundle: .main))
        )
    }

    /// Renders the icon view to an NSImage for proper color support
    private var renderedImage: NSImage? {
        let renderer = ImageRenderer(content: iconView)
        renderer.scale = 2 // Retina
        return renderer.nsImage
    }

    public var body: some View {
        Group {
            if pendingCount > 0, let image = renderedImage {
                Image(nsImage: image)
            } else {
                Symbols.sparkles.image
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPanesWindow)) { _ in
            openWindow(id: "panes")
        }
    }
}
