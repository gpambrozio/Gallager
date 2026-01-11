import AppKit
import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

/// Menu bar extra content displaying Claude sessions and app controls
public struct MenuBarView: View {
    @Environment(MirrorWindowManager.self) private var windowManager
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    public init() { }

    public var body: some View {
        Group {
            if windowManager.activeSessions.isEmpty {
                Text("No active sessions")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sortedSessions, id: \.paneId) { session in
                    sessionButton(for: session)
                }
            }

            Divider()

            Button("Show Panes Window") {
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }

            SettingsLink {
                Text("Settings...")
            }

            Divider()

            Button("Quit ClaudeSpy") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    /// Sessions sorted with needsAttention first, then by display name
    private var sortedSessions: [ClaudeSession] {
        windowManager.activeSessions.values.sorted { lhs, rhs in
            // Sessions needing attention come first
            if lhs.needsAttention != rhs.needsAttention {
                return lhs.needsAttention
            }
            // Then sort by display name
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    @ViewBuilder
    private func sessionButton(for session: ClaudeSession) -> some View {
        Button {
            Task { @MainActor in
                await windowManager.openMirrorForPane(session.paneId)
            }
        } label: {
            HStack {
                if session.needsAttention {
                    Symbols.sparkles.image
                        .foregroundStyle(.purple)
                }
                Text(session.displayName)
                Spacer()
                if let event = session.latestEvent {
                    Text(event.action.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The menu bar extra icon with optional badge
public struct MenuBarIcon: View {
    @Environment(MirrorWindowManager.self) private var windowManager

    public init() { }

    private var hasPending: Bool {
        windowManager.activeSessions.values.contains(where: \.needsAttention)
    }

    public var body: some View {
        if hasPending {
            Symbols.handsAndSparklesFill.image
        } else {
            Symbols.sparkles.image
        }
    }
}
