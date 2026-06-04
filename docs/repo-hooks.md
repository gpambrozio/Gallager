# Repository Claude Code hooks

This repo ships a few **project-scoped Claude Code hooks** in `.claude/settings.json`.
They run for anyone working in the repo with Claude Code and exist to keep the
development workflow consistent. They are unrelated to the `gallager` plugin hooks
(`plugin/**/hooks/`), which forward session events to the monitoring app and never
talk back to the agent.

## PostToolUse hooks

### `Edit|MultiEdit|Write` → swiftformat

After any file edit, an inline command runs `swiftformat` on the file when it is a
`.swift` file. Keeps formatting consistent without a manual step.

### `Bash` → PR checklist (`.claude/hooks/pr-checklist.py`)

Fires after every `Bash` tool call. When the command that just ran opens a pull
request (`gh pr create`), the hook prints a `hookSpecificOutput.additionalContext`
block so the agent finishes the project's post-PR chores before stopping:
documentation/CLAUDE.md updates, CLI + `gallager`-skill updates for new features, and
end-to-end scenarios (with committed baseline screenshots) for new features or bug
fixes. For every other Bash command it prints nothing and exits 0, so it is a no-op.

Matching is intentionally simple: a word-boundary regex for `gh pr create`, tolerant
of env prefixes (`GH_TOKEN=… gh pr create`), `cd … && gh pr create`, and extra
whitespace. It does not try to fully parse the shell, so a command that merely
*mentions* the phrase (an `echo`, a `grep`) will also fire — a harmless false positive
whose only cost is an injected reminder.

#### Output contract

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "Use the Task tool to work through these items before stopping: …"
  }
}
```

See the [PostToolUse hook reference](https://code.claude.com/docs/en/hooks.md#posttooluse).

#### Tests

`.claude/hooks/test_pr_checklist.py` runs the hook as a subprocess (exactly how
Claude Code invokes it) across the fire/silent cases. Stdlib only — no pytest:

```bash
python3 .claude/hooks/test_pr_checklist.py
```
