import ClaudeSpyCommon
import SwiftUI

/// One file's worth of content-search matches, used by the grouped results
/// list. Identified by `fullPath` so SwiftUI can preserve disclosure state
/// across streaming batches (each batch arrives, the array gets re-bucketed,
/// but the same path keeps the same identity).
struct ContentSearchGroup: Identifiable {
    var id: String { fullPath }
    let fullPath: String
    let relativePath: String
    let name: String
    var matches: [FileTextSearchMatch]
}

/// Sidebar list that renders streaming content-search matches grouped by
/// file, with collapsible disclosures and a per-row right-click menu.
///
/// Extracted from `FileBrowserView` so the layout can be previewed and
/// tweaked in isolation: callers pass already-fetched matches plus
/// bindings for selection and the user-collapsed file set.
struct ContentSearchResultsList: View {
    let matches: [FileTextSearchMatch]
    let query: String
    let isRunning: Bool
    @Binding var selection: String?
    @Binding var collapsedFiles: Set<String>
    let directoryPath: String
    let onOpenFileInNewTab: (String) -> Void

    var body: some View {
        let groups = groupedMatches
        if groups.isEmpty {
            if isRunning {
                ProgressView("Searching...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            List(selection: $selection) {
                ForEach(groups) { group in
                    DisclosureGroup(isExpanded: expansionBinding(for: group)) {
                        ForEach(group.matches) { match in
                            row(match)
                                .tag(match.id)
                                .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 0, trailing: 8))
                                .listRowSeparator(.hidden)
                                .fileContextMenu(
                                    fullPath: match.fullPath,
                                    directoryPath: directoryPath,
                                    isDirectory: false,
                                    onOpenFileInNewTab: onOpenFileInNewTab
                                )
                        }
                    } label: {
                        header(group)
                            .padding(.top, 10)
                            .padding(.bottom, 4)
                            .fileContextMenu(
                                fullPath: group.fullPath,
                                directoryPath: directoryPath,
                                isDirectory: false,
                                onOpenFileInNewTab: onOpenFileInNewTab
                            )
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 8))
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 16)
            .scrollContentBackground(.hidden)
        }
    }

    /// Buckets the streaming matches into per-file groups preserving
    /// first-occurrence order. Recomputed each render — the result is bounded
    /// by the search batch limits and the work is a single pass, so a cache
    /// here would just complicate invalidation.
    private var groupedMatches: [ContentSearchGroup] {
        var groups: [ContentSearchGroup] = []
        var indexByPath: [String: Int] = [:]
        for match in matches {
            if let i = indexByPath[match.fullPath] {
                groups[i].matches.append(match)
            } else {
                indexByPath[match.fullPath] = groups.count
                groups.append(ContentSearchGroup(
                    fullPath: match.fullPath,
                    relativePath: match.relativePath,
                    name: match.name,
                    matches: [match]
                ))
            }
        }
        return groups
    }

    /// Default-expanded binding: a path that's *not* in `collapsedFiles` is
    /// shown open. Tracking only the user-collapsed set (rather than the
    /// expanded set) keeps default-expanded semantics for new files arriving
    /// in streaming batches without us having to mutate state on every batch.
    private func expansionBinding(for group: ContentSearchGroup) -> Binding<Bool> {
        Binding(
            get: { !collapsedFiles.contains(group.fullPath) },
            set: { isExpanded in
                if isExpanded {
                    collapsedFiles.remove(group.fullPath)
                } else {
                    collapsedFiles.insert(group.fullPath)
                }
            }
        )
    }

    @ViewBuilder
    private func header(_ group: ContentSearchGroup) -> some View {
        let directory = directorySegment(of: group.relativePath)
        HStack(spacing: 6) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.name)
                        .font(.callout)
                        .lineLimit(1)
                    if !directory.isEmpty {
                        Text(directory)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            } icon: {
                Symbols.docPlaintextFill.image
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text("\(group.matches.count)")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.18)))
                .accessibilityLabel("\(group.matches.count) matches")
        }
    }

    private func row(_ match: FileTextSearchMatch) -> some View {
        Text(highlightedLine(match.lineText.trimmingCharacters(in: .whitespacesAndNewlines), query: query))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.callout)
            .foregroundStyle(.primary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Line \(match.lineNumber): \(match.lineText)")
    }

    /// Builds an `AttributedString` that highlights every case-insensitive
    /// occurrence of `query` inside `text`. The highlight uses the system
    /// accent color at low opacity so it adapts to the user's chosen accent
    /// rather than a fixed yellow that might clash in dark mode.
    private func highlightedLine(_ text: String, query: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard !query.isEmpty else { return attributed }
        let lowered = text.lowercased()
        let needle = query.lowercased()
        var cursor = lowered.startIndex
        while
            cursor < lowered.endIndex,
            let range = lowered.range(of: needle, range: cursor..<lowered.endIndex) {
            if let attRange = Range<AttributedString.Index>(range, in: attributed) {
                attributed[attRange].backgroundColor = Color.accentColor.opacity(0.35)
                attributed[attRange].foregroundColor = .primary
            }
            cursor = range.upperBound
        }
        return attributed
    }

    private func directorySegment(of relativePath: String) -> String {
        guard let lastSlash = relativePath.lastIndex(of: "/") else { return "" }
        return String(relativePath[..<lastSlash])
    }
}

