import Foundation
import Testing
@testable import CodexPluginCore

/// Covers the tolerant `config.toml` line scanner that resolves the effective
/// `approvals_reviewer`, the file-read path, and the FSEvents path filter used
/// by the config watcher. The parser must degrade (to `.user`, i.e.
/// notify-anyway) — never trap — on hostile input (spec §13).
@Suite("CodexConfigReader")
struct CodexConfigReaderTests {
    // MARK: - Reviewer value spellings

    @Test("auto_review maps to .autoReview")
    func autoReview() {
        let toml = """
        approvals_reviewer = "auto_review"
        """
        #expect(CodexConfigReader.approvalsReviewer(fromTOML: toml) == .autoReview)
    }

    @Test("legacy guardian_subagent alias maps to .autoReview")
    func guardianSubagentAlias() {
        let toml = """
        approvals_reviewer = "guardian_subagent"
        """
        #expect(CodexConfigReader.approvalsReviewer(fromTOML: toml) == .autoReview)
    }

    @Test("user maps to .user")
    func userReviewer() {
        let toml = """
        approvals_reviewer = "user"
        """
        #expect(CodexConfigReader.approvalsReviewer(fromTOML: toml) == .user)
    }

    @Test("unknown reviewer value fails safe to .user")
    func unknownValue() {
        let toml = """
        approvals_reviewer = "robot_overlord"
        """
        #expect(CodexConfigReader.approvalsReviewer(fromTOML: toml) == .user)
    }

    @Test("missing key defaults to .user")
    func missingKey() {
        let toml = """
        model = "gpt-5.5"
        approval_policy = "on-request"
        """
        #expect(CodexConfigReader.approvalsReviewer(fromTOML: toml) == .user)
    }

    @Test("empty file defaults to .user")
    func emptyFile() {
        #expect(CodexConfigReader.approvalsReviewer(fromTOML: "") == .user)
    }

    // MARK: - Syntax tolerance

