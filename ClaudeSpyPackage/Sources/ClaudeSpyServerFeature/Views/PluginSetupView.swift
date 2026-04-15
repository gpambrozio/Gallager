#if os(macOS)
    import AppKit
    import ClaudeSpyCommon
    import Dependencies
    import SwiftUI

    /// First-launch setup view for plugin installation
    public struct PluginSetupView: View {
        @Environment(PluginService.self) private var pluginService
        @Environment(AppSettings.self) private var settings
        @Environment(\.dismiss) private var dismiss

        @State private var showingInstructions = false
        @State private var showCopiedFeedback = false
        @State private var feedbackResetTrigger: UUID?

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
            .task {
                guard !skipAutoCheck else { return }
                await pluginService.checkInstallation()
            }
            .task(id: feedbackResetTrigger) {
                guard feedbackResetTrigger != nil else { return }
                try? await Task.sleep(for: .seconds(2))
                showCopiedFeedback = false
            }
        }

        // MARK: - Header

        @ViewBuilder
        private var headerSection: some View {
            VStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)

                Text("Welcome to Gallager")
                    .font(.title)
                    .fontWeight(.semibold)

                Text("To monitor Claude Code sessions, a plugin must be installed.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }

        // MARK: - Content

        @ViewBuilder
        private var contentSection: some View {
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
                    .cornerRadius(4)
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
                                .cornerRadius(4)
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

        @ViewBuilder
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
            .cornerRadius(8)
            .padding(.horizontal)
        }

        @ViewBuilder
        private var statusIcon: some View {
            switch pluginService.state {
            case .unknown,
                 .checking:
                ProgressView()
                    .controlSize(.regular)
            case .installed:
                Symbols.checkmarkCircleFill.image
                    .foregroundStyle(.green)
            case .notInstalled:
                Symbols.puzzlepiece.image
                    .foregroundStyle(.orange)
            case .installing:
                ProgressView()
                    .controlSize(.regular)
            case .installationFailed:
                Symbols.xmarkCircleFill.image
                    .foregroundStyle(.red)
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

        @ViewBuilder
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

        // MARK: - Helpers

        private func copyToClipboard(_ text: String) {
            @Dependency(ClipboardClient.self) var clipboard
            clipboard.setString(text)

            showCopiedFeedback = true
            feedbackResetTrigger = UUID()
        }
    }

    #Preview("Not Installed") {
        let service = PluginService()
        service.state = .notInstalled
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
