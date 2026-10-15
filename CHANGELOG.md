# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Support chat over Matrix, built into the client: the homeserver and the room come
  from the provider (`chat-homeserver` and `chat-room` subscription headers, or typed
  in by hand until the provider sends them), the account is issued by the provider —
  there is no self-registration. The access token is kept in the OS secure store
  (Keystore on Android, Credential Manager on Windows) and never in app preferences,
  so a config export carries no chat credentials. One long-poll at a time, backoff
  1/2/4/8/16 s, and an outbox that survives a restart: an unsent message keeps its
  transaction id and is retried under the same id, so the node cannot double it.
  A rejected token ends the session with a plain "chat access has expired" instead of
  a silent retry loop. TLS is strict everywhere; the chat never loosens it. The chat
  is reachable from the top bar even with no connection added — that is the case
  where support is needed most — and its history is scoped per provider, so removing
  a provider erases the chat data that came with it. The conversation is private by
  room membership, not by an interface filter: the client takes the room the node
  lists under `m.direct` instead of the first joined room, so another client's
  messages never arrive in this session at all. The ticket buttons above the input
  come from the room itself, its `support.quick_replies` state event, so the provider
  owns the category texts and the client keeps none of them
- Exit country selection. The client groups subscription profiles by the node name
  the provider sends (`🇪🇺 Europe 1`, `🇪🇺 Europe 2`, `🇰🇬 Kyrgyzstan 1` -> two
  countries) and shows a picker when a profile has more than one group. The label
  keeps the provider's full name together with its flag; the stored key is the
  name alone, so a node renumbered or re-flagged stays the same choice. The picker
  is a list opened from the row above the connect button: flags and full names,
  with the number of profiles per country. Windows cannot draw a flag built of
  regional indicator pairs and shows its two letters instead, so there the label is
  the full name without the glyph; the flag stays in the node name, the journal and
  the subscription. The choice is stored per
  profile, survives a restart, and only the selected region's profiles go into the
  core config; a region that disappears from the subscription falls back to the
  first one. Switching on a live tunnel asks for confirmation and reconnects
  through the new path. Subscriptions whose links carry no names behave as before
- Profiles, providers and subscriptions replaced the single `config.json` entry
  point: share links, base64 subscription bodies and subscription URLs, with a
  cache of the last good answer, usage headers and offline start from cache
- Journal on its own screen, masked before export: addresses and keys are replaced
  with placeholders

### Fixed

- Restarting the tunnel immediately after stopping it failed with the core's
  `bind: Only one usage of each socket address`: the local inbound port is not
  released at the moment the previous core process exits. The client now waits
  for the port to free up before starting the core (and after a forced kill waits
  for the process to actually finish), and reports a port held by another
  application in plain language instead of a core error. This is what broke
  switching the exit country on a live tunnel

### Changed

- The connection control is a round disc in the centre of the screen instead of a
  full-width button. Its colour, ring, glow, glyph and caption follow the tunnel
  state (ready, connecting, protected, failed): the disc dips on press, the icon
  and the caption cross-fade on every change, and a spinner replaces the glyph
  while the tunnel is coming up. Adding a connection moved from the extended
  floating button to a plain icon in the top bar next to the journal, which also
  ends the collision between the status line and the button
- The empty screen shows no disc — there is nothing to connect to — and its
  explanation scrolls instead of overflowing in a short window

## [0.2.1] - 2026-10-13

Windows-only fixes; the Android build is unchanged.

### Fixed

- The window opened at the 1280x720 template default, which `Win32Window::Create`
  multiplies by the monitor DPI factor — about 1600x900 physical pixels on a
  125% display, roughly 2.5x wider than intended. Both `windows/runner/main.cpp`
  and `WindowOptions.size` in `lib/main.dart` now say 500x700, and the window is
  centered with a 500x700 minimum size
- The primary button showed «ПОДКЛЮЧЕНИЕ...» with a spinner while the config was
  still being validated. Validation now has its own `_isValidating` flag and the
  button reads «ПРОВЕРКА...»

### Dependencies

- `window_manager` 0.4.3 -> 0.5.2 (verified: AOT build, analyzer, 23 tests and a
  live window geometry check; 0.6.0 is a breaking release that needs Flutter
  3.47 / Dart 3.13 and the `window_manager/legacy.dart` import)
- `flutter_lints` 5.0.0 -> 6.0.0

## [0.2.0] - 2026-10-13

Android support (R2). Windows behaviour is unchanged.

### Added

- Android build: `android/` project with `TunnelService` (a `VpnService`
  foreground service) and `TunnelBus`, exposed to Dart over the
  `client_vpn/tunnel` method channel
- TUN mode on Android: the tunnel file descriptor is handed to Xray as stdin
  because libcore closes every other descriptor in a child process; the core
  reads it from the `xray.tun.fd` environment variable
- Xray-core for Android is packed into the APK as `libxray.so` under
  `arm64-v8a` with legacy native-library packaging — Android 10+ only allows
  execution from the unpacked native library directory
- `scripts/download_xray_android.sh` fetches `Xray-android-arm64-v8a.zip`
  v26.3.27 and verifies the SHA-256 of the archive and of the extracted
  binary against pinned values (the `.dgst` file describes the archive, not
  the binary inside it)
- Platform-neutral core layer: `lib/vpn_core.dart` (abstract) with
  `lib/desktop_core.dart` (proxy + registry) and `lib/android_core.dart`
  (VpnService), so the single screen no longer knows the platform
- `lib/vpn_config.dart` — config picking, validation state and persistence;
  on mobile the content is read at pick time because a content URI cannot be
  reopened as a file
- `lib/tun_config.dart` — rewrites the user config for the core's tunnel mode:
  the local inbounds are replaced by a tun inbound, the terminating rule sends
  all traffic to the proxy outbound, user rules keep their priority. A config
  without a real proxy outbound (`freedom` or `blackhole` first) is refused —
  on Android that would be a silent leak
- Unit tests for the tunnel config builder (23 tests in total)

### Changed

- `lib/xray_process.dart` is replaced by `lib/desktop_core.dart`
- `file_picker` ^8.1.7 → ^13.1.0 (API used: `pickFile` + `readAsBytes`)

### Known limitations

- Android APK is arm64-v8a only — the official Xray-core Android release
  ships no other binary
- The release build is still signed with the debug key
- TUN is Android-only; Windows stays on system proxy (planned for R2.1)

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
