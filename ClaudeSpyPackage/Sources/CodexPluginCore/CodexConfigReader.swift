import Foundation

// MARK: - CodexApprovalsReviewer

/// The effective `approvals_reviewer` posture from a Codex `config.toml`.
///
/// When the reviewer is `auto_review` (legacy spelling `guardian_subagent`)
/// and the approval policy is `on-request`/granular, Codex routes tool
/// approvals to its guardian subagent instead of the user — the guardian's
/// outcome is a binary allow/deny that never escalates to a TUI prompt. The
/// reviewer is a sticky global preference: the TUI persists every "Approve for
/// me" toggle to `config.toml` immediately, so the file is a live source of
/// truth for mid-session switches.
enum CodexApprovalsReviewer: Sendable, Equatable {
    /// Approvals are presented to the user (Codex default).
    case user
    /// Approvals are routed to the guardian subagent ("Approve for me").
    case autoReview
}

// MARK: - CodexConfigReader

/// Reads the effective `approvals_reviewer` for a CODEX_HOME root from its
/// `config.toml`.
///
/// Deliberately NOT a full TOML parser (spec §13 — tolerant of hostile
/// on-disk data, degrades instead of trapping): a line scanner that resolves
/// the one key we care about. Only the top-level `approvals_reviewer` counts,
/// except when a top-level `profile = "<name>"` is set and the active
/// profile overrides the key (either as a `[profiles.<name>]` section or as
/// a dotted key, `profiles.<name>.approvals_reviewer = …`) — then the
/// profile value wins, matching Codex's own config resolution.
///
/// Every ambiguity degrades toward `.user` (notify-anyway, today's
/// behavior), the same direction as Codex's strict parser rejecting a
/// malformed file: missing file/key, unknown values, unterminated quotes,
/// and assignments hidden inside multi-line strings all resolve to `.user`.
/// Known accepted gap: profiles expressed as inline tables
/// (`profiles = { work = { … } }`) are invisible — Codex never writes them.
struct CodexConfigReader: Sendable {
    /// Reads `<codexHome>/config.toml` and resolves the reviewer.
    func approvalsReviewer(codexHome: URL) -> CodexApprovalsReviewer {
        let url = codexHome.appendingPathComponent("config.toml")
        guard let toml = try? String(contentsOf: url, encoding: .utf8) else {
            return .user
        }
        return Self.approvalsReviewer(fromTOML: toml)
    }

    /// Resolves the reviewer from TOML text: top-level key, overridden by the
    /// active profile's key when both `profile` and a profile entry exist.
    static func approvalsReviewer(fromTOML toml: String) -> CodexApprovalsReviewer {
        var topLevelReviewer: String?
        var activeProfile: String?
        var profileReviewers: [String: String] = [:]

        // nil while scanning top-level keys (TOML: only lines before the first
        // section header are top-level).
        var currentSection: String?
        // Non-nil while inside a `"""…"""` / `'''…'''` value: its body is
        // opaque, so a literal `approvals_reviewer = …` line inside it must
        // not parse as a real assignment.
        var multilineDelimiter: String?

        for rawLine in toml.split(separator: "\n", omittingEmptySubsequences: false) {
            // `.whitespacesAndNewlines` also strips the `\r` of CRLF files.
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if let delimiter = multilineDelimiter {
                if line.contains(delimiter) { multilineDelimiter = nil }
                continue
            }

            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("[") {
                // A section header closes its bracket at end-of-line (modulo
                // a trailing comment). A nested-array continuation line like
                // `["read", "/tmp"],` doesn't, and must not end top-level
                // scanning. A malformed-but-bracketed header still ends it —
                // a strict parser would reject the file, so degrading to
                // "stop trusting top-level keys" matches the `.user`
                // direction.
                let header = withoutTrailingComment(line)
                if header.hasSuffix("]") {
                    currentSection = sectionName(of: header) ?? ""
                }
                continue
            }

            if let delimiter = multilineOpenDelimiter(of: line) {
                multilineDelimiter = delimiter
                continue
            }

            guard let (key, value) = keyValue(of: line) else { continue }

            if currentSection == nil {
                if key == "approvals_reviewer" { topLevelReviewer = value }
                if key == "profile" { activeProfile = value }
                // Dotted-key spelling of a profile override:
                // `profiles.work.approvals_reviewer = "user"`.
                if
                    key.hasPrefix("profiles."), key.hasSuffix(".approvals_reviewer"),
                    let profile = dottedProfileName(
                        of: key.dropFirst("profiles.".count)
                    ) {
                    profileReviewers[profile] = value
                }
            } else if currentSection == "profiles" {
                // `[profiles]` table with dotted keys:
                // `work.approvals_reviewer = …`.
                if
                    key.hasSuffix(".approvals_reviewer"),
                    let profile = dottedProfileName(of: Substring(key)) {
                    profileReviewers[profile] = value
                }
            } else if
                key == "approvals_reviewer",
                let profile = currentSection.flatMap(profileName(of:)) {
                profileReviewers[profile] = value
            }
        }

        let effective = activeProfile.flatMap { profileReviewers[$0] } ?? topLevelReviewer
        switch effective {
        case "auto_review",
             "guardian_subagent": return .autoReview
        default: return .user
        }
    }

