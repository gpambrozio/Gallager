import AppKit
import ClaudeSpyCommon
import ClaudeSpyEncryption
import ClaudeSpyNetworking
import ClaudeSpyPluginRuntime
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

            BrowserSettingsView()
                .tabItem {
                    Label("Browser", symbol: .globe)
                }
                .tag(SettingsTab.browser)

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

            PluginsTabView()
                .tabItem {
                    Label("Plugins", symbol: .puzzlepiece)
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

                Toggle("Always open files in split tab", isOn: $settings.alwaysOpenFilesInSplit)
                    .help("When opening a file in a new tab, route it to the split-view right pane instead of the left.")

                Toggle("Always open links in split tab", isOn: $settings.alwaysOpenLinksInSplit)
                    .help("When opening a web link in an in-app browser tab, route it to the split-view right pane instead of the left.")

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

            Section("Agents") {
                Toggle("Close pane when agent exits", isOn: $settings.closePaneOnSessionEnd)
                    .help("Automatically close the tmux pane after a coding agent (Claude Code, Codex, …) exits normally")

                Text("Per-agent command paths and auto-launch toggles live in the Plugins tab, one tab per installed coding-agent plugin.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    ClaudeFolderRow(folder: folder)
                }

                Button("Add Folder...") {
                    _ = browseForClaudeFolder(settings: settings)
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
    }
}

/// Row in the custom Claude folders list.
///
/// Renders the folder path and a remove button. The legacy "install
/// gallager plugin for this folder" workflow was tied to the old hook
/// server and is gone — every coding-agent plugin now ships as a
/// bundled sidecar in `~/.gallager/state/plugins/`.
private struct ClaudeFolderRow: View {
    let folder: String

    @Environment(AppSettings.self) private var settings

    var body: some View {
        HStack {
            Text(abbreviatePath(folder))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(folder)

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

// MARK: - PluginsTabView

/// Settings → Plugins tab (Task 16).
///
/// Lists every plugin known to the runtime as a `NavigationLink`. Tapping
/// a row drills into ``PluginSettingsView`` with the chosen plugin's
/// presentation, where the user can flip the enabled bit, install hooks,
/// edit the schema-driven settings form, and view sidecar logs.
struct PluginsTabView: View {
    @Environment(\.pluginManager) private var pluginManager

    var body: some View {
        NavigationStack {
            Group {
                if let manager = pluginManager {
                    pluginsList(manager: manager)
                } else {
                    emptyState
                }
            }
            .navigationDestination(for: String.self) { pluginID in
                if
                    let manager = pluginManager,
                    let presentation = manager.presentation(for: pluginID) {
                    PluginSettingsView(presentation: presentation)
                } else {
                    Text("Plugin \(pluginID) is unavailable")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func pluginsList(manager: PluginManager) -> some View {
        if manager.presentations.isEmpty {
            emptyState
        } else {
            Form {
                Section {
                    ForEach(manager.presentations, id: \.id) { presentation in
                        NavigationLink(value: presentation.id) {
                            HStack(spacing: 12) {
                                pluginIcon(for: presentation)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(presentation.displayName)
                                        .font(.headline)
                                    Text("Version \(presentation.version)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } header: {
                    Text("Installed plugins")
                } footer: {
                    Text("Pick a plugin to manage its settings, install hooks, or view sidecar logs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
    }

    @ViewBuilder
    private func pluginIcon(for presentation: PluginPresentation) -> some View {
        if let nsImage = NSImage(data: presentation.iconPNGData) {
            Image(nsImage: nsImage)
                .resizable()
                .frame(width: 32, height: 32)
                .clipShape(.rect(cornerRadius: 6))
        } else {
            Symbols.puzzlepiece.image
                .font(.title2)
                .frame(width: 32, height: 32)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Symbols.puzzlepiece.image
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No plugins available")
                .font(.headline)
            Text("Plugin runtime hasn't started yet, or no plugins are installed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

#Preview {
    let settings = AppSettings()
    let e2eeService = E2EEService(keyPair: .generateNew())

    SettingsView()
        .environment(settings)
        .environment(AppCoordinator(settings: settings))
        .environment(PairingManager(settings: settings, e2eeService: e2eeService))
        .environment(UpdaterController(startUpdater: false))
        .e2eeService(e2eeService)
}
