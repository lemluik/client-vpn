# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed

- The "Node unreachable" banner could appear over a live tunnel. The connectivity probe used an
  HTTPS endpoint by default, so it depended on a TLS handshake with a foreign site passing through
  the tunnel; on some subscriber networks that handshake stalls after the certificate chain while
  ordinary traffic keeps flowing, and two stalled probes were enough to mark the path dead. The
  default probe endpoint is now a plain HTTP one (`http://connectivitycheck.gstatic.com/generate_204`):
  what the probe has to prove is that bytes reach the node and come back, not that a foreign TLS
  server completes a handshake. Measured 26.10.2026 on a controlled stall: the HTTPS probe turns
  the banner red, the HTTP probe stays green over the same path.

## [0.4.2] - 2026-10-22

### Fixed

- Failover between entry nodes actually works now. The observatory block the client used to build
  carried a single `target` field, which the core (Xray 26.3.27) silently ignores: `xray run -test`
  accepts unknown JSON fields, so the broken shape passed validation while the observatory never
  sent a single probe and the `leastPing` strategy stayed on the first node forever. The block is
  now built as `subjectSelector` + `probeURL` + `probeInterval` (a duration string — the core
  rejects a bare number with `invalid duration`) + `enableConcurrency`.
- Verified against a live stand (`test/stand`): two local SOCKS relays as entry nodes, a counting
  HTTP target for the observatory, injected node failure. Measured behaviour: the core probes the
  target, traffic moves to the live node after the first one fails, returns to the recovered node,
  and with both nodes dead nothing leaks direct (no `fallbackTag`, no `cvpn-direct` lines).

## [0.4.1] - 2026-10-21

### Added

- Connecting to a provider that hands out keys is now one button. The add-connection menu offers
  «Подключить {имя сервиса}», which asks the provider's control point for a trial key and adds the
  link it gets back — no pasting, no config file. The service name comes from the closed build's
  config asset, the registration response or a subscription header; with none of them the item reads
  «Подключить сервис», so the brand stays out of the source and the open client stays universal.
- The connection screen states why a request was refused, in the user's terms rather than a server
  code: this device already received a trial key, the key expired, the control point is unreachable.
  An expired key leads to the support chat instead of ending the flow.
- The device is identified by a UUID v4 kept in the OS secure storage (Keystore / Credential
  Manager), so a repeated request from the same installation is recognised by the provider instead of
  quietly issuing another key. Reinstalling or clearing the app's data gives a new identifier.
- Android quick-settings tile for the tunnel: one tap in the pull-down panel raises or drops the
  tunnel without opening the app, and its state is read from the actual tunnel interface rather than
  from the process memory, so a restarted shell still shows the truth. The client asks the system to
  place the tile from the settings screen (Android 13+); older versions get the manual instructions.
  The tile starts the tunnel directly only while a freshness marker on the saved config stands —
  every successful in-app connection sets it — otherwise the tap opens the app and connects from
  there, and with no saved connection the tile is greyed out.
- Android checks for a newer release a few seconds after start and offers to update in place: the
  package is downloaded over HTTPS, its SHA-256 is checked against the release's own checksum file
  before the installer is opened, "Later" snoozes the offer for a week, and the whole check can be
  switched off in settings
- Windows updates itself in place the same way: the zip is downloaded and checked, unpacked into a
  staging folder, and a detached script waits for the app to exit, swaps the files and relaunches
  it. Files the package does not carry — the core binary and the geo databases — are left alone, and
  a failed swap rolls back from the backup copy it made. If the install folder is read-only the app
  says so and opens the download link instead of asking Windows for elevated rights behind the
  user's back

### Security

- `assets/service_config.json` is gitignored. It was untracked but not ignored, so one bulk
  `git add` in a working copy of the closed build would have published the brand and the control
  point address into this public repository. The file now lives outside the repo and is overlaid
  before the build.

## [0.4.0] - 2026-10-17

### Added


- Closing the window asks what to do instead of guessing: minimize to the tray keeps the tunnel
  running, quit tears it down, and the checkbox remembers which one was chosen. Both answers stay
  editable in settings, and a remembered minimize still quits when no tray icon could be mounted,
  because a hidden window with no way back is indistinguishable from a crash
- Settings screen behind the gear button in the top-left corner of the home screen: theme
  (system, light, dark), start with the system, auto-connect to the connection that last worked,
  and the list of saved profiles where one can be selected, renamed or removed
- Autostart keeps the system's own flag rather than a copy of it: on Windows that is the
  `HKCU\...\Run` value of the current user, on Android a boot receiver opens the app after start
- Support chat accepts screenshots: the composer has an attach button, the file is uploaded to the
  homeserver and sent as an `m.image` event, and incoming images are downloaded and shown inline.
  Both the authenticated media API (Matrix 1.11+) and the legacy one are tried, so homeservers that
  serve media only on the old path keep working
- Routing rules the user can write: an editor with manual domain and IP rules, presets (everything
  through the tunnel / everything direct / split), per-address exceptions and, on Android, per-app
  exclusions. The Russian preset ships with banks and government services so they keep going direct.
- Nodes inside one region are balanced between each other with a stickiness threshold taken from
  measurements, and the probe target became a setting the user can change.
- The tunnel is raised again when the device switches network, and the service recovers after an
  outage. A subscription that stops answering freezes the service instead of dropping connections.
- Tapping a `vless://` link outside the app — in a browser or a messenger — opens the client and
  adds the connection itself on Android.
- Live traffic counters: the Android VPN notification shows the speed and the session total, and
  Windows reads the same numbers from the core's gRPC StatsService and puts them in the tray tooltip.
- Update check: the client asks GitHub Releases for the newest version, understands both manifest
  formats, and shows a screen with the release description and a download link.
