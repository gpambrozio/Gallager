#if os(macOS)
    import AppKit
    import ClaudeSpyCommon
    import SwiftUI

    /// First-launch prompt asking if the user wants the app to start at login
    public struct LaunchAtLoginPromptView: View {
        @Environment(AppSettings.self) private var settings
        @Environment(\.dismiss) private var dismiss

        @State private var showingError = false
        @State private var errorMessage = ""

        public init() { }

        public var body: some View {
            VStack(spacing: 24) {
                // Header with app icon
                headerSection

                Divider()

                // Explanation
                explanationSection

                Spacer()

                // Action buttons
                footerSection
            }
            .padding(24)
            .frame(width: 450, height: 340)
            .alert("Error", isPresented: $showingError) {
                Button("OK") { }
            } message: {
                Text(errorMessage)
            }
        }

        // MARK: - Header

        @ViewBuilder
        private var headerSection: some View {
            VStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)

                Text("Launch at Login")
                    .font(.title)
                    .fontWeight(.semibold)
            }
        }

        // MARK: - Explanation

        @ViewBuilder
        private var explanationSection: some View {
            VStack(spacing: 16) {
                Text("Would you like Gallager to start automatically when you log in?")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text("This allows Gallager to monitor your Claude Code sessions in the background. You can change this later in Settings.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal)
        }

        // MARK: - Footer

        @ViewBuilder
        private var footerSection: some View {
            HStack(spacing: 12) {
                Button("No, Thanks") {
                    markAsAsked()
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button("Yes, Launch at Login") {
                    enableLaunchAtLogin()
                }
                .buttonStyle(.borderedProminent)
            }
        }

        // MARK: - Actions

        private func enableLaunchAtLogin() {
            do {
                try settings.setLoginItemEnabled(true)
                markAsAsked()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }
        }

        private func markAsAsked() {
            settings.hasAskedAboutLaunchAtLogin = true
        }
    }
#endif
