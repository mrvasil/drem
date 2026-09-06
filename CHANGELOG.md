# Changelog

User-visible changes are recorded here. Version numbers correspond to the
application bundle.

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
