import Foundation
import Testing
@testable import CodexPluginCore

/// `CodexRolloutPostureReader` reads a session's EFFECTIVE approvals posture
/// from the latest `turn_context` record of its rollout file (issue #717).
///
/// codex ≥ 0.146 persists `approvals_reviewer` (and `approval_policy`) into
/// every `turn_context` rollout record — the exact per-session signal the
/// #585 snapshot design had to approximate. The reader returns `nil` when the
/// rollout carries no such signal (older codex, missing file) so callers fall
/// back to the snapshot heuristic; any present-but-ambiguous shape degrades
/// toward `.user` (notify-anyway), matching the config reader's direction.
@Suite("CodexRolloutPostureReader")
struct CodexRolloutPostureReaderTests {
    // MARK: - Helpers

    private func withRollout<T>(
        lines: [String],
        _ body: (CodexRolloutPostureReader, String) throws -> T
    ) throws -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gallager-cx-rollout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rollout = dir.appendingPathComponent("rollout-test.jsonl")
        try Data(lines.joined(separator: "\n").utf8).write(to: rollout)
        return try body(CodexRolloutPostureReader(), rollout.path)
    }

    /// A realistic rollout `turn_context` line. `reviewer`/`policy` are
    /// omitted from the payload when nil (pre-0.146 shape).
    private func turnContext(
        reviewer: String?,
        policy: String? = "on-request",
        turnID: String = "t-1"
    ) -> String {
        var payload = "\"turn_id\": \"\(turnID)\", \"cwd\": \"/Users/test/MyProject\""
        if let policy {
            payload += ", \"approval_policy\": \"\(policy)\""
        }
        if let reviewer {
            payload += ", \"approvals_reviewer\": \"\(reviewer)\""
        }
        payload += ", \"sandbox_policy\": {\"type\": \"workspace-write\", \"network_access\": false}"
        return """
        {"timestamp": "2026-08-03T22:25:06.671Z", "type": "turn_context", "payload": {\(payload)}}
        """
    }

    private let sessionMeta = """
    {"timestamp": "2026-07-31T23:09:49.000Z", "type": "session_meta", "payload": {"id": "s-1", "cwd": "/Users/test/MyProject"}}
    """

    private let responseItem = """
    {"timestamp": "2026-08-03T22:25:07.000Z", "type": "response_item", "payload": {"type": "message", "role": "assistant"}}
    """

    // MARK: - Reviewer mapping

    @Test("auto_review + on-request resolves to autoReview")
    func autoReviewOnRequest() throws {
        try withRollout(lines: [sessionMeta, turnContext(reviewer: "auto_review")]) { reader, path in
            #expect(reader.posture(transcriptPath: path) == .autoReview)
        }
    }

    @Test("legacy guardian_subagent spelling resolves to autoReview")
    func guardianSubagentSpelling() throws {
        try withRollout(lines: [turnContext(reviewer: "guardian_subagent")]) { reader, path in
            #expect(reader.posture(transcriptPath: path) == .autoReview)
        }
    }

    @Test("user reviewer resolves to user")
    func userReviewer() throws {
        try withRollout(lines: [turnContext(reviewer: "user")]) { reader, path in
            #expect(reader.posture(transcriptPath: path) == .user)
        }
    }

    @Test("an unknown reviewer value fails safe to user")
    func unknownReviewerFailsSafe() throws {
        try withRollout(lines: [turnContext(reviewer: "some_future_mode")]) { reader, path in
            #expect(reader.posture(transcriptPath: path) == .user)
        }
    }

    // MARK: - Approval-policy gating (untrusted/on-failure route approvals to the user)

    @Test("auto_review with a user-routing approval policy resolves to user", arguments: [
        "untrusted", "on-failure", "never",
    ])
    func userRoutingPolicies(policy: String) throws {
        try withRollout(
            lines: [turnContext(reviewer: "auto_review", policy: policy)]
        ) { reader, path in
            #expect(reader.posture(transcriptPath: path) == .user)
        }
    }

    @Test("auto_review with an unknown or missing approval policy fails safe to user")
    func unknownPolicyFailsSafe() throws {
        try withRollout(
            lines: [turnContext(reviewer: "auto_review", policy: "granular-v2")]
        ) { reader, path in
            #expect(reader.posture(transcriptPath: path) == .user)
        }
        try withRollout(
            lines: [turnContext(reviewer: "auto_review", policy: nil)]
        ) { reader, path in
            #expect(reader.posture(transcriptPath: path) == .user)
        }
    }

    // MARK: - Latest record wins

    @Test("the latest turn_context wins, in both directions")
    func latestTurnContextWins() throws {
        try withRollout(lines: [
            turnContext(reviewer: "user", turnID: "t-1"),
            responseItem,
            turnContext(reviewer: "auto_review", turnID: "t-2"),
            responseItem,
        ]) { reader, path in
            #expect(reader.posture(transcriptPath: path) == .autoReview)
        }
        try withRollout(lines: [
            turnContext(reviewer: "auto_review", turnID: "t-1"),
            responseItem,
            turnContext(reviewer: "user", turnID: "t-2"),
            responseItem,
        ]) { reader, path in
            #expect(reader.posture(transcriptPath: path) == .user)
        }
    }

    // MARK: - No signal → nil (fallback to the snapshot heuristic)

    @Test("a turn_context without approvals_reviewer (codex < 0.146) yields nil")
    func preReviewerTurnContextYieldsNil() throws {
        try withRollout(lines: [turnContext(reviewer: nil)]) { reader, path in
            #expect(reader.posture(transcriptPath: path) == nil)
        }
    }

    @Test("a rollout with no turn_context records yields nil")
    func noTurnContextYieldsNil() throws {
        try withRollout(lines: [sessionMeta, responseItem]) { reader, path in
            #expect(reader.posture(transcriptPath: path) == nil)
        }
    }

    @Test("a missing rollout file yields nil")
    func missingFileYieldsNil() {
        let reader = CodexRolloutPostureReader()
        #expect(reader.posture(transcriptPath: "/nonexistent/rollout.jsonl") == nil)
    }

    // MARK: - Hostile on-disk data (spec §13: degrade, never trap)

    @Test("a torn final turn_context line falls back to the previous one")
    func tornLastLineFallsBack() throws {
        // Long enough to include the "turn_context" marker, short enough to
        // be invalid JSON — a mid-append read of the newest record.
        let torn = String(turnContext(reviewer: "user", turnID: "t-torn").prefix(80))
        try withRollout(lines: [
            turnContext(reviewer: "auto_review", turnID: "t-1"),
            torn,
        ]) { reader, path in
            #expect(reader.posture(transcriptPath: path) == .autoReview)
        }
    }

    @Test("garbage lines between records are skipped")
    func garbageLinesSkipped() throws {
        try withRollout(lines: [
            "not json at all",
            turnContext(reviewer: "auto_review"),
            "{\"truncated\": ",
            "",
        ]) { reader, path in
            #expect(reader.posture(transcriptPath: path) == .autoReview)
        }
    }

    @Test("a line mentioning turn_context in another position is not a turn_context record")
    func lookalikeLineIgnored() throws {
        // e.g. an event_msg whose text quotes the string "turn_context".
        let lookalike = """
        {"timestamp": "2026-08-03T22:25:08.000Z", "type": "event_msg", "payload": {"type": "agent_message", "message": "reading turn_context records", "approvals_reviewer": "user"}}
        """
        try withRollout(lines: [
            turnContext(reviewer: "auto_review"),
            lookalike,
        ]) { reader, path in
            #expect(reader.posture(transcriptPath: path) == .autoReview)
        }
    }

    /// A record whose serialized JSON contains the raw quoted marker
    /// `"turn_context"` as a VALUE — it passes the substring pre-filter but is
    /// not a turn_context record.
    private let prefilterLookalike = """
    {"timestamp": "2026-08-03T22:25:09.000Z", "type": "event_msg", "payload": {"type": "item_removed", "item_type": "turn_context"}}
    """

    @Test("any number of pre-filter lookalikes after the real record are scanned past")
    func manyPrefilterLookalikesScannedPast() throws {
        // Candidates must be walked backward until one PARSES as a real
        // turn_context — a fixed window of trailing candidates would exhaust
        // here and wrongly fall back to the snapshot heuristic.
        try withRollout(lines: [
            turnContext(reviewer: "user"),
            prefilterLookalike,
            prefilterLookalike,
            prefilterLookalike,
        ]) { reader, path in
            #expect(reader.posture(transcriptPath: path) == .user)
        }
    }

    @Test("a torn multi-byte character at EOF doesn't defeat the previous-record fallback")
    func tornMultiByteUTF8FallsBack() throws {
        // A concurrent append cut mid-multi-byte UTF-8 character: the decode
        // must be lossy (torn line → U+FFFD → JSON parse fails → previous
        // record wins), not fail the whole file.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gallager-cx-rollout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rollout = dir.appendingPathComponent("rollout-torn.jsonl")

        var data = Data((turnContext(reviewer: "auto_review") + "\n").utf8)
        data.append(Data(turnContext(reviewer: "user", turnID: "t-torn").prefix(80).utf8))
        // First two bytes of a three-byte UTF-8 character ("…").
        data.append(Data([0xE2, 0x80]))
        try data.write(to: rollout)

        #expect(CodexRolloutPostureReader().posture(transcriptPath: rollout.path) == .autoReview)
    }

    // MARK: - Large rollouts (bounded tail read + full-scan fallback)

    /// ~150 bytes per filler line; 3000 lines ≈ 450KB, comfortably past the
    /// reader's tail chunk.
    private var filler: [String] {
        Array(repeating: responseItem, count: 3_000)
    }

    @Test("a large rollout's latest turn_context is found in the tail")
    func largeRolloutTailRead() throws {
        try withRollout(lines: filler + [turnContext(reviewer: "auto_review")]) { reader, path in
            #expect(reader.posture(transcriptPath: path) == .autoReview)
        }
    }

    @Test("a turn_context buried past the tail chunk is still found")
    func largeRolloutTurnContextBeyondTail() throws {
        // A single turn that appended more than the tail chunk after its
        // turn_context (large tool results): the reader must fall back to
        // scanning the rest of the file, not lose ground truth.
        try withRollout(lines: [turnContext(reviewer: "auto_review")] + filler) { reader, path in
            #expect(reader.posture(transcriptPath: path) == .autoReview)
        }
    }
}
