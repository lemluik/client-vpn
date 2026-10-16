# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 0.3.x   | :white_check_mark: |
| < 0.3   | :x: — update to the current release |

## Reporting a Vulnerability

If you discover a security vulnerability, please **do not** open a public issue.

Report it privately via [GitHub Security Advisories](https://github.com/lemluik/client-vpn/security/advisories/new):

1. Go to the repository's **Security** tab
2. Click **Report a vulnerability**
3. Describe the vulnerability and how to reproduce it

Do not include your own private keys, server addresses or UUIDs unless they are
required to reproduce the issue — and never include credentials of a live server.

We will acknowledge your report within 48 hours and provide a fix timeline.

## Security Considerations

- **Binary integrity is enforced, not delegated to you.** `xray.exe` is *not*
  committed to this repository — it is fetched by `scripts/download_xray.sh`,
  which verifies the SHA-256 of both the downloaded archive and the extracted
  binary against pinned values, and refuses to keep a mismatched file. On
  Windows the app re-verifies the SHA-256 of the binary before every launch and
  refuses to execute a tampered `xray.exe` (`DesktopCore` in
  `lib/desktop_core.dart`). On Android the engine is packed into the APK as
  `libxray.so` (`scripts/download_xray_android.sh` pins the same checksums), so
  its integrity is guaranteed by the APK signature; the geo databases copied to
  the app directory at first launch are checked against a checksum manifest
  (`android/app/src/main/kotlin/.../GeoAssets.kt`).
  Pinned version: Xray-core 26.3.27.
- **Your connection strings are secrets, and they are stored in plain text.**
  This is the honest description of the current build, not an aspiration: the
  profiles you add — including the node keys inside them — are kept in this
  app's private storage (`SharedPreferences` on Android, the app's preference
  store on Windows), and the engine needs a config file on disk, so the client
  writes it next to the launch: `%TEMP%\client_vpn-<pid>\config.json` on
  Windows, removed when the client exits (`lib/temp_config.dart`), and
  `filesDir/user-config.json` / `tunnel-config.json` on Android. Both locations
  are readable only by the app's own user account. Android backup and
  device-to-device transfer are switched off in the manifest
  (`android:allowBackup="false"` plus `data_extraction_rules.xml`), so the keys
  do not leave the device through a cloud backup. **Encrypting this storage with
  the platform keystore is the announced next step**; the session token of the
  support chat already uses it (`flutter_secure_storage`). Until that lands,
  treat a rooted or jailbroken device as a device where your connection strings
  are readable.
- **The system proxy is modified.** On Windows the client writes `ProxyServer`
  and `ProxyEnable` under `HKCU\...\Internet Settings`. It saves your previous
  values first and restores them on disconnect, and its crash-recovery only
  touches the proxy if it exactly matches the one this app set — so an
  unrelated local proxy (Fiddler, Clash, a corporate client) is left alone.
  Review `lib/system_proxy.dart`.
- **No traffic leaves the app except through Xray.** There is no telemetry,
  no analytics and no update check in this client. The claim is checked by the
  repository gate, not by hand: `tools/check_public.py` fails the build if a
  telemetry or analytics package appears in the dependency graph, and the
  **About** screen repeats the same statement to the user.
- **Logs are masked before you can export them.** The log screen strips node
  addresses, keys and identifiers (`lib/log_mask.dart`); an exported log is
  still yours to read carefully before you attach it to a public issue.
