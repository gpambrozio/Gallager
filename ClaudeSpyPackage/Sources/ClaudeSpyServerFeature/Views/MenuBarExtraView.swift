import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

/// The content view displayed in the menu bar dropdown
public struct MenuBarExtraView: View {
    @Environment(MirrorWindowManager.self) private var windowManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    public init() { }

    public var body: some View {
        Group {
            if windowManager.sortedSessions.isEmpty {
                Text("No active sessions")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(windowManager.sortedSessions, id: \.paneId) { session in
                    sessionButton(for: session)
                }
            }
        }

        Divider()

        Button {
            openWindow(id: "panes")
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            Label("Show Panes Window", symbol: .terminal)
        }
        .keyboardShortcut("p", modifiers: [.command, .shift])

        Button {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            Label("Settings...", symbol: .gearshape)
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit ClaudeSpy") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    // MARK: - Session Button

    @ViewBuilder
    private func sessionButton(for session: ClaudeSession) -> some View {
        Button {
            Task {
                await windowManager.openMirrorForPane(session.paneId)
                NSApp.activate(ignoringOtherApps: true)
            }
        } label: {
            let title = if let latestEvent = session.latestEvent {
                "\(session.displayName) • \(latestEvent.action.title)"
            } else {
                session.displayName
            }

            if session.needsAttention {
                Label(title, symbol: .exclamationmarkCircleFill)
                    .symbolRenderingMode(.multicolor)
            } else {
                Label(title, symbol: .checkmarkCircleFill)
                    .foregroundStyle(.green)
            }
        }
    }
}

// MARK: - Menu Bar Label

/// The label shown in the menu bar itself (sparkles icon with optional badge)
public struct MenuBarLabel: View {
    let pendingCount: Int

    public init(pendingCount: Int) {
        self.pendingCount = pendingCount
    }

    public var body: some View {
        if pendingCount > 0 {
            Label("\(pendingCount)", symbol: .sparkles)
        } else {
            Symbols.sparkles.image
        }
    }
}
