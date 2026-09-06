# Contributing to drem

Small, focused changes are welcome. Reports and pull requests can be in
Russian or English.

## Start here

Read [Architecture](docs/ARCHITECTURE.md), [Privacy](docs/PRIVACY.md) and
the behavior you are changing in [Usage](docs/USAGE.md).
The Swift package is Drem; the installed application is drem.app.

```sh
make check
make test
make build
```

Use Swift 6+ on macOS 14+ for tests. No package dependencies are required.
`make check` runs repository hygiene checks and installer tests against temporary
fixtures. `make test` runs the core self-test and Swift Testing suites.
It does not change your pmset configuration or request an administrator password.

## Keep these boundaries

- A running process is not proof of a working agent.
- Exact session identity takes precedence over working-directory guesses.
- Finishing the last agent releases every blocker owned by agent mode.
- Brightness restoration must never prolong sleep prevention.
- The icon follows blocker state and appearance preferences, not agent activity.
- Do not add per-second process discovery, transcript rescans or UI animations.
- Keep user defaults, lifecycle hooks and recovery data compatible.
- Preserve third-party copyright and SPDX notices.

Add a regression test for behavior changes. Use temporary directories,
isolated UserDefaults and injected system effects. Never include real user
transcripts, credentials or project paths in fixtures.

The optional native display test is intentionally excluded from normal CI.
Only run it deliberately on a Mac with a built-in display:

```sh
DREM_LIVE_DISPLAY_TESTS=1 zsh scripts/test-automation.sh --filter liveBuiltinDisplay
```

It writes the current brightness value back to the same display. Actual
lid-close/open verification still needs a physical, ventilated laptop.

## Pull requests

Describe the user-visible change, the failure it addresses and the commands you
actually ran. Include before/after images for visual changes using synthetic
project names. Do not claim physical lid tests from a virtual runner.

Keep generated `.build`, `dist`, config backups and local agent data out of Git.
Run `git diff --check` before submitting.

Contributions are provided under [GPL-3.0-or-later](LICENSE).
