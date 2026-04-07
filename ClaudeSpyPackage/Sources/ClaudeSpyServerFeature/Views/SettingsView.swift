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

            SidebarLayoutSettingsView()
                .tabItem {
                    Label("Sidebar", symbol: .listBulletClipboard)
                }
                .tag(SettingsTab.sidebarLayout)

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
                    TextField("Lines", value: $settings.scrollbackLines, format: .number)
                        .frame(width: 80)
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
                    Text("Path")
                    TextField("Path to tmux", text: $settings.tmuxPath)
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
                        Text("Command")
                        TextField("claude", text: $settings.claudeCommandPath)
                            .help("Path to the claude command (full path or just 'claude' if in PATH)")
                        Button("Browse...") {
                            browseForClaude(settings: settings)
                        }
                    }
                }
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
