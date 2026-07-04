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
    /// Emoji per browse row, derived from the scroll view's width. The browse
    /// list is a flat stack of FIXED-HEIGHT rows so the lazy layout's offset
    /// estimates are exact and the category jump is a plain one-shot
    /// `scrollTo` that cannot land off-target. (Variable-height lazy sections
    /// made `scrollTo` miss, and a `scrollPosition` binding re-anchoring
    /// against shifting estimates hung the layout until the watchdog killed
    /// the app — don't reintroduce either.)
    @State private var columnCount = 8

    /// Sections are bucketed once; the table is immutable so there is nothing
    /// to recompute per render.
    private let sections = EmojiDatabase.shared.categorized()

    /// Search results only; the browse list does its own fixed-row layout.
    private let columns = [GridItem(.adaptive(minimum: 40, maximum: 48), spacing: 2)]

    private let cellSize: CGFloat = 40
    private let cellSpacing: CGFloat = 2
    /// Every browse row — headers included — is exactly this tall. The
    /// uniformity is load-bearing: it is what makes `scrollTo` exact.
    private var rowHeight: CGFloat { cellSize + cellSpacing }

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
        #if os(iOS)
            // The detent sheet's content starts under the drag indicator, inside
            // the sheet's large corner radius — the popover-sized 8pt inset gets
            // the capsule clipped by the corner cut. Clear both.
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 8)
        #else
            .padding(8)
        #endif
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

    /// One fixed-height row of the flat browse list: a section title or a run
    /// of up to ``columnCount`` emoji.
    private struct BrowseRow: Identifiable {
        enum Kind {
            case header(EmojiCategory)
            case emoji([Emoji])
        }

        let id: String
        let kind: Kind

        static func headerID(_ category: EmojiCategory) -> String {
            "header-\(category.rawValue)"
        }
    }

    private var browseRows: [BrowseRow] {
        var rows: [BrowseRow] = []
        for section in sections {
            rows.append(BrowseRow(
                id: BrowseRow.headerID(section.category),
                kind: .header(section.category)
            ))
            var start = 0
            var index = 0
            while start < section.emoji.count {
                let end = min(start + columnCount, section.emoji.count)
                rows.append(BrowseRow(
                    id: "row-\(section.category.rawValue)-\(index)",
                    kind: .emoji(Array(section.emoji[start..<end]))
                ))
                start = end
                index += 1
            }
        }
        return rows
    }

    private var browseView: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                categoryBar(proxy)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(browseRows) { row in
                            rowView(row)
                                .frame(height: rowHeight)
                                .id(row.id)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.width
                } action: { width in
                    let usable = width - 16 + cellSpacing
                    columnCount = max(1, Int(usable / (cellSize + cellSpacing)))
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: BrowseRow) -> some View {
        switch row.kind {
        case let .header(category):
            // Vertically centered in the fixed-height row: the leftover space
            // splits evenly above and below the title, so the top of the list
            // doesn't read as a dead gap (bottom-aligning put all ~23pt of the
            // row's slack above the text).
            Text(category.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.leading, 2)
        case let .emoji(emoji):
            HStack(spacing: cellSpacing) {
                ForEach(emoji) { cell($0) }
                Spacer(minLength: 0)
            }
        }
    }

    private func categoryBar(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 0) {
            ForEach(sections, id: \.category) { section in
                Button {
                    // Exact by construction: every row is `rowHeight` tall, so
                    // the lazy layout's estimate for the header's offset IS its
                    // real offset — one call, no correction passes.
                    proxy.scrollTo(BrowseRow.headerID(section.category), anchor: .top)
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
