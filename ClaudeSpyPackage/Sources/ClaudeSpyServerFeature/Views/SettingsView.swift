import AppKit
import ClaudeSpyCommon
import ClaudeSpyEncryption
import SwiftUI
import UniformTypeIdentifiers

/// Settings view for configuring the application
public struct SettingsView: View {
    @Environment(AppSettings.self) private var settings

    public init() { }

    public var body: some View {
        @Bindable var settings = settings

        TabView(selection: $settings.selectedSettingsTab) {
            GeneralSettingsView()
                .tabItem {
                    Label("General", symbol: .gearshape)
                }
                .tag(SettingsTab.general)

            AppearanceSettingsView()
                .tabItem {
                    Label("Appearance", symbol: .circleLefthalfFilled)
                }
                .tag(SettingsTab.appearance)

            SidebarLayoutSettingsView()
                .tabItem {
                    Label("Sidebar", symbol: .listBulletClipboard)
                }
                .tag(SettingsTab.sidebarLayout)

            EditorsSettingsView()
                .tabItem {
                    Label("Editors", symbol: .pencil)
                }
                .tag(SettingsTab.editors)

            RemoteAccessSettingsView()
                .tabItem {
                    Label("Remote Access", symbol: .iphone)
                }
                .tag(SettingsTab.remoteAccess)

            RemoteHostsSettingsView()
                .tabItem {
                    Label("Remote Hosts", symbol: .laptopcomputer)
                }
                .tag(SettingsTab.remoteHosts)

            PluginSettingsView()
                .tabItem {
                    Label("Plugin", symbol: .puzzlepiece)
                }
                .tag(SettingsTab.plugin)

            AboutView()
                .tabItem {
                    Label("About", symbol: .infoCircle)
                }
                .tag(SettingsTab.about)
        }
        .frame(minWidth: 900, minHeight: 500)
    }
}

