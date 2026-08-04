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
/// Reads are bounded: rollouts of multi-day threads — the exact sessions the
/// turn_context path exists for — reach tens of MB, so the reader scans a
/// fixed-size tail chunk first (turn contexts recur every turn, so the
/// latest is almost always near EOF) and falls back to scanning the whole
/// file only when a single turn appended more than the chunk after its
/// turn_context (large tool results).
///
/// Returns `nil` when the rollout carries no signal (missing file, no
/// `turn_context` records, or a pre-0.146 record without
/// `approvals_reviewer`) so the caller can fall back to the snapshot
/// heuristic. Any present-but-unrecognized value degrades toward `.user`
/// (notify-anyway), the same fail-safe direction as `CodexConfigReader`.
struct CodexRolloutPostureReader: Sendable {
    /// Bytes scanned from the file tail before falling back to a full read.
    /// turn_context records are ~300 bytes and recur at every turn spawn, so
    /// the latest one sits within the tail unless the current turn has
    /// appended more than this since it started.
    private static let tailChunkBytes: UInt64 = 256 * 1024

    /// What a scan of one region concluded — distinguishes "no turn_context
    /// here" (worth scanning further) from "found one, and its verdict is
    /// nil" (pre-0.146 record: the latest record IS the answer, and the
    /// answer is "no signal").
    private enum ScanResult {
        case found(CodexApprovalsReviewer?)
        case noTurnContext
    }

    /// Resolves the posture from the rollout at `transcriptPath`.
    func posture(transcriptPath: String) -> CodexApprovalsReviewer? {
        guard let handle = FileHandle(forReadingAtPath: transcriptPath) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }

        let tailStart = size > Self.tailChunkBytes ? size - Self.tailChunkBytes : 0
        guard
            (try? handle.seek(toOffset: tailStart)) != nil,
            let tail = try? handle.readToEnd()
        else { return nil }

        if case let .found(posture) = scan(tail, isCompleteFromStart: tailStart == 0) {
            return posture
        }

        // No turn_context in the tail. If the tail already covered the whole
        // file there is nothing more to find; otherwise the latest record
        // sits further back — scan the rest (rare, bounded by today's turn).
        guard tailStart > 0 else { return nil }
        guard
            (try? handle.seek(toOffset: 0)) != nil,
            let whole = try? handle.readToEnd()
        else { return nil }
        if case let .found(posture) = scan(whole, isCompleteFromStart: true) {
            return posture
        }
        return nil
    }

    /// Scans one contiguous region for the latest `turn_context` record.
    /// `isCompleteFromStart` is false for a mid-file tail chunk, whose first
    /// line is (in general) the torn remainder of a record and must be
    /// dropped. The decode is deliberately lossy (`String(decoding:)`): a
    /// concurrent append torn mid-multi-byte-character must corrupt only the
    /// torn line (which then fails the JSON parse and is skipped), not fail
    /// the whole region.
    private func scan(_ data: Data, isCompleteFromStart: Bool) -> ScanResult {
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)[...]
        if !isCompleteFromStart {
            lines = lines.dropFirst()
        }

        // Newest wins: walk the candidate lines backward until one PARSES as
        // a real turn_context. The cheap substring pre-filter also matches
        // torn appends and records quoting "turn_context" as a value — those
        // fail the parse and are simply scanned past.
        for line in lines.reversed() where line.contains("\"turn_context\"") {
            guard let payload = turnContextPayload(of: line) else { continue }
            return .found(reviewer(of: payload))
        }
        return .noTurnContext
    }

    /// Parses a candidate line, returning its `payload` only when the line
    /// really is a `turn_context` record.
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
