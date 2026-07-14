import Foundation
import Testing
@testable import ClaudeSpyNetworking

@Suite("License models")
struct LicenseModelsTests {
    @Test("LicenseStatus round-trips through ISO8601 JSON")
    func statusRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let status = LicenseStatus(
            state: .trial,
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            activationLimit: 3,
            activationUsage: 1
        )
        let decoded = try decoder.decode(LicenseStatus.self, from: encoder.encode(status))
        #expect(decoded == status)
    }

    @Test("LicenseStatus decodes with only state present (cross-version skew)")
    func statusMinimalDecode() throws {
        let json = Data(#"{"state":"active"}"#.utf8)
        let decoded = try JSONDecoder().decode(LicenseStatus.self, from: json)
        #expect(decoded.state == .active)
        #expect(decoded.expiresAt == nil)
        #expect(decoded.activationLimit == nil)
    }

    @Test("LicenseActivationRequest round-trips")
    func activationRequestRoundTrip() throws {
        let request = LicenseActivationRequest(
            licenseKey: "ABCD-1234", deviceId: "dev-1", deviceName: "My Mac"
        )
        let decoded = try JSONDecoder().decode(
            LicenseActivationRequest.self, from: JSONEncoder().encode(request)
        )
        #expect(decoded.licenseKey == "ABCD-1234")
        #expect(decoded.deviceId == "dev-1")
        #expect(decoded.deviceName == "My Mac")
    }

    @Test("subscriptionRequired error factory is non-recoverable with stable code")
    func subscriptionRequiredFactory() {
        let error = ErrorMessage.subscriptionRequired()
        #expect(error.code == ErrorMessage.subscriptionRequiredCode)
        #expect(error.code == "SUBSCRIPTION_REQUIRED")
        #expect(error.recoverable == false)
    }

    @Test("hostSubscriptionInactive round-trips over the wire")
    func hostSubscriptionInactiveRoundTrip() throws {
        let data = try JSONEncoder().encode(WebSocketMessage.hostSubscriptionInactive)
        let decoded = try JSONDecoder().decode(WebSocketMessage.self, from: data)
        guard case .hostSubscriptionInactive = decoded else {
            Issue.record("Expected .hostSubscriptionInactive, got \(decoded)")
            return
        }
    }

    @Test("ErrorInfo decodes legacy payloads without a code")
    func errorInfoLegacyDecode() throws {
        let json = Data(#"{"message":"boom"}"#.utf8)
        let decoded = try JSONDecoder().decode(ErrorInfo.self, from: json)
        #expect(decoded.message == "boom")
        #expect(decoded.code == nil)
    }

    @Test("ErrorInfo round-trips a code")
    func errorInfoCodeRoundTrip() throws {
        let info = ErrorInfo(message: "sub required", code: ErrorMessage.subscriptionRequiredCode)
        let decoded = try JSONDecoder().decode(ErrorInfo.self, from: JSONEncoder().encode(info))
        #expect(decoded == info)
    }
}
