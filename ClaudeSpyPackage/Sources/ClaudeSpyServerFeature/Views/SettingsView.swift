import AppKit
import ClaudeSpyCommon
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

            RemoteAccessSettingsView()
                .tabItem {
                    Label("Remote Access", symbol: .iphone)
                }
                .tag(SettingsTab.remoteAccess)

            RemoteMacsSettingsView()
                .tabItem {
                    Label("Remote Macs", symbol: .laptopcomputer)
                }
                .tag(SettingsTab.remoteHosts)

            PluginSettingsView()
                .tabItem {
                    Label("Plugin", symbol: .puzzlepiece)
                }
                .tag(SettingsTab.plugin)
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}

/// General settings tab
struct GeneralSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(UpdaterController.self) private var updaterController

    @State private var launchAtLoginEnabled = LoginItemService.isEnabled
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

                Picker("Theme", selection: $settings.theme) {
                    ForEach(TerminalTheme.allCases, id: \.self) { theme in
                        Text(theme.rawValue).tag(theme)
                    }
                }
            }

            Section("Behavior") {
                Toggle("Launch at login", isOn: $launchAtLoginEnabled)
                    .help("Start ClaudeSpy automatically when you log in")
                    .onChange(of: launchAtLoginEnabled) { _, newValue in
                        do {
                            try LoginItemService.setEnabled(newValue)
                            settings.launchAtLogin = newValue
                        } catch {
                            // Revert toggle state on failure
                            launchAtLoginEnabled = LoginItemService.isEnabled
                            loginItemErrorMessage = error.localizedDescription
                            showingLoginItemError = true
                        }
                    }

                Toggle("Restore windows on launch", isOn: $settings.restoreWindowsOnLaunch)

                Toggle("Show status bar", isOn: $settings.showStatusBar)

                Toggle("Auto-open mirror on session start", isOn: $settings.autoOpenMirrorOnSession)

                Toggle("Prevent sleep during active sessions", isOn: $settings.preventSleepDuringSessions)
                    .help("Keep Mac awake while Claude Code sessions are running")

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
            launchAtLoginEnabled = LoginItemService.isEnabled
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

// Preview disabled - E2EEService requires async initialization
// #Preview {
//     let settings = AppSettings()
//     SettingsView()
//         .environment(settings)
//         .environment(PairingManager(settings: settings, e2eeService: ...))
//         .environment(ExternalServerClient())
// }
