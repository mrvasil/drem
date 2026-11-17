# Changelog

User-visible changes are recorded here. Version numbers correspond to the
application bundle.

## Unreleased

### Added

- Highlight confirmed Claude permission/question waits with amber symbols,
  prioritized overview, an alert creature expression and privacy-safe labels. Ignore text
  guesses and ordinary idle notifications; native Codex pending requests are
  not exposed by its persisted event channel and remain unsupported.
- Make island swipes follow the fingers, squeeze and settle on release; add
  compact restore previews, cancellation/reversal, a single threshold haptic
  and reduced-motion feedback without new polling.
- Distinguish working, reading, editing, tool use and context compaction with
  native action icons across the island overview, session cards and details,
  including when public status text is hidden; reuse existing activity events.
- Add opt-in drem Island on built-in notched MacBook displays, including
  fullscreen Spaces: hover summary, click expansion, per-session projects and
  source-backed actions, upward dismissal until the next work cycle.
- Prefer Codex's short public operation heading, with bounded public-message
  excerpts as fallback; never display summary bodies, raw reasoning or tool
  output. Reuse existing transcript reads; keep diagnostic CLI output unchanged.
- Respect Reduce Motion, Reduce Transparency and Increase Contrast; tear down
  animation and pointer observation when hidden, locked or the lid is closed.
- Add expressive geometric agent characters, a wide session overview, cursor gaze,
  interruptible spring transitions and a selected-agent detail view with a
  compact session rail, project reveal and privacy-aware status copying.
- Fit the compact island to the menu-bar height; restore by sideways trackpad
  gesture or click at the camera, with an invisible click area below the notch.
  Show actual sleep protection, per-agent completion notices, saved session names,
  stable folder characters and interactive reactions without new polling.
- Give every project folder a stable, locally generated blob character: seven original
  silhouettes, a wide deterministic pastel colour space and small facial variations
  derived only from the normalized folder. Reading, editing, tool use, compaction, attention
  and completion use distinct Core Animation expressions without dependencies
  or a new frame timer.
- Add explicit terminal-tab/pane navigation by PID/start time and TTY for iTerm2
  and Ghostty versions exposing terminal TTY; reject ambiguity and unsupported
  versions without guessing. Automation runs only on click, off the main thread.

### Fixed

- Return sleep control to macOS after the final agent finishes, preserving
  closed lid use with an external monitor instead of requesting immediate sleep.
- Make every agent in one folder share the same character while keeping different
  folders out of the old seven-colour collision buckets.
- Recover the island from current display/session/lid state instead of sticky
  notification flags. Reassert it after Space changes and rebuild its hosting
  view on an explicit Show command, including when no agent is working.
  Clear manual-wake dismissal when that session ends; prevent obsolete animation
  callbacks and repeated refreshes from keeping hidden hosts alive.
  Serialize notification handling outside the current view-update stack to
  prevent reentrant SwiftUI layout crashes during host creation.
  Reassert the island after another application or Space becomes active, and
  detach/reattach only when WindowServer confirms the settled surface is off-screen.
  This preserves Ghostty recovery without blinking on every desktop switch.
  Scope island preference notifications to its own UserDefaults store so an
  unrelated settings write cannot clear a transient display/lock/lid block.
- Keep the project folder as the primary island heading, with the saved session
  title beneath it instead of replacing the folder; retain both in tooltips.
- Hide the island with left/right/up swipes and restore only the compact view
  with left/right/down swipes. Prevent a single gesture or its momentum from
  toggling visibility twice; preserve expanded content scrolling.
- Attach the island's square top corners to the screen edge and round only the
  lower corners, sharing the geometry with mouse hit testing.
- Keep Codex and Claude working during context compaction, including synthetic
  final-summary messages and post-compaction SessionStart. Add PreCompact and
  PostCompact hooks, a compacting status, manual/automatic return semantics and
  millisecond hook ordering; actual completion and process exit still stop work.
- Open the tray panel on the first click even when the accessory app remains
  inactive, with its content preloaded and no delayed expanding animation.
- Keep closed-lid protection recoverable when its helper exits unexpectedly or
  stops responding; bounded cleanup now restores normal sleep and leaves later
  enable requests able to run.
- Keep long-running Codex turns visible when `turn_context` and the following
  reasoning or tool work arrive in separate filesystem event batches.
- Keep Codex `/goal` sessions working across automatic turn completions by
  observing the local goal registry; stop on paused, blocked, limited or
  completed status without adding a polling loop.
- Restore the persistent closed-lid sleep switch through an event-driven child
  guard when drem is force-quit or crashes, without background polling.

## 1.6.0 — 2026-09-10

### Added

- Add an independent Away mode that requests the real macOS lock screen when the lid closes.
- Keep active agents running behind the lock screen, let the display sleep, and preserve the existing last-agent sleep release.
- Share one event-driven lid observer between screen security and built-in display brightness.
- Verify every lock request, fall back to the system Lock Screen shortcut, and report failure instead of showing a false protected state.

### Fixed

- Keep Codex marked as working when an automatic continuation after compaction starts real reasoning or tool work without another user-prompt hook.

### Distribution

- Publish verified Apple Silicon ZIP releases with SHA-256 checksums from version-matched Git tags.

## 1.5.2 — 2026-09-07

### Fixed

- Bind Claude Code sessions through its per-PID registry when transcripts are closed between writes and several agents share a folder.
- Validate registry process-start times against the kernel to reject stale files after PID reuse.
- Ignore historical work from before a resumed process started, while preserving new task events and completion detection.
- Discover registry changes through file events; status-only updates do not trigger a process scan.

## 1.5.1 — 2026-09-07

### Fixed

- Stale hooks can no longer count a different session just because its agent uses the same folder.
- All explicitly bound transcripts are checked, including older sessions outside the recent-history window and sessions whose project folder was renamed.
- Unrelated transcript events cannot borrow a PID already bound to another log; idle sessions no longer keep the working count and sleep blocker active.

## 1.5.0 — 2026-09-06

### Branding and migration

- Renamed the application, package, binaries and interface to drem.
- Unified the app icon, exported logo and menu symbol around the single star.
- Added one-time settings/recovery migration from Agent Watch and legacy hook compatibility.

### Repository

- Introduced drem branding, Russian and English READMEs and focused guides.
- Added macOS CI, isolated installer tests, issue/PR templates and contributor guidance.
- Included the complete GPLv3 license and preserved upstream attribution.

## 1.4.5 — 2026-09-06

### Fixed

- A disabled blocker always uses the monochrome star.
- An enabled blocker respects the selected icon and color.
- The drem selection uses the same star, not the older eye.
- Agent activity no longer overrides the icon or its render cache.

## Earlier local builds

The project was developed locally before its first Git publication.
Those builds introduced event-driven Codex/Claude monitoring, manual and
agent-driven keep-awake sessions, closed-lid operation and display restoration.
This repository does not invent Git tags or release artifacts for that history.
