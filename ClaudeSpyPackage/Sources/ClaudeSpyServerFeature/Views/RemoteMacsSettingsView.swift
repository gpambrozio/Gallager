import AppKit
import ClaudeSpyCommon
import ClaudeSpyEncryption
import SwiftUI

/// Settings view for managing paired Mac hosts (other Macs this Mac can view)
public struct RemoteMacsSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.e2eeService) private var e2eeService: E2EEService?

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
                Text("Paired Mac Hosts")
            } footer: {
                Text("Mac hosts you can connect to for viewing their Claude sessions remotely.")
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
        .navigationTitle("Remote Macs")
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
            Text("This will remove the pairing with \(host.displayName). You can pair again using a new code from that Mac.")
        }
    }

    // MARK: - Connection Status Row

    @ViewBuilder
    private var connectionStatusRow: some View {
        let hostManager = coordinator.hostConnectionManager
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

                if let connectedCount = hostManager?.activeConnections.filter({ $0.isHostConnected }).count,
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
        let hostManager = coordinator.hostConnectionManager
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
                        let hostManager = coordinator.hostConnectionManager
                    else { return }

                    await hostManager.connectAll(
                        pairedHosts: settings.pairedHosts,
                        serverURL: serverURL,
                        deviceId: settings.deviceId,
                        deviceName: Host.current().localizedName ?? "Mac"
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
                Text("No Mac hosts paired")
                    .foregroundStyle(.secondary)

                Text("Get a pairing code from another Mac running ClaudeSpy to connect.")
                    .foregroundStyle(.secondary)
                    .font(.caption)

                Button {
                    showAddHostSheet = true
                } label: {
                    Label("Add Mac Host", symbol: .plus)
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            ForEach(settings.pairedHosts) { host in
                HostRow(
                    host: host,
                    connection: coordinator.hostConnectionManager?.connection(for: host.id),
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
                Label("Add Mac Host", symbol: .plus)
            }
            .buttonStyle(.borderless)
            .padding(.top, 4)
        }
    }

    // MARK: - Actions

    private func removeHost(_ host: PairedHost) async {
        // Disconnect from this host
        await coordinator.hostConnectionManager?.disconnect(from: host.id)

        // Remove from settings
        settings.removeHostPairing(id: host.id)

        hostToDelete = nil
    }
}

// MARK: - Host Row

private struct HostRow: View {
    let host: PairedHost
    let connection: HostConnection?
    var showUsername: Bool = false
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
            case .connected where connection.isHostConnected:
                Text("Connected")
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

    @State private var pairingCode = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Text("Add Mac Host")
                .font(.headline)

            Text("Enter the 6-digit pairing code from the Mac you want to connect to.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField("Pairing Code", text: $pairingCode)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .multilineTextAlignment(.center)
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .onChange(of: pairingCode) { _, newValue in
                    // Only allow digits, max 6 characters
                    let filtered = String(newValue.filter { $0.isNumber }.prefix(6))
                    if filtered != newValue {
                        pairingCode = filtered
                    }
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
                    submitPairingCode()
                }
                .buttonStyle(.borderedProminent)
                .disabled(pairingCode.count != 6 || isSubmitting)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 350)
    }

    private func submitPairingCode() {
        // TODO: Implement actual pairing flow
        // This would:
        // 1. Send the pairing code to the relay server
        // 2. Receive the host's public key and info
        // 3. Exchange our public key
        // 4. Create a PairedHost and add to settings

        errorMessage = "Pairing flow not yet implemented. This is a placeholder UI."
    }
}

// MARK: - Edit Host Sheet

private struct EditHostSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings

    let host: PairedHost

    @State private var customName: String = ""

    var body: some View {
        VStack(spacing: 20) {
            Text("Edit Mac Host")
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
