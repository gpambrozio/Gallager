#if os(macOS)
    import ClaudeSpyNetworking
    import Dependencies
    import DependenciesMacros
    import Foundation

    /// Vapor's default error body: {"error": true, "reason": "…"}.
    private struct RelayErrorResponse: Codable {
        let reason: String
    }

    public enum LicensingClientError: LocalizedError, Equatable {
        case invalidURL
        case invalidResponse
        case server(String)

        public var errorDescription: String? {
            switch self {
            case .invalidURL: "Invalid server URL"
            case .invalidResponse: "Invalid server response"
            case let .server(message): message
            }
        }
    }

    /// HTTP client for the relay's /api/license endpoints.
    @DependencyClient
    public struct LicensingClient: Sendable {
        public var activate: @Sendable (
            _ serverURL: String, _ licenseKey: String, _ deviceId: String, _ deviceName: String
        ) async throws -> LicenseStatus
        public var deactivate: @Sendable (_ serverURL: String, _ deviceId: String) async throws -> Void
        public var status: @Sendable (_ serverURL: String, _ deviceId: String) async throws -> LicenseStatus

        static func parseRelayError(from data: Data, statusCode: Int) -> LicensingClientError {
            if let parsed = try? JSONDecoder().decode(RelayErrorResponse.self, from: data) {
                return .server(parsed.reason)
            }
            return .server("Server error (HTTP \(statusCode))")
        }
    }

    extension LicensingClient: DependencyKey {
        public static var previewValue: LicensingClient {
            LicensingClient(
                activate: { _, _, _, _ in LicenseStatus(state: .trial) },
                deactivate: { _, _ in },
                status: { _, _ in LicenseStatus(state: .trial) }
            )
        }

        public static var liveValue: LicensingClient {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            @Sendable
            func request(
                serverURL: String, path: String, method: String, body: Data? = nil
            ) async throws -> Data {
                guard let url = URL(string: "\(serverURL.httpURL)\(path)") else {
                    throw LicensingClientError.invalidURL
                }
                var request = URLRequest(url: url)
                request.httpMethod = method
                if let body {
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = body
                }
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw LicensingClientError.invalidResponse
                }
                guard (200..<300).contains(httpResponse.statusCode) else {
                    throw parseRelayError(from: data, statusCode: httpResponse.statusCode)
                }
                return data
            }

            return LicensingClient(
                activate: { serverURL, licenseKey, deviceId, deviceName in
                    let body = try JSONEncoder().encode(LicenseActivationRequest(
                        licenseKey: licenseKey, deviceId: deviceId, deviceName: deviceName
                    ))
                    let data = try await request(
                        serverURL: serverURL, path: "/api/license/activate", method: "POST", body: body
                    )
                    return try decoder.decode(LicenseStatus.self, from: data)
                },
                deactivate: { serverURL, deviceId in
                    _ = try await request(
                        serverURL: serverURL,
                        path: "/api/license/activation?deviceId=\(deviceId)",
                        method: "DELETE"
                    )
                },
                status: { serverURL, deviceId in
                    let data = try await request(
                        serverURL: serverURL,
                        path: "/api/license/status?deviceId=\(deviceId)",
                        method: "GET"
                    )
                    return try decoder.decode(LicenseStatus.self, from: data)
                }
            )
        }
    }
#endif
