#if os(macOS)
    import ClaudeSpyNetworking
    import Foundation
    import Testing
    @testable import ClaudeSpyServerFeature

    @Suite("LicensingClient")
    @MainActor
    struct LicensingClientTests {
        @Test("Relay error body maps to a readable message")
        func serverErrorMapping() {
            let error = LicensingClientError.server("This license key has reached the activation limit.")
            #expect(error.errorDescription == "This license key has reached the activation limit.")
        }

        @Test("parseRelayError extracts Vapor's reason field")
        func parseRelayError() {
            let body = Data(#"{"error":true,"reason":"This license key is not valid for this product"}"#.utf8)
            let parsed = LicensingClient.parseRelayError(from: body, statusCode: 400)
            #expect(parsed == .server("This license key is not valid for this product"))
        }

        @Test("parseRelayError falls back to the status code")
        func parseRelayErrorFallback() {
            let parsed = LicensingClient.parseRelayError(from: Data(), statusCode: 500)
            #expect(parsed == .server("Server error (HTTP 500)"))
        }
    }
#endif
