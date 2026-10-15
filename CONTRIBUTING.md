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

- **lib/main.dart** — app entry, theme, single-instance guard, tray wiring
- **lib/home_screen.dart**, **lib/app_state.dart** — the UI and the state machine that drives it
- **lib/desktop_core.dart** — `DesktopCore`: starts the `xray.exe` subprocess and verifies its SHA-256 before every launch
- **lib/android_core.dart** + `android/app/src/main/kotlin/` — the same contract on Android through the `VpnService` tunnel
- **lib/tun_config.dart**, **lib/temp_config.dart** — config assembly for the engine and the working file it needs
- **lib/system_proxy.dart** — Windows system proxy via registry, saves and restores the user's previous settings

## Bumping the Xray-core version

The binary's SHA-256 is pinned in **three** places, and all of them must be
updated together or the client will refuse to start:

1. `lib/desktop_core.dart` — `_expectedSha256` (the extracted `xray.exe`) and `version`
2. `scripts/download_xray.sh` — `ZIP_SHA256` and `EXE_SHA256`
3. `scripts/download_xray_android.sh` — `ZIP_SHA256` and `BIN_SHA256` for the arm64 build

Take the new values from the official digest file, never from a local build:

```bash
curl -sfL "https://github.com/XTLS/Xray-core/releases/download/<VERSION>/Xray-windows-64.zip.dgst"
```

Also update the `xray-26.3.27` badge in `README.md` and `DesktopCore.version`.
`test/kernel_config_test.dart` runs the real binary, so a mismatched pin fails
there before it fails for a user.

## Questions?

Open an [Issue](../../issues) using the appropriate template, or use the
[Security Advisories](../../security/advisories/new) channel for anything
security-related.
