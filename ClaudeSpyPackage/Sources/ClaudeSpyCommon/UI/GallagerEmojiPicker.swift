import GallagerEmoji
import SwiftUI

/// A self-contained emoji picker with keyword-aware search.
///
/// Replaces the third-party `SwiftEmojiPicker`, whose search only matched an
/// emoji's single primary shortcode — so "trash" found nothing even though 🗑️
/// exists (issue #630). This one searches the CLDR synonym set baked into
/// ``GallagerEmoji``, so "trash", "bin", and "garbage" all surface the
/// wastebasket, and the same index powers the `gallager` CLI.
///
/// The API mirrors the view it replaced: pick a glyph and it is written through
/// `selectedEmoji`. The host presentation (macOS popover / iOS detent sheet)
/// observes that binding to commit and dismiss.
public struct GallagerEmojiPicker: View {
    @Binding private var selectedEmoji: String
    @State private var searchText = ""

    /// Sections are bucketed once; the table is immutable so there is nothing
    /// to recompute per render.
    private let sections = EmojiDatabase.shared.categorized()

    private let columns = [GridItem(.adaptive(minimum: 40, maximum: 48), spacing: 2)]

    public init(selectedEmoji: Binding<String>) {
        self._selectedEmoji = selectedEmoji
    }

    public var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            if trimmedQuery.isEmpty {
                browseView
            } else {
                searchResultsView
            }
        }
    }

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 6) {
            Symbols.magnifyingglass.image
                .foregroundStyle(.secondary)
            searchTextField
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Symbols.xmarkCircleFill.image
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Search")
            }
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .padding(8)
    }

    private var searchTextField: some View {
        let field = TextField("Search", text: $searchText)
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            .accessibilityLabel("Search")
            .accessibilityIdentifier("emoji-search-field")
        #if os(iOS)
            return field.textInputAutocapitalization(.never)
        #else
            return field
        #endif
    }

    // MARK: - Browsing

    private var browseView: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                categoryBar(proxy)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections, id: \.category) { section in
                            Section {
                                grid(section.emoji)
                            } header: {
                                sectionHeader(section.category)
                            }
                            .id(section.category)
                        }
                    }
                }
            }
        }
    }

    private func categoryBar(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 0) {
            ForEach(sections, id: \.category) { section in
                Button {
                    withAnimation {
                        proxy.scrollTo(section.category, anchor: .top)
                    }
                } label: {
                    section.category.symbol.image
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(section.category.title)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func sectionHeader(_ category: EmojiCategory) -> some View {
        Text(category.title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.bar)
    }

    // MARK: - Search results

    private var searchResultsView: some View {
        let results = EmojiDatabase.shared.search(searchText)
        return Group {
            if results.isEmpty {
                VStack(spacing: 8) {
                    Symbols.magnifyingglass.image
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No emoji found for “\(trimmedQuery)”")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollView {
                    grid(results)
                }
            }
        }
    }

    // MARK: - Shared grid

    private func grid(_ emoji: [Emoji]) -> some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(emoji) { cell($0) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func cell(_ emoji: Emoji) -> some View {
        Button {
            selectedEmoji = emoji.glyph
        } label: {
            Text(emoji.glyph)
                .font(.system(size: 30))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(emoji.glyph)
        .help(emoji.label)
    }
}

private extension EmojiCategory {
    /// Category-bar glyph. Kept here (not in the UI-free ``GallagerEmoji``
    /// module) so the emoji data stays platform-agnostic.
    var symbol: Symbols {
        switch self {
        case .smileysAndPeople: .faceSmiling
        case .animalsAndNature: .leaf
        case .foodAndDrink: .forkKnife
        case .activities: .figureRun
        case .travelAndPlaces: .car
        case .objects: .lightbulb
        case .symbols: .number
        case .flags: .flag
        }
    }
}

#Preview("Emoji picker") {
    @Previewable @State var emoji = ""
    GallagerEmojiPicker(selectedEmoji: $emoji)
        .frame(width: 360, height: 380)
}
