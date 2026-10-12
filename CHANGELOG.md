# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-10-12

Initial release (Windows MVP).

### Added

- Import an Xray-core configuration (`config.json`) and validate it with
  `xray run -test` before connecting
- Connect over VLESS + Reality to a server of your choice
- System proxy mode on localhost, supporting both `http` and `socks` inbounds,
  with ports given as either a number or a string
- SHA-256 verification of `xray.exe` before every launch — a tampered or
  corrupted binary is refused, not executed
- `scripts/download_xray.sh` fetches Xray-core and verifies the SHA-256 of both
  the archive and the extracted binary against pinned values
- Previous system proxy settings are saved on connect and restored on disconnect
- Proxy rollback when the Xray process dies mid-session, and when the app is
  closed or crashes (crash recovery only touches a proxy that exactly matches
  the one this app set, leaving an unrelated local proxy alone)
- Single-screen UI with connection status and a 200-line rolling log