// MARK: - Previews

private let previewRoot = "/Users/preview/project"

private struct ContentSearchResultsListPreview: View {
    let matches: [FileTextSearchMatch]
    let query: String
    var isRunning = false
    var initiallyCollapsed: Set<String> = []

    @State private var selection: String?
    @State private var collapsedFiles: Set<String> = []

    var body: some View {
        ContentSearchResultsList(
            matches: matches,
            query: query,
            isRunning: isRunning,
            selection: $selection,
            collapsedFiles: $collapsedFiles,
            directoryPath: previewRoot,
            onOpenFileInNewTab: { _ in }
        )
        .onAppear { collapsedFiles = initiallyCollapsed }
        .frame(width: 280, height: 520)
    }
}

private enum ContentSearchResultsListPreviewData {
    static let query = "todo"

    static let matches: [FileTextSearchMatch] = [
        match(
            rel: "Sources/App/AppDelegate.swift",
            line: 12,
            text: "// TODO: wire up the new menu bar item"
        ),
        match(
            rel: "Sources/App/AppDelegate.swift",
            line: 47,
            text: "    // todo: revisit once we drop macOS 14 support"
        ),
        match(
            rel: "Sources/App/AppDelegate.swift",
            line: 88,
            text: "    NSLog(\"TODO: emit telemetry on first launch\")"
        ),
        match(
            rel: "Sources/Networking/RelayClient.swift",
            line: 134,
            text: "        // TODO: backoff after 3 consecutive failures"
        ),
        match(
            rel: "Sources/Networking/RelayClient.swift",
            line: 201,
            text: "        // TODO: drop legacy header once iOS app pins 1.4+"
        ),
        match(
            rel: "README.md",
            line: 3,
            text: "An exhaustive list of TODOs lives in the GitHub project board."
        ),
        match(
            rel: "Sources/Features/Files/FileBrowserView.swift",
            line: 882,
            text: "    // TODO: animate transitions between name and content modes"
        ),
    ]

    static func match(rel: String, line: Int, text: String) -> FileTextSearchMatch {
        let name = (rel as NSString).lastPathComponent
        return FileTextSearchMatch(
            fullPath: "\(previewRoot)/\(rel)",
            relativePath: rel,
            name: name,
            lineNumber: line,
            lineText: text
        )
    }
}

#Preview("Results") {
    ContentSearchResultsListPreview(
        matches: ContentSearchResultsListPreviewData.matches,
        query: ContentSearchResultsListPreviewData.query
    )
}

#Preview("Results — one collapsed") {
    ContentSearchResultsListPreview(
        matches: ContentSearchResultsListPreviewData.matches,
        query: ContentSearchResultsListPreviewData.query,
        initiallyCollapsed: [
            "\(previewRoot)/Sources/Networking/RelayClient.swift",
        ]
    )
}

#Preview("Searching…") {
    ContentSearchResultsListPreview(
        matches: [],
        query: ContentSearchResultsListPreviewData.query,
        isRunning: true
    )
}

#Preview("No results") {
    ContentSearchResultsListPreview(
        matches: [],
        query: "asdfqwer",
        isRunning: false
    )
}