- About screen with the app version, the MPL-2.0 license, third-party notices and the no-telemetry
  statement. The app icon is the Neutrino atom: adaptive on Android, plus favicon and store icon.
- Windows keeps a single client window and puts the connection control in the tray icon.
- CI runs the analysis, the tests and the repository gates on every pull request, Dependabot tracks
  workflow action versions, and a tag build publishes the GitHub Release itself with the license
  files and `SHA256SUMS.txt` next to the artifacts.
- Android: cloud backup is switched off so a saved key does not leave the device, and the release
  signing configuration is prepared.

### Changed

- The home screen toolbar is balanced by how often each action is used: settings and log sit on the
  left, add-connection and support chat on the right. The log used to be wedged between the two
  actions people reach for daily, and the right side carried three buttons against one on the left.
- The profiles section is first on the settings screen, above theme and startup: the list of saved
  connections is what the screen is opened for, and at the bottom it sat behind everything else.
- One settings entry point instead of two: the second toolbar button on the home screen opened a
  sheet with rules, probe target, updates and about, while the gear opened a screen holding the
  same routing choice under a different label. The sheet is gone and every item it held lives on
  the settings screen; the routing choice is shown once — as the home-region switch when the device
  language resolves to a region, otherwise as the preset list
- The connect button sits in the middle of the home screen instead of being pinned to the bottom:
  the profile list now keeps its natural height, two spacers center the button in the space left,
  and the connection status stays at the bottom edge of the window
- The connect button keeps the same power glyph once the tunnel is up instead of switching to a
  padlock; the active state is shown by the filled circle and its glow
- The support team member is called an "operator" everywhere in the chat interface and texts,
  replacing the previous wording

### Fixed

- Pressing "Update" in the update dialog closed the screen under it instead of starting the
  download. Both the button and the callback the dialog was given popped the route, so the first
  pop returned `null` — read as "turn automatic checks off" — and the second removed the home
  screen, leaving a black window. Dismissal now belongs to the callbacks alone.
- The tray tooltip now uses the method the Windows plugin actually implements.
  `setTitle` only exists on macOS, so on Windows mounting the tray threw
  `MissingPluginException`, the app believed no tray was available, and closing the
  window quit without asking — the prompt added above never appeared. A tray the
  platform rejects is now unwound instead of left half-mounted.
- Recovery after a core failure is wired to startup. It was written and never called, so on Windows
  the system proxy could stay enabled after the core process was killed externally — every browser
  then fails to open pages until the setting is cleared by hand. The app now asks the core what state
  it is in and rolls the proxy back; the same path drives the interval-based subscription refresh,
  which until now only happened when its button was pressed.
- The system proxy prefers the `http` inbound over `socks`. Measured on Xray-core 26.3.27 with
  headless Chrome: a `socks=127.0.0.1:port` entry makes the browser resolve the destination itself
  and hand the kernel an address, so DNS leaks to the local resolver; a bare `host:port` entry hands
  over the domain and the server resolves it.
- `ProxyOverride` gets the `<local>` exception while the proxy is enabled, and the user's own
  exceptions come back when it is disabled — including the case where the rollback runs after a
  crash. Browsers bypass loopback anyway; the marker is for clients that do read the list.
- Android: reopening the screen while the tunnel is up no longer shows «Disconnected» with the
  control stuck at «Connecting». The service outlives the screen, and nothing used to ask it for the
  real state: the status bus now replays the last state on re-subscription, the Dart side asks the
  service on startup, and the "tunnel is already up" branch publishes the status before returning.
- Known gap, not fixed here: the app's own requests (subscription fetch, refresh and chat) still go
  direct even while the tunnel is up, because the HTTP client reads proxy settings from environment
  variables rather than from the system — on both platforms. Closing it needs a local inbound on
  Android, where the tunnel config replaces local inbounds with the tun device.

### Dependencies

- `tray_manager` 0.5.2 → 0.8.0. Since 0.7.0 the package is built on `nativeapi`: the old singleton
  and its platform channel moved to a deprecated `legacy.dart` that disappears in the next release,
  so the tray controller now creates a `TrayIcon`, a `Menu` with `MenuItem`s and event listeners.
  All native calls are synchronous and can return "not created", and the objects have to be kept
  referenced — finalized by the garbage collector, a tray object releases its native handle and the
  icon vanishes.
- The state on the icon is still `setToolTip`, and only `setToolTip`: `setTitle` does nothing on
  Windows. The difference from 0.5.x is that an unsupported call is now ignored silently instead of
  throwing, which removes the half-mounted tray but gives no signal either, so the mount path keeps
  checking every step and tears the tray down if any of them fails.
- `dynamic_color` stays on 1.9.0 on purpose. From 2.0.0 the package returns a `ColorScheme` from
  `material_ui` — a different Material implementation — so taking the upgrade would mean swapping
  the app's widget library to get a palette.

## [0.3.0] - 2026-10-15

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
- The top-level core blocks a user writes in a config — `dns`, `observatory`,
  `burstObservatory`, `policy` — now survive into the assembled tunnel config, and that config is
  checked by the same core before it starts (`run -test`; on Android the tun inbound is swapped for a
  local socks, because the tunnel device does not exist yet at validation time). Geo databases come
  with the app instead of being missing at the first `geoip:`/`geosite:` rule: `download_xray.sh`
  fetches `geoip.dat` and `geosite.dat` with a SHA-256 check, the APK carries them together with a
  manifest of checksums and sizes, and the first launch copies them into `filesDir`. The asset
  directory is passed to the core in `XRAY_LOCATION_ASSET` on both platforms, because the core's
  search by working directory does not work when the config is read from the profile's temp folder

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
