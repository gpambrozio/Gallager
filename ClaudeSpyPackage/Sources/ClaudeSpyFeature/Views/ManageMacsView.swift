#if os(iOS)
    import ClaudeSpyCommon
    import ClaudeSpyEncryption
    import SwiftUI

    /// View for managing paired Mac servers.
    ///
    /// Displays a list of paired Macs with connection status and allows
    /// adding new Macs or removing existing pairings.
    struct ManageMacsView: View {
        @Environment(IOSSettings.self) private var settings
        @Environment(ConnectionManager.self) private var connectionManager

        @State private var showPairingSheet = false
        @State private var hostToDelete: PairedHost?
        @State private var showDeleteConfirmation = false
        @State private var hostToEdit: PairedHost?

        var body: some View {
            List {
                // Paired Macs section
                Section {
                    if settings.pairedHosts.isEmpty {
                        Text("No Macs paired")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(settings.pairedHosts) { host in
                            MacRowView(
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
                    Text("Paired Macs")
                } footer: {
                    Text("Tap to edit name. Swipe left to remove.")
                }

                // Add Mac section
                Section {
                    Button {
                        showPairingSheet = true
                    } label: {
                        Label("Add Mac", symbol: .plus)
                    }
                }
            }
            .navigationTitle("Manage Macs")
            .sheet(isPresented: $showPairingSheet) {
                AddMacSheet()
            }
            .sheet(item: $hostToEdit) { host in
                EditMacSheet(host: host)
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
                Text("This will remove the pairing with \(host.displayName). You can pair again using a new code from the Mac app.")
            }
        }

        private func removeHost(_ host: PairedHost) async {
            // Disconnect from this Mac
            await connectionManager.disconnect(from: host.id)

            // Delete encryption session key for this Mac
            let keyManager = KeyManager(accessGroup: sharedKeychainAccessGroup)
            try? await keyManager.deleteSessionKey(for: host.id)

            // Remove from settings
            settings.removePairing(id: host.id)

            hostToDelete = nil
        }
    }

    // MARK: - Mac Row View

    /// Row view displaying a paired Mac with connection status
    struct MacRowView: View {
        let host: PairedHost
        let connection: ViewerConnection?
        var showUsername = false

        var body: some View {
            HStack(spacing: 12) {
                // Mac icon with connection indicator
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
                return "Waiting for Mac..."
            } else {
                return connection.state.statusText
            }
        }
    }

    // MARK: - Add Mac Sheet

    /// Sheet for adding a new Mac pairing
    struct AddMacSheet: View {
        @Environment(\.dismiss) private var dismiss
        @Environment(IOSSettings.self) private var settings
        @Environment(ConnectionManager.self) private var connectionManager

        var body: some View {
            NavigationStack {
                if let e2ee = connectionManager.pairingService {
                    PairingView { pairedHost in
                        // Add the new pairing
                        settings.addPairing(pairedHost)

                        // Connect to the new Mac
                        Task {
                            await connectionManager.connect(to: pairedHost, settings: settings)
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

    // MARK: - Edit Mac Sheet

    /// Sheet for editing a Mac's custom name
    struct EditMacSheet: View {
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
                        Text("Leave empty to use the default Mac name.")
                    }

                    Section {
                        LabeledContent("Mac Name", value: host.hostName)
                        LabeledContent("Username", value: host.username)
                        LabeledContent("Paired", value: DateFormatters.relativeTime(for: host.pairedAt))
                    } header: {
                        Text("Mac Info")
                    }
                }
                .navigationTitle("Edit Mac")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            saveMac()
                            dismiss()
                        }
                    }
                }
                .onAppear {
                    customName = host.customName ?? ""
                }
            }
        }

        private func saveMac() {
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
