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

    @State private var hoveredWindowId: String?

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
        let isHovered = hoveredWindowId == window.id
        let windowName = windowTabLabel(windowName: window.windowName, windowIndex: window.windowIndex)

        return HStack(spacing: 0) {
            Button {
                onSelectWindow(window)
            } label: {
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
                .padding(.leading, 12)
                .padding(.trailing, 4)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(window.id) \(windowName)")
            .accessibilityValue(isSelected ? "selected" : "")

            TabCloseButton(
                isVisible: isSelected || isHovered,
                isDisabled: !isHostConnected,
                accessibilityLabel: "Close window: \(windowName)",
                helpText: "Close window",
                action: { onCloseWindow(window) }
            )
            .padding(.trailing, 6)
        }
        .tabStripItemStyle(isSelected: isSelected)
        .modifier(WindowRenamingModifier(
            currentName: window.windowName,
            isDisabled: !isHostConnected,
            onRename: { newName in
                onRenameWindow(window, newName)
            }
        ))
        .onHover { hovering in
            hoveredWindowId = hovering ? window.id : nil
        }
    }
}
