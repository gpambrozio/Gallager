# E2E Baseline Review: PR #287 — Add customizable sidebar cell layout

## Expected Changes (from PR description)

- New **Sidebar** preferences tab added to Preferences window toolbar
- Local and remote session sidebar rows unified with shared `SessionFieldsView` rendering fields in configurable order
- Default field ordering: project name + latest event for Claude sessions; current path + command for terminal sessions
- New `sidebar-layout` E2E scenario covering the new preferences UI and various field configurations

## New Images (15 files)

All in `E2ETests/sidebar-layout/` — new test scenario for the sidebar layout feature. Expected.

- `sidebar-layout/01-default-layout.png`
- `sidebar-layout/02-sidebar-settings-default.png`
- `sidebar-layout/03-sidebar-settings-session-command.png`
- `sidebar-layout/04-layout-session-command.png`
- `sidebar-layout/05-sidebar-settings-project-session.png`
- `sidebar-layout/06-layout-project-session.png`
- `sidebar-layout/07-sidebar-settings-terminal-default.png`
- `sidebar-layout/08-sidebar-settings-terminal-session-only.png`
- `sidebar-layout/09-layout-split-claude-terminal.png`
- `sidebar-layout/10-sort-status-priority-idle-first.png`
- `sidebar-layout/11-sort-status-priority.png`
- `sidebar-layout/12-sort-alphabetical.png`
- `sidebar-layout/13-sort-claude-first.png`
- `sidebar-layout/14-sort-recent-activity.png`
- `sidebar-layout/15-sort-session-name.png`

## Deleted Images (8 files)

All in `E2ETests/sidebar-selection/` — this scenario tested the two-section sidebar behavior ("Claude Sessions" / "Terminals") which no longer exists after the unification into a single "Local" section. Deletion is confirmed intentional in the fix commit (`38dd5eb`): "Remove SidebarSelectionScenario (tested two-section behavior that no longer exists)." Expected.

- `sidebar-selection/01-mac-both-in-terminals.png`
- `sidebar-selection/02-mac-pane1-selected.png`
- `sidebar-selection/03-mac-pane1-moved-to-claude-sessions.png`
- `sidebar-selection/04-mac-pane2-selected.png`
- `sidebar-selection/05-mac-pane1-reselected-in-claude-sessions.png`
- `sidebar-selection/06-mac-pane1-back-in-terminals.png`
- `sidebar-selection/07-mac-all-visible-after-session-end.png`
- `sidebar-selection/08-mac-new-session-no-steal.png`

## Dithering Only (107 files)

No meaningful visual differences — sub-pixel rendering artifacts only.

## Changed Images (197 files)

### Expected (non-deterministic content) — 24 files

Images that always differ between test runs due to the randomly generated 6-letter pairing code displayed in the macOS pairing UI.

- `disconnect-ios-unpair-macos/02-mac-code-generated.png`
- `truecolor-rendering-stress/02-mac-code-generated.png`
- `multi-window-tabs-ios/02-mac-code-generated.png`
- `yolo-mode-state-sync/02-mac-code-generated.png`
- `project-search-ios/02-mac-code-generated.png`
- `table-rendering/02-mac-code-generated.png`
- `da-response-leak/02-mac-code-generated.png`
- `terminal-title-mac-to-ios/02-mac-code-generated.png`
- `claude-session-replies-persist/02-mac-code-generated.png`
- `claude-sessions-show/02-mac-code-generated.png`
- `yolo-mode-auto-approve/02-mac-code-generated.png`
- `emoji-table-rendering/02-mac-code-generated.png`
- `unpair-from-macos/02-mac-code-generated.png`
- `stop-hook-summary/02-mac-code-generated.png`
- `window-description-sync/02-mac-code-generated.png`
- `mark-handled/02-mac-code-generated.png`
- `terminal-links/02-mac-code-generated.png`
- `unpair-from-ios/02-mac-code-generated.png`
- `claude-session-updates/02-mac-code-generated.png`
- `new-terminal/02-mac-code-generated.png`
- `footer-rendering/02-mac-code-generated.png`
- `multi-pane-ios/02-mac-code-generated.png`
- `terminal-notification/02-mac-code-generated.png`
- `disconnect-macos-unpair-ios/02-mac-code-generated.png`

---

### Expected Changes

#### ✅ Preferences window — new Sidebar tab in toolbar (37 files)

**What changed:** The Preferences window toolbar gained a new "Sidebar" tab between "General" and "Remote Access." Main had 5 tabs (General, Remote Access, Remote Hosts, Plugin, About); current has 6 (General, **Sidebar**, Remote Access, Remote Hosts, Plugin, About). The pairing date shown in the Paired Viewers list also differs between test runs. `stop-hook-summary/04` additionally shows a "Connecting…" state rather than "Connected" due to test timing, which explains its slightly higher diff (0.19% vs 0.18% for the others).