    @Test("single-quoted and unquoted values are accepted")
    func quoteVariants() {
        #expect(CodexConfigReader.approvalsReviewer(
            fromTOML: "approvals_reviewer = 'auto_review'"
        ) == .autoReview)
        #expect(CodexConfigReader.approvalsReviewer(
            fromTOML: "approvals_reviewer = auto_review"
        ) == .autoReview)
        #expect(CodexConfigReader.approvalsReviewer(
            fromTOML: "approvals_reviewer=\"auto_review\""
        ) == .autoReview)
    }

    @Test("trailing comments are ignored, quoted and bare")
    func trailingComments() {
        #expect(CodexConfigReader.approvalsReviewer(
            fromTOML: "approvals_reviewer = \"auto_review\" # guardian on"
        ) == .autoReview)
        #expect(CodexConfigReader.approvalsReviewer(
            fromTOML: "approvals_reviewer = auto_review # guardian on"
        ) == .autoReview)
    }

    @Test("a commented-out key does not count")
    func commentedOutKey() {
        let toml = """
        # approvals_reviewer = "auto_review"
        """
        #expect(CodexConfigReader.approvalsReviewer(fromTOML: toml) == .user)
    }

    @Test("malformed lines never trap and are skipped")
    func malformedLines() {
        let toml = """
        [[[]]]
        = = =
        approvals_reviewer
        [unterminated
        approvals_reviewer = "auto_review
        key = "value" extra ] [
        """
        // The `[unterminated` line is ignored (bracket never closes) and the
        // unterminated-quote assignment fails closed, so nothing ever sets
        // the reviewer → .user.
        #expect(CodexConfigReader.approvalsReviewer(fromTOML: toml) == .user)
    }

    @Test("an unterminated quoted value fails closed to .user (torn write)")
    func unterminatedQuoteFailsClosed() {
        // A crash or full disk mid-save can truncate the file right after the
        // opening quote. Codex's strict parser rejects such a file and falls
        // back to the user reviewer — the scanner must degrade the same way,
        // never toward suppression.
        #expect(CodexConfigReader.approvalsReviewer(
            fromTOML: "approvals_reviewer = \"auto_review"
        ) == .user)
        #expect(CodexConfigReader.approvalsReviewer(
            fromTOML: "approvals_reviewer = 'auto_review"
        ) == .user)
    }

    @Test("an assignment inside a multi-line string value is not a real key")
    func multilineStringBodyIsOpaque() {
        // The literal reviewer line inside the """…""" body must not override
        // the explicit top-level `user` (in either order).
        let basic = """
        approvals_reviewer = "user"
        notes = \"\"\"
        approvals_reviewer = "auto_review"
        \"\"\"
        """
        #expect(CodexConfigReader.approvalsReviewer(fromTOML: basic) == .user)

        // Without masking, the body line would be the only (and thus winning)
        // top-level assignment.
        let literal = """
        notes = '''
        approvals_reviewer = "auto_review"
        '''
        """
        #expect(CodexConfigReader.approvalsReviewer(fromTOML: literal) == .user)

        // A key after the closing delimiter is parsed again.
        let closed = """
        notes = '''
        anything
        '''
        approvals_reviewer = "auto_review"
        """
        #expect(CodexConfigReader.approvalsReviewer(fromTOML: closed) == .autoReview)
    }

    @Test("a nested-array continuation line does not end top-level scanning")
    func arrayContinuationLineIgnored() {
        // `["read", "/tmp"],` starts with `[` but is not a section header —
        // a genuine top-level reviewer after it must still count.
        let toml = """
        permissions = [
            ["read", "/tmp"],
            ["write", "/tmp"],
        ]
        approvals_reviewer = "auto_review"
        """
        #expect(CodexConfigReader.approvalsReviewer(fromTOML: toml) == .autoReview)
    }

    @Test("realistic config: top-level key before many sections (real-world shape)")
    func realisticConfig() {
        let toml = """
        personality = "pragmatic"
        model = "gpt-5.5"
        approvals_reviewer = "guardian_subagent"

        [marketplaces.openai-bundled]
        last_updated = "2026-06-05T19:08:16Z"
        source = "/Users/x/.codex/.tmp/bundled-marketplaces/openai-bundled"

        [marketplaces.gallager]
        source_type = "git"
        """
        #expect(CodexConfigReader.approvalsReviewer(fromTOML: toml) == .autoReview)
    }

    // MARK: - Section awareness

    @Test("the key inside a foreign section does not count as top-level")
    func keyInForeignSection() {
        let toml = """
        model = "gpt-5.5"

        [tui]
        approvals_reviewer = "auto_review"
        """
        #expect(CodexConfigReader.approvalsReviewer(fromTOML: toml) == .user)
    }

    // MARK: - Profile overrides

    @Test("the active profile's reviewer wins over the top-level key")
    func profileOverrideWins() {
        let toml = """
        profile = "work"
        approvals_reviewer = "user"

        [profiles.work]
        approvals_reviewer = "auto_review"
        """
        #expect(CodexConfigReader.approvalsReviewer(fromTOML: toml) == .autoReview)
    }

    @Test("the active profile can also override back to user")
    func profileOverridesBackToUser() {
        let toml = """
        profile = "work"
        approvals_reviewer = "auto_review"

        [profiles.work]
        approvals_reviewer = "user"
        """
        #expect(CodexConfigReader.approvalsReviewer(fromTOML: toml) == .user)
    }

    @Test("a profile without the key falls back to the top-level value")
    func profileWithoutKeyFallsBack() {
        let toml = """
        profile = "work"
        approvals_reviewer = "auto_review"

        [profiles.work]
        model = "gpt-5.5"
        """
        #expect(CodexConfigReader.approvalsReviewer(fromTOML: toml) == .autoReview)
    }

    @Test("a profile pointing at a missing section falls back to top-level")
    func missingProfileSection() {
        let toml = """
        profile = "nope"
        approvals_reviewer = "auto_review"
        """
        #expect(CodexConfigReader.approvalsReviewer(fromTOML: toml) == .autoReview)
    }

    @Test("an inactive profile's reviewer does not leak")
    func inactiveProfileIgnored() {
        let toml = """
        profile = "home"

        [profiles.work]
        approvals_reviewer = "auto_review"
        """
        #expect(CodexConfigReader.approvalsReviewer(fromTOML: toml) == .user)
    }

    @Test("no active profile means profile sections are ignored entirely")
    func noActiveProfile() {
        let toml = """
        [profiles.work]
        approvals_reviewer = "auto_review"
        """
        #expect(CodexConfigReader.approvalsReviewer(fromTOML: toml) == .user)
    }

    @Test("quoted profile section names match")
    func quotedProfileSection() {
        let toml = """
        profile = "work"

        [profiles."work"]
        approvals_reviewer = "auto_review"
        """
        #expect(CodexConfigReader.approvalsReviewer(fromTOML: toml) == .autoReview)
    }

    // MARK: - File read

    @Test("reads the reviewer from <codexHome>/config.toml")
    func readsFromFile() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("gallager-cx-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        try Data("approvals_reviewer = \"auto_review\"\n".utf8)
            .write(to: home.appendingPathComponent("config.toml"))

        #expect(CodexConfigReader().approvalsReviewer(codexHome: home) == .autoReview)
    }

    @Test("a missing config.toml defaults to .user")
    func missingFile() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("gallager-cx-noconfig-\(UUID().uuidString)")
        #expect(CodexConfigReader().approvalsReviewer(codexHome: home) == .user)
    }

    // MARK: - Dotted-key profile overrides

    @Test("a dotted-key profile override wins over the top-level key")
    func dottedProfileOverrideWins() {
        // Codex resolves this back to the user reviewer — the scanner must
        // not stay on the top-level auto_review and suppress real prompts.
        let toml = """
        profile = "work"
        approvals_reviewer = "auto_review"
        profiles.work.approvals_reviewer = "user"
        """
        #expect(CodexConfigReader.approvalsReviewer(fromTOML: toml) == .user)
    }

    @Test("a dotted key under a [profiles] table is recognized")
    func profilesTableDottedKey() {
        let toml = """
        profile = "work"
        approvals_reviewer = "user"

        [profiles]
        work.approvals_reviewer = "auto_review"
        """
        #expect(CodexConfigReader.approvalsReviewer(fromTOML: toml) == .autoReview)
    }

    @Test("dotted keys for an inactive profile do not leak")
    func dottedKeyInactiveProfileIgnored() {
        let toml = """
        profile = "home"
        profiles.work.approvals_reviewer = "auto_review"
        """
        #expect(CodexConfigReader.approvalsReviewer(fromTOML: toml) == .user)
    }

    @Test("a quoted dotted profile segment matches")
    func dottedQuotedProfileSegment() {
        let toml = """
        profile = "work"
        profiles."work".approvals_reviewer = "auto_review"
        """
        #expect(CodexConfigReader.approvalsReviewer(fromTOML: toml) == .autoReview)
    }
}
