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

    private var localSessions: [AgentSession] {
        windowManager.sortedSessions
    }

    private var remoteSessionsByHost: [(host: PairedHost, sessions: [AgentSession])] {
        guard let sessionStore = coordinator.remoteSessionStore else { return [] }
        return settings.pairedHosts.compactMap { host in
            let sessions = sessionStore.agentSessions(for: host.id).map(\.session)
            guard !sessions.isEmpty else { return nil }
            return (host: host, sessions: sessions)
        }
    }

    public var body: some View {
        let local = localSessions
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
                if !local.isEmpty {
                    ForEach(local, id: \.paneId) { session in
                        localSessionButton(for: session)
                    }
                }

                ForEach(remote, id: \.host.id) { entry in
                    Divider()
                    Text(entry.host.displayName(showUsername: settings.hasDuplicateHostName(for: entry.host)))
                        .foregroundStyle(.secondary)

                    ForEach(entry.sessions, id: \.paneId) { session in
                        remoteSessionButton(for: session, host: entry.host)
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

    // MARK: - Session Buttons

    private func localSessionButton(for session: AgentSession) -> some View {
        Button {
            coordinator.pendingMenuBarSelection = .local(paneId: session.paneId)
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "panes")
            Self.bringAppToFront()
        } label: {
            sessionLabel(for: session, displayedState: localDisplayedState(for: session))
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
            sessionLabel(for: session, displayedState: remoteDisplayedState(for: session, host: host))
        }
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

    @ViewBuilder
    private func sessionLabel(for session: AgentSession, displayedState: CLISessionState?) -> some View {
        // The plugin model dropped the per-event buffer (spec §16); the menu label
        // is just the session display name now.
        let title = session.displayName

        // Menu items can't render ProgressView, so use SF Symbols for all states.
        // The state honors the manual "Set State" override (issue #702), so the row
        // matches the sidebar's indicator rather than the raw agent state. A listed
        // session always owns an agent session, so `displayedState` is non-nil;
        // fall back to idle (moon) defensively.
        switch displayedState ?? .idle {
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
