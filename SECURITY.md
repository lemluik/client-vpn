# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |

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
  binary against pinned values, and refuses to keep a mismatched file. The app
  re-verifies the SHA-256 of the binary before every launch
  (`lib/xray_process.dart`) and will not execute a tampered `xray.exe`.
  Pinned version: Xray-core 26.3.27.
- **Configuration files are secrets.** Your `config.json` contains private keys
  and server addresses. The client stores only the *path* to it
  (via `shared_preferences`), never its contents, and does not write logs to
  disk. Keep the file itself outside of any synced or shared folder.
- **The system proxy is modified.** On Windows the client writes `ProxyServer`
  and `ProxyEnable` under `HKCU\...\Internet Settings`. It saves your previous
  values first and restores them on disconnect, and its crash-recovery only
  touches the proxy if it exactly matches the one this app set — so an
  unrelated local proxy (Fiddler, Clash, a corporate client) is left alone.
  Review `lib/system_proxy.dart`.
- **No traffic leaves the app except through Xray.** There is no telemetry,
  no update check and no analytics in this client.
