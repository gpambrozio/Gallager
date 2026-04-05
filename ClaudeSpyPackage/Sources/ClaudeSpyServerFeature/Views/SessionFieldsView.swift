import ClaudeSpyCommon
import SwiftUI

/// Renders sidebar session fields in the order configured by the user.
///
/// The first field with a non-empty value gets primary styling (`.body.weight(.medium)`).
/// Subsequent fields use caption styling. Fields whose value is nil or empty are skipped.
struct SessionFieldsView: View {
    let fields: [SidebarField]
    let customDescription: String?
    let projectName: String?
    let sessionName: String
    let terminalTitle: String?
    let command: String?
    let currentPath: String?
    let latestEvent: String?
    /// Remote host's home directory for proper path abbreviation (nil for local sessions)
    var homeDirectory: String?

    var body: some View {
        let visibleFields = fields.compactMap { field -> (SidebarField, String)? in
            guard let value = value(for: field), !value.isEmpty else { return nil }
            return (field, value)
        }

        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(visibleFields.enumerated()), id: \.element.0) { index, entry in
                if index == 0 {
                    Text(entry.1)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                } else {
                    Text(entry.1)
                        .font(entry.0 == .latestEvent ? .caption2 : .caption)
                        .foregroundStyle(entry.0 == .latestEvent ? .tertiary : .secondary)
                        .lineLimit(entry.0 == .latestEvent ? 2 : 1)
                }
            }
        }
    }

    private func value(for field: SidebarField) -> String? {
        switch field {
        case .customDescription: customDescription
        case .projectName: projectName
        case .sessionName: sessionName
        case .terminalTitle: terminalTitle
        case .command: command
        case .currentPath: currentPath?.abbreviatedPath(home: homeDirectory)
        case .latestEvent: latestEvent
        }
    }
}
