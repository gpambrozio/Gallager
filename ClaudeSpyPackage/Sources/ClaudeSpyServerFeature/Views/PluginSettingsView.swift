#if os(macOS)
    import AppKit
    import ClaudeCodePluginCore
    import ClaudeSpyCommon
    import Dependencies
    import SwiftUI

    /// Settings view for managing the Claude Code plugin
    public struct PluginSettingsView: View {
        @Environment(PluginService.self) private var pluginService
        @Environment(AppSettings.self) private var settings

        @Dependency(ClaudeBinaryLocator.self) private var claudeLocator

        @State private var showingInstructions = false
        @State private var showCopiedFeedback = false
        @State private var commandCopiedResetTrigger: UUID?
        @State private var claudeCopied = false
        @State private var claudeCopiedResetTrigger: UUID?

        public init() { }

        public var body: some View {
            Form {
                // Plugin Status Section
                Section {
                    pluginStatusRow
                } header: {
                    Text("Plugin Status")
                } footer: {
                    Text("The gallager plugin enables real-time monitoring of Claude Code sessions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Claude Code Installation Section (when claude binary is missing)
                if case .claudeNotInstalled = pluginService.state {
                    Section {
                        claudeInstallContent
                    } header: {
                        Text("Install Claude Code")
                    } footer: {
                        Text("The plugin requires the Claude Code CLI. Install it using the command above — the installation will be detected automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Installation Section
                if case .notInstalled = pluginService.state {
                    Section {
                        installationContent
                    } header: {
                        Text("Installation")
                    }
                }

                // Manual Instructions Section
                Section {
                    manualInstructionsContent
                } header: {
                    Text("Manual Installation")
                } footer: {
                    Text("Use these commands if automatic installation fails.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Installation Output (if any)
                if !pluginService.installationOutput.isEmpty {
                    Section {
                        ScrollView {
                            Text(pluginService.installationOutput)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 150)
                    } header: {
                        Text("Installation Log")
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 400, minHeight: 300)
            .navigationTitle("Plugin")
            .task {
                await runCheckFlow()
            }
            .task(id: commandCopiedResetTrigger) {
                guard commandCopiedResetTrigger != nil else { return }
                try? await Task.sleep(for: .seconds(2))
                showCopiedFeedback = false
            }
            .task(id: claudeCopiedResetTrigger) {
                guard claudeCopiedResetTrigger != nil else { return }
                try? await Task.sleep(for: .seconds(2))
                claudeCopied = false
            }
        }

        // MARK: - Check Flow

        /// Checks for claude, then the plugin. Polls for claude when it's
        /// missing so the UI reacts as soon as the user installs it.
        ///
        /// Once the user has finished the initial plugin setup the configured
        /// `claudeCommandPath` is treated as authoritative — they may have
        /// changed it (or pointed it at a non-default install location), and
        /// re-running auto-detection here would silently overwrite that
        /// choice. After setup, only the plugin status is refreshed.
        private func runCheckFlow() async {
            if settings.hasCompletedPluginSetup {
                await pluginService.checkInstallation()
                return
            }

            if let path = await pluginService.findClaude() {
                settings.claudeCommandPath = path
                await pluginService.checkInstallation()
                return
            }

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if let path = await claudeLocator.find() {
                    settings.claudeCommandPath = path
                    await pluginService.checkInstallation()
                    return
                }
            }
        }

        // MARK: - Plugin Status Row

        private var pluginStatusRow: some View {
            HStack(spacing: 12) {
                statusIcon
                    .font(.title2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(statusText)
                        .font(.headline)

                    if case let .installed(version) = pluginService.state {
                        Text("Version \(version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if
                        case let .installationFailed(summary) = pluginService.state {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }

                Spacer()

                if
                    case .installationFailed = pluginService.state,
                    let failure = pluginService.lastFailure {
                    PluginFailureDetailsButton(failure: failure)
                }

                statusActionButton
            }
            .padding(.vertical, 4)
        }

        @ViewBuilder
        private var statusIcon: some View {
            switch pluginService.state {
            case .unknown,
                 .checking,
                 .checkingClaude:
                ProgressView()
                    .controlSize(.small)
            case .installed:
                Symbols.checkmarkCircleFill.image
                    .foregroundStyle(.green)
            case .notInstalled,
                 .claudeNotInstalled:
                Symbols.exclamationmarkTriangle.image
                    .foregroundStyle(.orange)
            case .installing:
                ProgressView()
                    .controlSize(.small)
            case .installationFailed:
                Symbols.xmarkCircleFill.image
                    .foregroundStyle(.red)
            }
        }

        private var statusText: String {
            switch pluginService.state {
            case .unknown,
                 .checking:
                "Checking..."
            case .checkingClaude:
                "Checking for Claude Code..."
            case .claudeNotInstalled:
                "Claude Code Not Installed"
            case .installed:
                "Plugin Installed"
            case .notInstalled:
                "Plugin Not Installed"
            case .installing:
                "Installing..."
            case .installationFailed:
                "Installation Failed"
            }
        }

        @ViewBuilder
        private var statusActionButton: some View {
            switch pluginService.state {
            case .installed:
                Button("Check for Updates") {
                    Task {
                        await pluginService.checkInstallation()
                    }
                }
            case .notInstalled,
                 .installationFailed:
                Button("Install Plugin") {
                    Task {
                        await pluginService.installPlugin()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(pluginService.state == .installing)
            case .unknown,
                 .checking,
                 .checkingClaude,
                 .claudeNotInstalled,
                 .installing:
                EmptyView()
            }
        }

        // MARK: - Claude Install Content

        private var claudeInstallContent: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Run this command in Terminal to install Claude Code:")
                    .foregroundStyle(.secondary)

                HStack(alignment: .top) {
                    Text(ClaudeBinaryLocator.installCommand)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer()

                    Button {
                        copyClaudeCommand()
                    } label: {
                        Label(
                            claudeCopied ? "Copied!" : "Copy",
                            symbol: .docOnClipboard
                        )
                    }
                    .buttonStyle(.bordered)
                }
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(.rect(cornerRadius: 6))

                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for Claude Code to be installed\u{2026}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        // MARK: - Installation Content

        private var installationContent: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("The plugin is required for Gallager to receive events from Claude Code sessions.")
                    .foregroundStyle(.secondary)

                Button {
                    Task {
                        await pluginService.installPlugin()
                    }
                } label: {
                    Label("Install Automatically", symbol: .arrowDown)
                }
                .buttonStyle(.borderedProminent)
                .disabled(pluginService.state == .installing)
            }
        }

        // MARK: - Manual Instructions

        private var manualInstructionsContent: some View {
            DisclosureGroup("Show Installation Commands") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(pluginService.manualInstructions)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(.rect(cornerRadius: 4))

                    Button {
                        copyToClipboard(pluginService.manualInstructions)
                    } label: {
                        Label(showCopiedFeedback ? "Copied!" : "Copy Commands", symbol: .docOnClipboard)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }

        // MARK: - Helpers

        private func copyToClipboard(_ text: String) {
            @Dependency(ClipboardClient.self) var clipboard
            clipboard.setString(text)

            showCopiedFeedback = true
            commandCopiedResetTrigger = UUID()
        }

        private func copyClaudeCommand() {
            @Dependency(ClipboardClient.self) var clipboard
            clipboard.setString(ClaudeBinaryLocator.installCommand)

            claudeCopied = true
            claudeCopiedResetTrigger = UUID()
        }
    }
#endif
