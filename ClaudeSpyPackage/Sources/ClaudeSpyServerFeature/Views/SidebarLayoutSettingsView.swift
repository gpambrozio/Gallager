import ClaudeSpyCommon
import SwiftUI

/// Preferences tab for customizing which fields appear in sidebar session rows and their order.
struct SidebarLayoutSettingsView: View {
    @Environment(AppSettings.self) private var settings

    @State private var selectedSessionType: SessionType = .claude

    enum SessionType: String, CaseIterable, Identifiable {
        case claude = "Claude Sessions"
        case terminal = "Terminals"

        var id: String { rawValue }
    }

    var body: some View {
        @Bindable var settings = settings

        VStack(spacing: 0) {
            Picker("Session Type", selection: $selectedSessionType) {
                ForEach(SessionType.allCases) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top)

            HStack(alignment: .top, spacing: 16) {
                FieldList(
                    title: "Available Fields",
                    fields: .init(
                        get: { availableFields },
                        set: { _ in }
                    ),
                    isSource: false,
                    onAdd: { field in
                        switch selectedSessionType {
                        case .claude: settings.sidebarFields.append(field)
                        case .terminal: settings.sidebarTerminalFields.append(field)
                        }
                    }
                )

                FieldList(
                    title: "Visible Fields",
                    fields: selectedSessionType == .claude
                        ? $settings.sidebarFields
                        : $settings.sidebarTerminalFields,
                    isSource: true
                )
            }
            .padding()

            Divider()

            HStack {
                SidebarPreview(
                    fields: activeFields,
                    isTerminal: selectedSessionType == .terminal
                )

                Spacer()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Sort Order")
                        .font(.headline)

                    Picker("Sort Order", selection: $settings.sidebarSortMode) {
                        ForEach(SidebarSortMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
            }
            .padding()
        }
    }

    private var activeFields: [SidebarField] {
        switch selectedSessionType {
        case .claude: settings.sidebarFields
        case .terminal: settings.sidebarTerminalFields
        }
    }

    private var allFieldsForType: [SidebarField] {
        switch selectedSessionType {
        case .claude: SidebarField.allCases
        case .terminal: SidebarField.terminalFields
        }
    }

    private var availableFields: [SidebarField] {
        allFieldsForType.filter { !activeFields.contains($0) }
    }
}

// MARK: - Field List

private struct FieldList: View {
    let title: String
    @Binding var fields: [SidebarField]
    let isSource: Bool
    var onAdd: ((SidebarField) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            List {
                if isSource {
                    ForEach(fields) { field in
                        FieldRow(field: field, isSource: true) {
                            fields.removeAll { $0 == field }
                        }
                        .draggable(field.rawValue)
                    }
                    .onMove { source, destination in
                        fields.move(fromOffsets: source, toOffset: destination)
                    }
                } else {
                    ForEach(fields) { field in
                        FieldRow(field: field, isSource: false) {
                            onAdd?(field)
                        }
                    }
                }
            }
            .listStyle(.bordered)
            .frame(minHeight: 200)
            .dropDestination(for: String.self) { items, _ in
                guard isSource else { return false }
                for rawValue in items {
                    guard let field = SidebarField(rawValue: rawValue) else { continue }
                    if !fields.contains(field) {
                        fields.append(field)
                    }
                }
                return true
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Field Row

private struct FieldRow: View {
    let field: SidebarField
    let isSource: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            if isSource {
                Symbols.line3Horizontal.image
                    .foregroundStyle(.tertiary)
            }

            Text(field.displayName)

            Spacer()

            Button {
                action()
            } label: {
                (isSource ? Symbols.minusCircleFill : Symbols.plusCircleFill).image
                    .foregroundStyle(isSource ? .red : .green)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(isSource ? "Remove" : "Add") \(field.displayName)")
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Preview

private struct SidebarPreview: View {
    let fields: [SidebarField]
    var isTerminal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview")
                .font(.headline)

            HStack(alignment: .top, spacing: 8) {
                if isTerminal {
                    Symbols.terminal.image
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                        .padding(.top, 2)
                } else {
                    Circle()
                        .fill(.green)
                        .frame(width: 10, height: 10)
                        .padding(.top, 4)
                }

                SessionFieldsView(
                    fields: fields,
                    customDescription: "My Feature Branch",
                    projectName: isTerminal ? nil : "Gallager",
                    sessionName: "dev",
                    terminalTitle: isTerminal ? nil : "claude",
                    command: isTerminal ? "zsh" : "claude",
                    currentPath: "~/Development/Gallager",
                    gitBranch: "feature/sidebar-layout",
                    latestEvent: isTerminal ? nil : "Reading file Package.swift"
                )
            }
            .padding(12)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

#Preview {
    SidebarLayoutSettingsView()
        .environment(AppSettings())
        .frame(width: 600, height: 500)
}
