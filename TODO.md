# TODO

Task ledger for olcrtc-ios. Every task has a permanent numeric ID and flows
**Backlog → Open → Closed**. This is the single place work is tracked;
`AGENTS.md` and `CONTRIBUTING.md` point here.

## How this file works

**Lifecycle**

1. **New task** → add a row to **Backlog**, and (if the title isn't enough) a
   block under **Details** with the full description.
2. **Work starts** → move the row to **Open**.
3. **Finished** → move the row to **Closed**, fill the **Resolution** column (how
   it was resolved — or `Won't Do` / `Duplicate` for rejected tasks), fill the
   **Release note** column (#315 — see below), and **delete its Details block**.
4. **Parked** → move the row to **Deferred** (the very end of the file) and fill
   its **Reason** column — blocked on something external (paid dev account,
   upstream-only work) or consciously postponed (low priority). Deferred tasks
   keep their Details blocks; revive one by moving the row back to Backlog or
   Open and dropping the Reason.

A rejected or duplicate task is also closed (Resolution `Won't Do` / `Duplicate`);
there is no separate "won't do" list. Detail blocks exist only for **Open +
Backlog + Deferred** tasks. Closed tasks are title-only history plus the
**Resolution** note — their full setup descriptions are intentionally not kept.

**Release note** (#315) — one short, user-facing "what's new" sentence describing
the change, filled in when the row is closed. `scripts/closed-tasks-since.py`
puts **this column** (not the verbose Resolution) into the GitHub Release notes;
put `—` when there's nothing worth announcing (internal-only change) — the
script then falls back to the task title. Rows closed before #315 carry `—`.

**Columns**

- **Pri** — `P0` critical (correctness / security / broken) · `P1` high ·
  `P2` medium · `P3` low / nice-to-have.
- **Eff** — `XS` ≤ 15 min · `S` ≤ 1 h · `M` ≤ ½ day · `L` ≤ 2 days · `XL` > 2 days.
- **Theme** — security · reliability · architecture · parity (server↔client wire
  contract) · tests · observability · ux · docs · build · l10n · features ·
  migration · accessibility · performance · settings.

**Sorting** — every table (Open, Backlog, Closed, Deferred) and the Details blocks
are kept in **ascending ID** order.

**Layout** — Open and Backlog come first, then their **Details** blocks, then the
**Closed** history, then the **Deferred** table last — active work and its
descriptions stay at the top, parked work sits at the very bottom.

**Table formats** — never delete a section's table when it empties; keep the header
rows so the structure survives and nothing has to be rebuilt from scratch. The columns are:

- **Open** / **Backlog** — `| ID | Pri | Eff | Theme | Title |`
- **Closed** — `| ID | Theme | Title | Resolution | Release note |`
  (#315 was: 4 columns, no Release note — `closed-tasks-since.py` still parses
  the old shape at historic git refs)
- **Deferred** — `| ID | Pri | Eff | Theme | Title | Reason |`
  (placed after Closed so `closed-tasks-since.py`'s Closed-section parser, which
  stops at the next `## ` heading, never sees the six-column rows)

When **Open** has no rows, keep the header + separator and leave a single placeholder
row — `| — | — | — | — | _(empty — promote one from Backlog)_ |` — instead of replacing
the table with prose.

**Next free ID:** 357

---

## Open

Current, actionable work.

| ID | Pri | Eff | Theme | Title |
|---|---|---|---|---|
| 323 | P3 | S | ux | #295 (`d8d04df`): non-ASCII labels sanitize to the `"server"` log prefix — two Cyrillic-named hosts collide (confusing "duplicate name" error on add; pre-#295 hosts silently share one container log file) |
| 324 | P3 | XS | observability | #294 (`d8d04df`): IPChecker never calls `startSession(.diagnostics)` — IP-check lines miss `diagnostics.log` until a speed test creates the writer, while the Logs tab header advertises that file |
| 328 | P2 | M | ux | Show the active carrier's hosts/IPs with one-tap copy — what to exclude in Shadowrocket-style apps to avoid the proxy loop |
| 330 | P1 | M | reliability | Edit sheet of the current connection: app hangs on open and on close |
| 331 | P3 | M | observability | Provisioning vs Container logs largely repeat each other — split by line origin (proposal in Details) |
| 333 | P1 | M | reliability | Port reads "busy" for seconds after disconnect, blocking reconnect on our own ghost — bounded same-port wait/retry, keep the #308 contract (proposal in Details) |
| 334 | P3 | S | ux | Container-log download shows no activity on the server card — add a progress/busy indicator |
| 335 | P3 | S | ux | Server card progress bar start: text overlaps for ~0.5 s — fix the visual jank |
| 337 | P3 | S | ux | Hide IPs in the UI for screenshot-safe sharing — a Settings toggle masks Diagnostics (IP-check results) and Manage VPS (host addresses); logs excluded |
| 346 | P3 | XS | l10n | #341 (build 248): VPS-card mini-stat labels "Ping"/"Disk"/"RAM"/"Up" are hardcoded — route through L10n like the #311 speed-tile labels (units like "ms" stay English, ru = en — operator decision); same for the pre-existing `"Restored: %@"` alert (#303) in ServersView |

---

## Backlog

Future / blocked / someday. Promote to Open when picked up.

| ID | Pri | Eff | Theme | Title |
|---|---|---|---|---|
| 135 | P3 | M | features | Share connection (full access: SSH creds + URI, for co-admin) |
| 279 | P2 | L | observability | Message catalog: typed (info/warn/error), error-coded client+server messages, searchable + troubleshooting cross-ref |
| 329 | P2 | L | features | On server stop: kick all participants + close the room, behind a setting (default ON) — **UPSTREAM-only**: needs core room-control support at shutdown; the iOS side is just a Settings toggle + `OLCRTC_*` env var once upstream lands |
| 347 | P3 | XS | build | closed-tasks-since.py: skip Closed rows whose Release note is `—` instead of falling back to the title — service-task titles (#322/#345 "amend the commit message") leak into release notes |
| 350 | P3 | S | ux | Remaining ad-hoc colors → Theme.Palette (#317 follow-up): CarrierTransportMatrix `Compat.color` + the matrix legend (bare .green/.orange/.red/systemGray), ConnectionsView `.tint(.orange)`, ServersView container-status `Color.green/.orange` |
| 351 | P2 | S | reliability | Live sessions still read the *configured* SOCKS port (#313 follow-up): SOCKSSession builds tunnel-mode sessions from `TunnelManager.socksPort`, so after a live port edit keep-alive verify targets the wrong port and tears down a healthy tunnel (~90 s); the Connections hero shows the wrong port too — prefer `boundPort` while connected (needs a nonisolated mirror) |
| 352 | P3 | S | observability | On-disk log rotation (#332/#336 follow-up): per-category and container log files append forever across sessions — add size-capped truncation at session start |
| 353 | P3 | XS | performance | LogsView toolbar builds the full share/export string eagerly on every refresh — add a lazily-evaluated share item to OlcOverflowMenu (#332 follow-up) |
| 354 | P3 | S | features | Plain `olcrtc://` links open the app but import nothing (#111 follow-up) — route single-URI links into the same confirm-then-import flow as `olcrtc-sub://` |
| 355 | P2 | S | parity | `OlcrtcURI.parse` drops seichannel payload params — `fps`/`batch` land in the vp8 fields, `frag`/`ack-ms` are discarded, so sei connections imported from URI/QR/sub/rotate run on defaults (#111 + #314 finding; upstream's own sub.md example carries a sei payload) |
| 356 | P3 | M | features | Subscriptions 2.0 (#111 follow-up): persist the sub source URL per imported group, honor `#refresh`, dedup re-imports (re-opening the same link currently adds duplicates) |

---

## Details (Open + Backlog + Deferred only)

### 112 — NetworkExtension packet tunnel

Full-device VPN (route every app, not just SOCKS-aware ones) needs a NetworkExtension
Packet Tunnel provider + the `packet-tunnel-provider` entitlement, which requires a paid
($99/yr) Apple Developer account. The standard pattern — confirmed by olcbox, a 5-platform
olcrtc client — is to keep running the olcrtc core as a local SOCKS5 and bridge TUN↔SOCKS5
with [`hev-socks5-tunnel`](https://github.com/heiher/hev-socks5-tunnel) inside the
`PacketTunnelProvider`. Worth noting even olcbox skipped iOS TUN (its iOS target is
SOCKS5-only — "a Swift shell"), so this is high-effort / low-ROI and gated on the paid
account.

### 115 — TestFlight

Stand up the App Store Connect app record and a TestFlight build for internal
testing. Prerequisites: a real app icon (#248), the privacy manifest (#249), and
signing (set `DEVELOPMENT_TEAM`). On-device testing over cellular and inside RU
networks is already handled by the maintainer — this task is only the TestFlight
pipeline (archive → upload → internal testers).

### 235 — Failover profiles: multi-carrier iOS install

**BLOCKED on #247.** Server-side failover is supported — `internal/config` parses
`profiles:` / `failover:`, and `cmd/olcrtc/main.go` drives them through
`internal/supervisor` (runs profiles in order; on a session drop it waits
`retry_delay` and advances, up to `max_cycles`). `srv.sh` could emit a multi-profile
`server.yaml`:

```yaml
mode: srv
profiles:
  - name: jitsi-primary
    auth: { provider: jitsi }
    room: { id: "https://meet1.arbitr.ru/myroom" }
  - name: telemost-fallback
    auth: { provider: telemost }
    room: { id: "telemost-room-id" }
failover: { retry_delay: 5s, max_cycles: 3 }
```

The blocker: client and server rendezvous in the **same conferencing room**, and a
profile switch changes carrier *and* room (`config.ApplyProfile`). The bundled
`Mobile.xcframework` is single-session only — `mobile/mobile.go` exposes
`Start`/`StartWithTransport`/`Stop` and imports neither `config` nor `supervisor`, so
the iOS client has no way to follow the server's switch; when the server moves it is
left calling an empty room. A server-only multi-profile install is therefore *worse*
than none on iOS. #247 (failover in the gomobile binding) must land first.

Once unblocked, the iOS work is: `InstallOptions` gains a list of `FailoverProfile`
(carrier + roomID); `InstallOptionsView` gets an "Add fallback carrier" button;
`SSHRunner` generates multi-profile YAML; `ConnectionRecord` represents a
multi-profile connection (which roomID/carrier to show); `TunnelManager` drives the
client failover loop exposed by #247.

### 247 — Failover/profiles in the gomobile binding

Prerequisite for #235. The server cycles failover profiles (`internal/supervisor`,
wired in `cmd/olcrtc/main.go`), but the iOS client binding
(`olcrtc-upstream/mobile/mobile.go`) is single-session and has no way to follow a
carrier/room switch. Expose a profile-aware client entry point — an ordered list of
carrier/room/transport that the client cycles through, mirroring the server's
`retry_delay` / `max_cycles` — or a lighter "reconnect across an ordered carrier list
until the server is found" loop. Needs upstream Go work in `mobile/` (the existing
`supervisor.Runner` is the *server* session runner; a client-side supervisor doesn't
exist yet) plus a `Mobile.xcframework` rebuild. Until this lands, end-to-end failover
on iOS is only achievable via an app-level Swift loop whose client/server convergence
is best-effort (they can sit on different profiles during the detection-skew window).

**Decision (2026-06-04): UPSTREAM-only — do not fork or patch the submodule locally.**
CI (`ci.yml`), `release.yml`, and every cloner's `fetch-framework.sh` build the framework
from the *pinned* upstream commit, so a local edit to `olcrtc-upstream/mobile/mobile.go`
would build on the maintainer's machine but break CI and every clone (the published
framework wouldn't carry the new symbol, and the Swift calling it wouldn't link). The
client entry point — sketch `StartWithProfiles(profilesSpec, clientID, keyHex, socksPort,
socksUser, socksPass, retryDelayMillis, maxCycles)`: cycle an ordered carrier/room/transport
list in the existing singleton slot, reusing `client.RunWithReady` with a per-profile
handshake-timeout advance, mirroring `internal/supervisor`'s `retry_delay`/`max_cycles` —
must therefore land in **upstream** `mobile/mobile.go`. Re-check on each `olcrtc-upstream`
pull (the #260-style integration); **close when upstream ships it**, after which the iOS
side is only an `OlcrtcEngine` wiring + a framework rebuild.

### 254 — CODE_OF_CONDUCT.md

Adopt the standard Contributor Covenant. The only decision is the enforcement-contact
method (a maintainer email, or "via GitHub private report") to fill the template
placeholder. Community-health hygiene; not blocking the first push.

### 257 — Privacy-policy document

App Store submission requires a privacy-policy URL even when the app collects nothing.
Write a short policy ("no personal data collected or transmitted; the encryption key and
SSH credentials never leave the device / Keychain") and host it (GitHub Pages or a gist),
then link it from App Store Connect and the README. Distinct from the in-bundle privacy
manifest (#249).

### 279 — Message catalog: typed, error-coded client + server messages

Define a **table of known conditions → messages** for both client and server, each with a
**type** (info / warn / error) and a stable **error code**, emitted into the logs when its
condition fires. Make the codes **searchable** and cross-referenced with the README
troubleshooting section, so a user hitting code `Cxx`/`Sxx` can look it up. **Prereq:** the
maintainer will send real container logs so we can pick which server-side conditions are worth
catching (e.g. room-missing → #275). Pairs with #276's level colour-coding.

**Seed catalog from a real `podman logs` capture (2026-06, telemost/vp8channel).** Server core lines
carry *no* level tag (only the bundled pion `[pc]`/`[ice]` lines do) — assign:
- `info` — `Connecting transport=… carrier=…` (session start), `Link connected` (control link up),
  `session opened: id=… device=… claims=…` / `session … opened (peer=…)` (peer joined the room ✓),
  `session closed: … reason=…` (peer left), `Shutting down gracefully…`;
- `warn` — `control missed pong on server … missed_pongs=N` (liveness degrading; escalate to **error**
  at N≥3 → imminent drop, the server-side mirror of our keep-alive loss);
- `debug/noise` — `sid=N connect/connected host:port`, `traffic: session=… addr=… in=N out=N`
  (very verbose — ~22% of lines; default-hidden), `vp8channel: KCP started` / `peer session created`,
  and the benign pion noise (`[pc] WARN: …stream is already closed`, `…PayloadType…(EOF)`,
  `[ice] WARN: Failed to ping without candidate pairs`, `[ice] INFO: Failed to send packet… network
  is unreachable` = IPv6-unreachable spam).
There were **no error-level lines in a healthy run** — true errors (carrier-auth, room-not-found,
panic) need a failing capture. Note the **server timestamp is Go's `2006/01/02 15:04:05`** (slashes,
second precision, no millis) — #277/#278 must reformat + tolerate the missing `.SSS`.

**Catalog seeded → [`docs/diagnostic-messages.md`](diagnostic-messages.md)** (client `OLC-1xxx` + server
`OLC-2xxx`, typed I/W/E, one continuous unique code space, from real client + server captures). #279 is
now the *wiring*: emit these coded lines from the right places (and detect the 🟡-planned ones), make the
codes searchable in the merged Logs stream (#276), and cross-link from the README troubleshooting.

### 299 — Theme = real colour schemes (Dark / Light / Gray)

**User wants this prioritised.** The current "Theme" picker (Refined/Console — #267/#281) only changes
corner radii + border weight; it does **not** change colours, which is what "Theme" should mean. Replace
it with **Dark / Light / Gray** colour schemes that actually swap the palette (`Theme.Palette`). The app
is currently forced-dark (`UIUserInterfaceStyle=Dark` in project.yml) — Light/Gray require lifting that
and authoring light + neutral-gray palettes while keeping the design-system component structure. Drop
the shape/border-only "design direction" framing.

### 328 — Carrier endpoints with one-tap copy (proxy-loop exclusions)

When an external app (e.g. Shadowrocket) routes *all* traffic through the
olcrtc SOCKS port, the tunnel's own carrier traffic (the Jitsi/telemost server)
must bypass the proxy or it loops. Today it's hard to tell which addresses to
exclude. Show, for the active connection, the carrier endpoints actually in
use — at minimum the carrier base host (e.g. `meet1.arbitr.ru`), its currently
resolved IPs (they rotate, so copy both host and IPs), and STUN/TURN hosts if
used — each one-tap copyable, with a short "add these as DIRECT rules in your
proxy app" hint. Sources: the `OlcrtcConnection` params + a resolver pass;
check what `Mobile.objc.h` exposes about live ICE endpoints before promising
IP-level accuracy.

### 329 — Kick participants + close the room on server stop

When the olcrtc server stops, the conference room currently stays open with
stale participants. Wanted: on server stop the server kicks all participants
and closes/ends the room — gated by a setting, **default ON**. Carrier-
dependent (Jitsi: end conference; telemost/wbstream: TBD) and likely needs
core/upstream support — check what the core exposes at shutdown before
scoping. Probably splits into an upstream change + an iOS toggle (Settings +
an `OLCRTC_*` env var through srv.sh, boc-patched).

### 331 — Provisioning vs Container logs: split by line origin (proposal)

Overlap: during install/start the provisioning stream carries the script's
output, which includes the container's own startup lines; "Download logs"
later re-pulls those same lines into the per-server container log — the two
tabs largely repeat each other. Proposed split — classify by **origin**, not
by operation:

- **provisioning** keeps orchestration only: SSH steps, script phase markers,
  ✓/✗ statuses, errors;
- anything **produced by the container itself** (the `podman logs` output, the
  container-startup tail inside the install output) always routes to the
  per-server container log (#295), even when it arrives during provisioning;
- at each hand-off, provisioning logs one pointer line ("container output →
  Container tab") so the narrative stays followable.

Implementation sketch: the install/start paths in `SSHRunner`/`Provisioning`
detect the container-output section of the script output and feed it through
`logContainer` instead of `.provisioning`. Once every line has exactly one
home, no dedupe pass is needed.

### 333 — Port "busy" right after disconnect (proposal)

After stopping the tunnel, the SOCKS port reads busy for a few seconds (the
core's listener teardown is asynchronous / the socket lingers), so an
immediate reconnect fails on our own ghost. The #308 contract stays untouched:
bind exactly the configured port, typed "port busy" error, **no port sliding**.
Proposal:

- first check the disconnect path: if we can await the core's listener close
  before reporting "disconnected", the window disappears at the source (and
  check whether the core can set `SO_REUSEADDR` upstream);
- client-side mitigation: on connect, if the configured port is busy AND we
  disconnected ourselves within the last ~10 s, wait-and-retry the **same**
  port (poll ~every 250 ms, up to ~5 s, with a "waiting for port release…"
  status) before surfacing the typed busy error.

### 337 — Hide IPs in the UI (screenshot-safe mode)

A **Settings toggle** (off by default) that masks IP addresses in the UI so
screenshots can be shared safely. Scope: the Diagnostics block on the
Connections tab (IP-check result rows) and Manage VPS (host addresses on
server cards / detail). **Logs are deliberately excluded** — they stay
unmasked. Mask style up to the implementer (e.g. keep the last octet:
`•••.•••.•.12`); masking is display-only — copy actions and the underlying
stored values stay real.

### 347 — closed-tasks-since.py: skip `—` Release-note rows

#315's fallback puts the task **title** into the release notes when the
Release note cell is `—`. For service rows that's exactly the text we don't
want published — #322's and #345's "amend the commit message before push"
titles leaked into release notes this way. Change `closed-tasks-since.py` to
**skip** rows whose Release note is `—` (or empty) instead of falling back to
the title; `—` then means "internal-only, not announced", matching its intent.
Update the TODO.md header sentence ("the script then falls back to the task
title") and the script's docstring to match.

---

## Closed

History of completed tasks. The **Resolution** column is a one-line "how it was
resolved" note for tasks closed under the current workflow; older entries are
title-only. The **Release note** column (#315) is the short user-facing line the
release notes use; `—` on rows closed before #315 or with nothing to announce.

| ID | Theme | Title | Resolution | Release note |
|---|---|---|---|---|
| 001 | reliability | SSH connect timeout — reproduce + document network-side root cause |  | — |
| 002 | parity | URI parser accepts URIs without `%clientID` |  | — |
| 003 | migration | Adapt Provisioning to upstream YAML config switch — triggered; covered by #221 + #222 |  | — |
| 004 | security | KeychainHelper — atomic upsert, no silent write failure |  | — |
| 005 | reliability | TunnelManager — retry ↔ disconnect race fix |  | — |
| 006 | architecture | `LogStore.log()` marked `@MainActor` |  | — |
| 007 | reliability | `BackgroundRuntimeKeeper` — guard let + rollback on engine.start failure |  | — |
| 008 | security | `NSAllowsArbitraryLoads: false` (all URLSession is HTTPS) |  | — |
| 009 | security | `SubscriptionFetcher` TLS host-override audit |  | — |
| 010 | reliability | `SettingsStore` — didSet clamping + `Defaults` enum |  | — |
| 011 | security | `KeychainHelper` — distinguish not-found from error |  | — |
| 012 | security | `KeychainHelper` — atomic delete+add via SecItemUpdate |  | — |
| 013 | architecture | `SettingsStore` snapshot before `Task.detached` (already correct, documented) |  | — |
| 014 | architecture | `Provisioning.install()` split into 5 phases |  | — |
| 015 | architecture | `TunnelManager.startOlcrtc()` split into preflight + runMobile |  | — |
| 016 | architecture | `SSHRunner.withConnection` helper (replaces 8 close calls) |  | — |
| 017 | architecture | `OlcrtcURI.parse()` split into named helpers |  | — |
| 018 | docs | README — structure, requirements, quick start, architecture |  | — |
| 019 | build | GitHub publish prep — LICENSE, .gitignore, no hardcoded paths |  | — |
| 020 | build | `olcrtc://` URL scheme registered in project.yml |  | — |
| 021 | architecture | Dedup SSH close × 8 (subsumed by #016) |  | — |
| 022 | architecture | Dedup guard-password/container × 4 |  | — |
| 023 | ux | Dedup copy-feedback pattern × 2 |  | — |
| 024 | architecture | Dedup `ContainerStatus.parse()` |  | — |
| 025 | architecture | Tunnel verify URL + fallback → `AppConstants` |  | — |
| 026 | architecture | Remote temp paths → `RemotePaths` enum |  | — |
| 027 | architecture | Poll constants named (`installMaxPolls`, etc.) |  | — |
| 028 | ux | DNS presets → `AppConstants.dnsPresets` |  | — |
| 029 | architecture | SpeedTest constants → `AppConstants.SpeedTest` |  | — |
| 030 | architecture | IPChecker services → `AppConstants.ipCheckServices` |  | — |
| 031 | architecture | `SettingsStore.Defaults` enum + range constants |  | — |
| 032 | docs | Doc comments on ObservableObject classes |  | — |
| 033 | docs | `OlcrtcURI` dual-format payload comment |  | — |
| 034 | docs | `ContinuationGate` `@unchecked Sendable` (first pass) |  | — |
| 035 | docs | `ProvisionError` cases doc-commented |  | — |
| 036 | tests | `TunnelManager.validate()` tests |  | — |
| 037 | tests | `SSHRunner.extract()` + `parseInstallResult()` tests |  | — |
| 038 | tests | URI parser edge case tests |  | — |
| 039 | tests | `PortAvailability.isFree` tests |  | — |
| 040 | tests | `KeychainHelper` roundtrip tests |  | — |
| 041 | tests | Provisioning poll-loop tests — needs `SSHClientProtocol` mock abstraction |  | — |
| 042 | build | `parity_check.py` line numbers + structural validation |  | — |
| 043 | ux | SettingsView — Steppers → TextField + quick-pick presets |  | — |
| 044 | security | `IPChecker` — proper IPv4/IPv6 validation |  | — |
| 045 | reliability | `SettingsStore.reset()` + fontSizeIndex clamp |  | — |
| 046 | architecture | Dead-code sweep |  | — |
| 047 | l10n | Translate UI to English with multi-language support |  | — |
| 048 | l10n | Translate code/docs to English |  | — |
| 049 | parity | Compatibility matrix — add jitsi carrier (new in universal-carrier); update existing cells |  | — |
| 050 | reliability | Install poll loop — explicit catch + classify SSH errors |  | — |
| 051 | reliability | Mid-install TCP-22 reachability re-probe every 5 polls |  | — |
| 052 | security | `OLCRTC_DNS` wrapped in `shellSafe()` |  | — |
| 053 | reliability | `LogFileWriter` — guard let Documents URL |  | — |
| 054 | observability | `bgKeeper.start()` — explicit catch + L10n log |  | — |
| 055 | architecture | Split `Provisioning.swift` → `SSHRunner.swift` |  | — |
| 056 | architecture | Group `App/` files by responsibility (`Core/`, `Models/`, `Views/`, …) |  | — |
| 058 | docs | `Provisioner` `@StateObject` lifecycle doc-block |  | — |
| 059 | reliability | Keep-alive / retry tasks — uniform synchronous-nil discipline |  | — |
| 060 | docs | `MobileSet*` thread-safety audit + doc |  | — |
| 061 | reliability | `SettingsStore` UserDefaults writes async (off-MainActor) |  | — |
| 062 | ux | `AddServerHostView` pre-fills password on edit |  | — |
| 063 | tests | `TunnelManager` state-machine tests (11 cases; private-state gaps documented) |  | — |
| 064 | tests | Provisioning polling untested (duplicate of #041) | Duplicate | — |
| 065 | tests | `ConnectionStore` persistence tests |  | — |
| 066 | tests | `SettingsStore` clamping tests |  | — |
| 067 | tests | `PortAvailabilityTests` retry-loop cap |  | — |
| 068 | observability | `verifyTunnel()` — per-URL success/failure log |  | — |
| 069 | architecture | Standardize `Task.sleep(for: .seconds(_:))` |  | — |
| 070 | reliability | `SubscriptionFetcher` — ephemeral URLSession (no cache) |  | — |
| 071 | reliability | `SubscriptionFetcher` — uniform 15 s timeout |  | — |
| 072 | reliability | `tunnelVerifyURLs` — add 3rd `ifconfig.me` fallback |  | — |
| 073 | reliability | `SubscriptionFetcher` — DoH endpoint fallback list |  | — |
| 074 | observability | `LogsView.fullText` recompute → cache via onChange |  | — |
| 075 | docs | `ContinuationGate` `@unchecked Sendable` — expand invariant doc |  | — |
| 076 | observability | `TunnelManager` — state-transition log line in didSet |  | — |
| 077 | docs | TODO.md P2 header renamed "Pre-publish polish (historical)" |  | — |
| 078 | docs | Move upstream-refactor section to `docs/UPSTREAM_MIGRATION_PLAN.md` |  | — |
| 079 | docs | README troubleshooting section |  | — |
| 080 | docs | README — Mobile.xcframework build instructions tightened |  | — |
| 081 | docs | `scripts/srv.sh` patch description tenses — standardize to imperative |  | — |
| 082 | docs | `parity_check.py` error message — concrete next-step diff hint |  | — |
| 083 | docs | Doc-comments on misc structs/enums (`IPResult`, `SpeedResult`, etc.) |  | — |
| 084 | build | `Entitlements.plist` for explicit `audio` background mode |  | — |
| 085 | reliability | Parallelize tunnel-verify probe (first-success wins) |  | — |
| 086 | parity | Container-name prefix sync (`olcrtc-server-` everywhere) |  | — |
| 087 | parity | SEI/video transport — UI hint about server defaults (option b) |  | — |
| 088 | security | `LogStore.redactSecrets()` — key + URI key-segment redaction |  | — |
| 089 | parity | `OLCRTC_CONFIG_NAME` duplication — kept + cross-ref comment |  | — |
| 090 | parity | `mimo` ↔ `sub_configname` naming drift | cross-ref comments link client `mimo` ↔ server `sub_configname`/`OLCRTC_CONFIG_NAME` | — |
| 091 | parity | DNS default differs (Yandex client vs Google upstream) | documented deliberate Yandex default in srv.sh boc | — |
| 092 | parity | Plumb `--branch=` from client to srv.sh | Won't Do | — |
| 093 | parity | Document `OLCRTC_CACHE_DIR` capability (or surface in UI) | documented in `SSHRunner.installEnv()`: a server-side Go-cache knob; client leaves it at the persistent default `$HOME/.cache/olcrtc` (surface in Settings only if a custom cache location is ever needed) | — |
| 094 | parity | Container accumulation across re-installs | srv.sh sweeps prior `olcrtc-server-*` before a new install (boc block) | — |
| 095 | observability | `pollUntilDone` — offset-tracked log streaming |  | — |
| 096 | parity | `--no-cache` flag — document, plumb, or remove | documented at the srv.sh invocation in `SSHRunner.launchBackground()`: client runs the script with no args so the Go cache is always reused (fast installs); a future clean-rebuild option (#109) would pass `--no-cache` | — |
| 097 | features | SEI/VIDEO env vars end-to-end UI, or commit to VP8-only | Decision: keep all four transports, no VIDEO_* UI. Premise was stale — OLCRTC_SEI_* is end-to-end since the install sheet gained SEI steppers (UI → installEnv → srv.sh → URI), and "VP8-only" would drop working transports (sei/video are ✓ on wbstream/telemost). videochannel keeps installing with server defaults (ten niche knobs deliberately unexposed); the stale install-sheet footer that still claimed *seichannel* uses server defaults now warns for videochannel only; decision recorded at the installEnv NOTE + the srv.sh boc comment | Install sheet: the "uses server defaults" note now applies only to videochannel — SEI tuning has its own steppers |
| 098 | architecture | Shared constants file for `RemotePaths` (server doesn't read them — document) |  | — |
| 099 | architecture | `extract(keys:from:)` single-pass overload |  | — |
| 100 | parity | `requiresRoomID` source-of-truth in `CarrierTransportMatrix` |  | — |
| 101 | migration | Migrate to olcrtc @ master (migration umbrella) | done via #221-#229; submodule @587c13e; residuals tracked as #230/#232/#235 | — |
| 102 | features | QR code import (AVCaptureSession + Vision) |  | — |
| 103 | features | QR code export (CIFilter.qrCodeGenerator) |  | — |
| 104 | features | Room ID OR link auto-detect in paste field |  | — |
| 105 | features | Room ID rotation without full reinstall |  | — |
| 106 | features | Change transport without reinstall |  | — |
| 107 | features | RU-carrier DNS presets |  | — |
| 108 | reliability | SOCKS port auto-retry (slide to next free) |  | — |
| 109 | features | Re-install / update olcrtc (git pull + rebuild, skip apt) |  | — |
| 110 | features | SEI channel params editor in OlcrtcConnection + UI |  | — |
| 111 | features | Subscription URLs (`olcrtc-sub://`) | `olcrtc-sub` scheme registered (project.yml); link maps to https (documented in docs/uri.md — the scheme mapping is an olcrtc-ios convention, upstream only hosts the file); body parsed per upstream docs/sub.md (`#name`→group, `##name`→record name, tolerant of bad lines) via new OlcrtcSubscription + the previously caller-less SubscriptionFetcher (DoH fallback); first-ever onOpenURL handler in App.swift, confirm-then-import through ConnectionStore; errors via existing sub* strings; 10 unit tests. Follow-ups filed: #354 (plain olcrtc:// links), #355 (URI parser drops sei params), #356 (refresh/dedup) | Open an olcrtc-sub:// subscription link to import a whole server list in one tap |
| 118 | ux | Tab bar overlaps content — add bottom safe-area padding to all tab root views |  | — |
| 119 | ux | Install progress — named phase title + detail subtitle (not raw log lines) |  | — |
| 120 | features | VPS "Stop server" — podman stop without uninstall (leave room without wiping) |  | — |
| 121 | features | Auto-link VPS install → ConnectionRecord; optional auto-delete on uninstall |  | — |
| 122 | ux | Logs: preserve previous session — startSession should archive not clear |  | — |
| 123 | ux | IPChecker: append logs, don't call startSession (overwrites previous IP check) |  | — |
| 124 | l10n | EN "Servers" tab → "Manage VPS"; "Speed" category → "Speed test" |  | — |
| 125 | l10n | Default connection group name: "Main" → "Servers" |  | — |
| 126 | ux | Settings SOCKS port: remove Stepper +/−, add "Random port" button |  | — |
| 127 | ux | App version display: "1.0 (N)" → "1.0.N" in Settings Info section |  | — |
| 128 | ux | Uninstall confirmation: clarify scope (container only; cache/image stay) |  | — |
| 129 | settings | Toggle: auto-remove connection from list when VPS uninstalled (on by default) |  | — |
| 130 | features | Deep uninstall: remove container + Go cache + key + optionally image |  | — |
| 131 | features | VPS server state detection: show what's installed (Podman? cache? container running?) |  | — |
| 132 | l10n | Hardcoded UI strings audit: "Transport", "Room ID", "SEI Settings" (InstallOptionsView, ReconfigureOptionsView), "QR" label (ConnectionsView) → L10n |  | — |
| 133 | features | Scan VPS for existing olcrtc containers (by user request, not auto) — recover after reinstall/new device |  | — |
| 134 | features | Share connection (connection-only: URI without SSH credentials) |  | — |
| 136 | ux | VPS card: show disk space, RAM, uptime alongside readiness state |  | — |
| 137 | security | Local SOCKS5 auth — toggle + username/password in Settings, off by default |  | — |
| 138 | reliability | Reconfigure → update linked ConnectionRecord: after room/transport change, ConnectionRecord has stale URI — root cause of connection instability after reconfigure |  | — |
| 139 | reliability | Room ID spaces: strip on any input (paste/type) in AddConnectionView, not just on save |  | — |
| 140 | features | Start stopped container — "Start" button for stopped containers (podman start, no reinstall) |  | — |
| 141 | ux | Uninstall + linked connection deleted: show alert/notice that ConnectionRecord was also removed |  | — |
| 142 | ux | Settings: per-setting footers instead of grouped subtitles at section bottom |  | — |
| 143 | ux | VPS menu: split destructive actions into two clear items — "Remove container from server" + "Wipe all olcrtc data" (no guessing submenu) |  | — |
| 144 | ux | Scan sheet: Restore button hidden in swipeActions — make it visible in the row |  | — |
| 145 | reliability | After Restore, `statuses[host.id] == nil` → `?? true` hides Start button; change default to false |  | — |
| 146 | ux | ServersView action layout: big buttons = Status + Ping only; Start/Stop/Update/Logs → context menu |  | — |
| 147 | build | Remove auto-bump build number from Xcode pre-build script; Claude bumps manually on code changes only | removed auto-bump pre-build script; build number bumped by hand | — |
| 148 | reliability | Port auto-increment: preflight() saves bumped port to SettingsStore → port grows on every reconnect |  | — |
| 149 | reliability | Retry without MobileStop: scheduleAutoRetry → MobileStartWithTransport without prior MobileStop → possible double session in room |  | — |
| 150 | ux | numberPad keyboard has no Done button — blocks tab navigation; add FocusState + keyboard toolbar |  | — |
| 151 | ux | SOCKS port change UX: TextField applies immediately but proxy not restarted; add explicit Save + confirmation |  | — |
| 152 | observability | Log proxy port on start: after MobileWaitReady log "SOCKS5 ready on port N" so user knows exact port |  | — |
| 153 | observability | Logs lost on reconnect: keepalive retry fills logBuffer → old logs evicted; consider larger default or session separator |  | — |
| 154 | reliability | AddConnectionView carrier picker hardcoded (wbstream/jazz/telemost); missing jitsi — use CarrierTransportMatrix.carriers |  | — |
| 155 | ux | Connections swipe-delete shows "Remove container from server" (actionUninstall) — wrong label; should be "Remove from list" |  | — |
| 156 | ux | VPS Reboot has no confirmation dialog — reboots the whole VPS without warning |  | — |
| 157 | ux | Key field in AddConnectionView is SecureField — no reveal button; user can't verify 64-char hex was pasted correctly |  | — |
| 158 | ux | Transport picker in AddConnectionView shows all 4 transports regardless of carrier compatibility — should grey out incompatible ones |  | — |
| 159 | ux | LogsView shows oldest first; user must scroll to bottom to see latest — add auto-scroll-to-bottom on appear and on new entries |  | — |
| 160 | ux | All numericField inputs in SettingsView use numberPad but only port field has Done toolbar button; add Done to FPS/batch/timeout/keepalive/logBuffer fields |  | — |
| 161 | ux | AddServerHostView port field uses numberPad but no Done button to dismiss keyboard |  | — |
| 162 | ux | IP check results show no timestamp — stale results look like fresh ones; add "last checked HH:mm" label |  | — |
| 163 | ux | Client ID field default "default" is confusing — add footer explaining it is used to identify this client in multi-client rooms |  | — |
| 164 | ux | Connections server row: pencil Edit button visible AND Edit in context menu — duplicated; remove inline button, keep in context menu only |  | — |
| 165 | ux | Onboarding: first launch shows empty Connections with no workflow guide — add empty-state text explaining Add VPS → Install → Connect flow |  | — |
| 166 | ux | LogsView: no per-category Clear button — "Clear all" nukes everything; add clear per selected category |  | — |
| 167 | ux | Add "Set as primary + Connect" context menu action in Connections list — currently requires two taps (tap to set primary, then toggle) |  | — |
| 168 | ux | InstallOptionsView carrier segmented control: 4 carriers (incl jitsi) is tight on small screen — consider wheel/inline Picker |  | — |
| 169 | ux | AddServerHostView: no "Test SSH connection" button before installing — users discover SSH failure only when install starts |  | — |
| 170 | ux | VPS tab: no guidance after install ("Connection added — go to Connections tab to connect"); users don't know next step |  | — |
| 171 | ux | AddConnectionView: SOCKS5 auth footer says "server started with -socksuser/-sockspass" but these are LOCAL proxy credentials — fix description |  | — |
| 172 | ux | Connections: show current SOCKS proxy port below the global toggle when connected ("proxy :8808") |  | — |
| 173 | ux | Logs: "Share" sends all logs as text blob — add option to share only last N lines or selected category |  | — |
| 174 | ux | VPS server state machine: centralize state, hide/show menu items based on state (no container → no Remove/Update/Stop/Reconfigure) |  | — |
| 175 | ux | Proxy port displays with thousands separator ("8 808") — use .grouping(.never) formatting everywhere |  | — |
| 176 | reliability | TunnelManager state glitch: UI shows Connected after manual disconnect; toggle inconsistent — needs investigation |  | — |
| 177 | ux | SOCKS port check shows "busy" when port is in use by us (connected) — show "in use by tunnel" instead |  | — |
| 178 | ux | Jitsi in CarrierTransportMatrix: mark as .unknown/.notImplemented across all transports — not yet available on master branch |  | — |
| 179 | ux | "Update" menu item label unclear — rename to "Update binary (git pull + rebuild)" or add subtitle explaining what is updated |  | — |
| 180 | ux | Start/Stop container: replace two separate menu items with a single toggle in the VPS card (like the Connect toggle in Connections tab) |  | — |
| 181 | ux | Context menu shows Start even when container is running (status not synced with menu) — gate on latest known status |  | — |
| 182 | ux | VPS card status dot area: merge status dot + stats row into one unified status line; move readiness text there |  | — |
| 183 | ux | SOCKS port Save: explicit Save button with feedback | Won't Do | — |
| 184 | reliability | SettingsStore: redundant didSet clamping loop — value = v triggers didSet again causing double UserDefaults write |  | — |
| 185 | reliability | SSHRunner: `fatalError("unreachable")` in `connect()` — replace with `preconditionFailure` to avoid release crashes |  | — |
| 186 | reliability | Provisioning.reconfigure: returns nil URI silently if server didn't emit OLCRTC_URI — UI shows success but ConnectionRecord not updated; should throw |  | — |
| 187 | reliability | ConnectionsView: `shareConn = nil; DispatchQueue.main.asyncAfter { qrConn = conn }` — race if view dismissed before delay fires; use onDisappear instead |  | — |
| 188 | ux | ServersView: `foundContainers` not cleared when scan sheet dismissed — old results flash briefly on next scan |  | — |
| 189 | observability | KeychainHelper: failure logs missing numeric OSStatus code — hard to debug Keychain errors without the code |  | — |
| 190 | reliability | TunnelManager keep-alive: guard check happens after `verifyTunnel()` call — one wasted network probe after disconnect; add guard before sleep |  | — |
| 191 | reliability | OlcrtcURI: invalid payload key-value pairs silently dropped — log warning for malformed values (e.g. `vp8-batch=abc`) |  | — |
| 192 | build | SSHRunner `_execute()` / `_withConnection()`: missing `@discardableResult` on internal helpers — will produce compiler warnings when warnings enabled |  | — |
| 193 | observability | Provisioning.start() and probeReadiness() missing LogStore.startSession() — inconsistent with all other Provisioner methods |  | — |
| 194 | reliability | NetPing: timeout DispatchWorkItem not cancelled after connection succeeds — fires anyway and wastes resources |  | — |
| 195 | reliability | SubscriptionFetcher: silent empty-string fallback when data can't be decoded as UTF-8 or latin1 — corrupted data treated as valid empty response |  | — |
| 196 | reliability | ConnectionStore.load: JSON decode failure is silent — corrupted UserDefaults loses all connections with no log or user notification |  | — |
| 197 | security | OlcrtcConnection.socksPass is Codable — if struct is ever encoded outside ConnectionStore.scrub() path, password leaks to JSON |  | — |
| 198 | reliability | OlcrtcURI: mixed bracket types in payload (e.g. `transport[bad>@room`) silently misparse — no guard against malformed bracket nesting |  | — |
| 199 | reliability | AddConnectionView: @State form fields not reset when sheet re-presented in create mode — old values persist from previous session |  | — |
| 200 | reliability | SettingsView: socksPassLoaded flag not reset on sheet disappear — SOCKS password not reloaded if changed externally |  | — |
| 201 | reliability | AddServerHostView: Test SSH Task not cancelled on sheet dismiss — updates @State after view gone causing SwiftUI warnings |  | — |
| 202 | reliability | LogsView: cachedFullText not updated when selected category changes — switching tabs shows stale log from previous category |  | — |
| 203 | performance | LogStore.timestamp(): DateFormatter created on every log call — cache as static let to avoid 60×/sec allocations during slider drag |  | — |
| 204 | performance | LogStore.redactSecrets(): two NSRegularExpression compiled on every log call — cache as static let |  | — |
| 205 | reliability | SpeedTest: result.error always nil even when all measurements fail — can't distinguish "all nil = all failed" from "all nil = not run yet" |  | — |
| 206 | reliability | InstallOptionsView: SEI params (seiFPS/Batch/Frag/ACK) not reset when transport changes away from seichannel — stale values submitted |  | — |
| 207 | observability | ServersView: readiness[host.id] not cleared at start of operation — stale dot/label shows briefly between op start and probe result |  | — |
| 208 | ux | AddServerHostView: "Test SSH" button label hardcoded EN — needs L10n key |  | — |
| 209 | ux | ServersView: deep uninstall confirmation body hardcoded EN — needs L10n key |  | — |
| 210 | accessibility | QRCodeView: QR image has no accessibilityLabel — screen readers can't describe it |  | — |
| 211 | accessibility | FormField: label text not linked to input via accessibilityLabel — screen readers can't associate them |  | — |
| 212 | accessibility | ConnectionsView speed metrics: Ping/DL/UL VStack not accessible as a unit — screen reader reads raw numbers without context |  | — |
| 213 | reliability | SSHRunner.shellSafe(): uses `.reduce(into:)` appending unicodeScalars — use `String(s.unicodeScalars.filter{...})` single allocation instead |  | — |
| 214 | ux | Manage VPS global status banner: replace with per-server inline progress inside host card — global banner makes no sense with multiple servers |  | — |
| 215 | ux | VPS action buttons: switch to icon-only (no text labels) with tooltip; duplicate all actions in context menu with same icons |  | — |
| 216 | ux | IP Check: collapse to "✓ 5.42.103.58 (3 sources)" when all agree; expand with ⚠️ only when IPs differ (potential DNS leak) |  | — |
| 217 | observability | Log levels: add multi-level system (Off/Error/Info/Debug/Verbose); current debug=Info, add Verbose for all Pion noise; filter duplicated-packet/TURN-refresh below Verbose; setting in Settings |  | — |
| 218 | architecture | SSHRunner: `withConnection` (private) is a trivial wrapper around `_withConnection` — delete wrapper, call `_withConnection` directly or rename | wrapper already gone; fixed stale comments to _withConnection/_execute | — |
| 219 | l10n | Delete dead `L10n` case `errorPortAllBusy_fmt` | already removed; key absent from codebase | — |
| 220 | l10n | Remove unused `L10n` keys | already removed; none of the listed keys remain | — |
| 221 | migration | srv.sh: complete rewrite for YAML-only binary (olcrtc no longer accepts CLI flags — server is broken) | srv.sh rewritten for YAML (server.yaml + ./cmd/olcrtc build) | — |
| 222 | migration | SSHRunner.reconfigureScript: rewrite to edit YAML fields instead of sed-on-CLI-args (completely broken after 221) |  | — |
| 223 | build | Mobile.xcframework rebuild: add SetLivenessOptions + SetSocksListenHost; remove dead SetLink |  | — |
| 224 | parity | Jazz carrier: remove from CarrierTransportMatrix (SaluteJazz deleted from upstream binary — server rejects it) | removed from CarrierTransportMatrix + carriers list | — |
| 225 | parity | Jitsi carrier: update CarrierTransportMatrix cells with real e2e data + defaultTransport() |  | — |
| 226 | migration | srv.sh: add Jitsi env-var support (OLCRTC_JITSI_URL, URL-format room IDs, Jitsi as new default) |  | — |
| 227 | build | Go-build path in updateScript wrong after #221 | `updateScript` now builds `-o olcrtc ./cmd/olcrtc` (was `/usr/local/bin/olcrtc .`), matching srv.sh + the `/app` entrypoint so restart picks up the rebuild | — |
| 228 | migration | parity_check.py: rebase onto new upstream srv.sh (YAML-based; virtually all base lines changed) |  | — |
| 229 | parity | OlcrtcURI.encode(): stop emitting %clientID (server YAML has no client_id filter; format removed from upstream URI) |  | — |
| 230 | parity | TunnelManager: call SetLivenessOptions() on start | MobileSetLivenessOptions(30s/10s/3) in runMobile, before start; complements app keep-alive | — |
| 231 | parity | CarrierTransportMatrix: update cells (jitsi now real data; jazz removed; vp8 multi-client fix; SEI defaults changed) |  | — |
| 232 | parity | Align golang image tag across all sites | pinned srv.sh + readiness + deep-uninstall to `golang:1.26-alpine3.22` | — |
| 233 | docs | Remove superseded UPSTREAM_MIGRATION_PLAN.md (migration complete via #221–#229; doc deleted, TODO pointers updated) | doc deleted as superseded; TODO pointers updated | — |
| 234 | features | Expose MobilePing() / MobileCheck() in TunnelManager for richer per-connection tunnel health checks | TunnelManager.ping() via MobilePing on a free ephemeral port + per-row UI chip | — |
| 236 | l10n | Hardcoded EN UI strings bypass L10n — RU users saw English | localized ~12 strings via new L10n keys (EN+RU) | — |
| 237 | l10n | Localize hardcoded picker/section labels in option views | Carrier/Transport/Room ID labels localized | — |
| 238 | docs | Russian code comments → English | translated SettingsStore `LogLevel` + Provisioning comments | — |
| 239 | docs | L10n.swift case annotations Russian → English | 95 annotations converted to the English source string (scripted from `L10nTable.english`) | — |
| 240 | docs | README stale | rewrote project-structure tree to the real layout, dropped dead refs (build-number.txt/Jazz), added the 3-layer note + AGENTS/CONTRIBUTING links | — |
| 241 | ux | Brand-name casing inconsistent — pick one | brand = `OlcRTC` for display (added `CFBundleDisplayName`); lowercase `olcrtc` for technical IDs + `Olcrtc` Swift type prefix; renamed `OlcRTCiOSApp`→`OlcrtcApp`; convention documented in CONTRIBUTING | — |
| 242 | features | `MobileCheck()` "Ready in Xms" metric per connection | `TunnelManager.checkReady()` via `MobileCheck` on a free ephemeral port; stopwatch "Ready Xms" overlay on the ping chip (long-press + context menu) | — |
| 243 | architecture | Protocol-agnostic `TunnelEngine` seam for a 2nd protocol | extracted `TunnelEngine` protocol + `OlcrtcEngine` (owns all `Mobile*`); `TunnelManager` is now protocol-agnostic (dropped `import Mobile`), dispatches via `ConnectionDetails.engine`; unblocks the #063 mock-engine testing seam | — |
| 244 | build | Replace placeholder bundle IDs before TestFlight/App Store | set to com.alexk.olcrtc-ios{,-tests} | — |
| 245 | docs | `OlcrtcConnection.swift` references missing `docs/uri.md` | created `docs/uri.md` (olcrtc:// URI format reference) | — |
| 246 | build | GitHub issue templates (bug report + feature request) | added `.github/ISSUE_TEMPLATE/` — bug_report + feature_request + config.yml (English, iOS-flavoured; core/protocol bugs routed upstream) | — |
| 248 | build | App icon — `AppIcon.appiconset` ships with no images | added user's pixel-hand + `olcrtc-ios` wordmark → `AppIcon.appiconset/AppIcon.png` (1024 universal); one-shot generator (`scripts/icon/`) removed once the icon was committed | — |
| 249 | build | Privacy manifest (`PrivacyInfo.xcprivacy`) — required for App Store | added `App/PrivacyInfo.xcprivacy`: no tracking, empty tracking-domains/collected-data; required-reason audit found only User Defaults → `CA92.1`; auto-bundled to Resources via the `App` glob, `plutil`-lint clean | — |
| 250 | build | CI: build + test (+ `srv.sh` parity) on a macOS runner | `.github/workflows/ci.yml` on push/PR/dispatch (macos-15): parity check → gomobile-build `Mobile.xcframework` (cached by upstream commit) → `xcodegen` → `xcodebuild test` on iPhone 16 sim | — |
| 252 | docs | README publication pass — public framing, screenshots, disclaimer | restructured for a serious-project layout (badges, Features, Screenshots placeholder, Contributing, neutral Disclaimer); corrected stale architecture docs (connect→start→runEngine per #243, ATS/`NWConnection` attribution, test coverage); set `haritos90/olcrtc-ios` links; dropped censorship/RU framing | — |
| 253 | build | `Mobile.xcframework` distribution for public cloners | GitHub Releases channel (vs git-lfs): `release.yml` builds/zips/attaches `Mobile.xcframework.zip` per `v*` tag; `scripts/fetch-framework.sh` one-line-downloads it via `gh`, `scripts/build-framework.sh` is the shared from-source fallback (also used by `ci.yml`); README rewritten download-first | — |
| 255 | build | SwiftLint config + CI lint step | lenient `.swiftlint.yml` (excludes the vendored core + generated framework; disables the house-style-divergent rules — identifier_name/type_name/todo/line_length + length/complexity/param-count/`large_tuple`; `force_cast`/`force_try`→warning) + a parallel `lint` job in `ci.yml` (source-only, installs swiftlint if the runner image lacks it, non-strict so warnings annotate but don't fail). Lenient start; tighten to `--strict` over time | — |
| 256 | reliability | Default Jitsi server: all users point at one public instance (`meet1.arbitr.ru`) | exposed the Jitsi base URL as an editable, pre-filled field in the install sheet (shown for the jitsi carrier) + a "shared public instance — point at your own" footer (en+ru), so users aren't silently funnelled onto one third party; `InstallOptions.jitsiBaseURL` (defaults to `AppConstants.defaultJitsiBaseURL`, never sent empty) → `SSHRunner` sends the user's value as `OLCRTC_JITSI_URL`; `srv.sh` untouched (still reads the var; its `:-` default stays the server-side fallback), parity tests green | — |
| 258 | ux | UI redesign — adopt unified design system across all screens | builds 212–216: `App/UI/Theme.swift` + `DesignSystem.swift` (8 components + OlcStatusDot/FlowLayout/OlcEmptyState, dark previews); ServersView (single-source `HostDisplay` model — kills the VPS status-jump), ConnectionsView, all sheets, LogsView, SettingsView restyled; app forced dark via `UIUserInterfaceStyle=Dark`. One button system / one overflow menu / one status vocabulary / one large-title header. Follow-ups split out: #259 (state-machine tests), #261–267 (polish/architecture) | — |
| 259 | tests | Tests for the VPS `HostDisplay` state machine (#258) | extracted the #258 transition rules into a pure reducer on `HostBase`/`HostDisplay` (`seed`/`start`/`advanced`/`terminalBase`/`failed`/`retryBase`) that `ServersView` now drives; `Tests/HostDisplayTests.swift` (16 tests → 182 total) covers readiness→base mapping, op `target`/`phases`, no-optimistic-base-while-running, monotonic+capped phases, probe-authoritative terminal assignment, and failure→Retry `previousBase` restore. Reducer still lives in ServersView.swift → moving it to Models is #263 | — |
| 260 | reliability | Integrate upstream olcrtc (587c13e → e2c4b1e) | bumped submodule pin (jitsi reconnect #82/#88/#89, vp8channel byte-rate pacer, videochannel ffmpeg→`gocodec`; nested `gr` submodule removed — now a go.mod dep `gr v0.1.5`); rebuilt `Mobile.xcframework` via `build-framework.sh` (Mobile* API unchanged → engine compiles), `parity_check.py` clean (srv.sh unchanged), app builds + 182 tests green. No doc churn — our docs never named the `gr` submodule and `--recursive` stays valid. Hijacked doc commit only touches upstream `readme.md`/`westand.svg`, not propagated. PENDING USER: on-device jitsi+vp8 smoke-test; commit+push the pin bump; cut a new `v*` tag so `release.yml` republishes the framework | — |
| 261 | l10n | Promote ServersView hardcoded status/phase strings to L10n | localized the design-system VPS status text — `HostBase.title`/`.subtitle`, `HostOp.verb`, the «Connecting…» initial note, «Check server», «Working…» and the «%@ failed» title — via 24 new `vps*` keys (en+ru). Replaced the never-displayed `HostOp.phases` arrays with `stepCount` (running subtitle = the live localized provisioner message; only the bar denominator is needed); updated the reducer + HostDisplayTests. Metric labels (Ping/Disk/RAM/Uptime) left as-is (not status/phase) | — |
| 262 | architecture | Shared sheet scaffolding + dedupe card-row helper | extracted `.olcSheet(confirm:icon:disabled:onConfirm:)` (an `OlcSheetChrome` ViewModifier — ✕ close + full-width primary footer) into DesignSystem; adopted by AddConnection/AddServerHost/Install/Reconfigure (AddServerHost keeps its keyboard toolbar). Promoted `olcCardRow()` into DesignSystem; removed the private copy in ConnectionsView and the 3 inlined modifier-stacks in ServersView | — |
| 263 | architecture | Move `HostBase`/`HostOp`/`HostDisplay` out of ServersView into App/Models | moved the 3 enums + the pure reducer into `App/Models/HostDisplay.swift` (behavior-preserving; ServersView 965→796 lines; 182 tests green) | — |
| 264 | ux | Restore the IP "last checked" timestamp in the Diagnostics card | re-added `ipCheckTime` (set after `checkAll`), shown as a clock + `HH:MM` caption under the IP result; no L10n needed (icon + localized time) | — |
| 265 | ux | AddConnectionView — manual URI entry | added a 1–3-line monospaced `TextField` (literal `olcrtc://…` placeholder) under the Scan/Paste buttons that auto-parses into the fields on change; restores typing / paste-and-edit that the redesign had dropped | — |
| 266 | l10n | Remove L10n keys orphaned by the redesign | removed 19 unused keys (uriPlaceholder, parseURIAction, typeField, ipLastCheck_fmt, speedTestTitle, statusUnreachable, connectionLine_fmt, alertPasswordMissingDetail, status{Running,Done,Error}Title, actionDisconnect/Ping/Status, sectionInfo, installResultSuccessNotice, rebootingInProgress, scanContainerRow_fmt, uninstallConnectionAlsoRemoved_fmt) from the enum + both dicts; verified zero code refs; L10nTests per-locale count stays balanced | — |
| 267 | ux | Runtime design-direction toggle (Refined/Console) in Settings | `SettingsStore.designConsole` (persisted @Published) drives the 6 direction-dependent Theme tokens (now `static var`: bg/card/segActive + control/card radii + card border); Settings «Theme» picker (Refined/Console); app reskins live via MainTabView's SettingsStore observation. Added L10n themeLabel/themeRefined/themeConsole | — |
| 268 | ux | Manage VPS card shows free disk as if used | disk `awk` field `$4` (Available/free) → `$3` (Used) in `SSHRunner.readinessScript` so the card shows `used/total`, consistent with the RAM line right below it; pure Swift, no `srv.sh`/parity impact | — |
| 269 | reliability | Reconnect on network-path change (`NWPathMonitor`) — Wi-Fi↔cellular handoff | always-on `NWPathMonitor` on `TunnelManager` (lazy-started first connect, never torn down); new `.waitingForNetwork` holding state — hero shows «Waiting for network…», global toggle stays on+enabled (flip off to give up); pure `nonisolated static pathDecision` maps loss→hold, regain→`reconnect(.restored)`, Wi-Fi↔cellular swap→`reconnect(.interfaceChanged)`, debounced 1.5 s and coalesced; `.disconnected`/`.failed` (down server ≠ path problem) + first-update baseline ignored; `bgKeeper` kept running while waiting so a backgrounded app self-recovers; reconnect funnels through `scheduleNetworkReconnect`→`start()` (the seam #270's backoff sink will absorb, #271 the room-settle, #272 the generation guard); `Tests/NetworkPathDecisionTests.swift` (14-case matrix) + `.waitingForNetwork` round-trip | — |
| 270 | reliability | Bounded exponential-backoff auto-reconnect (replace the one-shot retry) | replaced one-shot `scheduleAutoRetry` with `requestReconnect` — a single recovery sink both keep-alive loss and #269 (network regain/interface swap) feed; capped exponential backoff `backoffDelaySeconds` (2→4→8→16→32→60 s, base·2ⁿ clamped) over `maxReconnectAttempts`=6, then terminal `.failed` («tap Retry»), preserving the deliberate battery cap; idempotent (one loop at a time), a verified connect ends the loop so backoff resets, a network loss cancels it (resets on the round-trip), a manual connect/disconnect supersedes it; extracted `preflight` shared by fire-and-forget `start` + awaitable `connectAndAwait`, `runEngine` now returns `Bool` so the loop sees the *verified* outcome; `Tests/ReconnectBackoffTests.swift` (schedule + cap + overflow/negative guards); removed orphaned `autoReconnect_fmt`, added `reconnectAttempt_fmt`/`reconnectGaveUp` (en+ru) | — |
| 271 | reliability | Settle delay before reconnecting into the same room (ghost MUC presence) | carrier-aware room-settle on the auto-reconnect path: `EngineStartSettings.isReconnect` (true only via #270's `connectAndAwait`, false on user `start`) → `OlcrtcEngine.start` waits `rejoinSettleMs(carrier:)` after its `MobileStop()` before re-joining, so the prior session's MUC `presence-unavailable` clears first (jitsi/telemost 3 s, others 1.5 s — XMPP-MUC propagation lag, per the upstream `server.go` ghost-participant note); logged via `rejoinSettle_fmt` (en+ru); fresh connects skip it; `Tests/RejoinSettleTests.swift` pins the mapping + case-insensitivity | — |
| 272 | reliability | Epoch/generation guard in TunnelManager (discard superseded connect/retry results) | monotonic `connectEpoch` bumped in `preflight` per attempt + captured into each detached `runEngine`; new `isLiveAttempt(epoch)` (epoch matches **and** `state == .connecting`) replaces the bare `state == .connecting` guard at all four `runEngine` MainActor hops, so a fast disconnect→reconnect can't alias the new attempt's `.connecting` and post a result for the wrong session; `connectEpoch` is `private(set)` (test-observable); +2 tests (epoch advances per launched attempt; invalid connect consumes none) | — |
| 273 | features | Release the "Direct" routing mode (`.allDirect`) | added `RoutingMode.allDirect` (case + `routingAllDirect` L10n en+ru) so the routing segmented control is a real 2-option choice instead of one pointless item; `ConnectionsView.currentMode` honours it (`.allDirect ? .direct : connected ? .tunnel : .direct`), so the app's own IP-check / speed-test / in-app `SOCKSSession` bypass the tunnel even while connected (a diagnostics kill switch — external apps on the SOCKS port are unaffected, the documented scope); persists via the existing `@AppStorage("olcrtc_routing_mode")`; `Tests/RoutingModeTests.swift` pins raw-value stability (persisted) + distinct non-empty titles | — |
| 274 | ux | Unify the two per-connection probes into one Health check | replaced the dual ping (#234) / time-to-ready (#242) chip — which alternated in one slot via a long-press overlay — with a single **Health check** action (overflow item + chip): one tap runs both isolated probes and logs one combined line `🩺 Health %@ — ready %@ · RTT %@` (`healthResult_fmt`, en+ru); the chip shows RTT (familiar latency pill), or the ready time in amber if only RTT failed, or a red marker if both failed. Underlying `TunnelManager.ping`/`checkReady` + engine unchanged — only the row UI collapsed. Removed 6 now-unused L10n keys (ping/checkReady result/failed/a11y) | — |
| 275 | reliability | "Container running" ≠ "connection healthy" — diagnose connect timeouts | a `MobileWaitReady` timeout means the WebRTC transport never readied — no peer rendezvoused in the room ("Link connected" with no "session opened"). The state used to show the bare Go reason ("Timeout"); `TunnelEngine` now keeps that in the log but surfaces a diagnostic, `connectNoPeer` (en+ru): "No peer joined in time — check the key matches the server, the room is correct, or try another carrier/transport." Also reworded `vpsSubRunning` so the VPS "running" pill no longer reads as "connected" ("Server process up — not a connection test" / «Серверный процесс запущен — это не проверка подключения»). Distinct from #282's verify-failure path | — |
| 276 | observability | Logs: one merged stream + per-entry source tag + level colour-coding | merged the per-category tabs into one chronological stream — `LogEntry` now carries its `category` + an inferred `LogLineLevel` (debug/info/warn/error) + a monotonic `seq`; `LogStore.merged` flattens every category sorted by (date, seq); LogsView renders a single attributed `Text` (one layout region — keeps it cheap) with each line tagged `[Source]` and colour-coded by level (error red / warn orange / info secondary / debug dim), plus a single-select **source filter** (All + per-category) that replaces the tabs; `classify()` infers severity (pion noise→debug first, then ✗/⚠ emoji prefixes, then keyword fallback) and IP-check lines finally carry a source tag; `Tests/LogStoreMergedTests.swift` | — |
| 277 | observability | Logs: dated timestamps + consistent newest-first order + retained scroll | `LogStore.format(date:)`/`timestamp()` now emit `yyyy.MM.dd HH:mm:ss.SSS` (was time-only `HH:mm:ss.SSS`); the in-memory `LogEntry` carries the timestamp as a real `Date` (on-disk lines still self-describe with the inline stamp); the merged stream renders **newest-first** and no longer force-scrolls to the bottom on every append (kills the snap-back to old entries), so the view opens on the freshest line and stays where the user scrolled | — |
| 278 | observability | Server context-menu "Logs" → "Download container logs" + in-tab load/refresh | renamed the server-card context-menu `actionLogs` → `actionDownloadContainerLogs` ("Download container logs" / «Скачать логи контейнера») with an `arrow.down.doc` icon; `Provisioner.containerLogs` now parses each line's Go timestamp (`yyyy/MM/dd HH:mm:ss`, carry-forward for continuation lines) so container output interleaves chronologically with the client stream instead of clustering at fetch-time, and records the host/container via `LogStore.noteContainerTarget`; the Logs tab gains a **"Refresh from server"** button (`logsRefreshFromServer`) that re-pulls that target directly (no trip back to the server card); `parseExternalTimestamp` also tolerates our own format so re-ingesting is a no-op | — |
| 280 | performance | Fix UI jank when changing font size while scrolling | the font-size `Slider` committed `settings.fontSizeIndex` on **every drag tick**, and that value drives `.dynamicTypeSize` app-wide (a full view-tree relayout) + a UserDefaults write — the stutter. Now the drag updates a local `@State fontDragIndex` only (re-rendering just the Settings row + a live preview); the app-wide value commits **once on release** via `onEditingChanged`. The preview text scales live through a scoped `.dynamicTypeSize`. (The Logs list, the worst offender, is already a single attributed `Text` after #276.) | — |
| 281 | ux | Make the Refined/Console design directions actually distinct | amplified the Console tokens from near-identical (±2pt radius / 0.5pt border) into a clearly sharper, denser terminal direction: tighter radii (card 7 vs 20, control 5 vs 13, segmented 5 vs 10), a *visible* hairline card border (1pt @ white 16%, was 0.5pt @ 8% — invisible), denser spacing (card padding 12 vs 16, section gap 14 vs 22), and monospaced caption/section labels. Refined stays soft + borderless. `Tests/ThemeDirectionTests.swift` pins them as distinct | — |
| 282 | l10n | `serverNotResponding`: reword to name the carrier server (not the VPS) + RU | reworded the carrier-failure state messages so they no longer read as the user's VPS: `serverNotResponding` → "Conferencing server not responding" / «Сервер видеосвязи не отвечает» (verify-failed path), `serverConnectionLost` → "Connection to the conferencing server lost" / «Связь с сервером видеосвязи потеряна» (keep-alive-loss path). The "RU shows English" was a build-221 artifact — both RU values already shipped on current builds; this is the wording fix. L10n-string-only (no keys / Swift touched) → no bump/build | — |
| 283 | l10n | Localisation gaps: "Servers" group + carrier/transport display names | (a) the canonical default group token "Servers" now renders via `ConnectionRecord.displayGroupName` → `L10n.groupDefault` at display time (RU «Основная») with no record migration; AddConnectionView stores the canonical token when the field is left at the localised default. (b) the carrier/transport pickers + matrix showed raw IDs — added `CarrierTransportMatrix.carrierLabel`/`transportLabel` (7 L10n keys, en+ru; "telemost"→«Телемост») wired into all three pickers + the matrix rows (selection value stays the raw ID). Documented the explicit-entry convention in CONTRIBUTING. Logs tabs/header were already covered by #276/#278. `Tests/DisplayNameTests.swift` | — |
| 284 | parity | Update the carrier×transport compatibility matrix data | re-derived every cell from the upstream authoritative table (`olcrtc-upstream/docs/settings.md`, from the E2E suite): telemost+datachannel `.ok`→`.fail` (DataChannel removed from Telemost), telemost+seichannel `.unknown`→`.fail` (unsupported), telemost+videochannel and wbstream sei/video `.unknown`→`.ok`, wbstream+datachannel `.fail`→`.question` (guest tokens canPublishData=false), and promoted the per-carrier recommended cells to match `defaultTransport` (jitsi+datachannel, telemost/wbstream+vp8channel). `Tests/CarrierTransportMatrixTests.swift` pins the key cells | — |
| 285 | reliability | Speed test over the tunnel: degrade gracefully + selectable providers + connection-type | the test "never worked on the tunnel" because vp8channel is a <1 Mbps covert pipe (raw VPS 775/318 vs ~0.77/0.51 through it), not a broken test. On `.tunnel` the run now degrades: serial (not parallel) measurements, scaled-down payloads (1 MB/512 KB vs 5 MB/2 MB) + longer timeouts, ping failure tolerated (reports "n/a"), partial results kept. Header logs the connection type (direct/tunnel + carrier/transport). Provider is selectable in Settings (`SpeedTestProvider`: Cloudflare parametric down/up/trace + OVH fixed-file download/HEAD, both verified) persisted in `speedTestProviderID`. On a slow video-transport tunnel it hints toward Reconfigure → datachannel. `Tests/SpeedTestProviderTests.swift` | — |
| 288 | build | CI: skip the build/test + lint jobs on docs-only pushes | `ci.yml` `push`/`pull_request` now carry `paths-ignore: **/*.md, docs/**, LICENSE`, so a docs-only commit (a TODO/README/catalog edit) skips the whole run (gomobile build + xcodebuild test + SwiftLint); any `.swift` / `project.yml` / `scripts/**` / workflow change still runs. `release.yml` is tag-triggered and untouched. Caveat: if CI ever becomes a *required* branch-protection check, `paths-ignore` leaves it pending on skipped runs — switch to a path-filter gate job that reports success instead | — |
| 286 | ux | IP-check: selectable providers (10, incl. RU/ru-zone) + connection-type | grew `AppConstants.ipCheckServices` to a curated **10** (7 international + 3 RU/ru-zone — `2ip.ru`, `2ip.io`, `ip.beget.ru`, all verified to return a bare IP over HTTPS with a curl UA, 2026-06; JSON-only endpoints dropped). The user toggles which to query via **checkboxes in Settings** (`SettingsStore.enabledIPSources`, persisted as an array, keyed by label), with a default subset (3 intl + 1 RU) and an empty-set fallback so the check never queries nothing. IP-check header now logs `→ IP check (Direct/Via tunnel) — N source(s)` (connection-type was already there). `Tests/IPCheckSourcesTests.swift` | — |
| 287 | observability | Log-line cleanups from the real capture | three fixes, two extracted as pure testable helpers: (1) keep-alive "active −N s ago" went negative because `noteActivity(forAtLeast:)` parks the marker ahead → `TunnelManager.keepAliveSkipNote(ageSeconds:)` reports "tunnel busy (Ns reserved)" for the future-marker case; (2) tunnel-verify "bad URL" (a valid URL whose SOCKS session can't be built mid-teardown) → `verifyFailureReason(_:)` maps `URLError.badURL/.unsupportedURL` to "proxy not ready"; (3) the port check-result line now routes through single keys `logPortFree_fmt`/`logPortBusy_fmt` (en+ru) instead of assembling fragments. `Tests/LogLineCleanupTests.swift` | — |
| 289 | performance | Logs tab: visibility gate — rebuild the merged stream only when on-screen | `LogsView.refreshCache()` (sort all categories + rebuild the `AttributedString`) ran on every `LogStore.revision` bump — once per log line — and `TabView` keeps off-screen tabs alive, so it churned in the background during a log storm on another tab. Added `TabView(selection:)` + `.tag`s in App.swift and pass `isActive: selectedTab == 2` into `LogsView`; the per-line rebuild is gated on `isActive`, with a one-shot catch-up `onChange(of: isActive)` when the tab is shown. Eliminates all off-tab rebuild work. On-tab burst smoothing (debounce) is the follow-up #290 | — |
| 290 | performance | Logs: debounce/coalesce the on-tab merged-stream rebuild during log storms | Won't Do — superseded by #294 (logs revert to per-source tabs; no merged stream left to debounce) | — |
| 291 | reliability | Speed test: OVH measures no upload + result units (Mbps/ms) no longer shown | (a) upload: a fixed-file provider (OVH) has no `/__up` sink, so UL showed nothing — `AppConstants.SpeedTest.uploadProvider(for:)` now routes the upload leg to the Cloudflare parametric `/__up` fallback when the selected provider can't upload (logged), so UL is measured instead of blank; (b) units: DL/UL lost their `Mbps` suffix in the redesign — restored next to the numbers (Ping already showed `ms`), matching this view's hardcoded-unit convention. `Tests/SpeedTestProviderTests.swift` (+2 fallback-resolution tests) | — |
| 293 | ux | Settings: move IP-check source selection into its own sub-screen | the inline #286 checkboxes now sit behind a navigation row ("IP check sources" + a selected-count) in the main Settings list; the toggle list moved to a dedicated `IPSourcesSettingsView` sub-screen. Model unchanged (`SettingsStore.enabledIPSources` + default subset + empty-set fallback) | — |
| 298 | ux | Settings: keep scroll position stable on font-size change (don't jump) | wrapped the Settings `Form` in a `ScrollViewReader` and tagged the Font row with a stable id; on `fontSizeIndex` commit (the app-wide dynamic-type relayout that moved the viewport) it `scrollTo`s that anchor (`.center`), so the Font control stays put instead of the list jumping | — |
| 292 | features | Speed test: add Hetzner provider (Yandex researched, no usable endpoint) | added Hetzner (`ash-speed.hetzner.com/100MB.bin`, fixed-file, no upload → falls back to Cloudflare per #291) to `AppConstants.SpeedTest.providers`; researched Yandex + several other RU/regional mirrors but found no stable small-file (1-10 MB) HTTPS endpoint suitable for the existing whole-file download path — documented in code comments. `Tests/SpeedTestProviderTests.swift` +2 | Speed test: new Hetzner server option (ash-speed.hetzner.com) |
| 294 | observability | Logs: revert merged stream → per-source tabs (Connection/Diagnostics/VPS/Container) | `LogsView` rewritten as a `TabView` with 4 tabs (Connection/Diagnostics/VPS via `LogCategoryTabView`, Container via `ContainerLogsTabView`); shared `LogRendering` (filter/newest-first/colour/plain export, `@MainActor`) + `LogTabHeader` (description + file name). `LogCategory.ip`/`.speed` → `.diagnostics` (`diagnostics.log`). Removed the `merged` stream and the #289 visibility-gate plumbing — `isActive` kept on `LogsView.init` for call-site compatibility but unused. Supersedes #290 (Won't Do). New L10n: `categoryDiagnostics`, `logsTabDesc*`, `logsFileNameLabel_fmt` (en+ru) | Logs tab redesigned: separate Connection / Diagnostics / VPS / Container views, each showing its description and log file name |
| 295 | observability | Logs: per-server container log files with a unique server-name prefix | `LogStore` gained per-server container buffers/files keyed by `ServerHost.logFilePrefix` (new `sanitizeLogFilePrefix`: alphanumerics kept, rest collapse to `_`, falls back to `"server"`); `startContainerSession`/`logContainer`/`clearContainer`/`noteContainerTarget` all take `serverPrefix`. `Provisioning.containerLogs` writes through the per-host prefix. `AddServerHostView` rejects duplicate names/prefixes (`isDuplicateLabel`, new `duplicateServerNameError` L10n). `Tests/ServerHostTests.swift` (new) | Each server now keeps its own container log file |
| 296 | ux | Container logs: always-present "Download from server" button + empty hint | `ContainerLogsTabView` (part of #294's `LogsView` rewrite) has a server picker (when >1 host) and an always-present "Download logs from server" / "Check server" (when offline) button, plus an empty-state hint that logs need loading from the server. New L10n: `logsDownloadFromServer`, `logsCheckServer`, `logsContainerEmptyHint`, `logsContainerSelectServer`, `logsContainerNoServers` (en+ru) | Container logs: "Download from server" is always available (or "Check server" while offline) |
| 297 | reliability | Fix freeze when opening Container logs for a server not yet checked | `ContainerLogsTabView.primaryAction` (#296) called `probeReadiness(containerName: nil)`, but `parseReadiness` always returns `.imageReady` for `containerName == nil` — "Check server" could never discover/adopt a container, a silent dead end that read as a frozen button. Now mirrors #302: scans for an existing `olcrtc-server-*` via `scanContainers` and adopts the first match. Every remaining dead end (missing password, no container found, fetch error) sets a visible alert instead of returning silently | Container logs: "Check server" now finds and adopts an existing container, and shows an error instead of doing nothing |
| 300 | ux | Port check: 3 states (free / used by another / used by olcrtc tunnel) | `PortAvailability.PortState` (`.free`/`.busyOther`/`.busyOurs`) gated on live `TunnelManager` state via `tunnelHoldsPort`, replacing the binary `isFree` heuristic in `SettingsView`'s port check; new `logPortBusyOther_fmt`/`logPortBusyOlcrtc_fmt` + relabeled `portInUseByOlcrtc` (en+ru). `Tests/PortAvailabilityTests.swift` +4. Follow-up: #313 | Port check now distinguishes free / busy by another app / in use by the olcrtc tunnel |
| 301 | features | New "Config" tab between Manage VPS and Logs (placeholder "Coming soon") | new `ConfigView` (NavigationStack + `OlcEmptyState` "Coming soon") inserted at tab index 2; Logs/Settings shifted to tags 3/4 and the Logs visibility gate updated to `selectedTab == 3`. New L10n `tabConfig` + placeholder strings (en+ru) | — |
| 302 | reliability | Server check: auto-detect existing olcrtc containers (no false "cached for reinstall") | `checkServer` now, when the readiness probe finds no *known* container on a host with `lastContainerName == nil`, folds in `scanContainers` and adopts the first `olcrtc-server-*` found — persists its name, sets the base to running/stopped from its status, logs `autoDetectedContainer` — so an existing container surfaces without the separate "Look for olcrtc containers" tap (still available for multi-container hosts) | — |
| 304 | ux | Move "Share connection" from Connections to the Manage VPS tab | extracted the share sheet into a reusable `ShareConnectionView` (QR now a `NavigationLink` push, not a second-sheet handoff) and moved the "Share connection" action onto the server card (shown when the host has a linked `ConnectionRecord`). Removed it (and its `shareConn`/`pendingQRConn` plumbing) from the Connections row menu; Copy URI / QR remain there as quick utilities | — |
| 305 | build | Release notes: auto-append tasks closed between releases (ID + title + resolution) | new `scripts/closed-tasks-since.py` diffs TODO.md's Closed table between `--since <tag>` and the working tree → markdown bullets `- #ID title — resolution`; `release.yml` runs it for `$PREV` and appends a "Tasks closed since <tag>" section to the notes (omitted on the first release / when empty / when the script is absent at an old tag) | — |
| 306 | build | Release assets order: `.ipa` before `Mobile.xcframework` | `release.yml`: build the unsigned `.ipa` before creating the release and make it the create asset, then attach `Mobile.xcframework.zip` in a follow-up upload — GitHub orders assets by upload time, so the user-facing sideload artifact now leads. Asset footer in the notes reordered to match | — |
| 307 | build | Per-version download counter for Release assets (GitHub API `download_count`) | new `scripts/download-stats.py` (stdlib-only) sums `release.assets[].download_count` per tag → markdown table (per-asset + per-tag + all-time total); repo from `--repo`/`$GITHUB_REPOSITORY`/git origin, token from `GH_TOKEN`/`GITHUB_TOKEN` (one paginated `GET /releases`, within the unauth rate limit). New `download-stats.yml` workflow regenerates `docs/download-stats.md` weekly (+ manual) and commits only on change (`[skip ci]`). Surfaced via a README total-downloads shields badge + a link from the sideload section | — |
| 308 | reliability | SOCKS port: always bind the configured port (no auto-slide — breaks Shadowrocket etc.); busy → clear "port busy" error, don't connect | removed `PortAvailability.nextFreePort`/`autoRetryAttempts` (the auto-slide, reversing #108/#148); (a) `reservePortAndSettings` now does a single `isFree(configuredPort)` check → typed `.failed` before the engine starts; (b) `OlcrtcEngine.startErrorReason(_:port:)` maps a late gomobile bind race (`address already in use`) to the same reason; (c) new `errorPortBusy_fmt` L10n (en+ru) names the busy port, dropping `portChangedAuto_fmt`/`errorAllPortsBusy_fmt`; (d) catalog row OLC-1026 (E). `freeEphemeralPort` kept for probes. `Tests/PortAvailabilityTests.swift` (−3 slide tests, +2 error-mapping tests) | — |
| 303 | features | Recover/add a connection from server access when Connections is empty (import or generate) | added "Recover connection" host action (shown when a container is found but `lastConnectionID == nil`): `SSHRunner.recoverConfig`/`recoverConfigScript` read-only `cat` the deployed `server.yaml` + `~/.olcrtc_key`, `parseRecoveredConfig` rebuilds carrier/transport/room/key (+ vp8/sei tuning), `ServersView.recoverConnection` adds the resulting `ConnectionRecord` and links `lastConnectionID`. Import-from-existing only — "generate new key" fallback tracked as #314 | New "Recover connection" action rebuilds a connection from an already-installed server |
| 309 | build | download-stats: timestamp defeats the commit-on-change guard | `download-stats.py` now strips the `Last updated:` line before comparing the freshly-built doc to the existing file; if only the timestamp differs, the old file (with its old timestamp) is kept so the weekly workflow's `git diff --quiet` guard stays meaningful | Weekly download-stats workflow no longer commits when nothing changed |
| 310 | build | closed-tasks-since.py: `\d{3}` row regex silently drops task IDs ≥ #1000 | `ROW` regex `\d{3}` → `\d+` (header/separator/placeholder rows still excluded); `new_ids` now sorted with `key=int`; TODO.md header reworded "permanent 3-digit ID" → "permanent numeric ID" | Release-notes tooling now handles task IDs beyond #999 |
| 311 | l10n | Route speed-tile metric labels/units + upload-fallback log line through L10n | `ConnectionsView.speedRow` labels (Ping/DL/UL) and `"%.0f ms"`/`"%.1f Mbps"` formats, plus `SpeedTest.measureUpload`'s fallback log line, now go through new `speedLabelPing/DL/UL`, `speedPingValue_fmt`, `speedRateValue_fmt`, `speedUploadFallback_fmt` (en+ru, ru=en — universal abbreviations / deliberately-English diagnostic line) | Speed tile labels and units are now localizable |
| 312 | docs | README testing section drifted ("238 unit tests" + stale "port selection") | dropped the exact test count for "A broad suite of unit tests covers…"; replaced "port selection" with "port availability / busy-error mapping" (#308) | README: testing section brought up to date |
| 313 | reliability | TunnelManager doesn't track the actually-bound SOCKS port — port-check can mislabel "in use by olcrtc tunnel" after a live port change | TunnelManager now publishes `boundPort` — the snapshot preflight reserved (#308: bound exactly or the attempt fails) — set before `.connecting`, cleared in the state didSet on `.disconnected`/`.failed`/`.waitingForNetwork`; the Settings port check gates "in use by olcrtc tunnel" on `tunnel.boundPort == settings.socksPort` instead of comparing the configured port to itself; lifecycle covered in TunnelManagerStateTests. Follow-up filed: #351 (SOCKSSession/ConnectionsView still read the configured port while connected) | Check port now correctly identifies which port the running tunnel holds after you edit the port while connected |
| 314 | features | #303 "generate new key" fallback when server.yaml is unreadable/unparseable | New scripts/rotate-key.sh (ships as a bundle resource next to srv.sh): locates the deploy dir via podman inspect, salvages carrier/transport/room/dns/socks + tuning from the old server.yaml where readable, regenerates the key and rewrites server.yaml with srv.sh's verbatim commands (lines guarded by RotateKeyScriptTests — 105 lines checked against srv.sh, a real parity test without new infra), podman-restarts the container and emits the srv.sh OLCRTC_URI=/OLCRTC_CONTAINER= contract; SSHRunner.rotateKey + Provisioner.rotateKey reuse the upload channel and parseInstallResult; the #303 recover flow offers it only on a typed RecoverConfigError (never for transient SSH failures) behind a destructive confirmation that warns other devices lose access; non-jitsi rooms unrecoverable from a dead config → hard fail (reinstall is right). 7 L10n strings en+ru; loader generalized (loadBundledScript) with its dead dev-tree fallback path fixed | If a server's config can't be read during connection recovery, the app can generate a new encryption key on the server and restore the connection |
| 315 | build | Closed table: Release note column for curated GitHub Release notes | new 5th Closed column **Release note** (one user-facing "what's new" line, filled on close; `—` = fall back to title); `closed-tasks-since.py` emits `- #ID note` instead of `- #ID title — resolution` (5-col regex + 4-col fallback for historic refs); all 294 prior rows backfilled with `—`; documented in TODO.md header, AGENTS.md §5, CONTRIBUTING.md → Task tracking | Release notes now show short "what's new" lines instead of verbose task resolutions |
| 316 | ux | LogsView (#294) nests a `TabView` inside MainTabView's `TabView` — verify rendering; likely replace with `OlcSegmented` (the pre-#276 pattern) | rebuilt as a single `NavigationStack` (design_handoff_logs_theme §1): `OlcSegmented` category switch (short labels Conn/Diag/VPS/Container, full names via `accessibilityLabel`), ONE `.searchable` + ONE overflow menu, one file-header row (`doc.text` + monospaced file name + line count) attached to the log body; deleted the nested `TabView`, per-tab `NavigationStack`s, `LogTabHeader` (its description now opens the empty-state hint) and the unused `isActive` plumbing (App.swift call site included); per-server container picker/fetch (#295–#297) carried over unchanged | Logs tab redesigned: no more second tab bar — one header, a compact category switch, and a single file row with line count |
| 317 | ux | Unify ad-hoc `.red`/`.green` styles with `Theme.Palette` (#258 invariant) — AddServerHostView, AddConnectionView, SettingsView port check | Bare .red/.green in AddServerHostView (duplicate-name error, SSH test result), AddConnectionView (URI parse error), and the SettingsView port-check rows routed through Theme.Palette.red/green; existing status tokens sufficed — no new token. Follow-up filed: #350 (remaining ad-hoc colors in CarrierTransportMatrix/ConnectionsView/ServersView) | — |
| 318 | observability | Orphaned log files after #294/#295 linger in Documents/logs | `LogStore.init` now calls `cleanupOrphanedLogFiles()`, deleting `ip.log`/`speed.log` (merged into `diagnostics.log` by #294) and the old shared `containerLogs.log` (replaced by per-server files in #295), once per launch | — |
| 319 | reliability | Integrate upstream olcrtc (e2c4b1e → 39cc3fa) | bumped submodule pin (13 commits): server.go `reinstallSession` now closes the old muxconn before the session swap (fixes "frame too large" when a client reconnects faster than the server can push new-session frames into the dying smux session); jitsi engine hardening — `RequireTargetedPeer` drops untargeted broadcast frames before the peer-latch (already wired via `internal/client`, no mobile.go API change), bounded 30s rejoin-join timeout, RTCP keepalive only runs when a PC carries media/SCTP bridge, `PeerConnectionStateFailed` now triggers a reconnect instead of `onEnded`; muxconn/smux retuning (`inboundQueue` 256→128, `fastSpinAttempts` 200→16, `MaxStreamBuffer` 1MiB→512KiB, frames up to 32KiB); vp8channel default fps 60→30 + smaller KCP queues (CPU-reduction pass). Default Jitsi server list changed (`meet.cryptopro.ru` removed, `meet.small-dm.ru`/`meet.handyweb.org` added) — our `AppConstants.defaultJitsiBaseURL` (`meet1.arbitr.ru`) is unaffected, still in the list. `parity_check.py` clean — the upstream interactive Jitsi-menu/room-options rewrite in `script/srv.sh` falls entirely outside our non-interactive boc patches. Rebuilt `Mobile.xcframework` via `build-framework.sh` (Mobile* API unchanged), app builds + 265 tests green. Follow-up: #320 (re-benchmark our 60fps vp8/sei srv.sh defaults against upstream's new 30fps recommendation) | Reconnects after a dropped session are more reliable |
| 320 | parity | srv.sh `VP8_FPS`/`VP8_BATCH` (60/8) and SEI fps default (60) predate upstream's CPU-reduction pass — re-benchmark at 30fps before changing the boc defaults | Decision, no benchmark needed: the app always sends OLCRTC_VP8_* from Settings (default 60/64, "tested on Telemost + wbstream"), so the srv.sh boc fallbacks only govern non-app curl-piped runs — re-based VP8_FPS/VP8_BATCH 60/8 → upstream's post-CPU-reduction 25/1. The SEI premise was wrong: our SEI fallbacks already equal upstream's (60/64/900/2000). Mobile fps stays user-tunable via the Settings sliders | — |
| 321 | docs | README: rewrite the iPhone-install section around SideStore/LiveContainer + merge the build sections into one "Build it yourself" | README restructured: new lead section "Install on your iPhone (sideload)" — SideStore primary (one-time iLoader USB install, LocalDevVPN from the App Store for the on-device 7-day refresh, install via the Release-notes install link (#349) or `.ipa` import), LiveContainer alternative (LC+SideStore bundle via the same iLoader step, paste the `.ipa` Release link via **+**, apps inside the container never need re-signing), old AltStore/Sideloadly flow kept as a "Classic cable path" `<details>` block; Requirements + Build and run + Updating + the two build `<details>` blocks merged into one "Build it yourself" section (deps table → build & run in Xcode → unsigned `.ipa` → updating), placed after sideload and before Project structure; Troubleshooting `#build-and-run` anchor updated. All external links/claims verified against sidestore.io docs, LiveContainer docs, github.com/nab138/iloader and the LocalDevVPN App Store page | README: installing on your iPhone now leads with SideStore/LiveContainer — paste the Release link, no computer needed after one-time setup — and all build docs live in one "Build it yourself" section |
| 322 | build | Commit `bf48a75` message ("upstream parity update") is not Conventional Commits and omits the #297/#318 work — amend before push | amended before push | — |
| 325 | parity | parity_check 2.0: two-way line-by-line check — rejected upstream lines stay in srv.sh commented with a reason marker; unaccounted upstream additions fail the check into a triage task | parity_check.py rewritten: classifies our lines (base / ours-in-boc / rejected) and upstream lines (adopted / rejected / unaccounted); new `# boc olcrtc-ios-rejected: <reason>` … `# eoc olcrtc-ios-rejected` blocks carry skipped upstream lines as `# `-commented verbatim copies; backfilled all 156 unadopted upstream lines into five rejected blocks (interactive menus, /tmp workdir, unconditional image pull, config-name prompt, gr-binary QR download); fails on base drift, stale rejections, and unaccounted upstream additions (error text: adopt or reject-with-reason + file a TODO triage task); base-order deviations warn only; both failure directions negative-tested; docs updated (README *How srv.sh works* + Troubleshooting, CONTRIBUTING *srv.sh parity*, AGENTS §3) | — |
| 326 | l10n | Connections tab: default group header says "Servers" — rename to "Connections"; "servers" wording stays Manage-VPS-only | Duplicate — implemented as #344 in the build-248 commit (en "Connections", ru "Подключения"; stored `defaultGroupName` token unchanged per #283) | — |
| 327 | features | Routing switch (Connections tab) only reroutes diagnostics (IP check / speed test), not the actual tunnel — make "All direct" apply to the SOCKS path too | Removed instead (operator decision: not currently relevant — revisit later): the switch only rerouted in-app diagnostics, never the SOCKS tunnel, and a real bypass needs upstream/core support (no bypass mode in Mobile.objc.h, verified 2026-06-12). UI + plumbing commented out under boc #327 markers in ConnectionsView (RoutingMode enum and L10n strings kept for the return); diagnostics now simply follow tunnel state | The Routing switch is gone from the Connections tab for now — it only ever affected in-app diagnostics, never the real tunnel |
| 332 | performance | Log pipeline causes UI freezes: slow disconnect, laggy Logs screen | File writes moved to a shared serial background queue (ordering + redaction-before-disk preserved); per-line revision bumps coalesced via LogUpdateCoalescer (leading+trailing throttle, ≤4 UI updates/s); entries/containerEntries de-@Published; LogsView refresh gated on tab visibility (post-#316 re-check: it observed the store even while hidden); rendered lines capped at newest 500 with a localized notice (Share/Copy keep full history). Unit tests in LogPipelineCoalescingTests. Follow-ups filed: #352 (on-disk rotation), #353 (lazy share item) | Disconnect is fast again and the Logs screen stays smooth even when logs pour in |
| 336 | performance | App degrades over long sessions (suspected log growth) — profile to confirm; likely shares the #332 root | Shares the #332 root — closed by #332's rework: render cost is flat (newest-500 cap) regardless of session length, UI invalidations ≤4/s and zero while the Logs tab is hidden, file writes off-main, in-memory buffers already bounded (logBufferSize). Remaining suspect for any residue is unrotated on-disk log growth → #352; reopen if an on-device long-session check still degrades | — |
| 338 | ux | Logs: inline container fetch with progress (design_handoff_logs_theme §2) | Container source card in LogsView: host chips ≤3 (primary connection's host first, ★; `Menu` picker beyond 3) + secondary "Fetch"/"Check server" `OlcButton` with `isBusy`; monotonic 3-phase progress (Connecting… → `podman logs --tail N <name>` → Receiving output…) with k/n + new shared `OlcProgressBar(fraction:)` (also replaces the Manage VPS card's `ProgressView`); `Provisioner.containerLogs` emits the third phase signal and writes a `── podman logs --tail N · HH:mm ──` divider (`.debug`/tertiary) via `startContainerSession(divider:)` instead of the generic "── new session ──"; empty buffer → `OlcEmptyState` with primary "Fetch from {host}" CTA; scan-first fallback (#296/#297 alert) kept; removed orphaned `logsDownloadFromServer` key | Container logs now fetch right inside the Logs tab with live phase progress and a session divider |
| 339 | ux | Logs: delete the container-logs popup; Manage VPS routes to the Logs tab (design_handoff_logs_theme §3) | deleted `ContainerLogsView.swift` + `ContainerLogsPayload` + ServersView's `logsPayload`/`.sheet`/`fetchLogs`; new `LogsRouter` (`@Published request: (hostID, autofetch)?`) owned by App.swift — ServersView's renamed "Container logs" item writes a request, MainTabView switches to the Logs tab, LogsView consumes it (Container category + host + auto-fetch via #338's phase UI, idempotent, skipped if a fetch is running); removed orphaned `emptyLogsTitle`/`emptyLogsHint_fmt`, `actionDownloadContainerLogs` → `actionContainerLogs` ("Container logs"); no SSH/Provisioner logic changes (stale doc comment fixed) | "Container logs" on a VPS card now opens the Logs tab and fetches right there — no more popup |
| 340 | ux | Light/Dark theme with System/Light/Dark picker (design_handoff_logs_theme §4) | persisted `AppearanceMode` (system/light/dark, **default dark** so existing users see no change) in SettingsStore; "Appearance" picker above the Refined/Console picker; `.preferredColorScheme` on the root in App.swift; removed `UIUserInterfaceStyle: Dark` from project.yml (it would override the modifier); Theme.swift `bg`/`segActive`/Console `card` + new `cardBorder` token now dynamic via `UIColor` trait closures per the handoff token table (Console light values applied mechanically — no further Console design work per operator decision; #299 stays open for the full Refined/Console replacement); audit found one hardcoded surface (OlcCard hairline `Color.white.opacity(0.16)` → `Theme.Palette.cardBorder`); light `#Preview`s added for the component set + all five tabs; CLAUDE.md dark-only invariant rewritten | New Appearance setting: System, Light, or Dark theme (default stays dark) |
| 341 | ux | Manage VPS card: fixed footprint + icon actions + compact metrics (design_handoff_logs_theme §5) | status region in a `minHeight: 58` container (pill / pill+bar / failed pill crossfade, no height change); metrics strip ALWAYS rendered — new one-line `OlcMiniStat` strip `PING 27ms · DISK 36/40G · RAM 241/2048M · UP 11d` ("—" placeholders, `.opacity(0.45)` during ops) replacing the conditional two-deck `OlcMetric` row; action bar = contextual primary + three 44×44 tinted `OlcIconButton`s (Check accent / Container logs green → #339 route / Reconfigure orange), logs+reconfigure disabled without a container, all disabled during ops, still a strict subset of `hostMenu`; `OlcMiniStat(label:value:tone:)` + `OlcIconButton(systemImage:tint:)` added to DesignSystem.swift; compact formatters `shortUsage`/`shortUptime` pinned by new `VPSStatFormattingTests` (269 tests) | VPS cards keep one fixed size in every state, with compact one-line metrics and three tinted quick-action buttons |
| 342 | ux | Connections: fixed-footprint hero + connect progress + speed units (design_handoff_logs_theme §6) | hero restructured: status row · ALWAYS-rendered two-line server line (mono subtitle reserves its line) · always-present hairline · fixed `minHeight: 44` footer slot swapping hint ("Flip the switch to connect via %@") / connecting (mono text + `HeroIndeterminateFill` — single `.connecting` state, asymptotic 90% fill, no fake steps) / waiting-for-network / SOCKS5 line / failure (2-line clamp) + compact 32pt Retry; conditional divider+row appends deleted; `OlcButton` gained `compact:` (32pt, same roles); `OlcMetric` gained `unit:` (smaller secondary text) — speed formats become number-only (`speedPingValue_fmt` "%.0f", `speedRateValue_fmt` "%.1f") with new `speedUnitMs`/`speedUnitMbps`, unit only next to a real number; IP-check block untouched (growth on disagreement by design); no TunnelManager changes | Connections hero keeps one fixed size in every state, shows connect progress, and speed-test numbers carry their units cleanly |
| 343 | ux | Settings regroup + DNS submenu + Appearance last (design_handoff_logs_theme §7) | section order now SOCKS5 (one section: port + Random + check + auth) → DNS → vp8channel → Connection (six sections merged into one) → Diagnostics (IP-sources link + speed provider, picker unchanged per operator decision) → Logs (three merged) → Appearance (language · Theme=System/Light/Dark · Direction=Refined/Console · font slider) → version footer; DNS chip wall → `NavigationLink` summary row ("Yandex · 77.88.8.8:53") + new `DNSSettingsView` subscreen (preset rows: name + mono address + checkmark, long dnsFooter moved there, free-form field + keyboard Done; also kills the MegaFon/Yota duplicate-ForEach-ID the chip wall had); one short footer per section (kept: socksPortChangeNote, footerKeepAlive, speedProviderFooter, footerLogBuffer, fontFooter); relabels: scheme picker "Appearance"→"Theme", Refined/Console "Theme"→new `directionLabel` "Direction", section header "Font"→"Appearance"; removed 10 orphaned L10n keys; every SettingsStore binding kept | Settings reorganized: cleaner sections, DNS picker moved to its own page, appearance options grouped at the bottom |
| 344 | l10n | Connections tab: default list group says "Servers" — rename to "Connections" | `L10n.groupDefault` display value "Servers"→"Connections" (ru "Основная"→"Подключения"); display-only — the persisted raw `ConnectionRecord.defaultGroupName` stays "Servers", mapped via `displayGroupName` (#283), so no migration | The connection list on the Connections tab is now titled "Connections" instead of "Servers" |
| 345 | build | Commit `05b3447` message ("no description yet") is not Conventional Commits — amend before push | amended before push (build-248 commit, `feat(ui): single-stack Logs tab…`). Policy fixed so this task type isn't refiled: a placeholder subject is the expected pre-review state — the local `/review-commits` command now hands the ready-to-run amend command instead of filing a task; the commit-review and batch sections (§7/§8) were removed from public AGENTS.md (operator-local workflow — contributors review their own way) | — |
| 348 | tests | CI red on main: ConnectionStoreTests.testSaveLoadRoundtripPreservesAllFields — stale assertion after #344 | the test compared the persisted `groupName` against `L10n.groupDefault.localized()`; that held pre-#344 when both were "Servers", but #344 changed only the *display* value to "Connections" (raw token unchanged via `displayGroupName`, no migration), so the roundtrip assertion broke. Now asserts the raw token `ConnectionRecord.defaultGroupName` | — |
| 349 | build | Release notes: auto-generate SideStore/LiveContainer install links for the `.ipa` asset | release.yml "Build release notes" step now emits an "Install on iPhone" block before the asset footer: `sidestore://install?url=…` and `livecontainer://install?url=…` pointing at the tag's `olcrtc-ios-unsigned.ipa`, rendered as code spans (GitHub strips non-https schemes from markdown links — the reader copies them into Safari) plus a link to the README sideload section; the asset-footer line now names SideStore/LiveContainer alongside AltStore/Sideloadly | Release notes now include ready-to-paste SideStore/LiveContainer install links for the app |

---

## Deferred

Parked indefinitely — blocked on something external or consciously postponed.
Not part of active planning. Revive a task by moving its row back to Backlog
(or Open) and dropping the Reason; its Details block (if any) lives on in the
Details section meanwhile.

| ID | Pri | Eff | Theme | Title | Reason |
|---|---|---|---|---|---|
| 112 | P3 | XL | features | NetworkExtension packet tunnel | no paid dev account — `packet-tunnel-provider` entitlement needs the $99/yr program |
| 113 | P3 | M | features | SOCKS port per-profile (multiple simultaneous tunnels) | low priority |
| 114 | P3 | L | features | New protocols — vless / xray / reality / rprx-vision / awg 2.0 | low priority |
| 115 | P2 | M | build | TestFlight: App Store Connect record + internal-testing build | no paid dev account — App Store Connect needs the $99/yr program |
| 235 | P3 | L | features | Failover profiles — multi-profile install | depends on #247, which is UPSTREAM-only |
| 247 | P3 | L | build | Failover/profiles in the gomobile binding (rebuild xcframework; unblocks #235) | UPSTREAM-only — needs upstream binding work before any iOS side exists |
| 254 | P3 | XS | docs | CODE_OF_CONDUCT.md (Contributor Covenant) | low priority |
| 257 | P3 | S | docs | Privacy-policy document (App Store needs a hosted URL) | low priority |
| 299 | P3 | L | ux | Theme = real colour schemes (Dark/Light/Gray), not tile borders — replace Refined/Console | low priority |
