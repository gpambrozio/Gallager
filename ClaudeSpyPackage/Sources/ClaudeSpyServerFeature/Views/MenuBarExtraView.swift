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
            } else {
                Text(title)
            }
        }
    }
}

// MARK: - Menu Bar Label

/// The label shown in the menu bar itself (sparkles icon with optional badge)
/// Uses ImageRenderer to bypass SwiftUI's limitation where menu bar icons
/// don't respect color modifiers directly.
public struct MenuBarLabel: View {
    let pendingCount: Int

    public init(pendingCount: Int) {
        self.pendingCount = pendingCount
    }

    /// The icon view with color and badge - rendered to NSImage (only used when pendingCount > 0)
    private var iconView: some View {
        HStack(spacing: 2) {
            Symbols.handsAndSparklesFill.image
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.red)

            Text("\(pendingCount)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(.red)
                )
        }
    }

    /// Renders the icon view to an NSImage for proper color support
    private var renderedImage: NSImage? {
        let renderer = ImageRenderer(content: iconView)
        renderer.scale = 2 // Retina
        return renderer.nsImage
    }

    public var body: some View {
        if pendingCount > 0, let image = renderedImage {
            Image(nsImage: image)
        } else {
            Symbols.sparkles.image
        }
    }
}
