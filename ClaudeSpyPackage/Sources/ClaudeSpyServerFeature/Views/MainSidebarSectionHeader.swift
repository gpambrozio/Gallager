import ClaudeSpyCommon
import SwiftUI

/// A prominent section header with icon and title, optionally showing a "+" button with popover and trailing content.
/// Used by the local and remote-host sections in `MainView`'s sidebar.
struct MainSidebarSectionHeader<Trailing: View, Popover: View>: View {
    let title: String
    let symbol: Symbols
    var isNewSessionDisabled: Bool
    let trailing: Trailing
    let popover: Popover
    let hasPopover: Bool

    @State private var showingPopover = false

    var body: some View {
        HStack(spacing: 6) {
            symbol.image
                .font(.headline.weight(.semibold))

            Text(title)
                .font(.headline.weight(.semibold))

            if hasPopover || !(trailing is EmptyView) {
                Spacer()
            }

            if hasPopover {
                Button {
                    showingPopover = true
                } label: {
                    Symbols.plus.image
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(isNewSessionDisabled)
                .accessibilityLabel("Create new session")
                .help("Create new session")
                .popover(isPresented: $showingPopover) {
                    popover
                }
            }

            trailing
        }
        .foregroundStyle(.primary)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .padding(.trailing, 8)
    }
}

// Convenience: no popover, no trailing
extension MainSidebarSectionHeader where Trailing == EmptyView, Popover == EmptyView {
    init(title: String, symbol: Symbols) {
        self.title = title
        self.symbol = symbol
        self.isNewSessionDisabled = false
        self.trailing = EmptyView()
        self.popover = EmptyView()
        self.hasPopover = false
    }
}

// Convenience: popover only, no trailing
extension MainSidebarSectionHeader where Trailing == EmptyView {
    init(
        title: String,
        symbol: Symbols,
        isNewSessionDisabled: Bool = false,
        @ViewBuilder popover: () -> Popover
    ) {
        self.title = title
        self.symbol = symbol
        self.isNewSessionDisabled = isNewSessionDisabled
        self.trailing = EmptyView()
        self.popover = popover()
        self.hasPopover = true
    }
}

// Convenience: popover + trailing
extension MainSidebarSectionHeader {
    init(
        title: String,
        symbol: Symbols,
        isNewSessionDisabled: Bool = false,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder popover: () -> Popover
    ) {
        self.title = title
        self.symbol = symbol
        self.isNewSessionDisabled = isNewSessionDisabled
        self.trailing = trailing()
        self.popover = popover()
        self.hasPopover = true
    }
}
