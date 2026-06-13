import Foundation

/// How Gallager handles the in-app prompt editor (Ctrl-G) when the user's
/// shell config clobbers the `$VISUAL` Gallager sets on tmux panes.
///
/// Gallager points `$VISUAL` at the bundled `gallager edit` CLI so Ctrl-G in
/// Claude Code / Codex opens the in-app prompt editor. Spawned panes run a
/// login shell that sources the user's rc files *after* the session env is
/// applied, so a user with `export VISUAL=<their editor>` in `~/.zshrc` /
/// `~/.bashrc` clobbers Gallager's value. This setting is the user's deliberate
/// choice about what to do about that — Gallager's env is a *default*, never a
/// silent override. See issue #591.
public enum EditorOverrideMode: String, CaseIterable, Identifiable, Sendable {
    /// Probe each launch; on a detected conflict, ask the user (the dialog is
    /// deferred to the first session creation, when Ctrl-G has context). Default.
    case ask
    /// Type `export VISUAL=…` into Gallager's own shell panes so the in-app
    /// editor wins there (keystroke injection — see ``EditorOverride``).
    case overrideInGallagerSessions
    /// Never override, never ask — the user's editor wins everywhere.
    case useMyEditor

    public var id: String {
        rawValue
    }

    /// Short label for the Settings picker.
    public var displayName: String {
        switch self {
        case .ask: "Ask if my shell overrides it"
        case .overrideInGallagerSessions: "Override in Gallager sessions"
        case .useMyEditor: "Use my editor"
        }
    }
}

/// Outcome of the startup `$VISUAL` survival probe (issue #591 §1).
///
/// The trigger is "does Gallager's `$VISUAL` survive the user's rc files?",
/// *not* "does the user have `VISUAL`/`EDITOR` set" — `EDITOR=vim` alone is not
/// a conflict, because both agents resolve `VISUAL` → `EDITOR` and Gallager
/// sets `VISUAL`, so it still wins.
public enum VisualProbeResult: Sendable, Equatable {
    /// The sentinel survived the user's rc files — Gallager's `$VISUAL` wins,
    /// no conflict, the dialog is never shown.
    case intact
    /// rc files overrode (`effectiveValue` = their resolved value) or unset
    /// (`effectiveValue == nil`) the sentinel. Used for the dialog copy and the
    /// suggested rc line.
    case conflict(effectiveValue: String?)
    /// The probe couldn't run faithfully — no bundled CLI, an unknown shell
    /// whose syntax the probe command doesn't parse (e.g. nushell), or a
    /// timeout. Treated as no-conflict; the dialog is never shown.
    case skipped

    /// Whether this result should surface the consent dialog.
    public var isConflict: Bool {
        if case .conflict = self { return true }
        return false
    }

    /// The user's effective `$VISUAL` when a conflict was detected, else nil.
    public var conflictingValue: String? {
        if case let .conflict(value) = self { return value }
        return nil
    }
}

/// Pure, side-effect-free helpers for the consent-based editor override
/// (issue #591). Kept separate from `TmuxService` so the probe-output parser and
/// the per-shell command builders are unit-testable without a tmux server.
public enum EditorOverride {
    /// Sentinel `$VISUAL` value seeded on the probe session via `-e`. If it
    /// survives the user's rc files we read it back unchanged; anything else
    /// (a different value, or empty) means the rc clobbered it.
    public static let probeSentinel = "__gallager_probe__"

    /// Marker the probe's `printf` emits, immediately followed by the resolved
    /// `$VISUAL` value, so we can pick the output line out of the pane capture.
    public static let probeMarker = "GALLAGER_PROBE="

    /// Session-name prefix for the detached probe session. Panes whose session
    /// name carries this prefix are filtered out of every user-facing list
    /// (sidebar, iOS) — see `TmuxService.queryRefreshOutcome`.
    public static let probeSessionPrefix = "__gallager_probe"

