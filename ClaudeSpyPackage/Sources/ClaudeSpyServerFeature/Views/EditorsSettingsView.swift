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

            Divider()
                .padding(.horizontal)

            PromptEditorOverrideSection()
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
        Group {
            if let image = editor.nsIcon {
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

/// Settings for the in-app prompt editor (Ctrl-G) override (issue #591). Lets
/// the user pick how Gallager handles a shell config that clobbers `$VISUAL`,
/// and re-run the conflict probe on demand (e.g. after editing their rc files).
struct PromptEditorOverrideSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppCoordinator.self) private var coordinator

    @State private var isRechecking = false

    /// Drives the picker through the coordinator so changing the mode also
    /// updates the live tmux service (and injects into existing panes).
    private var modeBinding: Binding<EditorOverrideMode> {
        Binding(
            get: { settings.editorOverrideMode },
            set: { coordinator.setEditorOverrideMode($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prompt editor (Ctrl-G)")
                .font(.headline)

            Text("Gallager points $VISUAL at its in-app prompt editor so Ctrl-G in Claude Code / Codex edits prompts inside Gallager. If your shell config sets VISUAL, it overrides this in Gallager's sessions.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("When my shell overrides it", selection: modeBinding) {
                ForEach(EditorOverrideMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            HStack(spacing: 8) {
                statusLabel
                Spacer()
                Button("Re-check now") {
                    isRechecking = true
                    Task {
                        await coordinator.reprobeEditorConflict()
                        isRechecking = false
                    }
                }
                .disabled(isRechecking)
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if isRechecking {
            Label("Checking…", symbol: .arrowClockwise)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            switch coordinator.editorOverrideProbeResult {
            case .none:
                Label("Not checked yet", symbol: .questionmarkCircle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .intact,
                 .skipped:
                Label("Gallager's editor is active in sessions", symbol: .checkmarkCircle)
                    .font(.caption)
                    .foregroundStyle(.green)
            case let .conflict(value):
                Label(
                    "Your shell sets VISUAL=\(value ?? "(unset)"), overriding Gallager",
                    symbol: .exclamationmarkTriangle
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
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
        .environment(AppCoordinator(settings: settings))
        .frame(width: 600, height: 400)
}
