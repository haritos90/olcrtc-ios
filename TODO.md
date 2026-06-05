# TODO

Task ledger for olcrtc-ios. Every task has a permanent 3-digit ID and flows
**Backlog → Open → Closed**. This is the single place work is tracked;
`AGENTS.md` and `CONTRIBUTING.md` point here.

## How this file works

**Lifecycle**

1. **New task** → add a row to **Backlog**, and (if the title isn't enough) a
   block under **Details** with the full description.
2. **Work starts** → move the row to **Open**.
3. **Finished** → move the row to **Closed**, fill the **Resolution** column (how
   it was resolved — or `Won't Do` / `Duplicate` for rejected tasks), and
   **delete its Details block**.

A rejected or duplicate task is also closed (Resolution `Won't Do` / `Duplicate`);
there is no separate "won't do" list. Detail blocks exist only for **Open +
Backlog** tasks. Closed tasks are title-only history plus the **Resolution** note —
their full setup descriptions are intentionally not kept.

**Columns**

- **Pri** — `P0` critical (correctness / security / broken) · `P1` high ·
  `P2` medium · `P3` low / nice-to-have.
- **Eff** — `XS` ≤ 15 min · `S` ≤ 1 h · `M` ≤ ½ day · `L` ≤ 2 days · `XL` > 2 days.
- **Theme** — security · reliability · architecture · parity (server↔client wire
  contract) · tests · observability · ux · docs · build · l10n · features ·
  migration · accessibility · performance · settings.

**Sorting** — every table (Open, Backlog, Closed) and the Details blocks are kept
in **ascending ID** order.

**Layout** — Open and Backlog come first, then their **Details** blocks, then the
**Closed** history last, so the active work and its descriptions stay at the top.

**Next free ID:** 288

---

## Open

Current, actionable work.

| ID | Pri | Eff | Theme | Title |
|---|---|---|---|---|

_Nothing in progress right now — next candidates are in Backlog._

---

## Backlog

Future / blocked / someday. Promote to Open when picked up.

| ID | Pri | Eff | Theme | Title |
|---|---|---|---|---|
| 097 | P3 | L | features | SEI/VIDEO env vars end-to-end UI, or commit to VP8-only |
| 111 | P3 | M | features | Subscription URLs (`olcrtc-sub://`) — needs public server pools |
| 112 | P3 | XL | features | NetworkExtension packet tunnel (needs $99/yr dev account) |
| 113 | P3 | M | features | SOCKS port per-profile (multiple simultaneous tunnels) |
| 114 | P3 | L | features | New protocols — vless / xray / reality / rprx-vision / awg 2.0 |
| 115 | P2 | M | build | TestFlight: App Store Connect record + internal-testing build |
| 135 | P3 | M | features | Share connection (full access: SSH creds + URI, for co-admin) |
| 235 | P3 | L | features | Failover profiles — multi-profile install (BLOCKED on #247) |
| 247 | P3 | L | build | Failover/profiles in the gomobile binding — **UPSTREAM-only** (rebuild xcframework; unblocks #235) |
| 254 | P3 | XS | docs | CODE_OF_CONDUCT.md (Contributor Covenant) |
| 257 | P3 | S | docs | Privacy-policy document (App Store needs a hosted URL) |
| 273 | P3 | M | features | Release the "Direct" routing mode (`.allDirect`) — bypass the tunnel while staying connected |
| 274 | P3 | S | ux | Unify the two per-connection probes — "check latency" (#234) + "time to ready" (#242) share one chip |
| 275 | P2 | M | reliability | "Container running" ≠ "connection healthy" — explain connect timeouts (no peer joined / key mismatch), not a green "connected" |
| 276 | P2 | M | observability | Logs: one merged stream + per-entry source tag + level colour-coding |
| 277 | P3 | M | observability | Logs: dated timestamps `yyyy.MM.dd HH:mm:ss.SSS`, consistent newest-first order, retained scroll |
| 278 | P2 | M | observability | Server/container logs in the Logs tab (download→refresh); rename VPS "Logs" → "Download logs"; match ordering |
| 279 | P2 | L | observability | Message catalog: typed (info/warn/error), error-coded client+server messages, searchable + troubleshooting cross-ref |
| 280 | P2 | M | performance | Fix UI jank when changing font size while the screen scrolls |
| 281 | P3 | M | ux | Make the Refined/Console design directions actually distinct (or drop the toggle) |
| 282 | P2 | S | l10n | `serverNotResponding`: RU shows English + reword to name the carrier server, not the VPS |
| 283 | P2 | M | l10n | Localisation gaps: "Servers" group, VPS-list + matrix carrier/transport, Logs tabs + header; route hardcoded terms through L10n |
| 284 | P3 | M | parity | Update the carrier×transport compatibility matrix data (upstream / OpenWRT luci) |
| 285 | P2 | M | reliability | Speed test over the tunnel: graceful degradation on a narrow pipe + selectable providers + log connection-type |
| 286 | P3 | S | ux | IP-check: selectable providers (checkboxes in Settings) + log connection-type |
| 287 | P3 | S | observability | Log-line cleanups from the real capture: keep-alive "−N s ago", verify "bad URL", mixed RU/EN |

---

## Details (Open + Backlog only)

### 097 — SEI/VIDEO env vars end-to-end OR remove

Server reads `OLCRTC_VIDEO_*` and `OLCRTC_SEI_*`; the client never sets them. Either
expose them in `SettingsStore` + `InstallOptionsView` (~14 sliders), or commit to a
"VP8-only client" and drop the dead branches from `scripts/srv.sh`. The UI hint from
#087 buys time but is a placeholder.

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

### 273 — Release the "Direct" routing mode (`.allDirect`)

`RoutingMode` ships only `.allTunnel` today (`App/Models/RoutingMode.swift`), so the routing
segmented control in ConnectionsView is a pointless single option. Add the planned `.allDirect`
"Direct" mode — a global kill switch that bypasses the tunnel even while the session stays
connected. Wiring: add the case + `title`/L10n; make ConnectionsView's `currentMode` honour it
(`routingMode == .allDirect ? .direct : (connected ? .tunnel : .direct)`) so the app's own
diagnostics (IP check / speed test) and any in-app `SOCKSSession` go direct; persists via the
existing `@AppStorage("olcrtc_routing_mode")`. **Settle first:** scope — `.allDirect` cleanly
controls the *app's own* URLSession routing, but it can't force *external* apps off the local
SOCKS port, so decide whether "Direct" means "app-diagnostics bypass" only or also "tear the
proxy down but keep the config" (a truer kill switch). Mirrors Shadowrocket's global-route
toggle; framing groundwork for the later `.rules` / `.scene` modes noted in `RoutingMode`.

### 274 — Unify the two per-connection probes (ping + time-to-ready)

The connection row exposes two confusingly-similar probes that share one chip: **"check
latency"** (#234 `ping` — HTTP round-trip ms through a throwaway *isolated* olcrtc client that
doesn't touch the live tunnel) and **"measure time to ready"** (#242 `checkReady` — how long the
WebRTC transport takes to reach *ready*, via the same throwaway client). Because `checkReady`
overlays the `ping` chip (long-press / context menu), the two appear to alternate in one slot
and the distinction is opaque. Merge into a single "Health check" action that runs the probe(s)
once and shows one combined result (e.g. "ready 420 ms · RTT 90 ms"); drop the dual chip +
long-press gesture. `TunnelManager.ping`/`checkReady` + `OlcrtcEngine` stay — only the row UI
collapses. Small.

### 275 — "Container running" ≠ "connection healthy"

**Correction (2026-06):** the original "room does not exist" premise was a misunderstanding — the
server **auto-creates** the conferencing room (telemost), so a missing room isn't a real failure.
What remains valid: the VPS card shows "container running" (the *process* is up) even when no
tunnel/peer is actually established, which reads as "all OK". Detect "tunnel up but no peer in room"
vs "peer present" and, on a connect timeout, say *why* (no peer joined within Ns — wrong key / room
mismatch / carrier issue) instead of a generic failure. Ties into #280 (container-log inspection) and
#279 (typed message OLC-2014 for the condition).

**Signal (from the log capture):** the server joining a room but the iOS client never rendezvousing
shows as **`Link connected` with no following `session opened: …`** — i.e. the control link is up but
no peer session ever opens (vs the happy path `Connecting → Link connected → session opened (peer=…)`).
Client-side that's a `MobileWaitReady` timeout (already → `.failed`), but the VPS card separately shows
"container running" (the *process* is up), which is what reads as "all OK". So #275 is really two
fixes: (a) don't equate "container running" with "connection healthy", and (b) when a connect times
out, say *why* (likely empty/wrong room — no peer joined) rather than the generic carrier-not-responding
(#282).

### 276 — Logs: one merged stream + per-entry source + level colour-coding

Logs are split into per-category tabs (`connection` / `ip` / `containerLogs` / …) in
`LogStore.entries: [LogCategory: [LogEntry]]`. The volume is small, so separate tabs add friction
without value — merge into a **single chronological stream**, tagging each line with a compact
source badge (Conn / Container / IP / …) so origin stays clear (IP-check lines today carry no
source label at all). Add **colour-coding by level** — debug/noise · info · warning · error
(levels partly exist from #217) — so problems are scannable. Keep a source *filter*, not separate
tabs. Pairs with #277 (timestamps) and #279 (typed messages).

### 277 — Logs: dated timestamps + consistent ordering + scroll

`LogStore.timestamp()` emits `HH:mm:ss.SSS` — **time only, no date** — so it's unclear what
you're looking at across sessions/days. Standardise on **`yyyy.MM.dd HH:mm:ss.SSS`** everywhere
(client lines, and the server/container lines once #278 normalises them). Fix ordering + scroll:
the Logs tab and the VPS-fetched logs disagree on direction, and the view keeps snapping to old
entries at the bottom even after you scroll up to newer ones — pick one order (newest-first) and
**retain the user's scroll position**.

### 278 — Server/container logs in the Logs tab (download → refresh) + rename

Add a control **in the Logs tab** to pull the server's container log (`podman logs --tail N`,
already wired via `Provisioning.containerLogs` / `SSHRunner.containerLogs`); once loaded, change
it to **"Refresh from server"**. Rename the VPS-card **"Logs"** action (`L10n.actionLogs`) to
**"Download logs"** (it downloads a snapshot, not a live view). Normalise the fetched lines into
the same ordering + timestamp format as the client stream (#277) so the two interleave cleanly
(today the VPS "Logs" output is in a different order than the Logs tab).

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

### 280 — Fix UI jank when changing font size while scrolling

Dragging the font-size control while the screen scrolls stutters the UI. #203/#204 cached the
`DateFormatter` / redaction regexes, but the jank persists — profile the font-size path (likely a
full re-layout of long log lists on every slider tick + scroll) and debounce / virtualise so
resizing stays smooth.

### 281 — Make the Refined/Console design directions actually distinct

#267 added a Settings toggle (Refined / Console) driving 6 `Theme` tokens, but the two render
almost identically. Either make them **visibly different** (e.g. Console = sharper radii, mono
accents, denser spacing, hairline borders) or drop the toggle if a second direction isn't worth
maintaining.

### 282 — `serverNotResponding`: RU localisation + carrier-vs-VPS wording

On a failed connection the RU UI shows the English message even though the L10n value exists
(`Сервер не отвечает`) — the English likely comes from a raw Go `TunnelEngineError` message
passed straight into `.failed(e.message)`, bypassing L10n; route those through localised strings.
Also **reword**: "Server not responding" reads as if the user's *VPS* is down, when it's the
**carrier conferencing server** (Jitsi/Telemost/WBStream) that didn't answer — say so (e.g.
"Conferencing server not responding" / "Сервер видеосвязи не отвечает").

### 283 — Localisation gaps sweep

User-facing strings that render English in RU:
- the Connections **"Servers"** group name (`ConnectionRecord.groupName` default is a hardcoded
  literal, not L10n — needs display-time mapping or a migration for existing records);
- **carrier × transport** names in the VPS list and the compatibility matrix (rendered as raw IDs
  `telemost` / `vp8channel` via `map { ($0, $0) }`, never localised — add friendly localised
  display names);
- the **Logs** tab category labels + header (keys exist — `categoryConnection` = "Подключение",
  `logsTitle` = "Логи" — but the redesigned view appears to bypass them; wire the tabs/title
  through the keys).

Convention (per maintainer): route **every** user-facing term through L10n even when we keep it
English — put the English text in the RU dict explicitly rather than leaving it hardcoded — so
future locales can translate it. Translate at least `connection` / `container`; `vps` and the
like may stay English (but still as explicit entries). Document the convention in CONTRIBUTING.

### 284 — Update the carrier×transport compatibility matrix

Re-derive `CarrierTransportMatrix` cell data from the current source of truth. Check **upstream
`olcrtc`** first (e2e tests / docs) for authoritative carrier×transport support; cross-check the
OpenWRT luci app (`tankionline2005/OlcRTC-OpenWRT` → `…/view/olcrtc/main.js`, where the original
cells came from). Refresh recommended / ok / question / fail per current reality (jazz already
removed #224; jitsi data from #225).

### 285 — Speed test over the tunnel: degrade gracefully + selectable providers

**Root cause (measured 2026-06):** the speed test "never works on the tunnel" because `vp8channel` is a
low-bandwidth covert transport, not because the test is broken. VPS raw uplink ≈ **775/318 Mbps**
(cloudflare, from the host); through the tunnel ≈ **0.77/0.51 Mbps** — a ~1000× collapse. `server.yaml` =
`transport: vp8channel`, `vp8.fps 60 / batch 64`, carrier telemost. Under the test's parallel connections
the narrow, high-latency pipe returns `remote not ready (timeout)` (server `OLC-2008`), surfaced
client-side as `CFNetwork error 310` on the ping samples (`OLC-1021`); the bulk transfer still trickles
at <1 Mbps. Fixes:
- **Degrade gracefully:** fewer / sequential connections, longer timeouts, tolerate ping failure (report
  `ping n/a`, not an error), report partial throughput.
- **Log the connection type** (direct/tunnel + carrier/transport) in the speed-test header (`OLC-1020`).
- **Selectable providers** in Settings (cloudflare may be slow/blocked) — a short pick-list.
- **Surface the lever:** vp8channel trades bandwidth for looking like a video call; `datachannel` is far
  faster *where the network allows it* — and **telemost+datachannel is `.ok`** in the matrix, so hint the
  user toward Reconfigure → datachannel for speed. Ties into #284 (matrix accuracy).

### 286 — IP-check: selectable providers + connection-type

Add a **Settings list of IP-check providers with checkboxes** (which sources to query). The UI already
mostly shows just a source counter (#216 collapses agreeing sources), so the per-source choice belongs in
Settings, backed by the existing `AppConstants.ipCheckServices`. Also log the **connection type**
(direct/tunnel) in the IP-check header (`OLC-1023`) so a check's context is clear. Pairs with #285 (same
connection-type treatment).

### 287 — Log-line cleanups from the real capture

Small fixes to misleading lines the 2026-06 capture surfaced (`OLC-1024/1025`):
- **Keep-alive "active −N s ago"** — `noteActivity(forAtLeast:)` sets the activity marker *ahead* (to
  suppress probes during a known-busy window), so the "ago" math goes negative. Clamp the displayed age at
  0 (or word it "active now / for the next N s").
- **Tunnel verify "bad URL"** — a valid URL reports `bad URL` when the SOCKS session can't be built during
  teardown; give it a truthful reason ("proxy not ready").
- **Mixed RU/EN** for one concept (`Port 8808 free` vs `Порт 8808 свободен`) — two code paths log the same
  thing differently; route both through one L10n key (folds into #283).

---

## Closed

History of completed tasks. The **Done** column is a one-line "how it was
resolved" note for tasks closed under the current workflow; older entries are
title-only.

| ID | Theme | Title | Resolution |
|---|---|---|---|
| 001 | reliability | SSH connect timeout — reproduce + document network-side root cause |  |
| 002 | parity | URI parser accepts URIs without `%clientID` |  |
| 003 | migration | Adapt Provisioning to upstream YAML config switch — triggered; covered by #221 + #222 |  |
| 004 | security | KeychainHelper — atomic upsert, no silent write failure |  |
| 005 | reliability | TunnelManager — retry ↔ disconnect race fix |  |
| 006 | architecture | `LogStore.log()` marked `@MainActor` |  |
| 007 | reliability | `BackgroundRuntimeKeeper` — guard let + rollback on engine.start failure |  |
| 008 | security | `NSAllowsArbitraryLoads: false` (all URLSession is HTTPS) |  |
| 009 | security | `SubscriptionFetcher` TLS host-override audit |  |
| 010 | reliability | `SettingsStore` — didSet clamping + `Defaults` enum |  |
| 011 | security | `KeychainHelper` — distinguish not-found from error |  |
| 012 | security | `KeychainHelper` — atomic delete+add via SecItemUpdate |  |
| 013 | architecture | `SettingsStore` snapshot before `Task.detached` (already correct, documented) |  |
| 014 | architecture | `Provisioning.install()` split into 5 phases |  |
| 015 | architecture | `TunnelManager.startOlcrtc()` split into preflight + runMobile |  |
| 016 | architecture | `SSHRunner.withConnection` helper (replaces 8 close calls) |  |
| 017 | architecture | `OlcrtcURI.parse()` split into named helpers |  |
| 018 | docs | README — structure, requirements, quick start, architecture |  |
| 019 | build | GitHub publish prep — LICENSE, .gitignore, no hardcoded paths |  |
| 020 | build | `olcrtc://` URL scheme registered in project.yml |  |
| 021 | architecture | Dedup SSH close × 8 (subsumed by #016) |  |
| 022 | architecture | Dedup guard-password/container × 4 |  |
| 023 | ux | Dedup copy-feedback pattern × 2 |  |
| 024 | architecture | Dedup `ContainerStatus.parse()` |  |
| 025 | architecture | Tunnel verify URL + fallback → `AppConstants` |  |
| 026 | architecture | Remote temp paths → `RemotePaths` enum |  |
| 027 | architecture | Poll constants named (`installMaxPolls`, etc.) |  |
| 028 | ux | DNS presets → `AppConstants.dnsPresets` |  |
| 029 | architecture | SpeedTest constants → `AppConstants.SpeedTest` |  |
| 030 | architecture | IPChecker services → `AppConstants.ipCheckServices` |  |
| 031 | architecture | `SettingsStore.Defaults` enum + range constants |  |
| 032 | docs | Doc comments on ObservableObject classes |  |
| 033 | docs | `OlcrtcURI` dual-format payload comment |  |
| 034 | docs | `ContinuationGate` `@unchecked Sendable` (first pass) |  |
| 035 | docs | `ProvisionError` cases doc-commented |  |
| 036 | tests | `TunnelManager.validate()` tests |  |
| 037 | tests | `SSHRunner.extract()` + `parseInstallResult()` tests |  |
| 038 | tests | URI parser edge case tests |  |
| 039 | tests | `PortAvailability.isFree` tests |  |
| 040 | tests | `KeychainHelper` roundtrip tests |  |
| 041 | tests | Provisioning poll-loop tests — needs `SSHClientProtocol` mock abstraction |  |
| 042 | build | `parity_check.py` line numbers + structural validation |  |
| 043 | ux | SettingsView — Steppers → TextField + quick-pick presets |  |
| 044 | security | `IPChecker` — proper IPv4/IPv6 validation |  |
| 045 | reliability | `SettingsStore.reset()` + fontSizeIndex clamp |  |
| 046 | architecture | Dead-code sweep |  |
| 047 | l10n | Translate UI to English with multi-language support |  |
| 048 | l10n | Translate code/docs to English |  |
| 049 | parity | Compatibility matrix — add jitsi carrier (new in universal-carrier); update existing cells |  |
| 050 | reliability | Install poll loop — explicit catch + classify SSH errors |  |
| 051 | reliability | Mid-install TCP-22 reachability re-probe every 5 polls |  |
| 052 | security | `OLCRTC_DNS` wrapped in `shellSafe()` |  |
| 053 | reliability | `LogFileWriter` — guard let Documents URL |  |
| 054 | observability | `bgKeeper.start()` — explicit catch + L10n log |  |
| 055 | architecture | Split `Provisioning.swift` → `SSHRunner.swift` |  |
| 056 | architecture | Group `App/` files by responsibility (`Core/`, `Models/`, `Views/`, …) |  |
| 058 | docs | `Provisioner` `@StateObject` lifecycle doc-block |  |
| 059 | reliability | Keep-alive / retry tasks — uniform synchronous-nil discipline |  |
| 060 | docs | `MobileSet*` thread-safety audit + doc |  |
| 061 | reliability | `SettingsStore` UserDefaults writes async (off-MainActor) |  |
| 062 | ux | `AddServerHostView` pre-fills password on edit |  |
| 063 | tests | `TunnelManager` state-machine tests (11 cases; private-state gaps documented) |  |
| 064 | tests | Provisioning polling untested (duplicate of #041) | Duplicate |
| 065 | tests | `ConnectionStore` persistence tests |  |
| 066 | tests | `SettingsStore` clamping tests |  |
| 067 | tests | `PortAvailabilityTests` retry-loop cap |  |
| 068 | observability | `verifyTunnel()` — per-URL success/failure log |  |
| 069 | architecture | Standardize `Task.sleep(for: .seconds(_:))` |  |
| 070 | reliability | `SubscriptionFetcher` — ephemeral URLSession (no cache) |  |
| 071 | reliability | `SubscriptionFetcher` — uniform 15 s timeout |  |
| 072 | reliability | `tunnelVerifyURLs` — add 3rd `ifconfig.me` fallback |  |
| 073 | reliability | `SubscriptionFetcher` — DoH endpoint fallback list |  |
| 074 | observability | `LogsView.fullText` recompute → cache via onChange |  |
| 075 | docs | `ContinuationGate` `@unchecked Sendable` — expand invariant doc |  |
| 076 | observability | `TunnelManager` — state-transition log line in didSet |  |
| 077 | docs | TODO.md P2 header renamed "Pre-publish polish (historical)" |  |
| 078 | docs | Move upstream-refactor section to `docs/UPSTREAM_MIGRATION_PLAN.md` |  |
| 079 | docs | README troubleshooting section |  |
| 080 | docs | README — Mobile.xcframework build instructions tightened |  |
| 081 | docs | `scripts/srv.sh` patch description tenses — standardize to imperative |  |
| 082 | docs | `parity_check.py` error message — concrete next-step diff hint |  |
| 083 | docs | Doc-comments on misc structs/enums (`IPResult`, `SpeedResult`, etc.) |  |
| 084 | build | `Entitlements.plist` for explicit `audio` background mode |  |
| 085 | reliability | Parallelize tunnel-verify probe (first-success wins) |  |
| 086 | parity | Container-name prefix sync (`olcrtc-server-` everywhere) |  |
| 087 | parity | SEI/video transport — UI hint about server defaults (option b) |  |
| 088 | security | `LogStore.redactSecrets()` — key + URI key-segment redaction |  |
| 089 | parity | `OLCRTC_CONFIG_NAME` duplication — kept + cross-ref comment |  |
| 090 | parity | `mimo` ↔ `sub_configname` naming drift | cross-ref comments link client `mimo` ↔ server `sub_configname`/`OLCRTC_CONFIG_NAME` |
| 091 | parity | DNS default differs (Yandex client vs Google upstream) | documented deliberate Yandex default in srv.sh boc |
| 092 | parity | Plumb `--branch=` from client to srv.sh | Won't Do |
| 093 | parity | Document `OLCRTC_CACHE_DIR` capability (or surface in UI) | documented in `SSHRunner.installEnv()`: a server-side Go-cache knob; client leaves it at the persistent default `$HOME/.cache/olcrtc` (surface in Settings only if a custom cache location is ever needed) |
| 094 | parity | Container accumulation across re-installs | srv.sh sweeps prior `olcrtc-server-*` before a new install (boc block) |
| 095 | observability | `pollUntilDone` — offset-tracked log streaming |  |
| 096 | parity | `--no-cache` flag — document, plumb, or remove | documented at the srv.sh invocation in `SSHRunner.launchBackground()`: client runs the script with no args so the Go cache is always reused (fast installs); a future clean-rebuild option (#109) would pass `--no-cache` |
| 098 | architecture | Shared constants file for `RemotePaths` (server doesn't read them — document) |  |
| 099 | architecture | `extract(keys:from:)` single-pass overload |  |
| 100 | parity | `requiresRoomID` source-of-truth in `CarrierTransportMatrix` |  |
| 101 | migration | Migrate to olcrtc @ master (migration umbrella) | done via #221-#229; submodule @587c13e; residuals tracked as #230/#232/#235 |
| 102 | features | QR code import (AVCaptureSession + Vision) |  |
| 103 | features | QR code export (CIFilter.qrCodeGenerator) |  |
| 104 | features | Room ID OR link auto-detect in paste field |  |
| 105 | features | Room ID rotation without full reinstall |  |
| 106 | features | Change transport without reinstall |  |
| 107 | features | RU-carrier DNS presets |  |
| 108 | reliability | SOCKS port auto-retry (slide to next free) |  |
| 109 | features | Re-install / update olcrtc (git pull + rebuild, skip apt) |  |
| 110 | features | SEI channel params editor in OlcrtcConnection + UI |  |
| 118 | ux | Tab bar overlaps content — add bottom safe-area padding to all tab root views |  |
| 119 | ux | Install progress — named phase title + detail subtitle (not raw log lines) |  |
| 120 | features | VPS "Stop server" — podman stop without uninstall (leave room without wiping) |  |
| 121 | features | Auto-link VPS install → ConnectionRecord; optional auto-delete on uninstall |  |
| 122 | ux | Logs: preserve previous session — startSession should archive not clear |  |
| 123 | ux | IPChecker: append logs, don't call startSession (overwrites previous IP check) |  |
| 124 | l10n | EN "Servers" tab → "Manage VPS"; "Speed" category → "Speed test" |  |
| 125 | l10n | Default connection group name: "Main" → "Servers" |  |
| 126 | ux | Settings SOCKS port: remove Stepper +/−, add "Random port" button |  |
| 127 | ux | App version display: "1.0 (N)" → "1.0.N" in Settings Info section |  |
| 128 | ux | Uninstall confirmation: clarify scope (container only; cache/image stay) |  |
| 129 | settings | Toggle: auto-remove connection from list when VPS uninstalled (on by default) |  |
| 130 | features | Deep uninstall: remove container + Go cache + key + optionally image |  |
| 131 | features | VPS server state detection: show what's installed (Podman? cache? container running?) |  |
| 132 | l10n | Hardcoded UI strings audit: "Transport", "Room ID", "SEI Settings" (InstallOptionsView, ReconfigureOptionsView), "QR" label (ConnectionsView) → L10n |  |
| 133 | features | Scan VPS for existing olcrtc containers (by user request, not auto) — recover after reinstall/new device |  |
| 134 | features | Share connection (connection-only: URI without SSH credentials) |  |
| 136 | ux | VPS card: show disk space, RAM, uptime alongside readiness state |  |
| 137 | security | Local SOCKS5 auth — toggle + username/password in Settings, off by default |  |
| 138 | reliability | Reconfigure → update linked ConnectionRecord: after room/transport change, ConnectionRecord has stale URI — root cause of connection instability after reconfigure |  |
| 139 | reliability | Room ID spaces: strip on any input (paste/type) in AddConnectionView, not just on save |  |
| 140 | features | Start stopped container — "Start" button for stopped containers (podman start, no reinstall) |  |
| 141 | ux | Uninstall + linked connection deleted: show alert/notice that ConnectionRecord was also removed |  |
| 142 | ux | Settings: per-setting footers instead of grouped subtitles at section bottom |  |
| 143 | ux | VPS menu: split destructive actions into two clear items — "Remove container from server" + "Wipe all olcrtc data" (no guessing submenu) |  |
| 144 | ux | Scan sheet: Restore button hidden in swipeActions — make it visible in the row |  |
| 145 | reliability | After Restore, `statuses[host.id] == nil` → `?? true` hides Start button; change default to false |  |
| 146 | ux | ServersView action layout: big buttons = Status + Ping only; Start/Stop/Update/Logs → context menu |  |
| 147 | build | Remove auto-bump build number from Xcode pre-build script; Claude bumps manually on code changes only | removed auto-bump pre-build script; build number bumped by hand |
| 148 | reliability | Port auto-increment: preflight() saves bumped port to SettingsStore → port grows on every reconnect |  |
| 149 | reliability | Retry without MobileStop: scheduleAutoRetry → MobileStartWithTransport without prior MobileStop → possible double session in room |  |
| 150 | ux | numberPad keyboard has no Done button — blocks tab navigation; add FocusState + keyboard toolbar |  |
| 151 | ux | SOCKS port change UX: TextField applies immediately but proxy not restarted; add explicit Save + confirmation |  |
| 152 | observability | Log proxy port on start: after MobileWaitReady log "SOCKS5 ready on port N" so user knows exact port |  |
| 153 | observability | Logs lost on reconnect: keepalive retry fills logBuffer → old logs evicted; consider larger default or session separator |  |
| 154 | reliability | AddConnectionView carrier picker hardcoded (wbstream/jazz/telemost); missing jitsi — use CarrierTransportMatrix.carriers |  |
| 155 | ux | Connections swipe-delete shows "Remove container from server" (actionUninstall) — wrong label; should be "Remove from list" |  |
| 156 | ux | VPS Reboot has no confirmation dialog — reboots the whole VPS without warning |  |
| 157 | ux | Key field in AddConnectionView is SecureField — no reveal button; user can't verify 64-char hex was pasted correctly |  |
| 158 | ux | Transport picker in AddConnectionView shows all 4 transports regardless of carrier compatibility — should grey out incompatible ones |  |
| 159 | ux | LogsView shows oldest first; user must scroll to bottom to see latest — add auto-scroll-to-bottom on appear and on new entries |  |
| 160 | ux | All numericField inputs in SettingsView use numberPad but only port field has Done toolbar button; add Done to FPS/batch/timeout/keepalive/logBuffer fields |  |
| 161 | ux | AddServerHostView port field uses numberPad but no Done button to dismiss keyboard |  |
| 162 | ux | IP check results show no timestamp — stale results look like fresh ones; add "last checked HH:mm" label |  |
| 163 | ux | Client ID field default "default" is confusing — add footer explaining it is used to identify this client in multi-client rooms |  |
| 164 | ux | Connections server row: pencil Edit button visible AND Edit in context menu — duplicated; remove inline button, keep in context menu only |  |
| 165 | ux | Onboarding: first launch shows empty Connections with no workflow guide — add empty-state text explaining Add VPS → Install → Connect flow |  |
| 166 | ux | LogsView: no per-category Clear button — "Clear all" nukes everything; add clear per selected category |  |
| 167 | ux | Add "Set as primary + Connect" context menu action in Connections list — currently requires two taps (tap to set primary, then toggle) |  |
| 168 | ux | InstallOptionsView carrier segmented control: 4 carriers (incl jitsi) is tight on small screen — consider wheel/inline Picker |  |
| 169 | ux | AddServerHostView: no "Test SSH connection" button before installing — users discover SSH failure only when install starts |  |
| 170 | ux | VPS tab: no guidance after install ("Connection added — go to Connections tab to connect"); users don't know next step |  |
| 171 | ux | AddConnectionView: SOCKS5 auth footer says "server started with -socksuser/-sockspass" but these are LOCAL proxy credentials — fix description |  |
| 172 | ux | Connections: show current SOCKS proxy port below the global toggle when connected ("proxy :8808") |  |
| 173 | ux | Logs: "Share" sends all logs as text blob — add option to share only last N lines or selected category |  |
| 174 | ux | VPS server state machine: centralize state, hide/show menu items based on state (no container → no Remove/Update/Stop/Reconfigure) |  |
| 175 | ux | Proxy port displays with thousands separator ("8 808") — use .grouping(.never) formatting everywhere |  |
| 176 | reliability | TunnelManager state glitch: UI shows Connected after manual disconnect; toggle inconsistent — needs investigation |  |
| 177 | ux | SOCKS port check shows "busy" when port is in use by us (connected) — show "in use by tunnel" instead |  |
| 178 | ux | Jitsi in CarrierTransportMatrix: mark as .unknown/.notImplemented across all transports — not yet available on master branch |  |
| 179 | ux | "Update" menu item label unclear — rename to "Update binary (git pull + rebuild)" or add subtitle explaining what is updated |  |
| 180 | ux | Start/Stop container: replace two separate menu items with a single toggle in the VPS card (like the Connect toggle in Connections tab) |  |
| 181 | ux | Context menu shows Start even when container is running (status not synced with menu) — gate on latest known status |  |
| 182 | ux | VPS card status dot area: merge status dot + stats row into one unified status line; move readiness text there |  |
| 183 | ux | SOCKS port Save: explicit Save button with feedback | Won't Do |
| 184 | reliability | SettingsStore: redundant didSet clamping loop — value = v triggers didSet again causing double UserDefaults write |  |
| 185 | reliability | SSHRunner: `fatalError("unreachable")` in `connect()` — replace with `preconditionFailure` to avoid release crashes |  |
| 186 | reliability | Provisioning.reconfigure: returns nil URI silently if server didn't emit OLCRTC_URI — UI shows success but ConnectionRecord not updated; should throw |  |
| 187 | reliability | ConnectionsView: `shareConn = nil; DispatchQueue.main.asyncAfter { qrConn = conn }` — race if view dismissed before delay fires; use onDisappear instead |  |
| 188 | ux | ServersView: `foundContainers` not cleared when scan sheet dismissed — old results flash briefly on next scan |  |
| 189 | observability | KeychainHelper: failure logs missing numeric OSStatus code — hard to debug Keychain errors without the code |  |
| 190 | reliability | TunnelManager keep-alive: guard check happens after `verifyTunnel()` call — one wasted network probe after disconnect; add guard before sleep |  |
| 191 | reliability | OlcrtcURI: invalid payload key-value pairs silently dropped — log warning for malformed values (e.g. `vp8-batch=abc`) |  |
| 192 | build | SSHRunner `_execute()` / `_withConnection()`: missing `@discardableResult` on internal helpers — will produce compiler warnings when warnings enabled |  |
| 193 | observability | Provisioning.start() and probeReadiness() missing LogStore.startSession() — inconsistent with all other Provisioner methods |  |
| 194 | reliability | NetPing: timeout DispatchWorkItem not cancelled after connection succeeds — fires anyway and wastes resources |  |
| 195 | reliability | SubscriptionFetcher: silent empty-string fallback when data can't be decoded as UTF-8 or latin1 — corrupted data treated as valid empty response |  |
| 196 | reliability | ConnectionStore.load: JSON decode failure is silent — corrupted UserDefaults loses all connections with no log or user notification |  |
| 197 | security | OlcrtcConnection.socksPass is Codable — if struct is ever encoded outside ConnectionStore.scrub() path, password leaks to JSON |  |
| 198 | reliability | OlcrtcURI: mixed bracket types in payload (e.g. `transport[bad>@room`) silently misparse — no guard against malformed bracket nesting |  |
| 199 | reliability | AddConnectionView: @State form fields not reset when sheet re-presented in create mode — old values persist from previous session |  |
| 200 | reliability | SettingsView: socksPassLoaded flag not reset on sheet disappear — SOCKS password not reloaded if changed externally |  |
| 201 | reliability | AddServerHostView: Test SSH Task not cancelled on sheet dismiss — updates @State after view gone causing SwiftUI warnings |  |
| 202 | reliability | LogsView: cachedFullText not updated when selected category changes — switching tabs shows stale log from previous category |  |
| 203 | performance | LogStore.timestamp(): DateFormatter created on every log call — cache as static let to avoid 60×/sec allocations during slider drag |  |
| 204 | performance | LogStore.redactSecrets(): two NSRegularExpression compiled on every log call — cache as static let |  |
| 205 | reliability | SpeedTest: result.error always nil even when all measurements fail — can't distinguish "all nil = all failed" from "all nil = not run yet" |  |
| 206 | reliability | InstallOptionsView: SEI params (seiFPS/Batch/Frag/ACK) not reset when transport changes away from seichannel — stale values submitted |  |
| 207 | observability | ServersView: readiness[host.id] not cleared at start of operation — stale dot/label shows briefly between op start and probe result |  |
| 208 | ux | AddServerHostView: "Test SSH" button label hardcoded EN — needs L10n key |  |
| 209 | ux | ServersView: deep uninstall confirmation body hardcoded EN — needs L10n key |  |
| 210 | accessibility | QRCodeView: QR image has no accessibilityLabel — screen readers can't describe it |  |
| 211 | accessibility | FormField: label text not linked to input via accessibilityLabel — screen readers can't associate them |  |
| 212 | accessibility | ConnectionsView speed metrics: Ping/DL/UL VStack not accessible as a unit — screen reader reads raw numbers without context |  |
| 213 | reliability | SSHRunner.shellSafe(): uses `.reduce(into:)` appending unicodeScalars — use `String(s.unicodeScalars.filter{...})` single allocation instead |  |
| 214 | ux | Manage VPS global status banner: replace with per-server inline progress inside host card — global banner makes no sense with multiple servers |  |
| 215 | ux | VPS action buttons: switch to icon-only (no text labels) with tooltip; duplicate all actions in context menu with same icons |  |
| 216 | ux | IP Check: collapse to "✓ 5.42.103.58 (3 sources)" when all agree; expand with ⚠️ only when IPs differ (potential DNS leak) |  |
| 217 | observability | Log levels: add multi-level system (Off/Error/Info/Debug/Verbose); current debug=Info, add Verbose for all Pion noise; filter duplicated-packet/TURN-refresh below Verbose; setting in Settings |  |
| 218 | architecture | SSHRunner: `withConnection` (private) is a trivial wrapper around `_withConnection` — delete wrapper, call `_withConnection` directly or rename | wrapper already gone; fixed stale comments to _withConnection/_execute |
| 219 | l10n | Delete dead `L10n` case `errorPortAllBusy_fmt` | already removed; key absent from codebase |
| 220 | l10n | Remove unused `L10n` keys | already removed; none of the listed keys remain |
| 221 | migration | srv.sh: complete rewrite for YAML-only binary (olcrtc no longer accepts CLI flags — server is broken) | srv.sh rewritten for YAML (server.yaml + ./cmd/olcrtc build) |
| 222 | migration | SSHRunner.reconfigureScript: rewrite to edit YAML fields instead of sed-on-CLI-args (completely broken after 221) |  |
| 223 | build | Mobile.xcframework rebuild: add SetLivenessOptions + SetSocksListenHost; remove dead SetLink |  |
| 224 | parity | Jazz carrier: remove from CarrierTransportMatrix (SaluteJazz deleted from upstream binary — server rejects it) | removed from CarrierTransportMatrix + carriers list |
| 225 | parity | Jitsi carrier: update CarrierTransportMatrix cells with real e2e data + defaultTransport() |  |
| 226 | migration | srv.sh: add Jitsi env-var support (OLCRTC_JITSI_URL, URL-format room IDs, Jitsi as new default) |  |
| 227 | build | Go-build path in updateScript wrong after #221 | `updateScript` now builds `-o olcrtc ./cmd/olcrtc` (was `/usr/local/bin/olcrtc .`), matching srv.sh + the `/app` entrypoint so restart picks up the rebuild |
| 228 | migration | parity_check.py: rebase onto new upstream srv.sh (YAML-based; virtually all base lines changed) |  |
| 229 | parity | OlcrtcURI.encode(): stop emitting %clientID (server YAML has no client_id filter; format removed from upstream URI) |  |
| 230 | parity | TunnelManager: call SetLivenessOptions() on start | MobileSetLivenessOptions(30s/10s/3) in runMobile, before start; complements app keep-alive |
| 231 | parity | CarrierTransportMatrix: update cells (jitsi now real data; jazz removed; vp8 multi-client fix; SEI defaults changed) |  |
| 232 | parity | Align golang image tag across all sites | pinned srv.sh + readiness + deep-uninstall to `golang:1.26-alpine3.22` |
| 233 | docs | Remove superseded UPSTREAM_MIGRATION_PLAN.md (migration complete via #221–#229; doc deleted, TODO pointers updated) | doc deleted as superseded; TODO pointers updated |
| 234 | features | Expose MobilePing() / MobileCheck() in TunnelManager for richer per-connection tunnel health checks | TunnelManager.ping() via MobilePing on a free ephemeral port + per-row UI chip |
| 236 | l10n | Hardcoded EN UI strings bypass L10n — RU users saw English | localized ~12 strings via new L10n keys (EN+RU) |
| 237 | l10n | Localize hardcoded picker/section labels in option views | Carrier/Transport/Room ID labels localized |
| 238 | docs | Russian code comments → English | translated SettingsStore `LogLevel` + Provisioning comments |
| 239 | docs | L10n.swift case annotations Russian → English | 95 annotations converted to the English source string (scripted from `L10nTable.english`) |
| 240 | docs | README stale | rewrote project-structure tree to the real layout, dropped dead refs (build-number.txt/Jazz), added the 3-layer note + AGENTS/CONTRIBUTING links |
| 241 | ux | Brand-name casing inconsistent — pick one | brand = `OlcRTC` for display (added `CFBundleDisplayName`); lowercase `olcrtc` for technical IDs + `Olcrtc` Swift type prefix; renamed `OlcRTCiOSApp`→`OlcrtcApp`; convention documented in CONTRIBUTING |
| 242 | features | `MobileCheck()` "Ready in Xms" metric per connection | `TunnelManager.checkReady()` via `MobileCheck` on a free ephemeral port; stopwatch "Ready Xms" overlay on the ping chip (long-press + context menu) |
| 243 | architecture | Protocol-agnostic `TunnelEngine` seam for a 2nd protocol | extracted `TunnelEngine` protocol + `OlcrtcEngine` (owns all `Mobile*`); `TunnelManager` is now protocol-agnostic (dropped `import Mobile`), dispatches via `ConnectionDetails.engine`; unblocks the #063 mock-engine testing seam |
| 244 | build | Replace placeholder bundle IDs before TestFlight/App Store | set to com.alexk.olcrtc-ios{,-tests} |
| 245 | docs | `OlcrtcConnection.swift` references missing `docs/uri.md` | created `docs/uri.md` (olcrtc:// URI format reference) |
| 246 | build | GitHub issue templates (bug report + feature request) | added `.github/ISSUE_TEMPLATE/` — bug_report + feature_request + config.yml (English, iOS-flavoured; core/protocol bugs routed upstream) |
| 248 | build | App icon — `AppIcon.appiconset` ships with no images | added user's pixel-hand + `olcrtc-ios` wordmark → `AppIcon.appiconset/AppIcon.png` (1024 universal); reproducible via `scripts/icon/make-icon.py` |
| 249 | build | Privacy manifest (`PrivacyInfo.xcprivacy`) — required for App Store | added `App/PrivacyInfo.xcprivacy`: no tracking, empty tracking-domains/collected-data; required-reason audit found only User Defaults → `CA92.1`; auto-bundled to Resources via the `App` glob, `plutil`-lint clean |
| 250 | build | CI: build + test (+ `srv.sh` parity) on a macOS runner | `.github/workflows/ci.yml` on push/PR/dispatch (macos-15): parity check → gomobile-build `Mobile.xcframework` (cached by upstream commit) → `xcodegen` → `xcodebuild test` on iPhone 16 sim |
| 252 | docs | README publication pass — public framing, screenshots, disclaimer | restructured for a serious-project layout (badges, Features, Screenshots placeholder, Contributing, neutral Disclaimer); corrected stale architecture docs (connect→start→runEngine per #243, ATS/`NWConnection` attribution, test coverage); set `haritos90/olcrtc-ios` links; dropped censorship/RU framing |
| 253 | build | `Mobile.xcframework` distribution for public cloners | GitHub Releases channel (vs git-lfs): `release.yml` builds/zips/attaches `Mobile.xcframework.zip` per `v*` tag; `scripts/fetch-framework.sh` one-line-downloads it via `gh`, `scripts/build-framework.sh` is the shared from-source fallback (also used by `ci.yml`); README rewritten download-first |
| 255 | build | SwiftLint config + CI lint step | lenient `.swiftlint.yml` (excludes the vendored core + generated framework; disables the house-style-divergent rules — identifier_name/type_name/todo/line_length + length/complexity/param-count/`large_tuple`; `force_cast`/`force_try`→warning) + a parallel `lint` job in `ci.yml` (source-only, installs swiftlint if the runner image lacks it, non-strict so warnings annotate but don't fail). Lenient start; tighten to `--strict` over time |
| 256 | reliability | Default Jitsi server: all users point at one public instance (`meet1.arbitr.ru`) | exposed the Jitsi base URL as an editable, pre-filled field in the install sheet (shown for the jitsi carrier) + a "shared public instance — point at your own" footer (en+ru), so users aren't silently funnelled onto one third party; `InstallOptions.jitsiBaseURL` (defaults to `AppConstants.defaultJitsiBaseURL`, never sent empty) → `SSHRunner` sends the user's value as `OLCRTC_JITSI_URL`; `srv.sh` untouched (still reads the var; its `:-` default stays the server-side fallback), parity tests green |
| 258 | ux | UI redesign — adopt unified design system across all screens | builds 212–216: `App/UI/Theme.swift` + `DesignSystem.swift` (8 components + OlcStatusDot/FlowLayout/OlcEmptyState, dark previews); ServersView (single-source `HostDisplay` model — kills the VPS status-jump), ConnectionsView, all sheets, LogsView, SettingsView restyled; app forced dark via `UIUserInterfaceStyle=Dark`. One button system / one overflow menu / one status vocabulary / one large-title header. Follow-ups split out: #259 (state-machine tests), #261–267 (polish/architecture) |
| 259 | tests | Tests for the VPS `HostDisplay` state machine (#258) | extracted the #258 transition rules into a pure reducer on `HostBase`/`HostDisplay` (`seed`/`start`/`advanced`/`terminalBase`/`failed`/`retryBase`) that `ServersView` now drives; `Tests/HostDisplayTests.swift` (16 tests → 182 total) covers readiness→base mapping, op `target`/`phases`, no-optimistic-base-while-running, monotonic+capped phases, probe-authoritative terminal assignment, and failure→Retry `previousBase` restore. Reducer still lives in ServersView.swift → moving it to Models is #263 |
| 260 | reliability | Integrate upstream olcrtc (587c13e → e2c4b1e) | bumped submodule pin (jitsi reconnect #82/#88/#89, vp8channel byte-rate pacer, videochannel ffmpeg→`gocodec`; nested `gr` submodule removed — now a go.mod dep `gr v0.1.5`); rebuilt `Mobile.xcframework` via `build-framework.sh` (Mobile* API unchanged → engine compiles), `parity_check.py` clean (srv.sh unchanged), app builds + 182 tests green. No doc churn — our docs never named the `gr` submodule and `--recursive` stays valid. Hijacked doc commit only touches upstream `readme.md`/`westand.svg`, not propagated. PENDING USER: on-device jitsi+vp8 smoke-test; commit+push the pin bump; cut a new `v*` tag so `release.yml` republishes the framework |
| 261 | l10n | Promote ServersView hardcoded status/phase strings to L10n | localized the design-system VPS status text — `HostBase.title`/`.subtitle`, `HostOp.verb`, the «Connecting…» initial note, «Check server», «Working…» and the «%@ failed» title — via 24 new `vps*` keys (en+ru). Replaced the never-displayed `HostOp.phases` arrays with `stepCount` (running subtitle = the live localized provisioner message; only the bar denominator is needed); updated the reducer + HostDisplayTests. Metric labels (Ping/Disk/RAM/Uptime) left as-is (not status/phase) |
| 262 | architecture | Shared sheet scaffolding + dedupe card-row helper | extracted `.olcSheet(confirm:icon:disabled:onConfirm:)` (an `OlcSheetChrome` ViewModifier — ✕ close + full-width primary footer) into DesignSystem; adopted by AddConnection/AddServerHost/Install/Reconfigure (AddServerHost keeps its keyboard toolbar). Promoted `olcCardRow()` into DesignSystem; removed the private copy in ConnectionsView and the 3 inlined modifier-stacks in ServersView |
| 263 | architecture | Move `HostBase`/`HostOp`/`HostDisplay` out of ServersView into App/Models | moved the 3 enums + the pure reducer into `App/Models/HostDisplay.swift` (behavior-preserving; ServersView 965→796 lines; 182 tests green) |
| 264 | ux | Restore the IP "last checked" timestamp in the Diagnostics card | re-added `ipCheckTime` (set after `checkAll`), shown as a clock + `HH:MM` caption under the IP result; no L10n needed (icon + localized time) |
| 265 | ux | AddConnectionView — manual URI entry | added a 1–3-line monospaced `TextField` (literal `olcrtc://…` placeholder) under the Scan/Paste buttons that auto-parses into the fields on change; restores typing / paste-and-edit that the redesign had dropped |
| 266 | l10n | Remove L10n keys orphaned by the redesign | removed 19 unused keys (uriPlaceholder, parseURIAction, typeField, ipLastCheck_fmt, speedTestTitle, statusUnreachable, connectionLine_fmt, alertPasswordMissingDetail, status{Running,Done,Error}Title, actionDisconnect/Ping/Status, sectionInfo, installResultSuccessNotice, rebootingInProgress, scanContainerRow_fmt, uninstallConnectionAlsoRemoved_fmt) from the enum + both dicts; verified zero code refs; L10nTests per-locale count stays balanced |
| 267 | ux | Runtime design-direction toggle (Refined/Console) in Settings | `SettingsStore.designConsole` (persisted @Published) drives the 6 direction-dependent Theme tokens (now `static var`: bg/card/segActive + control/card radii + card border); Settings «Theme» picker (Refined/Console); app reskins live via MainTabView's SettingsStore observation. Added L10n themeLabel/themeRefined/themeConsole |
| 268 | ux | Manage VPS card shows free disk as if used | disk `awk` field `$4` (Available/free) → `$3` (Used) in `SSHRunner.readinessScript` so the card shows `used/total`, consistent with the RAM line right below it; pure Swift, no `srv.sh`/parity impact |
| 269 | reliability | Reconnect on network-path change (`NWPathMonitor`) — Wi-Fi↔cellular handoff | always-on `NWPathMonitor` on `TunnelManager` (lazy-started first connect, never torn down); new `.waitingForNetwork` holding state — hero shows «Waiting for network…», global toggle stays on+enabled (flip off to give up); pure `nonisolated static pathDecision` maps loss→hold, regain→`reconnect(.restored)`, Wi-Fi↔cellular swap→`reconnect(.interfaceChanged)`, debounced 1.5 s and coalesced; `.disconnected`/`.failed` (down server ≠ path problem) + first-update baseline ignored; `bgKeeper` kept running while waiting so a backgrounded app self-recovers; reconnect funnels through `scheduleNetworkReconnect`→`start()` (the seam #270's backoff sink will absorb, #271 the room-settle, #272 the generation guard); `Tests/NetworkPathDecisionTests.swift` (14-case matrix) + `.waitingForNetwork` round-trip |
| 270 | reliability | Bounded exponential-backoff auto-reconnect (replace the one-shot retry) | replaced one-shot `scheduleAutoRetry` with `requestReconnect` — a single recovery sink both keep-alive loss and #269 (network regain/interface swap) feed; capped exponential backoff `backoffDelaySeconds` (2→4→8→16→32→60 s, base·2ⁿ clamped) over `maxReconnectAttempts`=6, then terminal `.failed` («tap Retry»), preserving the deliberate battery cap; idempotent (one loop at a time), a verified connect ends the loop so backoff resets, a network loss cancels it (resets on the round-trip), a manual connect/disconnect supersedes it; extracted `preflight` shared by fire-and-forget `start` + awaitable `connectAndAwait`, `runEngine` now returns `Bool` so the loop sees the *verified* outcome; `Tests/ReconnectBackoffTests.swift` (schedule + cap + overflow/negative guards); removed orphaned `autoReconnect_fmt`, added `reconnectAttempt_fmt`/`reconnectGaveUp` (en+ru) |
| 271 | reliability | Settle delay before reconnecting into the same room (ghost MUC presence) | carrier-aware room-settle on the auto-reconnect path: `EngineStartSettings.isReconnect` (true only via #270's `connectAndAwait`, false on user `start`) → `OlcrtcEngine.start` waits `rejoinSettleMs(carrier:)` after its `MobileStop()` before re-joining, so the prior session's MUC `presence-unavailable` clears first (jitsi/telemost 3 s, others 1.5 s — XMPP-MUC propagation lag, per the upstream `server.go` ghost-participant note); logged via `rejoinSettle_fmt` (en+ru); fresh connects skip it; `Tests/RejoinSettleTests.swift` pins the mapping + case-insensitivity |
| 272 | reliability | Epoch/generation guard in TunnelManager (discard superseded connect/retry results) | monotonic `connectEpoch` bumped in `preflight` per attempt + captured into each detached `runEngine`; new `isLiveAttempt(epoch)` (epoch matches **and** `state == .connecting`) replaces the bare `state == .connecting` guard at all four `runEngine` MainActor hops, so a fast disconnect→reconnect can't alias the new attempt's `.connecting` and post a result for the wrong session; `connectEpoch` is `private(set)` (test-observable); +2 tests (epoch advances per launched attempt; invalid connect consumes none) |