    // MARK: - Line scanning helpers

    /// `profiles.work` / `profiles."work"` → `work`; `nil` for non-profile
    /// sections.
    private static func profileName(of section: String) -> String? {
        guard section.hasPrefix("profiles.") else { return nil }
        let raw = String(section.dropFirst("profiles.".count))
            .trimmingCharacters(in: .whitespaces)
        return unquote(raw)
    }

    /// The profile segment of a dotted reviewer key with the `profiles.`
    /// prefix already removed: `work.approvals_reviewer` / `"work".approvals_reviewer`
    /// → `work`. `nil` when empty or malformed.
    private static func dottedProfileName(of key: Substring) -> String? {
        let middle = String(key.dropLast(".approvals_reviewer".count))
            .trimmingCharacters(in: .whitespaces)
        guard let name = unquote(middle), !name.isEmpty else { return nil }
        return name
    }

    /// `[profiles.work]` → `profiles.work` (also tolerates `[[…]]`).
    /// `nil` when the bracket never closes.
    private static func sectionName(of line: String) -> String? {
        var body = Substring(line)
        while body.hasPrefix("[") {
            body.removeFirst()
        }
        guard let close = body.firstIndex(of: "]") else { return nil }
        return String(body[..<close]).trimmingCharacters(in: .whitespaces)
    }

    /// Cuts a trailing `#` comment and trims. Quote-blind — only used on
    /// section-header lines, where a `#` inside a quoted key is implausible.
    private static func withoutTrailingComment(_ line: String) -> String {
        guard let hash = line.firstIndex(of: "#") else { return line }
        return String(line[..<hash]).trimmingCharacters(in: .whitespaces)
    }

    /// When the line is an assignment whose value opens a multi-line string
    /// (`key = """` / `key = '''` without the closing delimiter on the same
    /// line), returns that delimiter.
    private static func multilineOpenDelimiter(of line: String) -> String? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let value = String(line[line.index(after: eq)...])
            .trimmingCharacters(in: .whitespaces)
        for delimiter in ["\"\"\"", "'''"] where value.hasPrefix(delimiter) {
            if !value.dropFirst(delimiter.count).contains(delimiter) {
                return delimiter
            }
        }
        return nil
    }

    /// Splits `key = "value"` into (key, unquoted value); `nil` when the line
    /// is not a simple assignment or the value is malformed.
    private static func keyValue(of line: String) -> (key: String, value: String)? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
        let rawValue = String(line[line.index(after: eq)...])
            .trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !rawValue.isEmpty, let value = unquote(rawValue) else {
            return nil
        }
        return (key, value)
    }

    /// Strips one level of `"…"` / `'…'` quoting (ignoring anything after the
    /// closing quote, e.g. a trailing comment). Bare values are cut at a `#`
    /// comment and trimmed. An UNTERMINATED quote returns `nil` — a torn or
    /// truncated write must fail closed toward `.user`, the same direction as
    /// Codex's own strict parser rejecting the file.
    private static func unquote(_ value: String) -> String? {
        guard let first = value.first else { return value }
        if first == "\"" || first == "'" {
            let rest = value.dropFirst()
            guard let close = rest.firstIndex(of: first) else { return nil }
            return String(rest[..<close])
        }
        if let hash = value.firstIndex(of: "#") {
            return String(value[..<hash]).trimmingCharacters(in: .whitespaces)
        }
        return value
    }
}