**Maps to:** New Sidebar preferences tab added by this PR.

- `stop-hook-summary/04-mac-connected.png`
- `disconnect-macos-unpair-ios/05-mac-after-disconnect.png`
- `claude-session-replies-persist/04-mac-connected.png`
- `claude-session-updates/04-mac-connected.png`
- `claude-sessions-show/04-mac-connected.png`
- `da-response-leak/04-mac-connected.png`
- `disconnect-ios-unpair-macos/04-mac-connected.png`
- `disconnect-macos-unpair-ios/04-mac-connected.png`
- `emoji-table-rendering/04-mac-connected.png`
- `multi-pane-ios/04-mac-connected.png`
- `multi-window-tabs-ios/04-mac-connected.png`
- `new-terminal/04-mac-connected.png`
- `project-search-ios/04-mac-connected.png`
- `table-rendering/04-mac-connected.png`
- `terminal-links/04-mac-connected.png`
- `terminal-notification/04-mac-connected.png`
- `terminal-title-mac-to-ios/04-mac-connected.png`
- `truecolor-rendering-stress/04-mac-connected.png`
- `unpair-from-ios/04-mac-connected.png`
- `unpair-from-macos/04-mac-connected.png`
- `unpair-from-macos/05-mac-before-unpair.png`
- `window-description-sync/04-mac-connected.png`
- `yolo-mode-auto-approve/04-mac-connected.png`
- `yolo-mode-state-sync/04-mac-connected.png`
- `footer-rendering/04-mac-connected.png`
- `mark-handled/04-mac-connected.png`
- `two-mac-pairing/01-host-after-pairing.png`
- `two-mac-pairing/03-host-connected.png`
- `yolo-mode-mac-to-mac/01-host-after-pairing.png`
- `yolo-mode-mac-to-mac/03-host-connected.png`
- `two-mac-pairing/02-viewer-after-pairing.png`
- `two-mac-pairing/04-viewer-connected.png`
- `yolo-mode-mac-to-mac/02-viewer-after-pairing.png`
- `yolo-mode-mac-to-mac/04-viewer-connected.png`
- `disconnect-ios-unpair-macos/06-mac-after-unpair.png`
- `disconnect-macos-unpair-ios/08-mac-invalid-pair-cleanup.png`
- `unpair-from-macos/06-mac-after-unpair.png`

---

#### ✅ Sidebar section headers renamed + row fields changed (133 files)

**What changed:** Two simultaneous changes visible in all screenshots showing the main Available Windows app window:

1. **Section headers renamed:** "Terminals" and "Claude Sessions" sections merged into a single "Local" section. In main, plain terminal sessions appeared under "Terminals" and Claude sessions appeared under "Claude Sessions." In current, both appear under "Local." This is confirmed intentional in commit `38dd5eb`: "sidebar unification (separate Claude Sessions/Terminals sections → single Local section)."

2. **Sidebar row fields changed:** Default field ordering now shows project name + latest event for Claude sessions (previously: session name + command), and current path + command for terminal sessions (previously: session name + command). `terminal-title-persistence` images show the terminal title field appearing when set. This is the `SessionFieldsView` change.

**Maps to:** "Unifies local and remote session sidebar rows with a shared `SessionFieldsView` that renders fields in user-configurable order."

