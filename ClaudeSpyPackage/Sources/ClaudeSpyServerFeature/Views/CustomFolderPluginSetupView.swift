#if os(macOS)
    import AppKit
    import ClaudeSpyCommon
    import Dependencies
    import SwiftUI

    /// Plugin installation prompt shown after a user adds a non-default
    /// `.claude` folder in settings.
    ///
    /// Mirrors the flow of ``PluginSetupView`` but scopes the plugin check
    /// and install commands to the given ``configDir`` (so they run with
    /// `CLAUDE_CONFIG_DIR` set). Claude Code itself is assumed to be
    /// installed — if the binary can't be found, the sheet surfaces the
    /// error without re-running the first-launch install prompt.
    public struct CustomFolderPluginSetupView: View {
        @Environment(\.dismiss) private var dismiss
        @Environment(AppSettings.self) private var settings

        @State private var pluginService: PluginService

        @State private var showingInstructions = false
        @State private var showCopiedFeedback = false
        @State private var commandCopiedResetTrigger: UUID?

        private let configDir: URL
        private let skipAutoCheck: Bool

        public init(configDir: URL) {
            self.configDir = configDir
            self.skipAutoCheck = false
            self._pluginService = State(initialValue: PluginService(configDir: configDir))
        }

        /// For previews only — starts from a caller-provided service and
        /// skips the automatic check task.
        package init(configDir: URL, service: PluginService) {
            self.configDir = configDir
            self.skipAutoCheck = true
            self._pluginService = State(initialValue: service)
        }

        public var body: some View {
            VStack(spacing: 24) {
                headerSection

                Divider()

                ScrollView {
                    contentSection
                }
                .scrollBounceBehavior(.basedOnSize)

                footerSection
            }
            .padding(24)
            .frame(width: 500, height: 500)
            .sheetFocusFix()
            .task {
                guard !skipAutoCheck else { return }
                guard let path = pluginService.findClaude() else {
                    // `findClaude` already transitioned state to
                    // `.claudeNotInstalled`, which the UI handles.
                    return
                }
                settings.claudeCommandPath = path
                await pluginService.checkInstallation()
            }
            .task(id: commandCopiedResetTrigger) {
                guard commandCopiedResetTrigger != nil else { return }
                try? await Task.sleep(for: .seconds(2))
                showCopiedFeedback = false
            }
        }

        // MARK: - Header

        private var headerSection: some View {
            VStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)

                Text("Install Plugin for Custom Folder")
                    .font(.title)
                    .fontWeight(.semibold)

                Text(configDir.lastPathComponent)
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Text("Gallager needs the plugin installed in this folder to monitor Claude Code sessions launched from it.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }

        // MARK: - Content

        private var contentSection: some View {
            VStack(spacing: 20) {
                statusView

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

        @ViewBuilder
        private var statusIcon: some View {
            switch pluginService.state {
            case .unknown,
                 .checking,
                 .checkingClaude,
                 .installing:
                ProgressView()
                    .controlSize(.regular)
            case .installed:
                Symbols.checkmarkCircleFill.image
                    .foregroundStyle(.green)
            case .notInstalled:
                Symbols.puzzlepiece.image
                    .foregroundStyle(.orange)
            case .claudeNotInstalled:
                Symbols.exclamationmarkTriangle.image
                    .foregroundStyle(.orange)
            case .installationFailed:
                Symbols.xmarkCircleFill.image
                    .foregroundStyle(.red)
            }
        }

        private var statusTitle: String {
            switch pluginService.state {
            case .unknown,
                 .checking,
                 .checkingClaude:
                "Checking plugin status..."
            case .installed:
                "Plugin Ready"
            case .notInstalled:
                "Plugin Not Installed"
            case .claudeNotInstalled:
                "Claude Code Not Found"
            case .installing:
                "Installing Plugin..."
            case .installationFailed:
                "Installation Failed"
            }
        }

        private var statusSubtitle: String {
            switch pluginService.state {
            case .unknown,
                 .checking,
                 .checkingClaude:
                "Please wait"
            case let .installed(version):
                "Version \(version) is installed for this folder"
            case .notInstalled:
                "Click Install to set up the plugin for this folder"
            case .claudeNotInstalled:
                "Install Claude Code and reopen Settings to finish setup"
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

        private var footerSection: some View {
            HStack {
                if case .installed = pluginService.state {
                    Spacer()

                    Button("Done") {
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Skip for Now") {
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
            commandCopiedResetTrigger = UUID()
        }
    }

    #Preview("Not Installed") {
        let service = PluginService(configDir: URL(fileURLWithPath: "/Users/test/work-claude"))
        service.state = .notInstalled
        return CustomFolderPluginSetupView(
            configDir: URL(fileURLWithPath: "/Users/test/work-claude"),
            service: service
        )
        .environment(AppSettings())
    }

    #Preview("Installed") {
        let service = PluginService(configDir: URL(fileURLWithPath: "/Users/test/work-claude"))
        service.state = .installed(version: "1.0.0")
        return CustomFolderPluginSetupView(
            configDir: URL(fileURLWithPath: "/Users/test/work-claude"),
            service: service
        )
        .environment(AppSettings())
    }

    #Preview("Installation Failed") {
        let service = PluginService(configDir: URL(fileURLWithPath: "/Users/test/work-claude"))
        service.state = .installationFailed("Plugin installation could not be verified")
        return CustomFolderPluginSetupView(
            configDir: URL(fileURLWithPath: "/Users/test/work-claude"),
            service: service
        )
        .environment(AppSettings())
    }
#endif
