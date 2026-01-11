import AppKit
import ClaudeSpyCommon
import SwiftUI

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
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}

/// General settings tab
struct GeneralSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Terminal") {
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
                Toggle("Menu bar only mode", isOn: $settings.menuBarOnly)
                    .help("Hide the dock icon and main window. Access sessions from the menu bar icon.")

                Toggle("Restore windows on launch", isOn: $settings.restoreWindowsOnLaunch)

                Toggle("Show status bar", isOn: $settings.showStatusBar)

                Toggle("Auto-reconnect on connection loss", isOn: $settings.autoReconnect)

                if settings.autoReconnect {
                    HStack {
                        Text("Reconnect delay")
                        TextField("Seconds", value: $settings.reconnectDelay, format: .number)
                            .frame(width: 60)
                        Text("seconds")
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
        }
        .formStyle(.grouped)
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

// Preview disabled - E2EEService requires async initialization
// #Preview {
//     let settings = AppSettings()
//     SettingsView()
//         .environment(settings)
//         .environment(PairingManager(settings: settings, e2eeService: ...))
//         .environment(ExternalServerClient())
// }
