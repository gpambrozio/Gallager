#if os(iOS)
    import ClaudeSpyCommon
    import ClaudeSpyEncryption
    import Dependencies
    import SwiftUI

    /// View for entering a pairing code to connect with a host.
    struct PairingView: View {
        @Environment(IOSSettings.self) private var settings
        @Environment(\.e2eeService) private var e2eeService
        @Environment(\.scenePhase) private var scenePhase

        @Dependency(ClipboardClient.self) private var clipboard

        @State private var pairingCode = ""
        @State private var isLoading = false
        @State private var errorMessage: String?
        @State private var clipboardSuggestion: String?
        @State private var handledClipboardCode: String?
        @State private var showClipboardPasteConfirmation = false
        @FocusState private var isInputFocused: Bool

        /// Called when pairing is successful with the new PairedHost
        var onPaired: ((PairedHost) -> Void)?

        private static var downloadURL: URL {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            return URL(staticString: "https://updates.gustavo.eng.br")
                .appending(path: "Gallager-\(version).dmg")
        }

        private let codeLength = 6

        var body: some View {
            ScrollView {
                VStack(spacing: 16) {
                    Text("Pair with Host")
                        .font(.title)
                        .fontWeight(.bold)

                    compactHeaderSection

                    codeInputSection

                    if isLoading {
                        ProgressView("Pairing...")
                    }

                    if let error = errorMessage {
                        errorSection(error)
                    }

                    instructionsSection

                    downloadSection

                    Spacer()
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                checkClipboardForPairingCode()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    checkClipboardForPairingCode()
                }
            }
            .alert(
                "Pairing Code on Clipboard",
                isPresented: $showClipboardPasteConfirmation,
                presenting: clipboardSuggestion
            ) { code in
                Button("Use \(code)") {
                    applyClipboardSuggestion(code)
                }
                Button("Cancel", role: .cancel) {
                    handledClipboardCode = code
                    clipboardSuggestion = nil
                }
            } message: { _ in
                Text("Found a pairing code in your clipboard. Use it to pair?")
            }
        }

        private var compactHeaderSection: some View {
            Text("Enter the 6-character pairing code shown in the Gallager host app")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }

        // MARK: - Sections

        private var codeInputSection: some View {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(0..<codeLength, id: \.self) { index in
                        codeDigitView(at: index)
                    }
                }

                // Hidden text field for input
                TextField("", text: $pairingCode)
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($isInputFocused)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .onChange(of: pairingCode) { _, newValue in
                        // Filter to letters only and limit length
                        let filtered = newValue
                            .uppercased()
                            .filter { $0.isLetter }
                            .prefix(codeLength)
                        pairingCode = String(filtered)

                        // Clear error when typing
                        if errorMessage != nil {
                            errorMessage = nil
                        }

                        // Auto-pair when code is complete
                        if pairingCode.count == codeLength, !isLoading {
                            Task {
                                await performPairing()
                            }
                        }
                    }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                isInputFocused = true
            }
            .onAppear {
                // Auto-focus on appear
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    isInputFocused = true
                }
            }
        }

        private func codeDigitView(at index: Int) -> some View {
            let character = pairingCode.count > index
                ? String(pairingCode[pairingCode.index(pairingCode.startIndex, offsetBy: index)])
                : ""

            return Text(character)
                .font(.system(size: 32, weight: .bold, design: .monospaced))
                .frame(width: 44, height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.15))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            pairingCode.count == index ? Color.blue : Color.clear,
                            lineWidth: 2
                        )
                )
        }

        private func errorSection(_ error: String) -> some View {
            HStack {
                Symbols.exclamationmarkTriangle.image
                    .foregroundStyle(.red)
                Text(error)
                    .foregroundStyle(.red)
            }
            .font(.subheadline)
        }

        private var instructionsSection: some View {
            VStack(spacing: 12) {
                Text("How to pair")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 8) {
                    instructionRow(number: 1, text: "Open Gallager on your mac")
                    instructionRow(number: 2, text: "Go to Settings > Remote Access")
                    instructionRow(number: 3, text: "Click \"Generate Pairing Code\"")
                    instructionRow(number: 4, text: "Enter the code above")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.1))
            )
        }

        private var downloadSection: some View {
            VStack(spacing: 12) {
                Text("Need the Mac app?")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 8) {
                    instructionRow(number: 1, text: "Send yourself the download link below")
                    instructionRow(number: 2, text: "Open the DMG and drag to Applications")
                    instructionRow(number: 3, text: "Launch Gallager and complete setup")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                ShareLink(item: Self.downloadURL) {
                    Label("Send Download Link", symbol: .squareAndArrowUp)
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.1))
            )
        }

        private func instructionRow(number: Int, text: String) -> some View {
            HStack(alignment: .top, spacing: 12) {
                Text("\(number)")
                    .font(.caption)
                    .fontWeight(.bold)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.blue.opacity(0.2)))

                Text(text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        // MARK: - Clipboard Detection

        /// Reads the system clipboard and, if it contains a valid pairing code,
        /// surfaces the paste-confirmation dialog.
        private func checkClipboardForPairingCode() {
            // Don't override anything the user has already typed or a pairing in flight.
            guard pairingCode.isEmpty, !isLoading else { return }

            let detected = PairingCodeValidator.pairingCode(from: clipboard.getString())

            guard let detected else {
                clipboardSuggestion = nil
                showClipboardPasteConfirmation = false
                return
            }

            // If we already prompted (and the user dismissed or applied) this
            // exact code, don't keep nagging them.
            guard detected != handledClipboardCode else { return }

            clipboardSuggestion = detected
            showClipboardPasteConfirmation = true
        }

        private func applyClipboardSuggestion(_ code: String) {
            clipboardSuggestion = nil
            // Avoid re-prompting for the same code if pairing fails and the
            // user comes back to this view.
            handledClipboardCode = code
            // Drop focus so the keyboard doesn't pop up over the in-flight
            // pairing progress.
            isInputFocused = false
            // Setting `pairingCode` triggers the existing onChange handler, which
            // filters input and auto-submits when the code is complete.
            pairingCode = code
        }

        // MARK: - Actions

        private func performPairing() async {
            guard pairingCode.count == codeLength else { return }

            isLoading = true
            errorMessage = nil

            do {
                let response = try await completePairing(code: pairingCode)

                switch response {
                case let .paired(info):
                    // Create the PairedHost struct
                    let pairedHost = PairedHost(
                        id: info.pairId,
                        hostName: info.partnerDeviceName,
                        username: info.partnerUsername,
                        partnerPublicKey: info.partnerPublicKey,
                        partnerPublicKeyId: info.partnerPublicKeyId,
                        pairedAt: Date()
                    )

                    onPaired?(pairedHost)
                case .registered:
                    // Unexpected - completion should return paired status
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

            isLoading = false
        }

        private func completePairing(code: String) async throws -> PairingResponse {
            let serverURL = settings.externalServerURL.httpURL

            guard let url = URL(string: "\(serverURL)/api/pairing/complete") else {
                throw PairingError.invalidURL
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            guard let e2eeService else {
                throw PairingError.encryptionNotAvailable
            }

            let completion = PairingCompletion(
                pairingCode: code,
                deviceId: settings.deviceId,
                deviceName: settings.deviceName,
                publicKey: e2eeService.publicKey.base64EncodedString(),
                publicKeyId: e2eeService.keyId
            )

            let encoder = JSONEncoder()
            request.httpBody = try encoder.encode(completion)

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw PairingError.invalidResponse
            }

            guard httpResponse.statusCode == 200 else {
                throw PairingError.serverError(statusCode: httpResponse.statusCode)
            }

            let decoder = JSONDecoder()
            return try decoder.decode(PairingResponse.self, from: data)
        }
    }

    // MARK: - Errors

    enum PairingError: LocalizedError {
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

    #Preview {
        NavigationStack {
            PairingView()
        }
        .environment(IOSSettings())
    }
#endif
