#if os(macOS)
    import AppKit
    import ClaudeSpyCommon
    import ClaudeSpyNetworking
    import ClaudeSpyPluginRuntime
    import Dependencies
    import GallagerPluginProtocol
    import SwiftUI

    // MARK: - PluginSettingsView (per-plugin detail page)

    /// Per-plugin Settings detail page (Spec §17.3, §17.5; Task 16).
    ///
    /// Reached by drilling into one row of the "Plugin" Settings tab.
    /// Shows:
    /// - Plugin metadata (display name, version, source).
    /// - Enabled toggle (calls `PluginManager.enable` / `disable`).
    /// - Install hooks button (`PluginManager.installHooks`).
    /// - The schema-driven settings form (Spec §17.3).
    /// - View Logs button → ``PluginLogViewerSheet`` (Spec §17.5).
    public struct PluginSettingsView: View {
        public let presentation: PluginPresentation

        @Environment(\.pluginManager) private var pluginManager

        @State private var schema: PluginSettingsSchema?
        @State private var values: [String: JSONValue] = [:]
        @State private var schemaError: String?
        @State private var validationError: String?

        @State private var hooksInstalled: Bool?
        @State private var hookOperationError: String?
        @State private var isInstallingHooks = false

        @State private var enabled = true
        @State private var bundled = true
        @State private var sourceDescription = ""

        @State private var showingLogViewer = false

        public init(presentation: PluginPresentation) {
            self.presentation = presentation
        }

        // MARK: - Body

        public var body: some View {
            Form {
                Section("Plugin") {
                    LabeledContent("Display name") {
                        Text(presentation.displayName)
                    }
                    LabeledContent("Short name") {
                        Text(presentation.shortName)
                    }
                    LabeledContent("Version") {
                        Text(presentation.version)
                    }
                    LabeledContent("Source") {
                        Text(sourceDescription.isEmpty ? "—" : sourceDescription)
                    }

                    Toggle("Enabled", isOn: $enabled)
                        .onChange(of: enabled) { _, newValue in
                            Task { await applyEnabled(newValue) }
                        }
                }

                Section("Hooks") {
                    HStack {
                        statusLabel
                        Spacer()
                        Button("Install hooks") {
                            Task { await installHooks() }
                        }
                        .disabled(isInstallingHooks)
                    }
                    if let error = hookOperationError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        showingLogViewer = true
                    } label: {
                        Label("View logs", symbol: .docPlaintextFill)
                    }
                }

                if let schema {
                    SchemaFormView(
                        values: $values,
                        schema: schema,
                        onSubmit: applySettings,
                        validationError: validationError
                    )
                } else if let schemaError {
                    Section {
                        Label(schemaError, symbol: .exclamationmarkTriangle)
                            .foregroundStyle(.orange)
                    }
                } else {
                    Section {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading settings schema…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(presentation.displayName)
            .sheet(isPresented: $showingLogViewer) {
                PluginLogViewerSheet(
                    pluginID: presentation.id,
                    displayName: presentation.displayName
                )
            }
            .task {
                await loadAll()
            }
        }

        // MARK: - Status label

        @ViewBuilder
        private var statusLabel: some View {
            switch hooksInstalled {
            case .some(true):
                Label("Hooks installed", symbol: .checkmarkCircleFill)
                    .foregroundStyle(.green)
            case .some(false):
                Label("Hooks not installed", symbol: .exclamationmarkTriangle)
                    .foregroundStyle(.orange)
            case .none:
                Label("Checking…", symbol: .ellipsisCircle)
                    .foregroundStyle(.secondary)
            }
        }

        // MARK: - Loaders

        private func loadAll() async {
            await loadMetadata()
            await loadSchema()
            await refreshHookStatus()
        }

        private func loadMetadata() async {
            guard let manager = pluginManager else {
                sourceDescription = "Plugin runtime unavailable"
                return
            }
            do {
                bundled = try await manager.isBundled(pluginID: presentation.id)
                enabled = try await manager.isEnabled(pluginID: presentation.id)
                let source = try await manager.source(pluginID: presentation.id)
                sourceDescription = (source == .bundled) ? "Bundled" : "Installed from URL"
            } catch {
                sourceDescription = "Unknown (\(error.localizedDescription))"
            }
        }

        private func loadSchema() async {
            guard let manager = pluginManager else {
                schemaError = "Plugin runtime unavailable."
                return
            }
            do {
                let fetched = try await manager.settingsSchema(pluginID: presentation.id)
                let existing = readExistingSettings(at: manager.settingsURL(pluginID: presentation.id))
                schema = fetched
                values = SchemaFormDefaults.merge(schema: fetched, with: existing)
            } catch {
                schemaError = "Could not load settings: \(error.localizedDescription)"
            }
        }

        private func refreshHookStatus() async {
            guard let manager = pluginManager else { return }
            do {
                hooksInstalled = try await manager.isHookInstalled(pluginID: presentation.id)
            } catch {
                // Surface as unknown so the install button still works
                // even if the status RPC isn't implemented yet.
                hooksInstalled = nil
            }
        }

        /// Read the on-disk settings.json so the form starts from the
        /// values the user previously saved. Unknown top-level keys are
        /// preserved by `SchemaFormDefaults.merge`.
        private func readExistingSettings(at url: URL) -> [String: JSONValue] {
            guard
                let data = try? Data(contentsOf: url),
                let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data)
            else {
                return [:]
            }
            return decoded
        }

        // MARK: - Actions

        private func applyEnabled(_ newValue: Bool) async {
            guard let manager = pluginManager else { return }
            do {
                if newValue {
                    try await manager.enable(pluginID: presentation.id)
                } else {
                    try await manager.disable(pluginID: presentation.id)
                }
                await refreshHookStatus()
            } catch {
                // Roll back the toggle on failure.
                enabled = !newValue
                hookOperationError = error.localizedDescription
            }
        }

        private func installHooks() async {
            guard let manager = pluginManager else { return }
            isInstallingHooks = true
            defer { isInstallingHooks = false }
            hookOperationError = nil
            do {
                try await manager.installHooks(pluginID: presentation.id)
                await refreshHookStatus()
            } catch {
                hookOperationError = error.localizedDescription
            }
        }

        /// Persist the form's snapshot to settings.json AND forward to
        /// the sidecar via `apply_settings`. The sidecar performs
        /// semantic validation; rejection surfaces as `validationError`.
        private func applySettings(_ snapshot: [String: JSONValue]) async throws {
            guard let manager = pluginManager else {
                throw PluginSettingsError.pluginRuntimeUnavailable
            }
            validationError = nil

            // Persist to disk first so a sidecar that rejects the
            // RPC still has the user's draft to fall back to on
            // restart. Atomic write so we never observe a half-formed
            // file on crash.
            try writeSettings(snapshot, to: manager.settingsURL(pluginID: presentation.id))

            do {
                try await manager.applySettings(
                    pluginID: presentation.id,
                    settings: .object(snapshot)
                )
            } catch {
                validationError = error.localizedDescription
                throw error
            }
        }

        private func writeSettings(
            _ snapshot: [String: JSONValue],
            to url: URL
        ) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
        }
    }

    // MARK: - PluginSettingsError

    enum PluginSettingsError: Error, LocalizedError {
        case pluginRuntimeUnavailable

        var errorDescription: String? {
            switch self {
            case .pluginRuntimeUnavailable:
                return "Plugin runtime is not available yet."
            }
        }
    }
#endif
