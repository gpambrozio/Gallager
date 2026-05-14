import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

/// Horizontal tab bar for remote session windows, mirroring `WindowTabBar` for local sessions.
///
/// In addition to the tmux window tabs, this bar renders any in-app browser
/// tabs opened from the session's terminals — clicking a link with
/// `browserLinkBehavior == .alwaysInApp` (or accepting the prompt) creates a
/// `BrowserTab` whose lifetime is scoped to the same `(hostId, sessionName)`
/// pair this bar represents.
struct RemoteWindowTabBar: View {
    let windows: [TmuxWindow]
    let selectedWindow: TmuxWindow
    let isHostConnected: Bool
    /// In-app browser tabs scoped to this remote session. Empty when no
    /// terminal-link click has spawned a tab yet.
    let openBrowserTabs: [BrowserTab]
    /// When set, the matching browser tab in `openBrowserTabs` is the active
    /// detail view. The parent renders `BrowserTabContentView` in place of
    /// `RemoteWindowPaneLayoutView` while non-nil.
    let selectedBrowserTabId: UUID?
    let onSelectWindow: (TmuxWindow) -> Void
    let onCloseWindow: (TmuxWindow) -> Void
    let onNewWindow: () -> Void
    let onRenameWindow: (TmuxWindow, String) -> Void
    let onSelectBrowserTab: (UUID) -> Void
    let onCloseBrowserTab: (UUID) -> Void

    @State private var hoveredWindowId: String?
    @State private var hoveredBrowserTabId: UUID?

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

                ForEach(openBrowserTabs) { tab in
                    browserTabView(tab)
                }

                Spacer()
            }
            .padding(.horizontal, 8)
        }
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func browserTabView(_ tab: BrowserTab) -> some View {
        let isSelected = tab.id == selectedBrowserTabId
        let isHovered = hoveredBrowserTabId == tab.id

        return HStack(spacing: 0) {
            Button {
                onSelectBrowserTab(tab.id)
            } label: {
                HStack(spacing: 4) {
                    Symbols.globe.image
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text(tab.tabLabel)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 160, alignment: .leading)
                }
                .padding(.leading, 12)
                .padding(.trailing, 4)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tab.url.absoluteString)
            .accessibilityLabel("Browser tab: \(tab.tabLabel)")
            .accessibilityValue(isSelected ? "selected" : "")

            TabCloseButton(
                isVisible: isSelected || isHovered,
                accessibilityLabel: "Close browser tab: \(tab.tabLabel)",
                action: { onCloseBrowserTab(tab.id) }
            )
            .padding(.trailing, 6)
        }
        .tabStripItemStyle(isSelected: isSelected)
        .onHover { hovering in
            hoveredBrowserTabId = hovering ? tab.id : nil
        }
    }

    private func windowTab(_ window: TmuxWindow) -> some View {
        // Match the local `WindowTabBar` styling: when a browser tab is the
        // active detail view, deselect the window tab visually so the user
        // sees at a glance that the in-app browser — not the terminal — owns
        // the content area.
        let isSelected = window.id == selectedWindow.id && selectedBrowserTabId == nil
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
