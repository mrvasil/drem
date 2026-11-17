# Changelog

User-visible changes are recorded here. Version numbers correspond to the
application bundle.

## Unreleased

### Changed

- Reduce the app to a native menu-bar popover and two settings tabs. Remove
  the island, animated agents, gestures, terminal navigation and their observers.
- Remove session-title indexing, public-message/action/attention parsing and
  the permission notification hook. Existing unrelated hooks are preserved.
- Remove pointer jiggling, decorative icon choices and the countdown refresh
  timer. Keep a static monochrome star, working-agent count and session end time.
- Run the battery timer only while its cutoff is enabled and wake is held;
  reuse it across unrelated preference changes.

### Fixed

- Expire wake ownership after 15 minutes without semantic progress, using a
  monotonic deadline. Process exit, suspension and PID reuse cannot retain work.
- Cache hook files and goal database fingerprints, filter unrelated events,
  reuse timestamp formatters, and handle transcript replacement/deletion.
- Restore the persistent sleep switch after normal quit or a crash through an
  event-driven child guard. Keep uncertain recovery state, bounded retries and
  operation identity; checking sudo permission no longer changes sleep state.
- Preserve Codex and Claude work during compaction, including split continuation
  events, PreCompact/PostCompact and post-compaction SessionStart. Real completion
  still releases sleep; active Codex goals obey the same progress deadline.
- Open the tray panel on the first click, with no expanding animation.

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
