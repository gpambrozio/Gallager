import Testing
@testable import ClaudeSpyExternalServerLib

struct MinClientVersionGateTests {
    // MARK: - fromEnvironment

    @Test("Unset MIN_CLIENT_VERSION → nil (gate disabled)")
    func unsetDisablesGate() throws {
        #expect(try MinClientVersionGate.fromEnvironment([:]) == nil)
    }

    @Test("Blank MIN_CLIENT_VERSION counts as unset")
    func blankCountsAsUnset() throws {
        #expect(try MinClientVersionGate.fromEnvironment(["MIN_CLIENT_VERSION": "   "]) == nil)
    }

    @Test("Set MIN_CLIENT_VERSION → gate, rejectUnknown defaults to false")
    func setEnablesGate() throws {
        let gate = try MinClientVersionGate.fromEnvironment(["MIN_CLIENT_VERSION": "2.1"])
        #expect(gate == MinClientVersionGate(minVersion: "2.1", rejectUnknown: false))
    }

    @Test("MIN_CLIENT_VERSION is trimmed")
    func versionIsTrimmed() throws {
        let gate = try MinClientVersionGate.fromEnvironment(["MIN_CLIENT_VERSION": "  2.1 "])
        #expect(gate?.minVersion == "2.1")
    }

    @Test("Malformed MIN_CLIENT_VERSION throws rather than silently under-enforcing")
    func malformedVersionThrows() {
        for raw in ["v2.1", "2.x", "2..1", "2.", ".2", "abc", "2 1"] {
            #expect(throws: MinClientVersionGateError.self, "\(raw) should be rejected") {
                try MinClientVersionGate.fromEnvironment(["MIN_CLIENT_VERSION": raw])
            }
        }
    }

    @Test("Well-formed MIN_CLIENT_VERSION values parse")
    func wellFormedVersionsParse() throws {
        for raw in ["2", "2.1", "2.1.0", "10.20.30"] {
            let gate = try MinClientVersionGate.fromEnvironment(["MIN_CLIENT_VERSION": raw])
            #expect(gate?.minVersion == raw, "\(raw) should be accepted")
        }
    }

    @Test("MIN_CLIENT_VERSION_REJECT_UNKNOWN opts in (1/true/yes, case-insensitive)")
    func rejectUnknownTruthy() throws {
        for raw in ["1", "true", "TRUE", "Yes", "yes"] {
            let gate = try MinClientVersionGate.fromEnvironment([
                "MIN_CLIENT_VERSION": "2.1",
                "MIN_CLIENT_VERSION_REJECT_UNKNOWN": raw,
            ])
            #expect(gate?.rejectUnknown == true, "\(raw) should enable rejectUnknown")
        }
    }

    @Test("MIN_CLIENT_VERSION_REJECT_UNKNOWN stays off for other values")
    func rejectUnknownFalsy() throws {
        for raw in ["0", "false", "no", "off", ""] {
            let gate = try MinClientVersionGate.fromEnvironment([
                "MIN_CLIENT_VERSION": "2.1",
                "MIN_CLIENT_VERSION_REJECT_UNKNOWN": raw,
            ])
            #expect(gate?.rejectUnknown == false, "\(raw) should leave rejectUnknown off")
        }
    }

    @Test("REJECT_UNKNOWN alone (no MIN_CLIENT_VERSION) → still disabled")
    func rejectUnknownWithoutMinIsDisabled() throws {
        #expect(try MinClientVersionGate.fromEnvironment(["MIN_CLIENT_VERSION_REJECT_UNKNOWN": "true"]) == nil)
    }

    // MARK: - allows(clientVersion:)

    @Test("Newer and equal versions are allowed; older is refused")
    func numericComparison() {
        let gate = MinClientVersionGate(minVersion: "2.1", rejectUnknown: false)
        #expect(gate.allows(clientVersion: "2.1")) // equal
        #expect(gate.allows(clientVersion: "2.2")) // newer
        #expect(gate.allows(clientVersion: "3.0")) // newer
        #expect(gate.allows(clientVersion: "2.10")) // numeric, not lexical (2.10 > 2.1)
        #expect(!gate.allows(clientVersion: "2.0")) // older
        #expect(!gate.allows(clientVersion: "1.9")) // older
    }

    @Test("Reported clientVersion is trimmed before comparison")
    func clientVersionIsTrimmed() {
        let gate = MinClientVersionGate(minVersion: "2.1", rejectUnknown: false)
        #expect(gate.allows(clientVersion: "  2.1 ")) // padded but new enough
        // swiftlint:disable:next custom_no_number_decimals
        #expect(!gate.allows(clientVersion: " 2.0 ")) // padded but too old
    }

    @Test("Whitespace-only clientVersion counts as unknown")
    func whitespaceCountsAsUnknown() {
        let allowUnknown = MinClientVersionGate(minVersion: "2.1", rejectUnknown: false)
        #expect(allowUnknown.allows(clientVersion: "   "))
        let refuseUnknown = MinClientVersionGate(minVersion: "2.1", rejectUnknown: true)
        #expect(!refuseUnknown.allows(clientVersion: "   "))
    }

    @Test("Unknown version follows rejectUnknown = false (allowed)")
    func unknownAllowedByDefault() {
        let gate = MinClientVersionGate(minVersion: "2.1", rejectUnknown: false)
        #expect(gate.allows(clientVersion: nil))
        #expect(gate.allows(clientVersion: ""))
    }

    @Test("Unknown version follows rejectUnknown = true (refused)")
    func unknownRefusedWhenConfigured() {
        let gate = MinClientVersionGate(minVersion: "2.1", rejectUnknown: true)
        #expect(!gate.allows(clientVersion: nil))
        #expect(!gate.allows(clientVersion: ""))
        // A reported version below the minimum is still refused regardless.
        #expect(!gate.allows(clientVersion: "2.0"))
        // A reported, new-enough version is still allowed even with rejectUnknown on.
        #expect(gate.allows(clientVersion: "2.1"))
    }
}
