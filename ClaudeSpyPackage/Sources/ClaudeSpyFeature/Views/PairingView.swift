import ClaudeSpyCommon
import ClaudeSpyEncryption
import SwiftUI

/// View for entering a pairing code to connect with a Mac.
struct PairingView: View {
    @Environment(IOSSettings.self) private var settings
    @Environment(RelayClient.self) private var relayClient
    @Environment(\.e2eeService) private var e2eeService

    @State private var pairingCode = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @FocusState private var isInputFocused: Bool

    /// Called when pairing is successful
    var onPaired: ((String, String?) -> Void)?

    private let codeLength = 6

    var body: some View {
        #if os(iOS)
            iOSBody
        #else
            macOSBody
        #endif
    }

    #if os(iOS)
        private var iOSBody: some View {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 24) {
                        compactHeaderSection

                        codeInputSection

                        if isLoading {
                            ProgressView("Pairing...")
                        }

                        if let error = errorMessage {
                            errorSection(error)
                        }

                        instructionsSection
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .navigationTitle("Pair with Mac")
                .navigationBarTitleDisplayMode(.large)
            }
        }

        private var compactHeaderSection: some View {
            Text("Enter the 6-character pairing code shown in the ClaudeSpy Mac app")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    #endif

    #if os(macOS)
        private var macOSBody: some View {
            VStack(spacing: 24) {
                headerSection

                macOSCodeInputSection

                if let error = errorMessage {
                    errorSection(error)
                }

                pairButton

                Spacer()

                instructionsSection
            }
            .padding()
            .frame(minWidth: 400, minHeight: 500)
        }

        private var macOSCodeInputSection: some View {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(0..<codeLength, id: \.self) { index in
                        codeDigitView(at: index)
                    }
                }

                TextField("Pairing Code", text: $pairingCode)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .frame(width: 200)
                    .onChange(of: pairingCode) { _, newValue in
                        let filtered = newValue
                            .uppercased()
                            .filter { $0.isLetter }
                            .prefix(codeLength)
                        pairingCode = String(filtered)

                        if errorMessage != nil {
                            errorMessage = nil
                        }
                    }
            }
        }
    #endif

    // MARK: - Sections

    private var headerSection: some View {
        VStack(spacing: 16) {
            Symbols.linkCircleFill.image
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            Text("Connect to your Mac")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Enter the 6-character pairing code shown in the ClaudeSpy Mac app")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 32)
    }

    #if os(iOS)
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
    #endif

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

    private var pairButton: some View {
        Button {
            Task {
                await performPairing()
            }
        } label: {
            HStack {
                if isLoading {
                    ProgressView()
                    #if os(iOS)
                        .tint(.white)
                    #endif
                } else {
                    Text("Pair")
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
        }
        .buttonStyle(.borderedProminent)
        .disabled(pairingCode.count != codeLength || isLoading)
    }

    private var instructionsSection: some View {
        VStack(spacing: 12) {
            Text("How to pair")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                instructionRow(number: 1, text: "Open ClaudeSpy on your Mac")
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

    // MARK: - Actions

    private func performPairing() async {
        guard pairingCode.count == codeLength else { return }

        isLoading = true
        errorMessage = nil

        do {
            let response = try await completePairing(code: pairingCode)

            if response.success, let pairId = response.pairId {
                // Save pairing with partner's public key for E2EE
                settings.savePairing(
                    pairId: pairId,
                    macName: response.partnerDeviceName,
                    partnerPublicKey: response.partnerPublicKey,
                    partnerPublicKeyId: response.partnerPublicKeyId
                )
                onPaired?(pairId, response.partnerDeviceName)
            } else {
                errorMessage = response.error ?? "Pairing failed"
                pairingCode = ""
            }
        } catch {
            errorMessage = "Network error: \(error.localizedDescription)"
            pairingCode = ""
        }

        isLoading = false
    }

    private func completePairing(code: String) async throws -> PairingResponse {
        let serverURL = settings.externalServerURL
            .replacingOccurrences(of: "wss://", with: "https://")
            .replacingOccurrences(of: "ws://", with: "http://")

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
    PairingView()
        .environment(IOSSettings.shared)
        .environment(RelayClient())
}