- `two-mac-pairing/05-viewer-sees-remote-pane.png`
- `two-mac-pairing/06-viewer-pane-selected.png`
- `two-mac-pairing/07-host-shows-command.png`
- `yolo-mode-context-compaction/03-mac-session-ended-yolo-cleared.png`
- `cursor-style-changes/01-mac-cursor-steady-block.png`
- `terminal-title-persistence/05-mac-pane2-title-displayed.png`
- `resize-pane/06-mac-resize-second-pane.png`
- `terminal-title-persistence/02-mac-pane2-selected.png`
- `table-rendering/05-mac-table-streamed.png`
- `table-rendering/07-mac-table-after-recapture.png`
- `always-auto-resize-preference/02-mac-new-session-inherits.png`
- `emoji-table-rendering/05-mac-emoji-tables-streamed.png`
- `emoji-table-rendering/07-mac-emoji-tables-recapture.png`
- `resize-pane/07-mac-resize-per-session-independence.png`
- `terminal-title-mac-to-ios/10-host-before-inactive-title-check.png`
- `terminal-title-mac-to-ios/11-host-inactive-pane-title.png`
- `terminal-title-persistence/04-mac-pane2-title-in-sidebar.png`
- `yolo-mode-mac-to-mac/10-host-yolo-enabled-from-viewer.png`
- `mark-handled/30-host-working-final.png`
- `yolo-mode-auto-approve/09-mac-yolo-auto-approved.png`
- `multi-window-tabs/02-mac-two-window-tabs.png`
- `multi-window-tabs/06-mac-three-window-tabs.png`
- `multi-window-tabs/07-mac-after-close-window-1.png`
- `yolo-mode-mac-to-mac/09-host-yolo-disabled-from-viewer.png`
- `mark-handled/26-host-still-attention-after-host-select.png`
- `terminal-title-mac-to-mac/02-host-custom-title.png`
- `da-response-leak/05-mac-after-da1.png`
- `da-response-leak/06-mac-both-after-da1.png`
- `terminal-title-persistence/01-mac-pane1-title-set.png`
- `terminal-title-persistence/03-mac-pane1-title-persisted.png`
- `always-auto-resize-preference/04-mac-global-off-no-resize.png`
- `yolo-mode-context-compaction/02-mac-yolo-preserved-after-compaction.png`
- `yolo-mode-context-compaction/04-mac-new-session-yolo-off.png`
- `always-auto-resize-preference/03-mac-per-session-opt-out.png`
- `cursor-style-changes/02-mac-cursor-steady-underline.png`
- `cursor-style-changes/03-mac-cursor-steady-bar.png`
- `cursor-style-changes/04-mac-cursor-hidden.png`
- `cursor-style-changes/05-mac-cursor-visible.png`
- `resize-pane/04-mac-resize-window-smaller.png`
- `resize-pane/05-mac-resize-auto-resize.png`
- `terminal-title-mac-to-mac/04-host-updated-title.png`
- `yolo-mode-context-compaction/01-mac-yolo-enabled-before-compaction.png`
- `terminal-title-mac-to-ios/08-host-updated-title.png`
- `rapid-keystroke-order/01-host-after-keystrokes.png`
- `yolo-mode-mac-to-mac/07-host-shows-command.png`
- `resize-pane/01-mac-resize-initial-state.png`
- `kitty-keyboard-protocol/01-mac-kitty-script-output.png`
- `kitty-keyboard-protocol/02-mac-kitty-protocol-filtered.png`
- `terminal-title-mac-to-ios/06-host-custom-title.png`
- `terminal-title-mac-to-mac/01-host-default-title.png`
- `multi-window-tabs-mac-viewer/08-host-after-window-close.png`
- `mouse-support/02-after-scroll.png`
- `mouse-support/03-after-clicks.png`
- `scrollback-gap-small-mirror/01-mac-initial-bottom-view.png`
- `scrollback-gap-small-mirror/02-mac-scrolled-up-page3.png`
- `scrollback-gap-small-mirror/03-mac-scrolled-up-page2.png`
- `scrollback-gap-small-mirror/04-mac-scrolled-up-page1.png`
- `mouse-support/01-mouse-mode-connected.png`
- `multi-window-tabs-mac-viewer/07-host-reflects-window1.png`
- `multi-window-tabs-mac-viewer/01-host-window0-selected.png`
- `multi-window-tabs-mac-viewer/04-host-follows-viewer-to-window1.png`
- `terminal-title-mac-to-ios/05-host-default-title.png`
- `terminal-title-mac-to-mac/03-viewer-custom-title.png`
- `terminal-title-mac-to-mac/05-viewer-updated-title.png`
- `stop-hook-summary/10-mac-stop-session.png`
- `multi-window-tabs/05-mac-reselect-opens-active-window.png`
- `truecolor-rendering-stress/09-mac-v3-small-cool-grid.png`
- `terminal-rendering-bugs/02-mac-h17-after-recapture-sgr-divergence.png`
- `terminal-rendering-bugs/03-mac-scrollback-before-recapture.png`
- `terminal-rendering-bugs/01-mac-h17-before-recapture-magenta-active.png`
- `terminal-rendering-bugs/04-mac-scrollback-after-recapture.png`
- `mark-handled/31-viewer-working-final.png`
- `multi-pane-window/03-mac-three-panes-final-layout.png`
- `multi-window-tabs-ios/07-mac-shows-window-1-after-ios-switch.png`
- `file-browser/16-mac-window-switch-no-file-browser.png`
- `always-auto-resize-preference/01-mac-global-auto-resize-on.png`
- `multi-window-tabs/03-mac-switched-to-window-0.png`
- `multi-window-tabs/04-mac-switched-to-window-1.png`
- `multi-pane-window/04-mac-all-panes-with-extra-content.png`
- `multi-pane-window/05-mac-two-panes-after-exit.png`
- `multi-pane-window/08-mac-three-panes-new-session.png`
- `multi-pane-window/01-mac-single-pane.png`
- `terminal-links/05-mac-terminal-links.png`
- `truecolor-rendering-stress/07-mac-v2-wide-warm-boxes.png`
- `truecolor-rendering-stress/11-mac-v4-full-width-bars.png`
- `truecolor-rendering-stress/05-mac-v1-standard-gradients.png`
- `truecolor-rendering-stress/13-mac-v5-dense-rainbow-grid.png`
- `multi-pane-window/02-mac-two-panes-vertical-split.png`
- `multi-pane-window/06-mac-single-pane-after-exits.png`
- `file-browser/01-mac-terminal-view-baseline.png`
- `resize-pane/08-mac-resize-pane-switch-auto-resize.png`
- `multi-pane-window/09-mac-last-should-have-echo.png`
- `file-browser/06-mac-video-player.png`
- `file-browser/08-mac-unsupported-file.png`
- `file-browser/02-mac-file-browser-empty-selection.png`
- `file-browser/03-mac-text-file-viewer.png`
- `file-browser/04-mac-image-viewer.png`
- `file-browser/05-mac-pdf-viewer.png`
- `file-browser/07-mac-html-viewer.png`
- `file-browser/09-mac-loading-indicator.png`
- `file-browser/10-mac-pending-file-loaded.png`
- `file-browser/11-mac-markdown-viewer.png`
- `file-browser/12-mac-deep-nested-file.png`
- `file-browser/13-mac-docs-nested-markdown.png`
- `file-browser/14-mac-terminal-restored.png`
- `file-browser/15-mac-file-browser-state-preserved.png`
- `multi-window-tabs/01-mac-single-window-with-tab.png`
- `empty-state-new-session/03-mac-terminal-created.png`
- `resize-pane/03-mac-resize-manual-resize.png`
- `resize-pane/02-mac-resize-after-manual.png`
- `footer-rendering/05-mac-footer-full-terminal.png`
- `mark-handled/12-host-working.png`
- `window-description-sync/11-host-after-add.png`
- `window-description-sync/16-host-after-viewer-edit.png`
- `mark-handled/05-host-attention.png`
- `mark-handled/15-host-attention-after-stop.png`
- `mark-handled/21-host-attention-permission.png`
- `mark-handled/24-host-still-attention-after-permission-handle.png`
- `window-description-sync/06-host-before-description.png`
- `mark-handled/09-host-idle-after-ios-handle.png`
- `mark-handled/18-host-idle-after-viewer-handle.png`
- `window-description-sync/09-host-alert-add.png`
- `window-description-sync/10-host-alert-add-typed.png`
- `multi-window-tabs-mac-viewer/03-viewer-window1-selected.png`
- `multi-window-tabs-mac-viewer/05-viewer-window2-created.png`
- `multi-window-tabs-mac-viewer/06-viewer-back-to-window1.png`
- `multi-window-tabs-mac-viewer/02-viewer-window0-selected.png`
- `multi-window-tabs-mac-viewer/09-viewer-after-window-close.png`
- `yolo-mode-mac-to-mac/05-viewer-sees-remote-pane.png`
- `yolo-mode-mac-to-mac/06-viewer-pane-selected.png`
- `window-description-sync/05-viewer-panes-opened.png`
- `window-description-sync/07-viewer-before-description.png`
- `window-description-sync/19-viewer-after-remove.png`

