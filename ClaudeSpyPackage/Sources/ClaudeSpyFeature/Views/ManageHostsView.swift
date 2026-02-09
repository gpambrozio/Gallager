#if os(iOS)
    import ClaudeSpyCommon
    import ClaudeSpyEncryption
    import Dependencies
    import SwiftUI

    /// View for managing paired hosts.
    ///
    /// Displays a list of paired hosts with connection status and allows
    /// adding new hosts or removing existing pairings.
    struct ManageHostsView: View {
        @Environment(IOSSettings.self) private var settings
        @Environment(ViewerConnectionManager.self) private var connectionManager

        @State private var showPairingSheet = false
        @State private var hostToDelete: PairedHost?
        @State private var showDeleteConfirmation = false
        @State private var hostToEdit: PairedHost?

        var body: some View {
            List {
                // Paired hosts section
                Section {
                    if settings.pairedHosts.isEmpty {
                        Text("No hosts paired")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(settings.pairedHosts) { host in
                            HostRowView(
                                host: host,
                                connection: connectionManager.connection(for: host.id),
                                showUsername: settings.hasDuplicateHostName(for: host)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                hostToEdit = host
                            }
                        }
                        .onDelete { indexSet in
                            if let index = indexSet.first {
                                hostToDelete = settings.pairedHosts[index]
                                showDeleteConfirmation = true
                            }
                        }
                    }
                } header: {
                    Text("Paired Hosts")
                } footer: {
                    Text("Tap to edit name. Swipe left to remove.")
                }

                // Add host section
                Section {
                    Button {
                        showPairingSheet = true
                    } label: {
                        Label("Add Host", symbol: .plus)
                    }
                }
            }
            .navigationTitle("Manage Hosts")
            .sheet(isPresented: $showPairingSheet) {
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
                Text("This will remove the pairing with \(host.displayName). You can pair again using a new code from the host app.")
            }
        }

        private func removeHost(_ host: PairedHost) async {
            // Disconnect from this host
            await connectionManager.disconnect(from: host.id)

            // Delete encryption session key for this host
            @Dependency(SecretsService.self) var secrets
            try? await secrets.deleteSessionKey(host.id)

            // Remove from settings
            settings.removePairing(id: host.id)

            hostToDelete = nil
        }
    }

    // MARK: - Host Row View

    /// Row view displaying a paired host with connection status
    struct HostRowView: View {
        let host: PairedHost
        let connection: ViewerConnection?
        var showUsername = false

        var body: some View {
            HStack(spacing: 12) {
                // Host icon with connection indicator
                ZStack(alignment: .bottomTrailing) {
                    Symbols.laptopcomputer.image
                        .font(.title2)
                        .foregroundStyle(.secondary)

                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                        .overlay(
                            Circle()
                                .stroke(Color(.systemBackground), lineWidth: 2)
                        )
                        .offset(x: 2, y: 2)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(host.displayName(showUsername: showUsername))
                        .font(.headline)

                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Edit indicator
                Symbols.chevronRight.image
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }

        private var statusColor: Color {
            guard let connection else { return .gray }

            if connection.isHostConnected {
                return .green
            } else if connection.isRelayConnected {
                return .yellow
            } else if case .reconnecting = connection.state {
                return .orange
            } else {
                return .red
            }
        }

        private var statusText: String {
            guard let connection else { return "Not connected" }

            if connection.isHostConnected {
                return "Online"
            } else if connection.isRelayConnected {
                return "Waiting for host..."
            } else {
                return connection.state.statusText
            }
        }
    }

    // MARK: - Add Host Sheet

    /// Sheet for adding a new host pairing
    struct AddHostSheet: View {
        @Environment(\.dismiss) private var dismiss
        @Environment(IOSSettings.self) private var settings
        @Environment(ViewerConnectionManager.self) private var connectionManager

        var body: some View {
            NavigationStack {
                if let e2ee = connectionManager.pairingService {
                    PairingView { pairedHost in
                        // Add the new pairing
                        settings.addPairing(pairedHost)

                        // Connect to the new host
                        Task {
                            guard let serverURL = URL(string: settings.externalServerURL) else { return }
                            await connectionManager.connect(
                                to: pairedHost,
                                serverURL: serverURL,
                                deviceId: settings.deviceId,
                                deviceName: settings.deviceName
                            )
                        }

                        dismiss()
                    }
                    .e2eeService(e2ee)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {
                                dismiss()
                            }
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "Encryption Error",
                        image: Symbols.lockTriangleBadgeExclamationmark.rawValue,
                        description: Text("Unable to initialize encryption.")
                    )
                }
            }
        }
    }

    // MARK: - Edit Host Sheet

    /// Sheet for editing a host's custom name
    struct EditHostSheet: View {
        @Environment(\.dismiss) private var dismiss
        @Environment(IOSSettings.self) private var settings

        let host: PairedHost

        @State private var customName = ""

        var body: some View {
            NavigationStack {
                Form {
                    Section {
                        TextField("Custom Name", text: $customName, prompt: Text(host.hostName))
                    } header: {
                        Text("Display Name")
                    } footer: {
                        Text("Leave empty to use the default host name.")
                    }

                    Section {
                        LabeledContent("Host Name", value: host.hostName)
                        LabeledContent("Username", value: host.username)
                        LabeledContent("Paired", value: DateFormatters.relativeTime(for: host.pairedAt))
                    } header: {
                        Text("Host Info")
                    }
                }
                .navigationTitle("Edit Host")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            saveHost()
                            dismiss()
                        }
                    }
                }
                .onAppear {
                    customName = host.customName ?? ""
                }
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
            settings.updatePairing(updatedHost)
        }
    }
#endif
