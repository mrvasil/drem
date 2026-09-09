# Changelog

User-visible changes are recorded here. Version numbers correspond to the
application bundle.

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
