import AppKit
import ClaudeSpyCommon
import Dependencies
import SwiftUI
import UniformTypeIdentifiers

/// Settings tab for managing the list of external editors used by the
/// "Open in Editor" command in the file browser and on file tabs.
struct EditorsSettingsView: View {
    @Environment(AppSettings.self) private var settings

    @State private var selection: EditorConfiguration.ID?
    @State private var renamingId: UUID?
    @State private var renameDraft = ""
    @State private var addEditorPickerVisible = false

    var body: some View {
        @Bindable var settings = settings

        VStack(alignment: .leading, spacing: 12) {
            Text("Editors that appear in the file context menu and the Cmd+E menu when a file tab is focused.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 12)

            List(selection: $selection) {
                ForEach(settings.editors) { editor in
                    editorRow(editor)
                        .tag(editor.id)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(minHeight: 200)
            .accessibilityIdentifier("editors-list")

            HStack(spacing: 8) {
                Button {
                    addEditorPickerVisible = true
                } label: {
                    Label("Add Editor", symbol: .plus)
                }
                .help("Add an editor by selecting its application")
                .accessibilityLabel("Add Editor")

                Button {
                    if let selection {
                        settings.removeEditor(id: selection)
                        self.selection = nil
                    }
                } label: {
                    Label("Remove", symbol: .minusCircleFill)
                }
                .disabled(selection == nil)
                .accessibilityLabel("Remove Editor")

                Spacer()

                Button("Detect Installed Editors") {
                    @Dependency(EditorClient.self) var client
                    Task {
                        let detected = await client.detectInstalledKnownEditors()
                        let existingBundles = Set(settings.editors.compactMap(\.bundleIdentifier))
                        for editor in detected where !existingBundles.contains(editor.bundleIdentifier ?? "") {
                            settings.addEditor(editor)
                        }
                    }
                }
                .help("Re-scan for known editors that are installed and add any missing ones")
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
        .fileImporter(
            isPresented: $addEditorPickerVisible,
            allowedContentTypes: [.application]
        ) { result in
            switch result {
            case let .success(url):
                addEditor(at: url)
            case .failure:
                break
            }
        }
    }

    private func editorRow(_ editor: EditorConfiguration) -> some View {
        HStack(spacing: 8) {
            editorIcon(for: editor)
                .frame(width: 24, height: 24)

            if renamingId == editor.id {
                TextField("Editor name", text: $renameDraft, onCommit: {
                    var updated = editor
                    let trimmed = renameDraft.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        updated.displayName = trimmed
                        settings.updateEditor(updated)
                    }
                    renamingId = nil
                })
                .textFieldStyle(.roundedBorder)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(editor.displayName)
                    if let detail = detailString(for: editor) {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .onTapGesture(count: 2) {
                    renamingId = editor.id
                    renameDraft = editor.displayName
                }
            }

            Spacer()
        }
        .accessibilityLabel("Editor: \(editor.displayName)")
        .padding(.vertical, 2)
    }

    private func editorIcon(for editor: EditorConfiguration) -> some View {
        let image: NSImage? = {
            if
                let bundleId = editor.bundleIdentifier,
                let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
            if let path = editor.executablePath {
                return NSWorkspace.shared.icon(forFile: path)
            }
            return nil
        }()
        return Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Symbols.pencil.image
            }
        }
    }

    private func detailString(for editor: EditorConfiguration) -> String? {
        if let bundleId = editor.bundleIdentifier { return bundleId }
        return editor.executablePath
    }

    private func addEditor(at url: URL) {
        let bundle = Bundle(url: url)
        let bundleId = bundle?.bundleIdentifier
        let displayName = bundle?.infoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle?.infoDictionary?["CFBundleName"] as? String
            ?? url.deletingPathExtension().lastPathComponent
        let editor = EditorConfiguration(
            displayName: displayName,
            bundleIdentifier: bundleId,
            executablePath: bundleId == nil ? url.path : nil
        )
        settings.addEditor(editor)
        selection = editor.id
    }
}

#Preview {
    let settings = AppSettings()
    settings.editors = [
        EditorConfiguration(
            displayName: "Visual Studio Code",
            bundleIdentifier: "com.microsoft.VSCode"
        ),
        EditorConfiguration(
            displayName: "Custom Script",
            executablePath: "/usr/local/bin/some-editor"
        ),
    ]
    return EditorsSettingsView()
        .environment(settings)
        .frame(width: 600, height: 400)
}
