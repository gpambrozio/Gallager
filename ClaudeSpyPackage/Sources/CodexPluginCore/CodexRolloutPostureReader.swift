import Foundation

// MARK: - CodexRolloutPostureReader

/// Reads a session's EFFECTIVE approvals posture from the latest
/// `turn_context` record of its rollout file (issue #717).
///
/// codex ≥ 0.146 persists `approvals_reviewer` (and `approval_policy`) into
/// every `turn_context` rollout record — turn contexts are written when a
/// turn spawns, from the same context that routes that turn's approvals, so
/// the latest record IS the per-session ground truth the #585 snapshot
/// design had to approximate. In particular it survives resumes (which fire
/// no SessionStart hook) and attributes mid-session "Approve for me"
/// toggles to the toggling session.
///
/// Returns `nil` when the rollout carries no signal (missing file, no
/// `turn_context` records, or a pre-0.146 record without
/// `approvals_reviewer`) so the caller can fall back to the snapshot
/// heuristic. Any present-but-unrecognized value degrades toward `.user`
/// (notify-anyway), the same fail-safe direction as `CodexConfigReader`.
struct CodexRolloutPostureReader: Sendable {
    /// Resolves the posture from the rollout at `transcriptPath`.
    func posture(transcriptPath: String) -> CodexApprovalsReviewer? {
        guard
            let data = FileManager.default.contents(atPath: transcriptPath),
            let text = String(data: data, encoding: .utf8)
        else { return nil }

        // Keep the last TWO candidate lines (cheap substring pre-filter,
        // confirmed by parse below): codex appends while we read, so a torn
        // final record falls back to the previous turn's context.
        var previous: Substring?
        var last: Substring?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true)
            where line.contains("\"turn_context\"") {
            previous = last
            last = line
        }

        for candidate in [last, previous] {
            guard let candidate, let payload = turnContextPayload(of: candidate) else {
                continue
            }
            return reviewer(of: payload)
        }
        return nil
    }

    /// Parses a candidate line, returning its `payload` only when the line
    /// really is a `turn_context` record (the pre-filter also matches e.g. an
    /// `event_msg` whose text quotes the string, and torn appends).
    private func turnContextPayload(of line: Substring) -> [String: Any]? {
        guard
            let record = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                as? [String: Any],
            record["type"] as? String == "turn_context",
            let payload = record["payload"] as? [String: Any]
        else { return nil }
        return payload
    }

    /// Maps a turn_context payload to a posture. `nil` when the record
    /// predates the `approvals_reviewer` field (codex < 0.146).
    ///
    /// The reviewer alone is not sufficient: under an `untrusted`/
    /// `on-failure` approval policy codex routes approvals to the USER even
    /// with `auto_review` set, so suppression additionally requires the
    /// guardian-routing `on-request` policy. Unknown reviewer or policy
    /// values (future codex) fail safe to `.user`.
    private func reviewer(of payload: [String: Any]) -> CodexApprovalsReviewer? {
        guard let reviewer = payload["approvals_reviewer"] as? String else {
            return nil
        }
        guard
            reviewer == "auto_review" || reviewer == "guardian_subagent",
            payload["approval_policy"] as? String == "on-request"
        else { return .user }
        return .autoReview
    }
}
