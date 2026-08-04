import Foundation
import Testing
@testable import ClaudeCodePluginCore

/// Tolerant `tool_input` decoding (issue #717): a surprising `tool_input`
/// shape must never fail the WHOLE hook frame — a dropped `PermissionRequest`
/// means a real TUI prompt with no notification and no form, the exact
/// eaten-prompt failure the permission path fails closed to prevent.
///
/// The known case: codex (and Claude Code) hook payloads carry an MCP tool's
/// RAW arguments as `tool_input` — there is no `{server, tool, input}`
/// wrapper — so `MCPToolParameters`'s required keys threw and the frame
/// dropped. Server and tool are recoverable from the `mcp__<server>__<tool>`
/// name; anything else degrades to `.other` instead of throwing.
@Suite("ClaudeCodeToolDecode")
struct ClaudeCodeToolDecodeTests {
    /// Parses a full PermissionRequest hook payload and returns its decoded
    /// tool input — the level at which a decode throw drops the frame.
    private func toolInput(
        toolName: String,
        toolInputJSON: String
    ) throws -> ClaudeCodeTool? {
        let payload = """
        {
            "hook_event_name": "PermissionRequest",
            "session_id": "sess-1",
            "cwd": "/Users/test/MyProject",
            "tool_name": "\(toolName)",
            "tool_input": \(toolInputJSON)
        }
        """
        let action = try HookAction.from(jsonData: Data(payload.utf8))
        guard case let .permissionRequest(body) = action else {
            Issue.record("expected .permissionRequest, got \(action)")
            return nil
        }
        return body.toolInput
    }

    @Test("an MCP tool_input carrying the tool's raw arguments decodes via the name")
    func mcpRawArgumentsShape() throws {
        let input = try toolInput(
            toolName: "mcp__memory__create_entities",
            toolInputJSON: #"{ "entities": [{ "name": "A" }], "count": 1 }"#
        )
        guard case let .mcp(params) = input else {
            Issue.record("expected .mcp, got \(String(describing: input))")
            return
        }
        #expect(params.server == "memory")
        #expect(params.tool == "create_entities")
        #expect(params.fullToolName == "mcp__memory__create_entities")
        #expect(params.input?["count"] == AnyCodable(1))
    }

    @Test("a tool segment containing double underscores stays intact")
    func mcpToolNameWithDoubleUnderscore() throws {
        let input = try toolInput(
            toolName: "mcp__linear__issue__create",
            toolInputJSON: #"{ "title": "x" }"#
        )
        guard case let .mcp(params) = input else {
            Issue.record("expected .mcp, got \(String(describing: input))")
            return
        }
        #expect(params.server == "linear")
        #expect(params.tool == "issue__create")
    }

    @Test("the wrapped {server, tool, input} MCP shape still decodes")
    func mcpWrappedShape() throws {
        let input = try toolInput(
            toolName: "mcp__memory__create_entities",
            toolInputJSON: #"{ "server": "memory", "tool": "create_entities", "input": { "a": 1 } }"#
        )
        guard case let .mcp(params) = input else {
            Issue.record("expected .mcp, got \(String(describing: input))")
            return
        }
        #expect(params.server == "memory")
        #expect(params.tool == "create_entities")
        #expect(params.input?["a"] == AnyCodable(1))
    }

    @Test("raw arguments that coincidentally carry server/tool keys keep the full payload")
    func mcpRawArgumentsWithCoincidentalWrapperKeys() throws {
        // A tool whose REAL arguments include `server` and `tool` strings
        // (plausible for ssh/db/infra MCP tools) must not decode as the
        // wrapped shape — that would take the wrong identity and silently
        // drop every other argument from the permission form. The wrapped
        // shape is only accepted when it mirrors the tool name.
        let input = try toolInput(
            toolName: "mcp__infra__run_command",
            toolInputJSON: #"{ "server": "prod-1", "tool": "rsync", "command": "rsync -a /src /dst" }"#
        )
        guard case let .mcp(params) = input else {
            Issue.record("expected .mcp, got \(String(describing: input))")
            return
        }
        #expect(params.server == "infra")
        #expect(params.tool == "run_command")
        #expect(params.input?["command"] == AnyCodable("rsync -a /src /dst"))
        #expect(params.input?["server"] == AnyCodable("prod-1"))
    }

    @Test("a non-dictionary tool_input still fails the frame (the tolerant-decode boundary)")
    func nonDictionaryToolInputStillFailsTheFrame() {
        // The deliberate rethrow edge of the tolerant-decode contract: a
        // scalar or array tool_input isn't a tool payload at all, so the
        // frame drops rather than inventing an empty .other.
        #expect(throws: (any Error).self) {
            try toolInput(
                toolName: "mcp__memory__create_entities",
                toolInputJSON: #""echo hi""#
            )
        }
        #expect(throws: (any Error).self) {
            try toolInput(toolName: "Bash", toolInputJSON: "[1, 2, 3]")
        }
    }

    @Test("an mcp__ name without a tool segment degrades to .other")
    func mcpNameWithoutToolSegment() throws {
        let input = try toolInput(
            toolName: "mcp__memory",
            toolInputJSON: #"{ "entities": [] }"#
        )
        guard case let .other(name, _) = input else {
            Issue.record("expected .other, got \(String(describing: input))")
            return
        }
        #expect(name == "mcp__memory")
    }

    @Test("a known tool with a surprising parameter shape degrades to .other, not a dropped frame")
    func knownToolSurprisingShapeDegrades() throws {
        // BashParameters requires `command`; an agent serializing the family
        // differently must degrade, not kill the PermissionRequest.
        let input = try toolInput(
            toolName: "Bash",
            toolInputJSON: #"{ "cmd": "rm -rf build" }"#
        )
        guard case let .other(name, dictionary) = input else {
            Issue.record("expected .other, got \(String(describing: input))")
            return
        }
        #expect(name == "Bash")
        #expect(dictionary["cmd"] == AnyCodable("rm -rf build"))
    }

    @Test("a well-formed known tool still decodes to its typed case")
    func knownToolStillTyped() throws {
        let input = try toolInput(
            toolName: "Bash",
            toolInputJSON: #"{ "command": "swift test", "description": "run tests" }"#
        )
        guard case let .bash(params) = input else {
            Issue.record("expected .bash, got \(String(describing: input))")
            return
        }
        #expect(params.command == "swift test")
    }
}
