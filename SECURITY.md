# Security policy

## Reporting

Do not put credentials, private transcripts or exploitable system-permission
details in a public issue.

Use [GitHub private vulnerability reporting](https://github.com/mrvasil/drem/security/advisories/new)
when it is available. If it is unavailable for this repository, contact
[@mrvasil](https://github.com/mrvasil) through a contact method on the profile
before sharing sensitive material. There is no guaranteed response-time SLA.

Report the affected version, the relevant code path, impact and a minimal
reproduction with synthetic data. Keep the report within systems you own
or have permission to test.

## Relevant boundaries

drem reads local agent metadata and parts of transcripts. Its optional closed-lid
mode installs a narrow sudoers rule for two exact pmset commands. Brightness
control uses dynamically loaded macOS interfaces. Changes around these
boundaries need explicit review and tests.

Normal CI has no production credentials and must not request administrator
access, change pmset, install user hooks or run native display tests.

## Supported code

Security fixes target the current main branch and the latest version documented
in [CHANGELOG.md](CHANGELOG.md). Older builds are not maintained separately.

See [Privacy](docs/PRIVACY.md) for local data handling.
