#if os(macOS)
    import AppKit
    import ClaudeSpyCommon
    import Dependencies
    import SwiftUI

    /// Button that reveals a popover with the full diagnostic report for a failed
    /// plugin installation attempt, plus a one-click copy-to-clipboard action.
    ///
    /// Used by `PluginSetupView` and `PluginSettingsView` whenever
    /// `PluginService.lastFailure` is non-nil.
    struct PluginFailureDetailsButton: View {
        let failure: PluginInstallationFailure

        @State private var showingDetails = false
        @State private var showCopiedFeedback = false
        @State private var feedbackResetTrigger: UUID?

        var body: some View {
            Button {
                showingDetails = true
            } label: {
                Label("Show Details", symbol: .infoCircle)
            }
            .buttonStyle(.bordered)
            .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
                detailsContent
            }
            .task(id: feedbackResetTrigger) {
                guard feedbackResetTrigger != nil else { return }
                try? await Task.sleep(for: .seconds(2))
                showCopiedFeedback = false
            }
        }

        @ViewBuilder
        private var detailsContent: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Symbols.xmarkCircleFill.image
                        .foregroundStyle(.red)
                        .font(.title3)
                    Text("Installation Failed")
                        .font(.headline)
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Step: \(failure.failedStep)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(failure.summary)
                        .font(.subheadline)
                        .textSelection(.enabled)
                }

                Divider()

                ScrollView {
                    Text(failure.report)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(width: 540, height: 320)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )

                HStack(spacing: 12) {
                    Button {
                        copyReport()
                    } label: {
                        Label(
                            showCopiedFeedback ? "Copied!" : "Copy to Clipboard",
                            symbol: .docOnClipboard
                        )
                    }
                    .buttonStyle(.borderedProminent)

                    Text("Share this report to help diagnose the issue.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    Spacer()
                }
            }
            .padding(16)
            .frame(width: 580)
        }

        private func copyReport() {
            @Dependency(ClipboardClient.self) var clipboard
            clipboard.setString(failure.report)
            showCopiedFeedback = true
            feedbackResetTrigger = UUID()
        }
    }

    #Preview {
        PluginFailureDetailsButton(
            failure: PluginInstallationFailure(
                summary: "Failed to install plugin (exit code 1)",
                failedStep: "install plugin",
                commandLine: "/usr/local/bin/claude plugin install gallager --scope user",
                exitCode: 1,
                stdout: "Resolving plugin gallager...",
                stderr: "Error: plugin verification failed",
                installationLog: "Adding ClaudeSpy marketplace...\nMarketplace added successfully.\nInstalling gallager plugin...\nError: plugin verification failed",
                claudePath: "/usr/local/bin/claude",
                bundledPluginPath: "/Applications/Gallager.app/Contents/Resources/plugin",
                underlyingError: nil,
                appVersion: "1.19 (42)",
                osVersion: "macOS 15.3.0",
                timestamp: Date()
            )
        )
        .padding()
    }
#endif
