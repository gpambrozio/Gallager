#if os(macOS)
    import AppKit
    import ClaudeCodePluginCore
    import ClaudeSpyCommon
    import CodexPluginCore
    import GallagerPluginProtocol
    import SwiftUI

    // MARK: - AgentsSettingsView

    /// Settings tab listing all registered agent plugins (Claude Code, Codex CLI, …)
    /// with a segmented picker and per-agent form. Thin MV view — all data/actions go
    /// through `AppCoordinator`.
    public struct AgentsSettingsView: View {
        @Environment(AppCoordinator.self) private var coordinator

        @State private var selectedAgentID = ""
        @State private var showAddPluginSheet = false
        @State private var pluginToRemove: String?
        @State private var showRemoveConfirmation = false

        public init() { }

        public var body: some View {
            VStack(spacing: 0) {
                let agents = coordinator.agentPluginList()

                // Segmented picker at the top
                if agents.count > 1 {
                    HStack {
                        Picker("Agent", selection: $selectedAgentID) {
                            ForEach(agents) { agent in
                                Text(agent.name).tag(agent.id)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityIdentifier("agentPicker")

                        removeButton
                    }
                    .padding()
                }

                if selectedAgentID.isEmpty {
                    // Not yet loaded — show nothing (task below will set it)
                    Spacer()
                } else {
                    PluginAgentForm(pluginID: selectedAgentID)
                }

                Divider()

                // Toolbar row at the bottom of the tab
                HStack {
                    Button {
                        showAddPluginSheet = true
                    } label: {
                        Label("Add Plugin from URL…", symbol: .arrowDownCircle)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("addPluginFromURL")
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .frame(minWidth: 500, minHeight: 400)
            .sheet(isPresented: $showAddPluginSheet) {
                AddPluginSheet()
            }
            .confirmationDialog(
                "Remove Plugin",
                isPresented: $showRemoveConfirmation,
                presenting: pluginToRemove
            ) { id in
                Button("Remove \"\(pluginDisplayName(id))\"", role: .destructive) {
                    Task {
                        await performRemove(id: id)
                    }
                }
                Button("Cancel", role: .cancel) {
                    pluginToRemove = nil
                }
            } message: { id in
                Text("This will uninstall the \"\(pluginDisplayName(id))\" plugin and delete its files. This cannot be undone.")
            }
            .task {
                // Set initial selection once (only when empty to avoid overwriting
                // a user change that races with the first render).
                if
                    selectedAgentID.isEmpty,
                    let first = coordinator.agentPluginList().first {
                    selectedAgentID = first.id
                }
            }
        }

        // MARK: - Remove button (only for non-bundled plugins)

        @ViewBuilder
        private var removeButton: some View {
            if !selectedAgentID.isEmpty, !coordinator.isBundledPlugin(id: selectedAgentID) {
                Button(role: .destructive) {
                    pluginToRemove = selectedAgentID
                    showRemoveConfirmation = true
                } label: {
                    Label("Remove…", symbol: .minusCircleFill)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("removePlugin-\(selectedAgentID)")
            }
        }

        // MARK: - Helpers

        private func pluginDisplayName(_ id: String) -> String {
            coordinator.agentPluginList().first { $0.id == id }?.name ?? id
        }

        @MainActor
        private func performRemove(id: String) async {
            _ = await coordinator.removePlugin(id: id, deleteState: true)
            // If the removed plugin was selected, switch to the first remaining one.
            if selectedAgentID == id {
                selectedAgentID = coordinator.agentPluginList().first { $0.id != id }?.id ?? ""
            }
            pluginToRemove = nil
        }
    }

    // MARK: - PluginAgentForm

    /// Per-agent settings form. Decodes the correct typed-settings struct (switching
    /// on pluginID), renders shared field UI, and re-encodes + persists on every
    /// change. Config-folder rows appear below with Install/Uninstall actions.
    private struct PluginAgentForm: View {
        let pluginID: String

        @Environment(AppCoordinator.self) private var coordinator

        // The decoded field values (shared between both concrete types)
        @State private var commandPath = ""
        @State private var autoRun = true
        @State private var logLevel: LogLevel = .info
        @State private var closePaneOnSessionEnd = false
        @State private var additionalConfigFolders: [String] = []
        // Codex-only: point Codex's OTLP export at the loopback receiver (#602).
        @State private var exportTelemetry = true

        /// Whether the agent binary was not found
        @State private var agentUnavailable = false

        /// Inline write error
        @State private var writeError: String?

        /// Prevent persisting while we're still loading
        @State private var isLoaded = false

        var body: some View {
            Form {
                // Agent-unavailable banner
                if agentUnavailable {
                    Section {
                        Label(
                            "\(agentDisplayName) CLI not found — install it to enable this agent.",
                            symbol: .exclamationmarkTriangle
                        )
                        .foregroundStyle(.orange)
                    }
                }

                // Inline write-error banner
                if let writeError {
                    Section {
                        Label(writeError, symbol: .exclamationmarkCircleFill)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("agentWriteError-\(pluginID)")
                    }
                }

                // Command + Browse
                Section("Command") {
                    HStack {
                        TextField("Command path", text: $commandPath)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { persist() }
                            .accessibilityIdentifier("agentCommandPath-\(pluginID)")
                        Button("Browse…") {
                            browseForCommand()
                        }
                    }
                }

                // Behaviour
                Section("Behaviour") {
                    Toggle("Auto-run \(agentDisplayName) in project folders", isOn: $autoRun)
                        .onChange(of: autoRun) { _, _ in persist() }
                        .accessibilityIdentifier("agentAutoRun-\(pluginID)")

                    Picker("Log level", selection: $logLevel) {
                        ForEach(LogLevel.allCases, id: \.self) { level in
                            Text(level.rawValue.capitalized).tag(level)
                        }
                    }
                    .onChange(of: logLevel) { _, _ in persist() }
                    .accessibilityIdentifier("agentLogLevel-\(pluginID)")

                    Toggle("Close pane when \(agentDisplayName) exits", isOn: $closePaneOnSessionEnd)
                        .onChange(of: closePaneOnSessionEnd) { _, _ in persist() }
                        .accessibilityIdentifier("agentClosePane-\(pluginID)")

                    // Codex configures OTEL through its own config (it doesn't read
                    // `OTEL_*` env vars like Claude), so the export is opt-out-able
                    // per-agent here (#602). Claude has no equivalent toggle.
                    if pluginID == "codex" {
                        Toggle("Export telemetry (tokens, latency, model)", isOn: $exportTelemetry)
                            .onChange(of: exportTelemetry) { _, _ in persist() }
                            .accessibilityIdentifier("agentExportTelemetry-\(pluginID)")
                            .help(
                                "Point this agent's OpenTelemetry export at Gallager's loopback receiver "
                                    + "so the session's token meter, latency, and model show in the UI. "
                                    + "One-way and local only — no prompt or tool content leaves your Mac."
                            )
                    }
                }

                // Config folders
                Section {
                    // Default root row (not removable)
                    AgentConfigFolderRow(
                        pluginID: pluginID,
                        folderPath: defaultConfigRoot,
                        isRemovable: false,
                        onRemove: nil
                    )

                    // Additional folders
                    ForEach(additionalConfigFolders, id: \.self) { folder in
                        AgentConfigFolderRow(
                            pluginID: pluginID,
                            folderPath: folder,
                            isRemovable: true,
                            onRemove: {
                                additionalConfigFolders.removeAll { $0 == folder }
                                persist()
                            }
                        )
                    }

                    Button("Add Folder…") {
                        addConfigFolder()
                    }
                    .accessibilityIdentifier("agentAddFolder-\(pluginID)")
                } header: {
                    Text("Config Folders")
                } footer: {
                    Text("Additional folders where the \(agentDisplayName) plugin should be installed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            // Load settings whenever the selected plugin changes
            .task(id: pluginID) {
                await loadSettings()
            }
        }

        // MARK: - Computed helpers

        private var agentDisplayName: String {
            coordinator.agentPluginList().first { $0.id == pluginID }?.name ?? pluginID
        }

        private var defaultConfigRoot: String {
            switch pluginID {
            case "claude-code": return "~/.claude"
            case "codex": return "~/.codex"
            // A sidecar declares its own default root in the manifest
            // (`sidecar.default_config_root`); fall back to `~` when absent.
            default: return coordinator.pluginDefaultConfigRoot(id: pluginID) ?? "~"
            }
        }

        // MARK: - Load

        @MainActor
        private func loadSettings() async {
            isLoaded = false
            writeError = nil

            let data = coordinator.pluginSettingsData(id: pluginID)
            switch pluginID {
            case "claude-code":
                let s = ClaudeCodeSettings.decode(from: data)
                commandPath = s.commandPath
                autoRun = s.autoRun
                logLevel = s.logLevel
                closePaneOnSessionEnd = s.closePaneOnSessionEnd
                additionalConfigFolders = s.additionalConfigFolders
                exportTelemetry = true
            case "codex":
                let s = CodexSettings.decode(from: data)
                commandPath = s.commandPath
                autoRun = s.autoRun
                logLevel = s.logLevel
                closePaneOnSessionEnd = s.closePaneOnSessionEnd
                additionalConfigFolders = s.additionalConfigFolders
                exportTelemetry = s.exportTelemetry
            default:
                // Any non-bundled sidecar: generic settings that persist + reach
                // the sidecar via apply_settings.
                let s = SidecarPluginSettings.decode(from: data)
                commandPath = s.commandPath
                autoRun = s.autoRun
                logLevel = s.logLevel
                closePaneOnSessionEnd = s.closePaneOnSessionEnd
                additionalConfigFolders = s.additionalConfigFolders
                exportTelemetry = true
            }

            // Check agent availability for the default root
            let status = await coordinator.pluginInstallStatus(id: pluginID, configRoot: nil)
            agentUnavailable = (status == .agentUnavailable)

            isLoaded = true
        }

        // MARK: - Persist

        private func persist() {
            guard isLoaded else { return }
            let data = encodeSettings()
            let id = pluginID
            Task {
                let error = await coordinator.setPluginSettings(id: id, data)
                guard pluginID == id else { return }
                writeError = error
            }
        }

        private func encodeSettings() -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            switch pluginID {
            case "claude-code":
                let s = ClaudeCodeSettings(
                    commandPath: commandPath,
                    autoRun: autoRun,
                    logLevel: logLevel,
                    additionalConfigFolders: additionalConfigFolders,
                    closePaneOnSessionEnd: closePaneOnSessionEnd
                )
                return (try? encoder.encode(s)) ?? Data()
            case "codex":
                let s = CodexSettings(
                    commandPath: commandPath,
                    autoRun: autoRun,
                    logLevel: logLevel,
                    closePaneOnSessionEnd: closePaneOnSessionEnd,
                    additionalConfigFolders: additionalConfigFolders,
                    exportTelemetry: exportTelemetry
                )
                return (try? encoder.encode(s)) ?? Data()
            default:
                let s = SidecarPluginSettings(
                    commandPath: commandPath,
                    autoRun: autoRun,
                    logLevel: logLevel,
                    additionalConfigFolders: additionalConfigFolders,
                    closePaneOnSessionEnd: closePaneOnSessionEnd
                )
                return (try? encoder.encode(s)) ?? Data()
            }
        }

        // MARK: - Browse

        @MainActor
        private func browseForCommand() {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
            panel.message = "Select the \(agentDisplayName) executable"

            if panel.runModal() == .OK, let url = panel.url {
                commandPath = url.path
                persist()
            }
        }

        @MainActor
        private func addConfigFolder() {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.showsHiddenFiles = true
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            panel.message = "Select an additional config folder for \(agentDisplayName)"
            panel.prompt = "Add Folder"

            guard panel.runModal() == .OK, let url = panel.url else { return }
            let path = url.standardizedFileURL.path
            guard !additionalConfigFolders.contains(path) else { return }
            additionalConfigFolders.append(path)
            persist()
        }
    }

    // MARK: - AgentConfigFolderRow

    /// A row in the config-folders list. Owns its install-status state and drives
    /// Install/Uninstall actions through `AppCoordinator`.
    ///
    /// - `configRoot: nil` → the default root row (not removable).
    /// - `configRoot: path` → an additional folder row (removable).
    private struct AgentConfigFolderRow: View {
        let pluginID: String
        /// The display path shown to the user (e.g. "~/.claude" or the actual path).
        let folderPath: String
        let isRemovable: Bool
        let onRemove: (() -> Void)?

        @Environment(AppCoordinator.self) private var coordinator

        @State private var status: PluginInstallStatus = .notInstalled
        @State private var busy = false
        @State private var error: String?

        /// `nil` for the default root, absolute path for additional folders.
        private var configRootArg: String? {
            // Default root rows use folderPath like "~/.claude" — these pass nil
            // (the coordinator resolves the default). Additional-folder rows pass
            // the real absolute path.
            isRemovable ? folderPath : nil
        }

        /// Stable identifier suffix for this row's controls. The default root row
        /// uses "default"; additional folders use their config-root path so each
        /// row's Install/Uninstall button is uniquely addressable.
        private var rowKey: String {
            configRootArg ?? "default"
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    // Path label
                    Text(abbreviatedPath(folderPath))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(folderPath)

                    Spacer()

                    // Status + action area
                    if busy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        statusAndAction
                    }

                    // Remove button for non-default rows
                    if isRemovable {
                        Button {
                            onRemove?()
                        } label: {
                            Symbols.minusCircleFill.image
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this folder")
                    }
                }

                // Inline error below the row (sibling, not an overlay).
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .accessibilityIdentifier("installStatus-\(pluginID)-\(rowKey)")
            .task(id: folderPath) {
                await refreshStatus()
            }
        }

        @ViewBuilder
        private var statusAndAction: some View {
            switch status {
            case let .installed(version):
                HStack(spacing: 6) {
                    Label(
                        version.map { "Installed v\($0)" } ?? "Installed",
                        symbol: .checkmarkCircleFill
                    )
                    .font(.caption)
                    .foregroundStyle(.green)

                    Button("Uninstall") {
                        Task { await performUninstall() }
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("uninstallPlugin-\(pluginID)-\(rowKey)")
                }

            case .notInstalled:
                Button("Install") {
                    Task { await performInstall() }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("installPlugin-\(pluginID)-\(rowKey)")

            case .agentUnavailable:
                Label("Agent not found", symbol: .exclamationmarkTriangle)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("Install the \(pluginID) CLI to enable plugin installation for this folder")
                    .disabled(true)
            }
        }

        // MARK: - Actions

        @MainActor
        private func refreshStatus() async {
            status = await coordinator.pluginInstallStatus(id: pluginID, configRoot: configRootArg)
        }

        @MainActor
        private func performInstall() async {
            busy = true
            error = nil
            let result = await coordinator.installPlugin(id: pluginID, configRoot: configRootArg)
            error = result
            status = await coordinator.pluginInstallStatus(id: pluginID, configRoot: configRootArg)
            busy = false
        }

        @MainActor
        private func performUninstall() async {
            busy = true
            error = nil
            let result = await coordinator.uninstallPlugin(id: pluginID, configRoot: configRootArg)
            error = result
            status = await coordinator.pluginInstallStatus(id: pluginID, configRoot: configRootArg)
            busy = false
        }

        // MARK: - Helpers

        private func abbreviatedPath(_ path: String) -> String {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            if path.hasPrefix(home + "/") || path == home {
                return "~" + path.dropFirst(home.count)
            }
            return path
        }
    }
#endif