---

#### Minor iOS non-deterministic (2 files)

**What changed:** Terminal content scrolled slightly differently between test runs — one extra terminal history line visible at the top of the terminal view. Layout and navigation are identical to main.

- `project-search-ios/07-ios-project-selected.png`
- `claude-session-replies-persist/07-ios-prompt-filled.png`

---

### Unexpected Changes

#### ❌ `terminal-links/03-ios-paired.png`

**What changed:** The iOS Sessions list shows "Disconnected" (red dot) and "Host offline" instead of the expected "Connected" (green dot) and "No active sessions." The step name (`ios-paired`) implies the device should be paired and connected at this point.

**Why unexpected:** This connection state failure is not mentioned in the PR description. The PR touches only sidebar row rendering and Preferences UI — not networking or iOS session display. This is most likely test flakiness (relay connection timing during CI), but it cannot be explained by the PR's stated changes and warrants attention before merging.

---

## Summary

| Category | Count |
|----------|-------|
| New images | 15 |
| Deleted images | 8 |
| Dithering only | 107 |
| Non-deterministic content | 24 |
| Preferences window (new Sidebar tab) | 37 |
| Sidebar section + row field changes | 133 |
| iOS non-deterministic terminal scroll | 2 |
| **Unexpected changes** | **1** |
| **Total changed** | **197** |
