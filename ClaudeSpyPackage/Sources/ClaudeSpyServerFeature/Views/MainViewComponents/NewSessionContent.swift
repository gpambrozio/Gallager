import ClaudeSpyCommon
import SwiftUI

/// Tracks which item is currently being created in the new session view
enum NewSessionCreatingState: Equatable {
    case newTerminal
    case project(String)
}

/// Tracks which row is currently highlighted via keyboard navigation
enum NewSessionSelection: Hashable {
    case newTerminal
    case project(String)
}

/// Unified content for creating a new session, used in popovers and the empty-state detail area
struct NewSessionContent: View {
    let title: String
    let projects: [AgentProject]
    let isLoadingProjects: Bool
    let creatingSelection: NewSessionCreatingState?
    let onCreate: (AgentProject?) -> Void
    /// When true, constrains size for popover use. When false, expands to fill available space.
    var popover = true

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isSearchFocused: Bool
    @State private var searchText = ""
    @State private var selection: NewSessionSelection?

    private var isCreating: Bool {
        creatingSelection != nil
    }

    private var filteredProjects: [AgentProject] {
        guard !searchText.isEmpty else { return projects }
        return projects.filter { $0.name.fuzzyMatches(searchText) }
    }

    /// Returns a one-line plugin label for the row badge, or `nil` for the
    /// default Claude Code projects (badgeless to match how things looked
    /// before plugins were configurable). Non-Claude built-in plugins map
    /// to short labels; unknown third-party ids fall back to the raw plugin
    /// id so the user still gets a visual hint.
    private func badgeForProject(_ project: AgentProject) -> String? {
        switch project.pluginID {
        case "claude-code": nil
        case "codex": "Codex"
        default: project.pluginID
        }
    }

    /// All keyboard-selectable rows in display order.
    private var selectableItems: [NewSessionSelection] {
        var items: [NewSessionSelection] = []
        if searchText.isEmpty {
            items.append(.newTerminal)
        }
        items.append(contentsOf: filteredProjects.map { .project($0.id) })
        return items
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .padding(.top, 12)
                .padding(.bottom, 8)

            if !isLoadingProjects && !projects.isEmpty {
                HStack(spacing: 6) {
                    Symbols.magnifyingglass.image
                        .foregroundStyle(.secondary)
                        .font(.caption)

                    TextField("Search projects...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .focused($isSearchFocused)
                        .accessibilityLabel("Search projects")
                        .onSubmit { handleSubmit() }
                        .onKeyPress(.downArrow) {
                            moveSelection(by: 1)
                            return .handled
                        }
                        .onKeyPress(.upArrow) {
                            moveSelection(by: -1)
                            return .handled
                        }

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Symbols.xmarkCircleFill.image
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
                .onAppear {
                    isSearchFocused = true
                }
            }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 8) {
                        if searchText.isEmpty {
                            NewSessionRow(
                                title: "New Terminal",
                                subtitle: "Start in home directory",
                                symbol: .terminal,
                                isCreating: creatingSelection == .newTerminal,
                                isDisabled: isCreating,
                                isSelected: selection == .newTerminal
                            ) {
                                dismiss()
                                onCreate(nil)
                            }
                            .id(NewSessionSelection.newTerminal)
                        }

                        if isLoadingProjects {
                            HStack {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Loading projects...")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 8)
                        } else if !filteredProjects.isEmpty {
                            if searchText.isEmpty {
                                Divider()
                                    .padding(.vertical, 4)

                                Text("Projects")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            ForEach(filteredProjects) { project in
                                NewSessionRow(
                                    title: project.name,
                                    subtitle: project.path.abbreviatedPath,
                                    symbol: .folder,
                                    isCreating: creatingSelection == .project(project.id),
                                    isDisabled: isCreating,
                                    isSelected: selection == .project(project.id),
                                    badge: badgeForProject(project)
                                ) {
                                    dismiss()
                                    onCreate(project)
                                }
                                .id(NewSessionSelection.project(project.id))
                            }
                        } else if !searchText.isEmpty {
                            Text("No matching projects")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                                .padding(.vertical, 8)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: popover ? 300 : .infinity)
                .onChange(of: selection) { _, newValue in
                    guard let newValue else { return }
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
                .onChange(of: searchText) { _, _ in
                    let items = selectableItems
                    if let current = selection, items.contains(current) {
                        return
                    }
                    selection = items.first
                }
            }
        }
        .frame(maxWidth: popover ? 280 : 400)
        .frame(width: popover ? 280 : nil)
    }

    private func moveSelection(by offset: Int) {
        let items = selectableItems
        guard !items.isEmpty else { return }

        let newIndex: Int
        if
            let current = selection,
            let currentIndex = items.firstIndex(of: current) {
            newIndex = (currentIndex + offset + items.count) % items.count
        } else {
            newIndex = offset > 0 ? 0 : items.count - 1
        }
        selection = items[newIndex]
    }

    private func handleSubmit() {
        switch selection {
        case .newTerminal:
            dismiss()
            onCreate(nil)
        case let .project(id):
            guard let project = filteredProjects.first(where: { $0.id == id }) else { return }
            dismiss()
            onCreate(project)
        case nil:
            return
        }
    }
}

/// A row in the new session sheet representing a selectable option
struct NewSessionRow: View {
    let title: String
    let subtitle: String
    let symbol: Symbols
    let isCreating: Bool
    let isDisabled: Bool
    var isSelected = false
    /// Optional badge text shown next to the title, used to mark non-default
    /// agents (e.g. "Codex") so users can tell them apart in mixed lists.
    var badge: String?
    let action: () -> Void

    private var iconStyle: AnyShapeStyle {
        isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.secondary)
    }

    private var chevronStyle: AnyShapeStyle {
        isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.tertiary)
    }

    private var backgroundFill: Color {
        isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                symbol.image
                    .font(.title2)
                    .foregroundStyle(iconStyle)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)

                        if let badge {
                            Text(badge)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(Color.accentColor.opacity(0.18))
                                )
                                .foregroundStyle(Color.accentColor)
                        }
                    }

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if isCreating {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Symbols.chevronRight.image
                        .font(.caption)
                        .foregroundStyle(chevronStyle)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(backgroundFill)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}
