import AppKit
import ClaudeSpyCommon
import ClaudeSpyEncryption
import SwiftUI

/// Settings view for configuring remote access via iOS
public struct RemoteAccessSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PairingManager.self) private var pairingManager
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.e2eeService) private var e2eeService: E2EEService?

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
                pairedDevicesContent
            } header: {
                Text("Paired Devices")
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
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 300)
        .navigationTitle("Remote Access")
    }

    // MARK: - Connection Status Row

    @ViewBuilder
    private var connectionStatusRow: some View {
        let connectionManager = coordinator.deviceConnectionManager
        let combinedState = connectionManager?.combinedState ?? .disconnected

        HStack(spacing: 12) {
            connectionStatusIcon(for: combinedState)
                .font(.title2)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusText(for: combinedState))
                    .font(.headline)

                if let connectedCount = connectionManager?.activeConnections.filter({ $0.isIOSConnected }).count,
                   connectedCount > 0 {
                    Text("\(connectedCount) device\(connectedCount == 1 ? "" : "s") connected")
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
    private func connectionStatusIcon(for state: DeviceConnection.ConnectionState) -> some View {
        switch state {
        case .disconnected:
            Symbols.wifiSlash.image
                .foregroundStyle(.secondary)
        case .connecting,
             .reconnecting,
             .extendedBackoff:
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

    private func statusText(for state: DeviceConnection.ConnectionState) -> String {
        state.statusText
    }

    @ViewBuilder
    private var connectionActionButton: some View {
        let connectionManager = coordinator.deviceConnectionManager
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
    private var pairedDevicesContent: some View {
        switch pairingManager.state {
        case .idle:
            if pairingManager.hasPairedDevices {
                pairedDevicesListView
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
    private var pairedDevicesListView: some View {
        ForEach(pairingManager.pairedDevices) { device in
            DeviceRow(
                device: device,
                connection: coordinator.deviceConnectionManager?.connection(for: device.id),
                onUnpair: {
                    Task {
                        await pairingManager.unpair(deviceId: device.id)
                        await coordinator.deviceConnectionManager?.disconnect(from: device.id)
                    }
                }
            )
        }

        Button {
            Task {
                await pairingManager.generatePairingCode()
            }
        } label: {
            Label("Add Device", symbol: .plus)
        }
        .buttonStyle(.borderless)
        .padding(.top, 4)
    }

    @ViewBuilder
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
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
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

    @ViewBuilder
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

    // MARK: - Helpers

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

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

// MARK: - Device Row

private struct DeviceRow: View {
    let device: PairedDevice
    let connection: DeviceConnection?
    let onUnpair: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            connectionIndicator
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName)
                    .font(.headline)

                Text("Paired \(device.pairedAt.formatted(date: .abbreviated, time: .omitted))")
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
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var connectionIndicator: some View {
        if let connection {
            switch connection.state {
            case .connected where connection.isIOSConnected:
                Symbols.checkmarkCircleFill.image
                    .foregroundStyle(.green)
            case .connected:
                Symbols.circle.image
                    .foregroundStyle(.yellow)
            case .connecting, .reconnecting:
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
            case .connected where connection.isIOSConnected:
                Text("Connected")
            case .connected:
                Text("Waiting for iOS")
            case .connecting:
                Text("Connecting...")
            case let .reconnecting(attempt):
                Text("Reconnecting (\(attempt))")
            case .extendedBackoff:
                Text("Reconnecting...")
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
