import AppKit
import ClaudeSpyCommon
import ClaudeSpyEncryption
import ClaudeSpyNetworking
import Dependencies
import SwiftUI

/// Settings view for managing paired hosts (other hosts this host can view)
public struct RemoteHostsSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.e2eeService) private var e2eeService: E2EEService?

    /// This Mac's advertised device name (overridable in E2E for deterministic screenshots).
    @Dependency(DeviceNameClient.self) private var deviceNameClient

    @State private var showAddHostSheet = false
    @State private var hostToDelete: PairedHost?
    @State private var showDeleteConfirmation = false
    @State private var hostToEdit: PairedHost?

    public init() { }

    public var body: some View {
        Form {
            // Connection Status Section
            Section {
                connectionStatusRow
            } header: {
                Text("Connection Status")
            }

            // Paired Hosts Section
            Section {
                pairedHostsContent
            } header: {
                Text("Paired Hosts")
            } footer: {
                Text("Hosts you can connect to for viewing their Claude sessions remotely.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Server Configuration
            Section {
                @Bindable var settings = settings
                TextField("Server URL", text: $settings.externalServerURL)
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text("Server")
            } footer: {
                Text("The relay server URL (same as for iOS pairing)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 300)
        .navigationTitle("Remote Hosts")
        .sheet(isPresented: $showAddHostSheet) {
            AddHostSheet()
        }
        .sheet(item: $hostToEdit) { host in
            EditHostSheet(host: host)
        }
        .confirmationDialog(
            "Remove Pairing",
            isPresented: $showDeleteConfirmation,
            presenting: hostToDelete
        ) { host in
            Button("Remove \(host.displayName)", role: .destructive) {
                Task {
                    await removeHost(host)
                }
            }
            Button("Cancel", role: .cancel) {
                hostToDelete = nil
            }
        } message: { host in
            Text("This will remove the pairing with \(host.displayName). You can pair again using a new code from that host.")
        }
    }

    // MARK: - Connection Status Row

    @ViewBuilder
    private var connectionStatusRow: some View {
        let hostManager = coordinator.viewerConnectionManager
        let anyConnected = hostManager?.anyHostConnected ?? false
        let isConnecting = hostManager?.isConnecting ?? false

        HStack(spacing: 12) {
            if anyConnected {
                Symbols.wifi.image
                    .font(.title2)
                    .foregroundStyle(.green)
            } else if isConnecting {
                ProgressView()
                    .controlSize(.small)
            } else {
                Symbols.wifiSlash.image
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(anyConnected ? "Connected" : isConnecting ? "Connecting..." : "Disconnected")
                    .font(.headline)

                if
                    let connectedCount = hostManager?.activeConnections.filter({ $0.isHostConnected }).count,
                    connectedCount > 0 {
                    Text("\(connectedCount) host\(connectedCount == 1 ? "" : "s") online")
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
    private var connectionActionButton: some View {
        let hostManager = coordinator.viewerConnectionManager
        let anyConnected = hostManager?.anyHostConnected ?? false
        let isConnecting = hostManager?.isConnecting ?? false

        if anyConnected {
            Button("Disconnect") {
                Task {
                    await hostManager?.disconnectAll()
                }
            }
        } else if isConnecting {
            EmptyView()
        } else if settings.hasRemoteHosts {
            Button("Connect") {
                Task {
                    guard
                        let serverURL = URL(string: settings.externalServerURL),
                        let hostManager = coordinator.viewerConnectionManager
                    else { return }

                    await hostManager.connectAll(
                        pairedHosts: settings.pairedHosts,
                        serverURL: serverURL,
                        deviceId: settings.deviceId,
                        deviceName: deviceNameClient.current()
                    )
                }
            }
        }
    }

    // MARK: - Paired Hosts Content

    @ViewBuilder
    private var pairedHostsContent: some View {
        if settings.pairedHosts.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("No hosts paired")
                    .foregroundStyle(.secondary)

                Text("Get a pairing code from another host running Gallager to connect.")
                    .foregroundStyle(.secondary)
                    .font(.caption)

                Button {
                    showAddHostSheet = true
                } label: {
                    Label("Add Host", symbol: .plus)
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            ForEach(settings.pairedHosts) { host in
                HostRow(
                    host: host,
                    connection: coordinator.viewerConnectionManager?.connection(for: host.id),
                    showUsername: settings.hasDuplicateHostName(for: host),
                    onEdit: {
                        hostToEdit = host
                    },
                    onDelete: {
                        hostToDelete = host
                        showDeleteConfirmation = true
                    }
                )
            }

            Button {
                showAddHostSheet = true
            } label: {
                Label("Add Host", symbol: .plus)
            }
            .buttonStyle(.borderless)
            .padding(.top, 4)
        }
    }

    // MARK: - Actions

    private func removeHost(_ host: PairedHost) async {
        // Disconnect from this host
        await coordinator.viewerConnectionManager?.disconnect(from: host.id)

        // Clear cached session data for this host
        coordinator.remoteSessionStore?.clearSessions(for: host.id)

        // Remove from settings
        settings.removeHostPairing(id: host.id)

        hostToDelete = nil
    }
}

// MARK: - Host Row

private struct HostRow: View {
    let host: PairedHost
    let connection: ViewerConnection?
    var showUsername = false
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            connectionIndicator
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName(showUsername: showUsername))
                    .font(.headline)

                Text("Paired \(host.pairedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            connectionStatusText
                .font(.caption)
                .foregroundStyle(.secondary)

            Menu {
                Button("Edit Name", action: onEdit)
                Divider()
                Button("Unpair", role: .destructive, action: onDelete)
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
            case .connected where connection.isHostConnected:
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
            case .connected where connection.isHostConnected:
                Text("Connected")
                    .accessibilityLabel("Host connected")
            case .connected:
                Text("Waiting for host")
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

// MARK: - Add Host Sheet

private struct AddHostSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.e2eeService) private var e2eeService: E2EEService?

    /// This Mac's advertised device name (overridable in E2E for deterministic screenshots).
    @Dependency(DeviceNameClient.self) private var deviceNameClient

    @State private var pairingCode = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Text("Add Host")
                .font(.headline)

            Text("Enter the 6-letter pairing code from the host you want to connect to.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField("Pairing Code", text: $pairingCode)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .multilineTextAlignment(.center)
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .onChange(of: pairingCode) { _, newValue in
                    let filtered = String(
                        newValue.uppercased().filter { $0.isLetter }.prefix(6)
                    )
                    if filtered != newValue {
                        pairingCode = filtered
                    }
                    if errorMessage != nil {
                        errorMessage = nil
                    }
                }

            if isSubmitting {
                ProgressView("Pairing...")
                    .controlSize(.small)
            }

            if let error = errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Connect") {
                    Task {
                        await submitPairingCode()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(pairingCode.count != 6 || isSubmitting)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 350)
    }

    private func submitPairingCode() async {
        guard pairingCode.count == 6, !isSubmitting else { return }

        isSubmitting = true
        errorMessage = nil

        do {
            let response = try await completePairing(code: pairingCode)

            switch response {
            case let .paired(info):
                let pairedHost = PairedHost(
                    id: info.pairId,
                    hostName: info.partnerDeviceName,
                    username: info.partnerUsername,
                    partnerPublicKey: info.partnerPublicKey,
                    partnerPublicKeyId: info.partnerPublicKeyId,
                    pairedAt: Date()
                )
                settings.addHostPairing(pairedHost)
                await coordinator.connectToNewlyPairedHost(pairedHost)
                dismiss()
            case .registered:
                errorMessage = "Unexpected response from server"
                pairingCode = ""
            case let .error(errorInfo):
                errorMessage = errorInfo.message
                pairingCode = ""
            }
        } catch {
            errorMessage = "Network error: \(error.localizedDescription)"
            pairingCode = ""
        }

        isSubmitting = false
    }

    private func completePairing(code: String) async throws -> PairingResponse {
        let serverURL = settings.externalServerURL.httpURL
        guard let url = URL(string: "\(serverURL)/api/pairing/complete") else {
            throw HostPairingError.invalidURL
        }

        guard let e2eeService else {
            throw HostPairingError.encryptionNotAvailable
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let completion = PairingCompletion(
            pairingCode: code,
            deviceId: settings.deviceId,
            deviceName: deviceNameClient.current(),
            publicKey: e2eeService.publicKey.base64EncodedString(),
            publicKeyId: e2eeService.keyId
        )

        request.httpBody = try JSONEncoder().encode(completion)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HostPairingError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw HostPairingError.serverError(statusCode: httpResponse.statusCode)
        }

        return try JSONDecoder().decode(PairingResponse.self, from: data)
    }
}

// MARK: - Host Pairing Errors

private enum HostPairingError: LocalizedError {
    case invalidURL
    case invalidResponse
    case serverError(statusCode: Int)
    case encryptionNotAvailable

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Invalid server URL"
        case .invalidResponse:
            "Invalid server response"
        case let .serverError(statusCode):
            "Server error (status \(statusCode))"
        case .encryptionNotAvailable:
            "Encryption service not available"
        }
    }
}

// MARK: - Edit Host Sheet

private struct EditHostSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings

    let host: PairedHost

    @State private var customName = ""

    var body: some View {
        VStack(spacing: 20) {
            Text("Edit Host")
                .font(.headline)

            Form {
                TextField("Custom Name", text: $customName, prompt: Text(host.hostName))

                LabeledContent("Host Name", value: host.hostName)
                LabeledContent("Username", value: host.username)
                LabeledContent("Paired", value: host.pairedAt.formatted(date: .abbreviated, time: .shortened))
            }
            .formStyle(.grouped)

            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    saveHost()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 350)
        .onAppear {
            customName = host.customName ?? ""
        }
    }

    private func saveHost() {
        let trimmedName = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        let updatedHost = PairedHost(
            id: host.id,
            hostName: host.hostName,
            username: host.username,
            partnerPublicKey: host.partnerPublicKey,
            partnerPublicKeyId: host.partnerPublicKeyId,
            pairedAt: host.pairedAt,
            customName: trimmedName.isEmpty ? nil : trimmedName
        )
        settings.updateHostPairing(updatedHost)
    }
}
