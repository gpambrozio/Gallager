import AppKit
import ClaudeSpyCommon
import ClaudeSpyEncryption
import Dependencies
import SwiftUI

/// Settings view for configuring remote access via iOS
public struct RemoteAccessSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PairingManager.self) private var pairingManager
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(LicenseManager.self) private var licenseManager
    @Environment(\.e2eeService) private var e2eeService: E2EEService?

    @Dependency(URLOpener.self) private var urlOpener

    @State private var showCopiedFeedback = false

    public init() { }

    public var body: some View {
        @Bindable var settings = settings

        Form {
            // Connection Status Section
            Section {
                connectionStatusRow
            } header: {
                Text("Connection Status")
            }

            // Paired Devices Section
            Section {
                pairedViewersContent
            } header: {
                Text("Paired Viewers")
            }

            // Server Configuration
            Section {
                TextField("Server URL", text: $settings.externalServerURL)
                    .textFieldStyle(.roundedBorder)

                Toggle("Auto-connect on launch", isOn: $settings.autoConnectToServer)
            } header: {
                Text("Server")
            } footer: {
                Text("The relay server URL (WSS for secure connection)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // License
            Section {
                licenseSection
            } header: {
                Text("License")
            } footer: {
                Text("The hosted relay requires a subscription after a 7-day free trial. Self-hosted relays never need one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 300)
        .navigationTitle("Remote Access")
        .task {
            await licenseManager.loadStoredKey()
            await licenseManager.refreshStatus()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .init("com.claudespy.e2e.unpairViewer")
            )
        ) { _ in
            guard let viewer = pairingManager.pairedViewers.first else { return }
            Task {
                await pairingManager.unpair(deviceId: viewer.id)
                await coordinator.connectedViewerManager?.disconnect(from: viewer.id)
            }
        }
    }

    // MARK: - Connection Status Row

    @ViewBuilder
    private var connectionStatusRow: some View {
        let connectionManager = coordinator.connectedViewerManager
        let combinedState = connectionManager?.combinedState ?? .disconnected

        HStack(spacing: 12) {
            connectionStatusIcon(for: combinedState)
                .font(.title2)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusText(for: combinedState))
                    .font(.headline)

                if
                    let connectedCount = connectionManager?.activeConnections.filter({ $0.isViewerConnected }).count,
                    connectedCount > 0 {
                    Text("\(connectedCount) viewer\(connectedCount == 1 ? "" : "s") connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            connectionActionButton
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func connectionStatusIcon(for state: ConnectedViewer.ConnectionState) -> some View {
        switch state {
        case .disconnected:
            Symbols.wifiSlash.image
                .foregroundStyle(.secondary)
        case .connecting,
             .reconnecting:
            ProgressView()
                .controlSize(.small)
        case .connected:
            Symbols.wifi.image
                .foregroundStyle(.green)
        case .error:
            Symbols.exclamationmarkTriangle.image
                .foregroundStyle(.red)
        }
    }

    private func statusText(for state: ConnectedViewer.ConnectionState) -> String {
        state.statusText
    }

    @ViewBuilder
    private var connectionActionButton: some View {
        let connectionManager = coordinator.connectedViewerManager
        let combinedState = connectionManager?.combinedState ?? .disconnected

        if combinedState.isConnected {
            Button("Disconnect") {
                Task {
                    await connectionManager?.disconnectAll()
                }
            }
        } else if case .connecting = combinedState {
            // No button while connecting
            EmptyView()
        } else if case .reconnecting = combinedState {
            Button("Cancel") {
                Task {
                    await connectionManager?.disconnectAll()
                }
            }
        } else if settings.isPaired {
            Button("Connect") {
                Task {
                    await connectionManager?.connectAll()
                }
            }
        }
    }

    // MARK: - Paired Devices Content

    @ViewBuilder
    private var pairedViewersContent: some View {
        switch pairingManager.state {
        case .idle:
            if pairingManager.hasPairedViewers {
                pairedViewersListView
            } else {
                unpairedView
            }

        case .generatingCode:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Generating pairing code...")
            }

        case let .waitingForPairing(code, expiresAt):
            pairingCodeView(code: code, expiresAt: expiresAt)

        case let .error(message):
            errorView(message: message)
        }
    }

    @ViewBuilder
    private var pairedViewersListView: some View {
        ForEach(pairingManager.pairedViewers) { viewer in
            ViewerRow(
                viewer: viewer,
                connection: coordinator.connectedViewerManager?.connection(for: viewer.id),
                onUnpair: {
                    Task {
                        await pairingManager.unpair(deviceId: viewer.id)
                        await coordinator.connectedViewerManager?.disconnect(from: viewer.id)
                    }
                }
            )
        }

        Button {
            Task {
                await pairingManager.generatePairingCode()
            }
        } label: {
            Label("Add Viewer", symbol: .plus)
        }
        .buttonStyle(.borderless)
        .padding(.top, 4)
    }

    private var unpairedView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pair your iPhone to monitor Claude sessions remotely.")
                .foregroundStyle(.secondary)

            Button {
                Task {
                    await pairingManager.generatePairingCode()
                }
            } label: {
                Label("Generate Pairing Code", symbol: .linkCircle)
            }
            .help("Generate Pairing Code")
            .buttonStyle(.borderedProminent)
        }
    }

    private func pairingCodeView(code: String, expiresAt: Date) -> some View {
        VStack(alignment: .center, spacing: 16) {
            Text("Enter this code on your iPhone:")
                .foregroundStyle(.secondary)

            // Large pairing code display
            HStack(spacing: 8) {
                ForEach(Array(code.enumerated()), id: \.offset) { _, char in
                    Text(String(char))
                        .font(.system(size: 32, weight: .bold, design: .monospaced))
                        .frame(width: 40, height: 50)
                        .background(Color.accentColor.opacity(0.1))
                        .cornerRadius(8)
                }
            }

            // Copy button
            Button {
                copyToClipboard(code)
            } label: {
                Label(showCopiedFeedback ? "Copied!" : "Copy Code", symbol: .docOnClipboard)
            }
            .help("Copy Code")
            .buttonStyle(.bordered)

            // Expiry countdown
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let remaining = expiresAt.timeIntervalSinceNow
                if remaining > 0 {
                    Text("Expires in \(formatTimeRemaining(remaining))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Code expired")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Button("Cancel") {
                pairingManager.cancelPairing()
            }
            .buttonStyle(.borderless)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func errorView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Symbols.exclamationmarkTriangle.image
                    .foregroundStyle(.red)
                Text(message)
                    .foregroundStyle(.red)
            }

            Button("Try Again") {
                Task {
                    await pairingManager.generatePairingCode()
                }
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - License Section

    @ViewBuilder
    private var licenseSection: some View {
        @Bindable var licenseManager = licenseManager

        switch licenseManager.status?.state {
        case .notRequired:
            Label("Not required on this relay", symbol: .checkmarkCircleFill)
                .foregroundStyle(.secondary)
        case .active:
            LabeledContent("Status") {
                Text("Active")
                    .foregroundStyle(.green)
            }
            if
                let limit = licenseManager.status?.activationLimit,
                let usage = licenseManager.status?.activationUsage {
                LabeledContent("Activations", value: "\(usage) of \(limit) Macs")
            }
            Button("Manage Subscription") {
                urlOpener.openInDefaultBrowser(LicensingLinks.billingPortal)
            }
            .buttonStyle(.borderless)
            Button("Deactivate This Mac", role: .destructive) {
                Task { await licenseManager.deactivate() }
            }
            .buttonStyle(.borderless)
        default:
            if let daysLeft = licenseManager.trialDaysLeft {
                LabeledContent("Status") {
                    Text("Trial — \(daysLeft) day\(daysLeft == 1 ? "" : "s") left")
                        .foregroundStyle(daysLeft <= 2 ? .orange : .secondary)
                }
            } else if licenseManager.status?.state == .expired {
                Label("Subscription required", symbol: .exclamationmarkTriangle)
                    .foregroundStyle(.orange)
            }
            TextField("License Key", text: $licenseManager.licenseKeyField)
                .textFieldStyle(.roundedBorder)
                // Unique AX label so E2E can focus the field itself — a bare
                // "License Key" query matches the row's static label first.
                .accessibilityLabel("License key field")
            HStack {
                Button("Activate") {
                    Task { await licenseManager.activate() }
                }
                .disabled(licenseManager.actionState == .working)
                Button("Buy a License…") {
                    urlOpener.openInDefaultBrowser(LicensingLinks.checkout)
                }
            }
            if case let .error(message) = licenseManager.actionState {
                Label(message, symbol: .exclamationmarkTriangle)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Helpers

    private func copyToClipboard(_ text: String) {
        @Dependency(ClipboardClient.self) var clipboard
        clipboard.setString(text)

        showCopiedFeedback = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            showCopiedFeedback = false
        }
    }

    private func formatTimeRemaining(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Viewer Row

private struct ViewerRow: View {
    let viewer: PairedViewer
    let connection: ConnectedViewer?
    let onUnpair: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            connectionIndicator
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(viewer.displayName)
                    .font(.headline)

                Text("Paired \(viewer.pairedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            connectionStatusText
                .font(.caption)
                .foregroundStyle(.secondary)

            Menu {
                Button("Unpair", role: .destructive, action: onUnpair)
            } label: {
                Symbols.ellipsisCircle.image
            }
            .help("Manage Viewer")
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var connectionIndicator: some View {
        if let connection {
            switch connection.state {
            case .connected where connection.isViewerConnected:
                Symbols.checkmarkCircleFill.image
                    .foregroundStyle(.green)
            case .connected:
                Symbols.circle.image
                    .foregroundStyle(.yellow)
            case .connecting,
                 .reconnecting:
                ProgressView()
                    .controlSize(.small)
            default:
                Symbols.circle.image
                    .foregroundStyle(.secondary)
            }
        } else {
            Symbols.circle.image
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var connectionStatusText: some View {
        if let connection {
            switch connection.state {
            case .connected where connection.isViewerConnected:
                Text("Connected")
                    .accessibilityLabel("Viewer connected")
            case .connected:
                Text("Waiting for viewer")
            case .connecting:
                Text("Connecting...")
            case let .reconnecting(attempt):
                Text("Reconnecting (\(attempt))")
            case let .error(message):
                Text(message)
                    .foregroundStyle(.red)
            case .disconnected:
                Text("Disconnected")
            }
        } else {
            Text("Not connected")
        }
    }
}
