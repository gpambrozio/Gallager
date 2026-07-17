import AsyncHTTPClient
import Foundation
import NIOCore

// MARK: - Protocol

/// Abstraction over Lemon Squeezy's public License API
/// (https://docs.lemonsqueezy.com/api/license-api) so LicensingService tests
/// can stub responses. These endpoints are keyed by the license key itself —
/// no API secret is required or stored on the relay.
protocol LicenseAPIClient: Sendable {
    func activate(licenseKey: String, instanceName: String) async throws -> LSLicenseResponse
    func validate(licenseKey: String, instanceId: String) async throws -> LSLicenseResponse
    func deactivate(licenseKey: String, instanceId: String) async throws -> LSDeactivateResponse
}

/// Placeholder client used when licensing is disabled — LicensingService
/// short-circuits before ever calling it, so any call is a programmer error.
struct DisabledLicenseAPIClient: LicenseAPIClient {
    struct LicensingDisabledError: Error { }
    func activate(licenseKey: String, instanceName: String) async throws -> LSLicenseResponse {
        throw LicensingDisabledError()
    }

    func validate(licenseKey: String, instanceId: String) async throws -> LSLicenseResponse {
        throw LicensingDisabledError()
    }

    func deactivate(licenseKey: String, instanceId: String) async throws -> LSDeactivateResponse {
        throw LicensingDisabledError()
    }
}

// MARK: - Response DTOs (snake_case per LS docs)

struct LSLicenseResponse: Codable, Sendable {
    let activated: Bool?
    let valid: Bool?
    let error: String?
    let licenseKey: LSLicenseKey?
    let instance: LSInstance?
    let meta: LSMeta?

    enum CodingKeys: String, CodingKey {
        case activated
        case valid
        case error
        case instance
        case meta
        case licenseKey = "license_key"
    }
}

struct LSLicenseKey: Codable, Sendable {
    /// "inactive" | "active" | "expired" | "disabled"
    let status: String
    let activationLimit: Int?
    let activationUsage: Int?
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case status
        case activationLimit = "activation_limit"
        case activationUsage = "activation_usage"
        case expiresAt = "expires_at"
    }
}

struct LSInstance: Codable, Sendable {
    let id: String
    let name: String
}

struct LSMeta: Codable, Sendable {
    let storeId: Int?
    let productId: Int?

    enum CodingKeys: String, CodingKey {
        case storeId = "store_id"
        case productId = "product_id"
    }
}

struct LSDeactivateResponse: Codable, Sendable {
    let deactivated: Bool?
    let error: String?
}

// MARK: - Live client

struct LemonSqueezyAPIClient: LicenseAPIClient {
    let baseURL: String

    func activate(licenseKey: String, instanceName: String) async throws -> LSLicenseResponse {
        try await send(path: "/v1/licenses/activate", fields: [
            ("license_key", licenseKey), ("instance_name", instanceName),
        ])
    }

    func validate(licenseKey: String, instanceId: String) async throws -> LSLicenseResponse {
        try await send(path: "/v1/licenses/validate", fields: [
            ("license_key", licenseKey), ("instance_id", instanceId),
        ])
    }

    func deactivate(licenseKey: String, instanceId: String) async throws -> LSDeactivateResponse {
        try await send(path: "/v1/licenses/deactivate", fields: [
            ("license_key", licenseKey), ("instance_id", instanceId),
        ])
    }

    /// POSTs form-encoded fields and decodes the JSON body regardless of HTTP
    /// status — LS returns 400/404 with the same JSON shape carrying `error`,
    /// which LicensingService maps to verdicts rather than treating as
    /// transport failure.
    private func send<Response: Decodable>(
        path: String, fields: [(String, String)]
    ) async throws -> Response {
        var request = HTTPClientRequest(url: baseURL + path)
        request.method = .POST
        request.headers.add(name: "Accept", value: "application/json")
        request.headers.add(name: "Content-Type", value: "application/x-www-form-urlencoded")
        request.body = .bytes(ByteBuffer(string: Self.formEncode(fields)))

        let response = try await HTTPClient.shared.execute(request, timeout: .seconds(15))
        var body = try await response.body.collect(upTo: 1 << 20)
        let data = body.readData(length: body.readableBytes) ?? Data()
        return try JSONDecoder().decode(Response.self, from: data)
    }

    static func formEncode(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .map { key, value in
                let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(key)=\(encoded)"
            }
            .joined(separator: "&")
    }

    /// LS timestamps carry microsecond fractions ("2026-08-13T10:00:00.000000Z"),
    /// which ISO8601DateFormatter cannot parse — strip the fraction first.
    static func parseLSDate(_ string: String?) -> Date? {
        guard var value = string else { return nil }
        if let dot = value.firstIndex(of: ".") {
            let afterFraction = value[value.index(after: dot)...].drop(while: \.isNumber)
            value = String(value[..<dot]) + afterFraction
        }
        return ISO8601DateFormatter().date(from: value)
    }
}
