import ClaudeSpyCommon
import SwiftUI

/// Displays a list of available tmux panes
struct PaneListView: View {
    let panes: [PaneInfo]
    let isLoading: Bool
    let error: String?
    let onRefresh: () async -> Void
    let onOpenMirror: (PaneInfo) -> Void
    let onAttachTerminal: (PaneInfo) -> Void

    var body: some View {
        Group {
            if isLoading && panes.isEmpty {
                loadingView
            } else if let error, panes.isEmpty {
                errorView(error)
            } else if panes.isEmpty {
                emptyView
            } else {
                paneList
            }
        }
        .frame(minWidth: 400, minHeight: 200)
    }

    // MARK: - Subviews

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading panes...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        ContentUnavailableView(
            "Error Loading Panes",
            symbol: .exclamationmarkTriangle,
            description: message
        )
    }

    private var emptyView: some View {
        ContentUnavailableView(
            "No Panes Available",
            symbol: .terminal,
            description: "Start tmux and create some panes to mirror."
        )
    }

    private var paneList: some View {
        List {
            Section {
                ForEach(panes) { pane in
                    PaneRow(
                        pane: pane,
                        onOpen: { onOpenMirror(pane) },
                        onAttach: { onAttachTerminal(pane) }
                    )
                }
            } header: {
                HStack {
                    Text("Target")
                        .frame(width: 120, alignment: .leading)
                    Text("Command")
                        .frame(width: 120, alignment: .leading)
                    Text("Directory")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("")
                        .frame(width: 90) // Space for Claude icon + two buttons
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset)
        .refreshable {
            await onRefresh()
        }
    }
}

/// A row displaying a single pane
private struct PaneRow: View {
    @Environment(MirrorWindowManager.self) private var windowManager

    let pane: PaneInfo
    let onOpen: () -> Void
    let onAttach: () -> Void

    /// Check if pane has active Claude session
    private var hasClaude: Bool {
        windowManager.paneStates[pane.paneId]?.claudeSession != nil
    }

    var body: some View {
        HStack {
            Text(pane.target)
                .font(.system(.body, design: .monospaced))
                .frame(width: 120, alignment: .leading)

            Text(pane.command)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)

            Text(pane.currentPath.abbreviatedPath)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if hasClaude {
                Symbols.sparkles.image
                    .foregroundStyle(.purple)
                    .help("Claude Code session active")
            }

            Button(action: onAttach) {
                Symbols.macwindow.image
            }
            .buttonStyle(.borderless)
            .help("Open session in terminal app")

            Button(action: onOpen) {
                Symbols.arrowRight.image
            }
            .buttonStyle(.borderless)
            .help("Open mirror window")
        }
        .padding(.vertical, 4)
    }
}

private struct PaneListPreview: View {
    @State private var settings = AppSettings()
    @State private var tmuxService = TmuxService()
    @State private var windowManager: MirrorWindowManager?

    var body: some View {
        Group {
            if let windowManager {
                PaneListView(
                    panes: [
                        PaneInfo(
                            paneId: "%0",
                            target: "main:0.0",
                            sessionName: "main",
                            windowIndex: 0,
                            paneIndex: 0,
                            command: "vim",
                            currentPath: "/Users/test/projects",
                            width: 80,
                            height: 24,
                            isActive: true
                        ),
                        PaneInfo(
                            paneId: "%1",
                            target: "main:0.1",
                            sessionName: "main",
                            windowIndex: 0,
                            paneIndex: 1,
                            command: "node server.js",
                            currentPath: "/Users/test/app",
                            width: 80,
                            height: 24,
                            isActive: false
                        ),
                    ],
                    isLoading: false,
                    error: nil,
                    onRefresh: { },
                    onOpenMirror: { _ in },
                    onAttachTerminal: { _ in }
                )
                .environment(windowManager)
            }
        }
        .onAppear {
            let controlClientManager = TmuxControlClientManager(
                tmuxPath: settings.tmuxPath,
                socketPath: settings.tmuxSocket.isEmpty ? nil : settings.tmuxSocket
            )
            windowManager = MirrorWindowManager(
                settings: settings,
                tmuxService: tmuxService,
                paneStreamManager: .init(
                    tmuxService: tmuxService,
                    controlClientManager: controlClientManager
                ),
                editorSessionManager: EditorSessionManager()
            )
        }
    }
}

#Preview {
    PaneListPreview()
}
