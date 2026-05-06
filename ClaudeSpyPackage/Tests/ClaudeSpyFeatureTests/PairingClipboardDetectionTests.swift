import Testing
@testable import ClaudeSpyFeature

@Suite("PairingCodeValidator")
struct PairingClipboardDetectionTests {
    @Test("Detects valid 6-letter code")
    func validCode() {
        #expect(PairingCodeValidator.pairingCode(from: "ABCDEF") == "ABCDEF")
    }

    @Test("Uppercases lowercase input")
    func uppercasesLowercase() {
        #expect(PairingCodeValidator.pairingCode(from: "abcdef") == "ABCDEF")
        #expect(PairingCodeValidator.pairingCode(from: "AbCdEf") == "ABCDEF")
    }

    @Test("Trims surrounding whitespace and newlines")
    func trimsWhitespace() {
        #expect(PairingCodeValidator.pairingCode(from: "  ABCDEF  ") == "ABCDEF")
        #expect(PairingCodeValidator.pairingCode(from: "\nABCDEF\n") == "ABCDEF")
        #expect(PairingCodeValidator.pairingCode(from: "\t abcdef \t") == "ABCDEF")
    }

    @Test("Rejects nil input")
    func rejectsNil() {
        #expect(PairingCodeValidator.pairingCode(from: nil) == nil)
    }

    @Test("Rejects wrong length")
    func rejectsWrongLength() {
        #expect(PairingCodeValidator.pairingCode(from: "") == nil)
        #expect(PairingCodeValidator.pairingCode(from: "ABCDE") == nil)
        #expect(PairingCodeValidator.pairingCode(from: "ABCDEFG") == nil)
    }

    @Test("Rejects codes containing digits")
    func rejectsDigits() {
        #expect(PairingCodeValidator.pairingCode(from: "ABC123") == nil)
        #expect(PairingCodeValidator.pairingCode(from: "123456") == nil)
        #expect(PairingCodeValidator.pairingCode(from: "ABCDE1") == nil)
    }

    @Test("Rejects codes containing punctuation or symbols")
    func rejectsPunctuation() {
        #expect(PairingCodeValidator.pairingCode(from: "ABCDE!") == nil)
        #expect(PairingCodeValidator.pairingCode(from: "AB CDE") == nil)
        #expect(PairingCodeValidator.pairingCode(from: "AB-CDE") == nil)
    }

    @Test("Rejects unrelated clipboard contents")
    func rejectsUnrelated() {
        #expect(PairingCodeValidator.pairingCode(from: "https://example.com/foo") == nil)
        #expect(PairingCodeValidator.pairingCode(from: "hello world") == nil)
        #expect(PairingCodeValidator.pairingCode(from: "{}") == nil)
    }
}
