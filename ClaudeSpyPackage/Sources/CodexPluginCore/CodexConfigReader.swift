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
/// except when a top-level `profile = "<name>"` is set and
/// `[profiles.<name>]` overrides the key — then the profile value wins,
/// matching Codex's own config resolution. Missing file, missing key, or an
/// unknown value all degrade to `.user` (notify-anyway, today's behavior).
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
    /// active profile's key when both `profile` and `[profiles.<name>]` exist.
    static func approvalsReviewer(fromTOML toml: String) -> CodexApprovalsReviewer {
        var topLevelReviewer: String?
        var activeProfile: String?
        var profileReviewers: [String: String] = [:]

        // nil while scanning top-level keys (TOML: only lines before the first
        // section header are top-level).
        var currentSection: String?

        for rawLine in toml.split(separator: "\n", omittingEmptySubsequences: false) {
            // `.whitespacesAndNewlines` also strips the `\r` of CRLF files.
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("[") {
                currentSection = sectionName(of: line) ?? ""
                continue
            }

            guard let (key, value) = keyValue(of: line) else { continue }

            if currentSection == nil {
                if key == "approvals_reviewer" { topLevelReviewer = value }
                if key == "profile" { activeProfile = value }
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

    // MARK: - Config-file FSEvents matching

    /// True when an FSEvents path concerns the config file: the file itself or
    /// an ancestor directory (coalesced / must-scan-subdirs events report the
    /// directory). Used to filter the recursive CODEX_HOME watch down to
    /// `config.toml` changes, ignoring the busy `sessions/` tree.
    static func isConfigEvent(eventPath: String, configPath: String) -> Bool {
        var normalized = eventPath
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        if normalized == configPath { return true }
        let directoryPrefix = normalized.hasSuffix("/") ? normalized : normalized + "/"
        return configPath.hasPrefix(directoryPrefix)
    }

    // MARK: - Line scanning helpers

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

    /// `profiles.work` / `profiles."work"` → `work`; `nil` for non-profile
    /// sections.
    private static func profileName(of section: String) -> String? {
        guard section.hasPrefix("profiles.") else { return nil }
        let raw = String(section.dropFirst("profiles.".count))
            .trimmingCharacters(in: .whitespaces)
        return unquote(raw)
    }

    /// Splits `key = "value"` into (key, unquoted value); `nil` when the line
    /// is not a simple assignment.
    private static func keyValue(of line: String) -> (key: String, value: String)? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
        let rawValue = String(line[line.index(after: eq)...])
            .trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !rawValue.isEmpty else { return nil }
        return (key, unquote(rawValue))
    }

    /// Strips one level of `"…"` / `'…'` quoting (ignoring anything after the
    /// closing quote, e.g. a trailing comment). Bare values are cut at a `#`
    /// comment and trimmed.
    private static func unquote(_ value: String) -> String {
        guard let first = value.first else { return value }
        if first == "\"" || first == "'" {
            let rest = value.dropFirst()
            guard let close = rest.firstIndex(of: first) else {
                // Unterminated quote — be liberal, take the rest.
                return String(rest).trimmingCharacters(in: .whitespaces)
            }
            return String(rest[..<close])
        }
        if let hash = value.firstIndex(of: "#") {
            return String(value[..<hash]).trimmingCharacters(in: .whitespaces)
        }
        return value
    }
}