/// General settings tab
struct GeneralSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(UpdaterController.self) private var updaterController

    @State private var launchAtLoginEnabled = false
    @State private var showingLoginItemError = false
    @State private var loginItemErrorMessage = ""

    /// Folder whose plugin install prompt is currently being shown, if any.
    @State private var pluginSetupFolder: ClaudeFolderIdentifier?

    /// Bumped after a custom-folder plugin setup sheet is dismissed so each
    /// folder row re-checks its plugin installation status.
    @State private var pluginStatusRefreshID = UUID()

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Terminal") {
                Picker("Terminal App", selection: $settings.terminalApp) {
                    ForEach(TerminalApp.allCases, id: \.self) { app in
                        HStack {
                            Text(app.rawValue)
                            if app != .custom && !app.isInstalled {
                                Text("(not installed)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(app)
                    }
                }
                .help("Terminal application to use when attaching to sessions")

                if settings.terminalApp == .custom {
                    HStack {
                        Text("App Path")
                        TextField("Path to terminal app", text: $settings.customTerminalPath)
                        Button("Browse...") {
                            browseForTerminalApp(settings: settings)
                        }
                    }
                }

                Picker("Font", selection: $settings.fontName) {
                    ForEach(availableFonts, id: \.self) { font in
                        Text(font).tag(font)
                    }
                }

                HStack {
                    Text("Size")
                    Slider(value: $settings.fontSize, in: 8...24, step: 1)
                    Text("\(Int(settings.fontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 40)
                }

                HStack {
                    Text("Scrollback")
                    Spacer()
                    TextField("", value: $settings.scrollbackLines, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                    Text("lines")
                }

                Toggle("Always auto-resize terminals", isOn: $settings.alwaysAutoResize)
                    .help("Automatically resize all terminal panes to fit the mirror view when the window size changes")

                Picker("Theme", selection: $settings.theme) {
                    ForEach(TerminalTheme.allCases, id: \.self) { theme in
                        Text(theme.rawValue).tag(theme)
                    }
                }
            }

            Section("Behavior") {
                Toggle("Launch at login", isOn: $launchAtLoginEnabled)
                    .help("Start Gallager automatically when you log in")
                    .onChange(of: launchAtLoginEnabled) { _, newValue in
                        do {
                            try settings.setLoginItemEnabled(newValue)
                        } catch {
                            // Revert toggle state on failure
                            launchAtLoginEnabled = settings.isLoginItemEnabled
                            loginItemErrorMessage = error.localizedDescription
                            showingLoginItemError = true
                        }
                    }

                Toggle("Open panes window on launch", isOn: $settings.openPanesWindowOnLaunch)
                    .help("Automatically open the panes window when the app starts")

                Toggle("Show status bar", isOn: $settings.showStatusBar)

                Toggle("Auto-copy selected text", isOn: $settings.autoCopyOnSelect)
                    .help("Automatically copy selected text to the clipboard when the mouse is released")

                Toggle("Open clicked file links in a new tab", isOn: $settings.openClickedFileInNewTab)
                    .help("When a file:// link is clicked in the terminal, open the file in a new tab instead of the system default browser")

                Toggle("Prevent sleep during active sessions", isOn: $settings.preventSleepDuringSessions)
                    .help("Keep host awake while Claude Code sessions are running")

                Toggle("Auto-reconnect on connection loss", isOn: $settings.autoReconnect)

                if settings.autoReconnect {
                    LabeledContent("Reconnect delay") {
                        HStack {
                            TextField("", value: $settings.reconnectDelay, format: .number)
                                .frame(width: 60)
                            Text("seconds")
                        }
                    }
                }
            }

            Section("tmux") {
                HStack {
                    TextField("Path to tmux", text: $settings.tmuxPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse...") {
                        browseForTmux(settings: settings)
                    }
                }

                HStack {
                    Text("Socket")
                    TextField("Default", text: $settings.tmuxSocket)
                        .help("Leave empty to use the default tmux socket")
                }
            }

            Section("Claude Code") {
                Toggle("Auto-run Claude in project folders", isOn: $settings.autoRunClaudeInProjects)
                    .help("When creating a session in a Claude project folder, automatically run the claude command")

                if settings.autoRunClaudeInProjects {
                    HStack {
                        TextField("Command", text: $settings.claudeCommandPath)
                            .help("Path to the claude command (full path or just 'claude' if in PATH)")
                            .textFieldStyle(.roundedBorder)
                        Button("Browse...") {
                            browseForClaude(settings: settings)
                        }
                    }
                }

                Toggle("Close pane when Claude exits", isOn: $settings.closePaneOnSessionEnd)
                    .help("Automatically close the tmux pane after Claude Code exits normally")
            }

            Section("Project Folders") {
                Text("Directories containing .claude.json and .claude/ to scan for projects.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Default") {
                    Text("~/.claude")
                        .foregroundStyle(.secondary)
                }

                ForEach(settings.additionalClaudeFolders, id: \.self) { folder in
                    ClaudeFolderRow(
                        folder: folder,
                        refreshTrigger: pluginStatusRefreshID
                    ) { url in
                        pluginSetupFolder = ClaudeFolderIdentifier(url: url)
                    }
                }

                Button("Add Folder...") {
                    if let url = browseForClaudeFolder(settings: settings) {
                        pluginSetupFolder = ClaudeFolderIdentifier(url: url)
                    }
                }
                .help("Add a directory that contains a .claude.json config and .claude/projects/ session data")
            }

            Section("Updates") {
                Toggle(
                    "Automatically check for updates",
                    isOn: Binding(
                        get: { updaterController.automaticallyChecksForUpdates },
                        set: { updaterController.automaticallyChecksForUpdates = $0 }
                    )
                )
                .help("Periodically check for new versions in the background")

                HStack {
                    Button("Check for Updates Now") {
                        updaterController.checkForUpdates()
                    }
                    .disabled(!updaterController.canCheckForUpdates)

                    if let lastCheck = updaterController.lastUpdateCheckDate {
                        Text("Last checked: \(lastCheck, format: .relative(presentation: .named))")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // Sync with actual system state (in case user changed it in System Settings)
            launchAtLoginEnabled = settings.isLoginItemEnabled
        }
        .alert("Login Item Error", isPresented: $showingLoginItemError) {
            Button("OK") { }
        } message: {
            Text(loginItemErrorMessage)
        }
        .sheet(
            item: $pluginSetupFolder,
            onDismiss: {
                pluginStatusRefreshID = UUID()
            }
        ) { folder in
            CustomFolderPluginSetupView(configDir: folder.url)
        }
    }
}

/// Identifier wrapper so a selected Claude folder URL can drive a
/// `sheet(item:)` presentation.
private struct ClaudeFolderIdentifier: Identifiable {
    let url: URL
    var id: String {
        url.path
    }
}

/// Row in the custom Claude folders list.
///
/// Owns a ``PluginService`` scoped to ``folder`` so the plugin install
/// status is checked and displayed inline. When the plugin isn't yet
/// installed, the Install Plugin button asks the parent view to open the
/// shared ``CustomFolderPluginSetupView`` — the same sheet used when the
/// user first adds a folder. `refreshTrigger` is bumped by the parent
/// after that sheet dismisses so each row re-checks its state.
private struct ClaudeFolderRow: View {
    let folder: String
    let refreshTrigger: UUID
    let onInstallRequested: (URL) -> Void

    @Environment(AppSettings.self) private var settings

    @State private var pluginService: PluginService

    init(
        folder: String,
        refreshTrigger: UUID,
        onInstallRequested: @escaping (URL) -> Void
    ) {
        self.folder = folder
        self.refreshTrigger = refreshTrigger
        self.onInstallRequested = onInstallRequested
        self._pluginService = State(
            initialValue: PluginService(configDir: URL(fileURLWithPath: folder))
        )
    }

    var body: some View {
        HStack {
            Text(abbreviatePath(folder))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(folder)

            pluginStatusView

            Spacer()

            Button {
                settings.removeClaudeFolder(folder)
            } label: {
                Symbols.minusCircleFill.image
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Remove this folder")
        }
        .task(id: folder + refreshTrigger.uuidString) {
            await checkPlugin()
        }
    }

    @ViewBuilder
    private var pluginStatusView: some View {
        switch pluginService.state {
        case .unknown,
             .checking,
             .checkingClaude:
            ProgressView()
                .controlSize(.small)
        case let .installed(version):
            Label("Plugin installed", symbol: .checkmarkCircleFill)
                .font(.caption)
                .foregroundStyle(.green)
                .help("Gallager plugin v\(version) is installed for this folder")
        case .notInstalled:
            Button {
                onInstallRequested(URL(fileURLWithPath: folder))
            } label: {
                Label("Install Plugin", symbol: .arrowDown)
            }
            .controlSize(.small)
        case let .installationFailed(reason):
            Button {
                onInstallRequested(URL(fileURLWithPath: folder))
            } label: {
                Label("Install Plugin", symbol: .arrowDown)
            }
            .controlSize(.small)
            .help("Previous attempt failed: \(reason)")
        case .claudeNotInstalled:
            Label("Claude Code not found", symbol: .exclamationmarkTriangle)
                .font(.caption)
                .foregroundStyle(.orange)
                .help("Install Claude Code to use the plugin in this folder")
        case .installing:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.small)
                Text("Installing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func checkPlugin() async {
        guard await pluginService.findClaude() != nil else {
            return
        }
        await pluginService.checkInstallation()
    }
}

// MARK: - Helpers

private var availableFonts: [String] {
    [
        "SF Mono",
        "Menlo",
        "Monaco",
        "Courier New",
        "Andale Mono",
        "Source Code Pro",
        "Fira Code",
        "JetBrains Mono",
    ]
}

@MainActor
private func browseForTmux(settings: AppSettings) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
    panel.message = "Select the tmux executable"

    if panel.runModal() == .OK, let url = panel.url {
        settings.tmuxPath = url.path
    }
}

@MainActor
private func browseForTerminalApp(settings: AppSettings) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.allowedContentTypes = [.application]
    panel.message = "Select a terminal application"

    if panel.runModal() == .OK, let url = panel.url {
        settings.customTerminalPath = url.path
    }
}

@MainActor
private func browseForClaude(settings: AppSettings) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
    panel.message = "Select the claude executable"

    if panel.runModal() == .OK, let url = panel.url {
        settings.claudeCommandPath = url.path
    }
}

/// Presents a folder picker for a new Claude folder, adds it to settings,
/// and returns the normalized URL when the folder was newly added so the
/// caller can follow up (e.g. offer to install the plugin for it). Returns
/// `nil` if the panel was cancelled or the folder was already tracked.
@MainActor
private func browseForClaudeFolder(settings: AppSettings) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
    panel.message = "Select a directory containing .claude.json and .claude/"
    panel.prompt = "Add Folder"

    guard panel.runModal() == .OK, let url = panel.url else {
        return nil
    }
    let normalized = URL(fileURLWithPath: url.path).standardizedFileURL.path
    guard !settings.additionalClaudeFolders.contains(normalized) else {
        return nil
    }
    settings.addClaudeFolder(url.path)
    return URL(fileURLWithPath: normalized)
}

private func abbreviatePath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path.hasPrefix(home + "/") || path == home {
        return "~" + path.dropFirst(home.count)
    }
    return path
}

#Preview {
    let settings = AppSettings()
    let e2eeService = E2EEService(keyPair: .generateNew())

    SettingsView()
        .environment(settings)
        .environment(AppCoordinator(settings: settings))
        .environment(PairingManager(settings: settings, e2eeService: e2eeService))
        .environment(UpdaterController(startUpdater: false))
        .environment(PluginService())
        .e2eeService(e2eeService)
}
