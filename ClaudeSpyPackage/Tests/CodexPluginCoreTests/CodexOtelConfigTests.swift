import Foundation
import Testing
@testable import CodexPluginCore

struct CodexOtelConfigTests {
    @Test("no endpoint → no overrides")
    func noEndpoint() {
        #expect(CodexOtelConfig.launchOverrides(otlpEndpoint: nil).isEmpty)
    }

    @Test("builds the -c otel overrides pointing logs at the receiver's /v1/logs")
    func buildsOverrides() {
        let args = CodexOtelConfig.launchOverrides(otlpEndpoint: URL(string: "http://127.0.0.1:4318"))
        // Four `-c <override>` pairs.
        #expect(args.count == 8)
        // Every override is preceded by a `-c` flag.
        for index in stride(from: 0, to: args.count, by: 2) {
            #expect(args[index] == "-c")
        }
        let overrides = stride(from: 1, to: args.count, by: 2).map { args[$0] }
        #expect(overrides.contains(#"otel.exporter.otlp-http.endpoint="http://127.0.0.1:4318/v1/logs""#))
        #expect(overrides.contains(#"otel.exporter.otlp-http.protocol="json""#))
        // Metrics carry no conversation.id (can't be joined) and we don't want
        // Codex's default Statsig export — disable them.
        #expect(overrides.contains(#"otel.metrics_exporter="none""#))
        // No prompt content leaves the process.
        #expect(overrides.contains(#"otel.log_user_prompt=false"#))
    }

    @Test("honors a non-default receiver port (E2E --otlp-port isolation)")
    func honorsCustomPort() {
        let args = CodexOtelConfig.launchOverrides(otlpEndpoint: URL(string: "http://127.0.0.1:55001"))
        #expect(args.contains(#"otel.exporter.otlp-http.endpoint="http://127.0.0.1:55001/v1/logs""#))
    }

    @Test("a trailing slash on the base endpoint doesn't double the path separator")
    func trimsTrailingSlash() {
        let args = CodexOtelConfig.launchOverrides(otlpEndpoint: URL(string: "http://127.0.0.1:4318/"))
        #expect(args.contains(#"otel.exporter.otlp-http.endpoint="http://127.0.0.1:4318/v1/logs""#))
    }
}
