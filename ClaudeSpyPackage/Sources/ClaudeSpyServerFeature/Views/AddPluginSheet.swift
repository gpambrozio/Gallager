#if os(macOS)
    import ClaudeSpyCommon
    import SwiftUI

    // MARK: - AddPluginSheet

    /// Two-stage sheet for installing a plugin from a URL (spec §12).
    ///
    /// **Stage 1 (entry):** URL text field. On submit, calls
    /// `coordinator.installPluginFromURL(url, trustConfirmed: false)`.
    ///
    /// **Stage 2 (trust):** Shows `TrustDetails` (name, publisher, version, source
    /// URL, bundle size + SHA-256, and the verbatim security warning). Confirm calls
    /// `coordinator.installPluginFromURL(url, trustConfirmed: true)`.
    ///
    /// Follows the structural pattern of `AddHostSheet` in `RemoteHostsSettingsView`:
    /// `VStack(spacing: 20)`, `.padding(24)`, `.keyboardShortcut(.cancelAction)`/
    /// `.defaultAction`, inline `ProgressView`, inline red error `Text`.
    struct AddPluginSheet: View {
        @Environment(\.dismiss) private var dismiss
        @Environment(AppCoordinator.self) private var coordinator

        // MARK: Phase

        private enum Phase {
            case entry
            case fetching
            case trust(TrustDetails)
            case installing
            case error(String)
        }

        // MARK: State

        @State private var urlText = ""
        @State private var phase: Phase = .entry

        // MARK: Body

        var body: some View {
            VStack(spacing: 20) {
                switch phase {
                case .entry,
                     .fetching,
                     .error:
                    entryView
                case let .trust(details):
                    trustView(details: details)
                case .installing:
                    installingView
                }
            }
            .padding(24)
            .frame(width: 440)
        }

        // MARK: - Entry / fetching / error view

        @ViewBuilder
        private var entryView: some View {
            Text("Add Plugin from URL")
                .font(.headline)

            Text("Enter the HTTPS URL of a plugin manifest (plugin.json).")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField("https://example.com/plugin.json", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .onChange(of: urlText) { _, _ in
                    // Clear any prior error when the user edits the URL.
                    if case .error = phase {
                        phase = .entry
                    }
                }

            if case .fetching = phase {
                ProgressView("Fetching manifest…")
                    .controlSize(.small)
            }

            if case let .error(message) = phase {
                Text(message)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Fetch") {
                    Task {
                        await fetchManifest()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(fetchButtonDisabled)
                .keyboardShortcut(.defaultAction)
            }
        }

        private var fetchButtonDisabled: Bool {
            if case .fetching = phase { return true }
            return urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        // MARK: - Trust view

        @ViewBuilder
        private func trustView(details: TrustDetails) -> some View {
            Text("Trust Plugin")
                .font(.headline)

            // Warning banner
            Label("This plugin runs arbitrary code on your Mac.", symbol: .exclamationmarkTriangle)
                .font(.callout)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)

            // Detail grid
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    trustRow(label: "Name", value: details.displayName)
                    if let publisher = details.publisher {
                        trustRow(label: "Publisher", value: publisher)
                    }
                    trustRow(label: "Version", value: details.version)
                    trustRow(label: "Source", value: details.sourceURL.absoluteString)
                    if let sizeBytes = details.bundleSizeBytes {
                        trustRow(label: "Bundle size", value: formatBytes(sizeBytes))
                    }
                    if let sha = details.bundleSHA256 {
                        trustRow(label: "SHA-256", value: sha)
                            .font(.caption.monospaced())
                    }
                }
                .padding(4)
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Trust and Install") {
                    Task {
                        await install(details: details)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }

        private func trustRow(label: String, value: String) -> some View {
            HStack(alignment: .top, spacing: 8) {
                Text(label + ":")
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .trailing)
                Text(value)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
            .font(.callout)
        }

        // MARK: - Installing view

        @ViewBuilder
        private var installingView: some View {
            Text("Installing Plugin")
                .font(.headline)

            ProgressView("Downloading and installing…")
                .controlSize(.small)

            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }

        // MARK: - Actions

        @MainActor
        private func fetchManifest() async {
            let raw = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return }

            // Reject obviously non-HTTPS in the UI before round-tripping to the
            // coordinator (the coordinator enforces it too, but this gives faster
            // feedback with a friendlier message).
            guard raw.hasPrefix("https://"), let url = URL(string: raw) else {
                phase = .error("URL must start with https://")
                return
            }

            phase = .fetching
            let result = await coordinator.installPluginFromURL(url, trustConfirmed: false)
            switch result {
            case let .success(.needsTrust(details)):
                phase = .trust(details)
            case .success(.installed):
                // Shouldn't happen at the fetch stage, but handle gracefully.
                dismiss()
            case let .failure(error):
                phase = .error(error.uiDescription)
            }
        }

        @MainActor
        private func install(details: TrustDetails) async {
            let raw = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: raw) else {
                phase = .error("Invalid URL")
                return
            }

            phase = .installing
            let result = await coordinator.installPluginFromURL(url, trustConfirmed: true)
            switch result {
            case .success(.installed):
                dismiss()
            case let .success(.needsTrust(newDetails)):
                // Unexpected repeat of trust gate — re-show trust view.
                phase = .trust(newDetails)
            case let .failure(error):
                phase = .error(error.uiDescription)
            }
        }

        // MARK: - Helpers

        private func formatBytes(_ bytes: Int) -> String {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter.string(fromByteCount: Int64(bytes))
        }
    }

    // MARK: - InstallError UI description

    private extension InstallError {
        /// Human-readable message for display in the sheet.
        var uiDescription: String {
            switch self {
            case .notHTTPS:
                return "URL must use HTTPS"
            case .manifestTooLarge:
                return "Plugin manifest is too large (limit: 1 MiB)"
            case .invalidSchema:
                return "Invalid plugin manifest format"
            case .invalidID:
                return "Plugin manifest contains an invalid ID"
            case .bundleTooLarge:
                return "Plugin bundle exceeds the size limit"
            case .hashMismatch:
                return "Bundle integrity check failed (SHA-256 mismatch)"
            case let .zipSlip(path):
                return "Unsafe bundle path: \(path)"
            case .bundleMissing:
                return "Plugin bundle is missing from the archive"
            case .notInstalled:
                return "Plugin is not installed"
            case let .treeValidationFailed(reason):
                return "Bundle validation failed: \(reason)"
            case let .enableFailed(reason):
                return "Plugin could not be enabled: \(reason)"
            }
        }
    }
#endif
