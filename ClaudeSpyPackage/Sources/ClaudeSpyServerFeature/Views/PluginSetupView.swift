#if os(macOS)
    import AppKit
    import ClaudeCodePluginCore
    import ClaudeSpyCommon
    import Dependencies
    import SwiftUI

    /// First-launch setup view for plugin installation
    public struct PluginSetupView: View {
        @Environment(PluginService.self) private var pluginService
        @Environment(AppSettings.self) private var settings
        @Environment(\.dismiss) private var dismiss

        @Dependency(ClaudeBinaryLocator.self) private var claudeLocator

        @State private var showingInstructions = false
        @State private var showCopiedFeedback = false
        @State private var commandCopiedResetTrigger: UUID?
        @State private var claudeCopied = false
        @State private var claudeCopiedResetTrigger: UUID?

        private let skipAutoCheck: Bool

        public init() {
            self.skipAutoCheck = false
        }

        /// For previews only — skips the automatic `checkInstallation` task.
        package init(skipAutoCheck: Bool) {
            self.skipAutoCheck = skipAutoCheck
        }

        public var body: some View {
            VStack(spacing: 24) {
                // Header
                headerSection

                Divider()

                // Content based on state
                ScrollView {
                    contentSection
                }
                .scrollBounceBehavior(.basedOnSize)

                // Footer actions
                footerSection
            }
            .padding(24)
            .frame(width: 500, height: 500)
            .sheetFocusFix()
            .task {
                guard !skipAutoCheck else { return }
                await runSetupFlow()
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

        // MARK: - Header

        private var headerSection: some View {
            VStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)

                Text(headerTitle)
                    .font(.title)
                    .fontWeight(.semibold)

                Text(headerSubtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }

        private var headerTitle: String {
            switch pluginService.state {
            case .checkingClaude,
                 .claudeNotInstalled:
                "Claude Code Required"
            default:
                "Welcome to Gallager"
            }
        }

        private var headerSubtitle: String {
            switch pluginService.state {
            case .checkingClaude,
                 .claudeNotInstalled:
                "Gallager monitors Claude Code sessions.\nInstall Claude Code to get started."
            default:
                "To monitor Claude Code sessions, a plugin must be installed."
            }
        }

        // MARK: - Content

        @ViewBuilder
        private var contentSection: some View {
            switch pluginService.state {
            case .checkingClaude,
                 .claudeNotInstalled:
                claudeContent
            default:
                pluginContent
            }
        }

        // MARK: - Claude Content

        private var claudeContent: some View {
            VStack(spacing: 20) {
                claudeStatusView

                if case .claudeNotInstalled = pluginService.state {
                    claudeCommandCard
                }
            }
        }

        private var claudeStatusView: some View {
            HStack(spacing: 16) {
                if case .checkingClaude = pluginService.state {
                    ProgressView()
                        .controlSize(.regular)
                } else {
                    Symbols.terminal.image
                        .foregroundStyle(.orange)
                        .font(.largeTitle)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(claudeStatusTitle)
                        .font(.headline)

                    Text(claudeStatusSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(.rect(cornerRadius: 8))
            .padding(.horizontal)
        }

        private var claudeStatusTitle: String {
            switch pluginService.state {
            case .checkingClaude:
                "Checking for Claude Code..."
            default:
                "Claude Code Not Installed"
            }
        }

        private var claudeStatusSubtitle: String {
            switch pluginService.state {
            case .checkingClaude:
                "Please wait"
            default:
                "Run the command below in Terminal to install Claude Code."
            }
        }

        private var claudeCommandCard: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("Install Claude Code")
                    .font(.headline)

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

                Text("Paste this into Terminal to install Claude Code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for Claude Code to be installed\u{2026}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal)
        }

        // MARK: - Plugin Content

        private var pluginContent: some View {
            VStack(spacing: 20) {
                // Status indicator
                statusView

                // Installation output (if any)
                if !pluginService.installationOutput.isEmpty {
                    ScrollView {
                        Text(pluginService.installationOutput)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 100)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(.rect(cornerRadius: 4))
                }

                // Manual instructions disclosure
                DisclosureGroup(
                    isExpanded: $showingInstructions,
                    content: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(pluginService.manualInstructions)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(8)
                                .background(Color(nsColor: .textBackgroundColor))
                                .clipShape(.rect(cornerRadius: 4))
                        }
                    },
                    label: {
                        HStack {
                            Text("Manual Installation")
                            Button {
                                copyToClipboard(pluginService.manualInstructions)
                            } label: {
                                Label(showCopiedFeedback ? "Copied!" : "Copy Commands", symbol: .docOnClipboard)
                            }
                            .buttonStyle(.bordered)

                            Spacer()
                        }
                    }
                )
                .padding(.horizontal)
            }
        }

        private var statusView: some View {
            HStack(spacing: 16) {
                statusIcon
                    .font(.largeTitle)

                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle)
                        .font(.headline)

                    Text(statusSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                VStack(alignment: .trailing) {
                    if
                        case .installationFailed = pluginService.state,
                        let failure = pluginService.lastFailure {
                        PluginFailureDetailsButton(failure: failure)
                    }

                    if shouldShowInstallButton {
                        Button {
                            Task {
                                await pluginService.installPlugin()
                            }
                        } label: {
                            Label("Install", symbol: .arrowDown)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(pluginService.state == .installing)
                    }
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(.rect(cornerRadius: 8))
            .padding(.horizontal)
        }

        // NOTE: `.checkingClaude` / `.claudeNotInstalled` are intentionally
        // omitted from the switches below — `contentSection` routes those
        // states to `claudeContent`, so `statusView` never renders in them.

        @ViewBuilder
        private var statusIcon: some View {
            switch pluginService.state {
            case .unknown,
                 .checking,
                 .installing:
                ProgressView()
                    .controlSize(.regular)
            case .installed:
                Symbols.checkmarkCircleFill.image
                    .foregroundStyle(.green)
            case .notInstalled:
                Symbols.puzzlepiece.image
                    .foregroundStyle(.orange)
            case .installationFailed:
                Symbols.xmarkCircleFill.image
                    .foregroundStyle(.red)
            case .checkingClaude,
                 .claudeNotInstalled:
                EmptyView()
            }
        }

        private var statusTitle: String {
            switch pluginService.state {
            case .unknown,
                 .checking:
                "Checking plugin status..."
            case .installed:
                "Plugin Ready"
            case .notInstalled:
                "Plugin Not Installed"
            case .installing:
                "Installing Plugin..."
            case .installationFailed:
                "Installation Failed"
            case .checkingClaude,
                 .claudeNotInstalled:
                ""
            }
        }

        private var statusSubtitle: String {
            switch pluginService.state {
            case .unknown,
                 .checking:
                "Please wait"
            case let .installed(version):
                "Version \(version) is installed and ready to use"
            case .notInstalled:
                "Click Install to set up the plugin automatically"
            case .installing:
                "This may take a moment"
            case let .installationFailed(error):
                error
            case .checkingClaude,
                 .claudeNotInstalled:
                ""
            }
        }

        private var shouldShowInstallButton: Bool {
            switch pluginService.state {
            case .notInstalled,
                 .installationFailed:
                true
            default:
                false
            }
        }

        // MARK: - Footer

        private var footerSection: some View {
            HStack {
                if case .installed = pluginService.state {
                    Spacer()

                    Button("Get Started") {
                        settings.hasCompletedPluginSetup = true
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Skip for Now") {
                        settings.hasCompletedPluginSetup = true
                        dismiss()
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                }
            }
        }

        // MARK: - Setup Flow

        /// Runs the full setup flow: detect claude, then verify plugin.
        ///
        /// Polls for the `claude` binary when it's not installed — when it
        /// appears the detected path is written to settings and the plugin
        /// installation check runs.
        private func runSetupFlow() async {
            if let path = await pluginService.findClaude() {
                settings.claudeCommandPath = path
                await pluginService.checkInstallation()
                return
            }

            // Poll for claude while dialog is open
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if let path = await claudeLocator.find() {
                    settings.claudeCommandPath = path
                    await pluginService.checkInstallation()
                    return
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

    #Preview("Not Installed") {
        let service = PluginService()
        service.state = .notInstalled
        return PluginSetupView(skipAutoCheck: true)
            .environment(AppSettings())
            .environment(service)
    }

    #Preview("Claude Not Installed") {
        let service = PluginService()
        service.state = .claudeNotInstalled
        return PluginSetupView(skipAutoCheck: true)
            .environment(AppSettings())
            .environment(service)
    }

    #Preview("Checking Claude") {
        let service = PluginService()
        service.state = .checkingClaude
        return PluginSetupView(skipAutoCheck: true)
            .environment(AppSettings())
            .environment(service)
    }

    #Preview("Installed") {
        let service = PluginService()
        service.state = .installed(version: "1.0.0")
        return PluginSetupView(skipAutoCheck: true)
            .environment(AppSettings())
            .environment(service)
    }

    #Preview("Installation Failed") {
        let service = PluginService()
        service.state = .installationFailed("Plugin installation could not be verified")
        service.lastFailure = PluginInstallationFailure(
            summary: "Plugin installation could not be verified",
            failedStep: "Verify installation",
            commandLine: nil,
            exitCode: nil,
            stdout: nil,
            stderr: nil,
            installationLog: "Adding ClaudeSpy marketplace...\nMarketplace added successfully.\nInstalling gallager plugin...\nPlugin installed successfully.",
            claudePath: "/usr/local/bin/claude",
            bundledPluginPath: "/Applications/Gallager.app/Contents/Resources/plugin",
            underlyingError: "After running the install commands, the gallager plugin did not appear in ~/.claude/plugins/installed_plugins.json.",
            appVersion: "1.19 (42)",
            osVersion: "macOS 15.3.0",
            timestamp: Date()
        )
        return PluginSetupView(skipAutoCheck: true)
            .environment(AppSettings())
            .environment(service)
    }
#endif
