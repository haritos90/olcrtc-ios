# olcrtc-ios

[![CI](https://github.com/haritos90/olcrtc-ios/actions/workflows/ci.yml/badge.svg)](https://github.com/haritos90/olcrtc-ios/actions/workflows/ci.yml)
![Platform](https://img.shields.io/badge/platform-iOS%2017%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5-orange)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

iOS client for [olcrtc](https://github.com/openlibrecommunity/olcrtc) — a WebRTC-based proxy that tunnels SOCKS5 traffic through video-conferencing carriers (Telemost, WBStream, Jitsi).

The app manages the full lifecycle end to end:

- **Provision** — SSH into a VPS, upload and run the install script, and capture the resulting `olcrtc://` URI.
- **Connect** — run the olcrtc Go core (via gomobile bindings) as a local SOCKS5 proxy.
- **Route** — send app traffic through the proxy with a per-app `URLSessionConfiguration`.

---

## Features

- One-tap VPS provisioning over SSH (non-interactive install of the olcrtc server).
- Telemost / WBStream / Jitsi carriers, each with its own transport options.
- Local SOCKS5 proxy with optional username/password auth.
- Connection manager: multiple servers, QR import/export, primary selection.
- Built-in diagnostics: live logs, IP check, speed test, and per-connection ping / readiness probes.
- Background keep-alive so the tunnel survives app backgrounding.
- Full English / Russian localization.

---

## Screenshots

> _Screenshots coming soon._

<!--
Add PNGs under docs/screenshots/ and uncomment this table:

| Connections | Install a VPS | Logs | Settings |
|---|---|---|---|
| ![Connections](docs/screenshots/connections.png) | ![Install](docs/screenshots/install.png) | ![Logs](docs/screenshots/logs.png) | ![Settings](docs/screenshots/settings.png) |
-->

---

## Requirements

| Tool | Version | Notes |
|------|---------|-------|
| Xcode | 15+ | iOS 17 deployment target |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | any | `brew install xcodegen` |
| [gh CLI](https://cli.github.com) | optional | to download a prebuilt `Mobile.xcframework` |
| Go + gomobile | optional | only to build `Mobile.xcframework` from source |

`Mobile.xcframework` — the gomobile-built olcrtc core (~228 MB) — is **not tracked in git**. Download a prebuilt copy or build it from source; see [Mobile.xcframework](#mobilexcframework).

---

## Quick start

```bash
git clone https://github.com/haritos90/olcrtc-ios.git
cd olcrtc-ios
git submodule update --init --recursive   # pulls olcrtc core into olcrtc-upstream/

# Get App/Mobile.xcframework (not in git) — download the prebuilt, or build it:
./scripts/fetch-framework.sh              # fast path (needs the gh CLI)
# ./scripts/build-framework.sh            # fallback (~5 min, needs Go + gomobile)

xcodegen generate --spec project.yml      # generates olcrtc-ios.xcodeproj
open olcrtc-ios.xcodeproj
```

Set your development team in Xcode (or in `project.yml` → `DEVELOPMENT_TEAM`), then build and run.

---

## Mobile.xcframework

The olcrtc core ships inside the app as `App/Mobile.xcframework`, compiled from
`olcrtc-upstream/mobile/mobile.go` with gomobile. It is **not tracked in git**
(~228 MB) — get it one of two ways.

### Download a prebuilt (recommended)

Every tagged release has the framework attached as `Mobile.xcframework.zip`, built by
[`.github/workflows/release.yml`](.github/workflows/release.yml). Fetch and unpack it:

```bash
./scripts/fetch-framework.sh            # latest release
./scripts/fetch-framework.sh v1.2.210   # a specific tag
```

Needs the [`gh` CLI](https://cli.github.com) (`brew install gh`, then `gh auth login`).

### Build from source

```bash
brew install go                         # the version pinned in olcrtc-upstream/go.mod
./scripts/build-framework.sh            # installs gomobile if needed, then binds
```

Takes ~5 minutes (mostly Go module fetches on first run); `-target=ios` produces both
the device and simulator slices.

Either way, run `xcodegen generate --spec project.yml` afterwards so Xcode picks up the
framework — `xcodegen` doesn't watch the filesystem.

---

## Project structure

```
olcrtc-ios/                      the iOS app (this repo)
├── App/                        Swift sources, grouped by responsibility:
│   ├── Core/                   TunnelManager, TunnelEngine, SSHRunner, ConnectionStore …
│   ├── Models/                 OlcrtcConnection, OlcrtcURI, ConnectionRecord …
│   ├── Services/               LogStore, SettingsStore, IPChecker, NetPing …
│   ├── Views/                  SwiftUI screens
│   ├── Security/               KeychainHelper, ConnectionSecretStore
│   ├── Utilities/              AppConstants, CarrierTransportMatrix
│   ├── Localization/           L10n + L10nTable (English source + translations)
│   ├── PrivacyInfo.xcprivacy   App Store privacy manifest (no tracking, no data collected)
│   └── Mobile.xcframework/     compiled olcrtc core (gomobile; not in git — download or build)
├── Tests/                      XCTest unit tests (URI parsing, env-var parity, …)
├── scripts/
│   ├── srv.sh                  VPS install script (patched copy of upstream)
│   ├── parity_check.py         build-phase check that keeps srv.sh in sync with upstream
│   ├── build-framework.sh      build Mobile.xcframework from the submodule (gomobile)
│   └── fetch-framework.sh      download a prebuilt Mobile.xcframework from a Release
├── .github/workflows/          CI (build + test + parity) and release (framework artifact)
├── docs/uri.md                 olcrtc:// URI format reference
├── olcrtc-upstream/            Git submodule — openlibrecommunity/olcrtc @ master (upstream source)
├── project.yml                 XcodeGen spec (source of truth; .xcodeproj is generated, gitignored)
├── AGENTS.md, CONTRIBUTING.md  AI-agent + contributor guides
└── .gitmodules
```

**The three "olcrtc" pieces** (easy to confuse):

- **`olcrtc-upstream/`** — the upstream submodule (Go core + `srv.sh`); used only
  at build time (parity check + building the framework).
- **`App/Mobile.xcframework`** — that core compiled for iOS via gomobile; this is
  what actually ships inside the app.
- **this repo** — the iOS app itself.

See **[CONTRIBUTING.md](CONTRIBUTING.md)** for conventions and **[AGENTS.md](AGENTS.md)**
for the AI-agent workflow.

---

## How srv.sh works

`scripts/srv.sh` is a **full verbatim copy** of `olcrtc-upstream/script/srv.sh` with non-interactive patches applied inline. Patches are marked with `# boc olcrtc-ios` / `# eoc olcrtc-ios` markers so they can be audited easily:

```bash
# boc olcrtc-ios: read carrier from env instead of interactive prompt
CARRIER=${OLCRTC_CARRIER:-telemost}
# eoc olcrtc-ios
```

`scripts/parity_check.py` runs as an Xcode pre-build phase and verifies that every **unmarked** line in `srv.sh` still appears verbatim in the upstream `olcrtc-upstream/script/srv.sh`. If upstream changes a command we depend on, the build fails until `srv.sh` is deliberately updated.

### Updating the olcrtc-upstream submodule

```bash
cd olcrtc-upstream
git pull origin master
cd ..
# Rebuild srv.sh if upstream changed script/srv.sh:
diff olcrtc-upstream/script/srv.sh scripts/srv.sh   # review differences
# Re-apply boc/eoc patches as needed, then:
python3 scripts/parity_check.py            # must pass before committing
```

---

## Architecture notes

### Connection flow

```
User taps Connect
  → TunnelManager.connect(record:)
      → start(record:)
          → engine.validate(details)     validate params (MainActor)
          → reservePortAndSettings()      reserve a free SOCKS port + snapshot settings (MainActor)
          → state = .connecting
          → Task.detached
              → runEngine()               drive the protocol engine off-MainActor
                  → engine.start()         OlcrtcEngine: MobileStartWithTransport + MobileWaitReady
                  → verifyTunnel()         end-to-end HTTPS probe through the SOCKS5 port
              → state = .connected
```

### VPS install flow

```
User taps Install
  → SSHRunner.install()
      → loadScript()        read srv.sh from the app bundle
      → uploadScript()      base64-encode + printf | base64 -d over SSH
      → launchBackground()  nohup srv.sh > /tmp/olcrtc-install.log &
      → pollUntilDone()     tail the log every 15 s until OLCRTC_URI= appears
  → parse the URI → save a ConnectionRecord
```

### Key design decisions

- **gomobile singleton** — the Go runtime is a package-level singleton; `TunnelManager` mirrors this so parallel connect attempts bail early.
- **TunnelEngine seam** — protocols sit behind a `TunnelEngine` protocol; `TunnelManager` is protocol-agnostic and dispatches to the engine named by `ConnectionDetails` (today `OlcrtcEngine`, the only place that touches `Mobile*`).
- **Background keep-alive** — `BackgroundRuntimeKeeper` plays a silent looping AVAudio buffer so iOS doesn't suspend the app while the tunnel is active (`UIBackgroundModes: audio`).
- **srv.sh parity** — instead of duplicating the install logic we keep a marked-up copy of the upstream script and fail the build on drift (see [How srv.sh works](#how-srvsh-works)).
- **ATS stays on** — `NSAllowsArbitraryLoads` is `false`, so all `URLSession` traffic is HTTPS (`SubscriptionFetcher` uses an ephemeral session with a DoH fallback). The only raw-socket path is `NetPing`'s `NWConnection` TCP latency probe, which ATS doesn't govern.

---

## Testing

```bash
xcodebuild test \
  -project olcrtc-ios.xcodeproj \
  -scheme olcrtc-ios-tests \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

166 unit tests cover URI round-trips, carrier/transport rules, connection persistence, Keychain round-trips, the tunnel state machine and parameter validation, settings clamping, log secret-redaction, port selection, SSH output parsing, and `installEnv()` ↔ `srv.sh` env-var parity. They also run on every push and PR in [CI](.github/workflows/ci.yml).

---

## Troubleshooting

### Xcode version mismatch

**Symptom:** project fails to open, or you see "deployment target X is not supported by this version of Xcode".

The project targets iOS 17 and requires Xcode 15 or later. Check your version with `xcodebuild -version`. If you have multiple Xcodes, run `sudo xcode-select -s /path/to/Xcode15.app` to switch. After switching, run `xcodegen generate --spec project.yml` to regenerate the `.xcodeproj`.

---

### Parity pre-build phase fails

**Symptom:** the build stops at the srv.sh parity pre-build phase with a diff error.

This means the upstream submodule (`olcrtc-upstream/script/srv.sh`) changed and your local `scripts/srv.sh` no longer matches it line-for-line outside the `# boc olcrtc-ios` / `# eoc olcrtc-ios` markers.

Fix:
```bash
cd olcrtc-upstream && git pull origin master && cd ..
diff olcrtc-upstream/script/srv.sh scripts/srv.sh   # review what changed
# Re-apply boc/eoc patches as needed, then verify:
python3 scripts/parity_check.py            # must pass before building
```

See [How srv.sh works](#how-srvsh-works) for the full patching workflow.

---

### Missing Mobile.xcframework

**Symptom:** Xcode cannot find `App/Mobile.xcframework`, or you see a "framework not found Mobile" linker error.

The framework is not in git. Download or build it:

```bash
./scripts/fetch-framework.sh     # download the prebuilt (needs gh), or
./scripts/build-framework.sh     # build from source (needs Go + gomobile)
```

See [Mobile.xcframework](#mobilexcframework) for details.

---

### Common SSH connect errors

| Error | Likely cause | Fix |
|---|---|---|
| **Timeout / connection hangs** | Port 22 is firewalled or the VPS is unreachable | Verify with `nc -zv <host> 22` from a terminal. Check VPS firewall rules. |
| **Authentication failed** | Wrong password or key, or the wrong username | Double-check credentials in the server profile. The app uses the username exactly as entered. |
| **Connection refused** | `sshd` is not running on the VPS | SSH into the VPS via another client and confirm `sshd` is running (`systemctl status sshd`). |

The app retries the connection twice (2 × 30 s) before surfacing the error. If it fails consistently, reproduce manually with `ssh user@host` to isolate whether the issue is network-side or credential-side.

---

## Contributing

Contributions are welcome. Before opening a PR:

- Read [CONTRIBUTING.md](CONTRIBUTING.md) for the conventions (Conventional Commits, English-only, task markers), and [AGENTS.md](AGENTS.md) if you work with an AI coding agent.
- Work is tracked in [TODO.md](TODO.md) — pick an **Open** task or file a new one.
- `xcodebuild test` and the `scripts/srv.sh` parity check run in [CI](.github/workflows/ci.yml) on every PR; keep them green.

Bug reports and feature requests use the [issue templates](.github/ISSUE_TEMPLATE).

---

## License

MIT — see [LICENSE](LICENSE).

---

## Disclaimer

This is alpha-quality software, provided as-is and without warranty of any kind. You are responsible for any servers you provision with it, and for using it in accordance with the terms of the conferencing services involved and any laws that apply to you.
