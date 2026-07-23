# Contributing to Gallager

Thanks for your interest! Issues and pull requests are welcome.

## Before you start

- **Bugs / features** — open a [GitHub issue](https://github.com/gpambrozio/Gallager/issues)
  first for anything non-trivial so we can agree on the approach.
- **Security issues** — never open a public issue; see [SECURITY.md](SECURITY.md).

## Project layout

Almost all code lives in the Swift package, not the Xcode project:

| Area | Where |
|---|---|
| macOS app | `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/` |
| iOS app | `ClaudeSpyPackage/Sources/ClaudeSpyFeature/` |
| Shared networking | `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/` |
| Encryption | `ClaudeSpyPackage/Sources/ClaudeSpyEncryption/` |
| Relay server | `ClaudeSpyPackage/Sources/ClaudeSpyExternalServer/` |
| Sidecar plugins | `plugins/` (Python; see [docs/plugins/sidecar-authoring.md](docs/plugins/sidecar-authoring.md)) |

Internal target names still say "ClaudeSpy" — that's the project's pre-rename
name, same codebase.

## Building and testing

- Requires a recent Xcode (Swift 6.3+ toolchain), macOS 15+, and tmux.
- Mac app: open `ClaudeSpy.xcworkspace`, scheme `ClaudeSpyServer`.
  iOS app: scheme `ClaudeSpy`.
- Unit tests: `swift test` in `ClaudeSpyPackage/`.
- End-to-end suite: `./scripts/e2e-test.sh` (see [docs/e2e-testing.md](docs/e2e-testing.md)).
  E2E screenshot baselines are CI-generated — don't commit locally regenerated
  baselines.
- Tip: `git clone --filter=blob:none` makes the first clone much faster.

## Code conventions

The short version (full details in [CLAUDE.md](CLAUDE.md) and
[docs/swift-patterns.md](docs/swift-patterns.md)):

- SwiftUI with native data flow (`@State`, `@Observable`, `@Environment`) — no
  ViewModels.
- Swift Concurrency only (`@MainActor` UI, actors for I/O) — no GCD.
- [Point-Free Dependencies](https://github.com/pointfreeco/swift-dependencies)
  for services that wrap system APIs or perform I/O.
- SwiftFormat runs via a repo hook; match the existing style.
- Fail fast with descriptive errors; no empty catch blocks.

## Pull requests

- Keep PRs focused — unrelated changes belong in separate PRs.
- Make sure `swift test` passes; add tests for new behavior.
- By contributing you agree your work is licensed under the project's
  [AGPL-3.0 license](LICENSE).