    /// The command typed into the probe shell. After the user's rc files run,
    /// this prints `GALLAGER_PROBE=<resolved $VISUAL>` at the first prompt. The
    /// `\n` is a literal backslash-n typed into the shell; `printf` turns it
    /// into a newline so the marker lands on its own line.
    public static let probeCommand = #"printf 'GALLAGER_PROBE=%s\n' "$VISUAL""#

    /// Builds the override line to type into a shell pane (issue #591 §5), or
    /// nil for shells we don't recognize (so they're skipped rather than
    /// corrupted). `visualValue` is the value `$VISUAL` should resolve to —
    /// Gallager's `<gallager> edit` for the override.
    ///
    /// The leading space keeps the line out of history under the common
    /// `HISTCONTROL=ignorespace` (bash) / `setopt HIST_IGNORE_SPACE` (zsh)
    /// setups (best-effort — it's harmless where those aren't set).
    public static func injectionCommand(visualValue: String, shell: String) -> String? {
        switch shellBasename(shell) {
        case "zsh",
             "bash",
             "sh",
             "dash",
             "ksh":
            return " export VISUAL=\(visualValue.posixSingleQuoted)"
        case "fish":
            return " set -gx VISUAL \(visualValue.posixSingleQuoted)"
        default:
            return nil
        }
    }

    /// Whether `pane_current_command` (or a shell path) names a shell we know
    /// how to inject into. Direct-command panes (an agent as the pane command)
    /// return false — they never ran rc files, so the `-e VISUAL` they inherited
    /// is already correct and must not be typed into.
    public static func isKnownShell(_ command: String) -> Bool {
        injectionCommand(visualValue: "x", shell: command) != nil
    }

    /// The guarded rc line suggested by dialog Option 1 (issue #591 §3). Gallager
    /// exports `GALLAGER_SOCKET` into panes *before* rc files run, so the user's
    /// rc can detect a Gallager pane natively and skip its own override there —
    /// keeping their editor in every non-Gallager terminal. `visualValue` here is
    /// the *user's* editor (their probed value), not Gallager's.
    public static func recommendedRcLine(visualValue: String, shell: String) -> String {
        if shellBasename(shell) == "fish" {
            return "set -q GALLAGER_SOCKET; or set -gx VISUAL \(visualValue.posixSingleQuoted)"
        }
        return "[ -n \"$GALLAGER_SOCKET\" ] || export VISUAL=\(visualValue.posixSingleQuoted)"
    }

    /// Parses captured probe output into a result, or nil while the marker line
    /// hasn't appeared yet (the caller keeps polling).
    ///
    /// Scans for the *last* line that begins with ``probeMarker`` after trimming:
    /// the typed command echo (`printf 'GALLAGER_PROBE=%s\n' …`) starts with the
    /// prompt, not the marker, so it's skipped — and even if a narrow terminal
    /// wrapped the echo so a continuation row started with `GALLAGER_PROBE=%s…`,
    /// the real output line always comes after it, so "last match" wins.
    public static func parseProbeOutput(_ captured: String) -> VisualProbeResult? {
        var result: VisualProbeResult?
        for rawLine in captured.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(probeMarker) else { continue }
            let value = String(line.dropFirst(probeMarker.count))
            if value == probeSentinel {
                result = .intact
            } else if value.isEmpty {
                result = .conflict(effectiveValue: nil)
            } else {
                result = .conflict(effectiveValue: value)
            }
        }
        return result
    }

    // MARK: - Helpers

    /// Last path component of a shell, with any leading `-` (login-shell argv[0]
    /// convention) stripped. `pane_current_command` is already a bare name, but
    /// a full `$SHELL` path needs trimming.
    static func shellBasename(_ shell: String) -> String {
        let base = (shell as NSString).lastPathComponent
        return base.hasPrefix("-") ? String(base.dropFirst()) : base
    }
}
