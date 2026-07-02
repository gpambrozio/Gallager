import Foundation

/// Builds the Codex CLI `-c key=value` launch overrides that point Codex's
/// OpenTelemetry export at the Mac-local OTLP/JSON receiver (issue #602).
///
/// **Why `-c` and not env vars or the config file.** Codex does *not* read
/// `OTEL_*` env vars — OTEL is configured only through its own `config.toml`
/// schema — so the `TmuxService` env injection that serves Claude Code never
/// reaches Codex. And `otel` is on Codex's project-local config denylist, so a
/// repo-local `.codex/config.toml` is ignored for OTEL. The remaining surfaces
/// are the user's global `~/.codex/config.toml` (persistent, risks corrupting
/// the user's own config) and the CLI runtime-override layer (`-c`). We use
/// `-c`: the runtime layer is explicitly *exempt* from the `otel` denylist
/// (verified against codex-rs `config/src/loader/mod.rs`
/// `PROJECT_LOCAL_CONFIG_DENYLIST`, whose comment notes these settings "are
/// still supported from user, system, managed, and runtime config layers"), and
/// it is ephemeral — nothing is written to the user's global config, so a
/// Gallager launch can never corrupt or persist changes to the user's Codex
/// setup. This matches Claude's posture: only app-launched panes are
/// instrumented; a manually-typed `codex` is untouched.
///
/// The emitted settings mirror the `[otel]` schema Codex deserializes (verified
/// against codex-rs `config/src/types.rs` `OtelConfigToml` / `OtelExporterKind`,
/// a kebab-case externally-tagged enum):
/// ```toml
/// [otel]
/// exporter = { otlp-http = { endpoint = "<base>/v1/logs", protocol = "json" } }
/// metrics_exporter = "none"
/// log_user_prompt = false
/// ```
/// expressed as dotted-path overrides (Codex merges them into one `otel` table).
///
/// - **logs only**: the `exporter` (log) channel is the only one that carries
///   `conversation.id` — Codex metrics omit it (openai/codex#15905), so they
///   can't be joined to a pane. `metrics_exporter = "none"` both reflects that
///   and prevents enabling Codex's default Statsig metrics export to OpenAI.
/// - **protocol = json**: so the existing OTLP/JSON `OTLPReceiver` is reused
///   unchanged.
/// - **log_user_prompt = false**: Codex's default, set explicitly so no prompt
///   content ever leaves the process (same privacy posture as #597).
enum CodexOtelConfig {
    /// The ordered `-c <override>` argument list for an OTLP base endpoint (e.g.
    /// `http://127.0.0.1:24318`). Returns `[]` when `endpoint` is `nil` (no
    /// receiver running), so the caller launches Codex with no OTEL overrides.
    ///
    /// Each override value is plain `key=value` text with TOML-quoted string
    /// values; the launch plumbing POSIX-quotes each argument before it reaches
    /// the shell, so the embedded double quotes survive for Codex to parse.
    static func launchOverrides(otlpEndpoint endpoint: URL?) -> [String] {
        guard let endpoint else { return [] }
        let base = endpoint.absoluteString.hasSuffix("/")
            ? String(endpoint.absoluteString.dropLast())
            : endpoint.absoluteString
        let logsEndpoint = "\(base)/v1/logs"
        return [
            "-c", #"otel.exporter.otlp-http.endpoint="\#(logsEndpoint)""#,
            "-c", #"otel.exporter.otlp-http.protocol="json""#,
            "-c", #"otel.metrics_exporter="none""#,
            "-c", #"otel.log_user_prompt=false"#,
        ]
    }
}
