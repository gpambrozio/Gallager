import ClaudeSpyCommon
import SwiftUI

/// Displays a list of available tmux panes
struct PaneListView: View {
    let panes: [PaneInfo]
    let isLoading: Bool
    let error: String?
    let onRefresh: () async -> Void
    let onOpenMirror: (PaneInfo) -> Void

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
                    PaneRow(pane: pane) {
                        onOpenMirror(pane)
                    }
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
                        .frame(width: 30)
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
    let pane: PaneInfo
    let onOpen: () -> Void

    var body: some View {
        HStack {
            Text(pane.target)
                .font(.system(.body, design: .monospaced))
                .frame(width: 120, alignment: .leading)

            Text(pane.command)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)

            Text(abbreviatedPath(pane.currentPath))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onOpen) {
                Symbols.arrowRight.image
            }
            .buttonStyle(.borderless)
            .help("Open mirror window")
        }
        .padding(.vertical, 4)
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

#Preview {
    PaneListView(
        panes: [
            PaneInfo(
                id: "%0",
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
                id: "%1",
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
        onRefresh: {},
        onOpenMirror: { _ in }
    )
}
