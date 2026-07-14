import Testing
@testable import ClaudeSpyExternalServerLib

@Suite("LicensingConfiguration")
struct LicensingConfigurationTests {
    @Test("Both unset → nil (licensing disabled)")
    func bothUnset() throws {
        #expect(try LicensingConfiguration.fromEnvironment([:]) == nil)
    }

    @Test("Empty strings count as unset")
    func emptyStrings() throws {
        let env = ["LEMONSQUEEZY_STORE_ID": "", "LEMONSQUEEZY_PRODUCT_ID": " "]
        #expect(try LicensingConfiguration.fromEnvironment(env) == nil)
    }

    @Test("Both set → config with defaults")
    func bothSet() throws {
        let env = ["LEMONSQUEEZY_STORE_ID": "123", "LEMONSQUEEZY_PRODUCT_ID": "456"]
        let config = try #require(try LicensingConfiguration.fromEnvironment(env))
        #expect(config.storeId == 123)
        #expect(config.productId == 456)
        #expect(config.trialDays == 7)
        #expect(config.revalidateHours == 24)
        #expect(config.graceDays == 7)
        #expect(config.apiBaseURL == "https://api.lemonsqueezy.com")
    }

    @Test("Overrides are honored")
    func overrides() throws {
        let env = [
            "LEMONSQUEEZY_STORE_ID": "123", "LEMONSQUEEZY_PRODUCT_ID": "456",
            "TRIAL_DAYS": "14", "LICENSE_REVALIDATE_HOURS": "6",
            "LICENSE_GRACE_DAYS": "3", "LEMONSQUEEZY_API_BASE": "http://127.0.0.1:9999",
        ]
        let config = try #require(try LicensingConfiguration.fromEnvironment(env))
        #expect(config.trialDays == 14)
        #expect(config.revalidateHours == 6)
        #expect(config.graceDays == 3)
        #expect(config.apiBaseURL == "http://127.0.0.1:9999")
    }

    @Test("Half-set throws (fail-loud at boot)")
    func halfSetThrows() {
        #expect(throws: LicensingConfigurationError.self) {
            try LicensingConfiguration.fromEnvironment(["LEMONSQUEEZY_STORE_ID": "123"])
        }
    }

    @Test("Non-integer ids throw")
    func nonIntegerThrows() {
        #expect(throws: LicensingConfigurationError.self) {
            try LicensingConfiguration.fromEnvironment(
                ["LEMONSQUEEZY_STORE_ID": "abc", "LEMONSQUEEZY_PRODUCT_ID": "456"]
            )
        }
    }
}
