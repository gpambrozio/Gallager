import ClaudeSpyCommon
import SwiftUI

/// Identifies which trailing drop zone is being targeted. The single section
/// is used when the tab bar is not split; left/right correspond to the two
/// sections of the split-mode bar. Shared by `WindowTabBar` and
/// `RemoteWindowTabBar` so any future drop-zone semantics stay aligned.
enum TabSection: Hashable {
    case single
    case left
    case right
}

/// Visual hint shown while a compatible drag is hovering a tab — a thin
/// vertical accent line on the leading edge that previews the drop slot.
struct DropIndicator: View {
    let visible: Bool

    var body: some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(width: 2)
            .opacity(visible ? 1 : 0)
            .animation(.easeOut(duration: 0.1), value: visible)
            .allowsHitTesting(false)
    }
}

/// Compact preview view drawn under the cursor while a tab is being dragged.
/// Mirrors the on-strip styling so the user sees a recognisable "ghost" of
/// the tab they're moving.
struct TabDragPreview: View {
    let label: String
    let symbol: Symbols

    var body: some View {
        HStack(spacing: 4) {
            symbol.image
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .cornerRadius(4)
        .shadow(radius: 2)
    }
}

/// Leading "+" menu used by both the local and remote tab bars. Exposes the
/// "New Terminal" / "New Browser" entries with a customizable help string and
/// optional disable on the terminal entry (the remote bar disables it while
/// the host is disconnected).
struct NewTabMenuButton: View {
    let helpText: String
    var isTerminalDisabled = false
    let onNewTerminal: () -> Void
    let onNewBrowser: () -> Void

    var body: some View {
        Menu {
            Button {
                onNewTerminal()
            } label: {
                Label("New Terminal", symbol: .terminal)
            }
            .disabled(isTerminalDisabled)
            Button {
                onNewBrowser()
            } label: {
                Label("New Browser", symbol: .globe)
            }
        } label: {
            Symbols.plus.image
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .fixedSize()
        .help(helpText)
        .accessibilityLabel("New Tab")
    }
}

/// Tab-strip entry for a single in-app browser tab. Identical between the
/// local and remote tab bars — both render the globe icon, the tab label with
/// the same truncation rules, the same split-toggle and close-button placement,
/// and expose the same drag/drop affordances.
struct BrowserTabStripItem: View {
    let tab: BrowserTab
    let isSelected: Bool
    let isOnRight: Bool
    let isSplit: Bool
    let showsDropIndicator: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onToggleSplit: () -> Void
    let onDrop: ([TabDragPayload]) -> Bool
    let onTargetedChanged: (Bool) -> Void

    @State private var isHovered = false

    var body: some View {
        let payload = TabDragPayload.browser(tab.id)

        HStack(spacing: 0) {
            Button(action: onSelect) {
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

            TabSplitToggleButton(
                isSplit: isSplit,
                isOnRight: isOnRight,
                tabKind: "browser tab",
                tabName: tab.tabLabel,
                action: onToggleSplit
            )

            TabCloseButton(
                isVisible: isSelected || isHovered,
                accessibilityLabel: "Close browser tab: \(tab.tabLabel)",
                action: onClose
            )
            .padding(.trailing, 6)
        }
        .tabStripItemStyle(isSelected: isSelected, isOnRightSplit: isOnRight, isSplit: isSplit)
        .overlay(alignment: .leading) {
            DropIndicator(visible: showsDropIndicator)
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .draggable(payload) {
            TabDragPreview(label: tab.tabLabel, symbol: .globe)
        }
        .dropDestination(for: TabDragPayload.self) { payloads, _ in
            onDrop(payloads)
        } isTargeted: { isTargeted in
            onTargetedChanged(isTargeted)
        }
    }
}
