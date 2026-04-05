import ClaudeSpyCommon
import SwiftUI
import UniformTypeIdentifiers

/// Preferences tab for customizing which fields appear in sidebar session rows and their order.
struct SidebarLayoutSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                FieldList(
                    title: "Visible Fields",
                    fields: $settings.sidebarFields,
                    allFields: settings.sidebarFields,
                    isSource: true
                )

                FieldList(
                    title: "Available Fields",
                    fields: .init(
                        get: { availableFields },
                        set: { _ in }
                    ),
                    allFields: settings.sidebarFields,
                    isSource: false,
                    onAdd: { field in
                        settings.sidebarFields.append(field)
                    }
                )
            }
            .padding()

            Divider()

            SidebarPreview(fields: settings.sidebarFields)
                .padding()
        }
    }

    private var availableFields: [SidebarField] {
        SidebarField.allCases.filter { !settings.sidebarFields.contains($0) }
    }
}

// MARK: - Field List

private struct FieldList: View {
    let title: String
    @Binding var fields: [SidebarField]
    let allFields: [SidebarField]
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
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Preview

private struct SidebarPreview: View {
    let fields: [SidebarField]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview")
                .font(.headline)

            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(.green)
                    .frame(width: 10, height: 10)
                    .padding(.top, 4)

                SessionFieldsView(
                    fields: fields,
                    customDescription: "My Feature Branch",
                    projectName: "Gallager",
                    sessionName: "dev",
                    terminalTitle: "claude",
                    command: "claude",
                    currentPath: "~/Development/Gallager",
                    latestEvent: "Reading file Package.swift"
                )
            }
            .padding(12)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
