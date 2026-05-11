import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

/// Horizontal tab bar for remote session windows, mirroring `WindowTabBar` for local sessions.
struct RemoteWindowTabBar: View {
    let windows: [TmuxWindow]
    let selectedWindow: TmuxWindow
    let isHostConnected: Bool
    let onSelectWindow: (TmuxWindow) -> Void
    let onCloseWindow: (TmuxWindow) -> Void
    let onNewWindow: () -> Void
    let onRenameWindow: (TmuxWindow, String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(windows) { window in
                    windowTab(window)
                }

                Button(action: onNewWindow) {
                    Symbols.plus.image
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New window")
                .accessibilityLabel("New Window")
                .disabled(!isHostConnected)

                Spacer()
            }
            .padding(.horizontal, 8)
        }
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func windowTab(_ window: TmuxWindow) -> some View {
        let isSelected = window.id == selectedWindow.id
        let windowName = windowTabLabel(windowName: window.windowName, windowIndex: window.windowIndex)

        return TabBarItem(
            isSelected: isSelected,
            onSelect: { onSelectWindow(window) },
            labelAccessibilityLabel: "\(window.id) \(windowName)",
            onClose: { onCloseWindow(window) },
            closeAccessibilityLabel: "Close window",
            closeHelp: "Close window",
            closeDisabled: !isHostConnected
        ) {
            HStack(spacing: 4) {
                if window.hasClaude {
                    Symbols.sparkles.image
                        .font(.caption2)
                        .foregroundStyle(.purple)
                }

                Text(windowName)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
            }
        }
        .modifier(WindowRenamingModifier(
            currentName: window.windowName,
            isDisabled: !isHostConnected,
            onRename: { newName in
                onRenameWindow(window, newName)
            }
        ))
    }
}
