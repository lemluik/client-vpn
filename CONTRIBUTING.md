# Contributing to КлиентВПН

Thank you for your interest in contributing!

## How to Contribute

### Reporting Bugs

1. Check if the bug is already reported in [Issues](../../issues)
2. If not, create a new issue using the [Bug Report template](.github/ISSUE_TEMPLATE/bug_report.yaml)
3. Include: steps to reproduce, expected behavior, actual behavior, logs, screenshots

### Suggesting Features

1. Check [Issues](../../issues) for similar requests
2. Create a new issue using the [Feature Request template](.github/ISSUE_TEMPLATE/feature_request.yaml)
3. Explain the use case and how it benefits users

### Code Contributions

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/your-feature-name`
3. Make your changes
4. Test locally (see [README.md](README.md#сборка-из-исходников))
5. Commit with a clear message following [Conventional Commits](https://www.conventionalcommits.org/)
6. Push to your fork and create a Pull Request

### Code Style

- Follow `analysis_options.yaml` (Flutter lints)
- Use `flutter format` before committing
- Write clear commit messages in English or Russian

## Development Setup

See [README.md](README.md#сборка-из-исходников) for setup instructions.

## Architecture

- **lib/main.dart** — UI (single screen), config validation, proxy/Xray lifecycle
- **lib/xray_process.dart** — manages xray.exe subprocess, verifies its SHA-256 before launch
- **lib/system_proxy.dart** — Windows system proxy via registry, saves and restores the user's previous settings

## Bumping the Xray-core version

The binary's SHA-256 is pinned in **two** places, and both must be updated
together or the client will refuse to start:

1. `lib/xray_process.dart` — `_expectedSha256` (the extracted `xray.exe`)
2. `scripts/download_xray.sh` — `ZIP_SHA256` and `EXE_SHA256`

Take the new values from the official digest file, never from a local build:

```bash
curl -sfL "https://github.com/XTLS/Xray-core/releases/download/<VERSION>/Xray-windows-64.zip.dgst"
```

Also update the version badge and `XrayProcessManager.version` in `README.md`.

## Questions?

Open an [Issue](../../issues) using the appropriate template, or use the
[Security Advisories](../../security/advisories/new) channel for anything
security-related.
