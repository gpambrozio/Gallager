---
name: install
description: Install app on one or multiple targets
argument-hint: Can be "all" or any combination of "ios", "mac", "server"
disable-model-invocation: true
allowed-tools:
  - Bash(op signin *)
  - Bash(osascript *)
  - Bash(scripts/deploy.sh)
  - Bash(*/ClaudeCodePlugins/XcodeBuildTools/*/scripts/*.py)
  - Skill(XcodeBuildTools:*)
---

# Install / Deploy

Build and deploy ClaudeSpy to one or more targets. Parse `$ARGUMENTS` to determine which targets to act on. If no arguments or "all" is specified, run all three targets in the order below.

Valid targets: `ios`, `mac`, `server` (case-insensitive, any combination).

## Execution Order

Always follow this exact sequence — skip steps whose target wasn't requested.

### 1. Sign into 1Password (server only)

Run this before the server deploy so credentials are available:

```bash
op signin --account OKIDD7RZWVFWPDPZSBA4O4BSPI
```

Only needed when deploying the server.

### 2. Kill the macOS app (mac only)

```bash
osascript -e 'quit app "Gallager"'
```

The app's process name is "Gallager" — `pkill`/`killall` don't work reliably for this app, so always use `osascript`. After quitting, wait a few seconds to ensure the process has exited before proceeding and double-check as even `osascript` can sometimes fail silently.

### 3. Deploy the server (server only)

```bash
scripts/deploy.sh
```

This script handles pre-deploy checks (release build + tests), rsync to the remote host, Docker build, container restart, Caddy reload, and health check. If it fails, **stop immediately** — report the error and suggest how to fix it. Do not continue to subsequent targets.

### 4. Build and run the macOS app (mac only)

Use the `XcodeBuildTools:xcodebuild` skill to build scheme `ClaudeSpyServer`, then the `XcodeBuildTools:macos-app` skill to launch the built app.

### 5. Build and install the iOS app (ios only)

Use the `XcodeBuildTools:device-app` skill to build scheme `ClaudeSpy`, install it on the `myiPhone` device, and launch it. If the device is not connected, let the user know and move on.
