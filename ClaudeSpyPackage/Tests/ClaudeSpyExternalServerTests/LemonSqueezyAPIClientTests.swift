import Foundation
import Testing
@testable import ClaudeSpyExternalServerLib

@Suite("LemonSqueezyAPIClient")
struct LemonSqueezyAPIClientTests {
    @Test("Decodes an activation success response")
    func decodeActivationSuccess() throws {
        let json = Data("""
        {
          "activated": true,
          "error": null,
          "license_key": {
            "id": 1, "status": "active", "key": "TEST-KEY",
            "activation_limit": 3, "activation_usage": 1,
            "created_at": "2026-07-13T10:00:00.000000Z",
            "expires_at": null
          },
          "instance": { "id": "inst-uuid-1", "name": "My Mac", "created_at": "2026-07-13T10:00:00.000000Z" },
          "meta": { "store_id": 123, "order_id": 9, "product_id": 456, "customer_id": 7 }
        }
        """.utf8)
        let response = try JSONDecoder().decode(LSLicenseResponse.self, from: json)
        #expect(response.activated == true)
        #expect(response.licenseKey?.status == "active")
        #expect(response.licenseKey?.activationLimit == 3)
        #expect(response.instance?.id == "inst-uuid-1")
        #expect(response.meta?.storeId == 123)
        #expect(response.meta?.productId == 456)
    }

    @Test("Decodes an activation-limit failure response")
    func decodeActivationLimit() throws {
        let json = Data("""
        {
          "activated": false,
          "error": "This license key has reached the activation limit.",
          "license_key": { "id": 1, "status": "active", "key": "TEST-KEY",
                           "activation_limit": 3, "activation_usage": 3, "expires_at": null },
          "meta": { "store_id": 123, "product_id": 456 }
        }
        """.utf8)
        let response = try JSONDecoder().decode(LSLicenseResponse.self, from: json)
        #expect(response.activated == false)
        #expect(response.error == "This license key has reached the activation limit.")
    }

    @Test("Decodes an expired validation response")
    func decodeExpiredValidation() throws {
        let json = Data("""
        {
          "valid": false,
          "error": "license_key expired",
          "license_key": { "id": 1, "status": "expired", "key": "TEST-KEY",
                           "activation_limit": 3, "activation_usage": 1,
                           "expires_at": "2026-08-13T10:00:00.000000Z" },
          "instance": { "id": "inst-uuid-1", "name": "My Mac" },
          "meta": { "store_id": 123, "product_id": 456 }
        }
        """.utf8)
        let response = try JSONDecoder().decode(LSLicenseResponse.self, from: json)
        #expect(response.valid == false)
        #expect(response.licenseKey?.status == "expired")
        #expect(response.licenseKey?.expiresAt == "2026-08-13T10:00:00.000000Z")
    }

    @Test("parseLSDate handles microsecond fractions and nil")
    func parseDates() {
        let parsed = LemonSqueezyAPIClient.parseLSDate("2026-08-13T10:00:00.000000Z")
        #expect(parsed != nil)
        let noFraction = LemonSqueezyAPIClient.parseLSDate("2026-08-13T10:00:00Z")
        #expect(parsed == noFraction)
        #expect(LemonSqueezyAPIClient.parseLSDate(nil) == nil)
        #expect(LemonSqueezyAPIClient.parseLSDate("garbage") == nil)
    }

    @Test("formEncode percent-encodes values")
    func formEncoding() {
        let encoded = LemonSqueezyAPIClient.formEncode([
            ("license_key", "AB+C 1"), ("instance_name", "Gustavo's Mac"),
        ])
        #expect(encoded == "license_key=AB%2BC%201&instance_name=Gustavo%27s%20Mac")
    }
}
