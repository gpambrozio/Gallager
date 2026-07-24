## What & why

<!-- What does this PR change, and what problem does it solve? Link the issue if there is one. -->

## Checklist

- [ ] `swift test` passes in `ClaudeSpyPackage/`
- [ ] New behavior has tests; bug fixes have a test/scenario that reproduces the bug without the fix
- [ ] New features / changed behavior: e2e scenario added or updated and passing (`./scripts/e2e-test.sh --scenario "Name"`)
- [ ] No locally generated e2e screenshot baselines committed (CI owns baselines)
- [ ] New SwiftUI views have `#Preview`s
- [ ] Docs updated where behavior changed (`docs/`, `CLAUDE.md`, CLI help + `gallager` skill if a command changed)
