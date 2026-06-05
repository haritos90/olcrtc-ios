# Diagnostic message catalog

A registry of coded diagnostic messages for olcrtc-ios, so a user (or maintainer) who
sees a code in the Logs tab can look up what it means and how to act — and so we emit
**consistent, typed** lines instead of ad-hoc text.

**Numbering** is continuous and unique across both tables (no code is reused):

| Block | Side |
|---|---|
| `OLC-1xxx` | **Client** — our Swift app + the on-device olcrtc core |
| `OLC-2xxx` | **Server / core** — the olcrtc Go core (server side, and the same lines on-device) |

**Type:** `I` info · `W` warning · `E` error · `D` debug (default-hidden noise).
**Status:** 🟢 emitted today · 🟡 planned (to be wired by [TODO #279]).
**Source:** `app` = our Swift (`LogStore`) · `core` = the gomobile/Go olcrtc binary (captured via the log writer / `podman logs`).

English only for now (see the L10n convention — every key still gets a Russian entry when wired into the UI).
Seeded from real client + server captures (2026-06, build 221 / telemost + vp8channel). This is a starting
set, not exhaustive — extend it as new conditions are caught.

---

## Client — `OLC-1xxx`

| Code | Type | Message | Trigger / meaning | Src | Status |
|---|---|---|---|---|---|
| OLC-1001 | I | New log session — `olcrtc-ios <ver> build <n>` | App launched / a diagnostic action started a session | app | 🟢 |
| OLC-1002 | I | Connecting — carrier=… transport=… clientID=… | Connect attempt began | app | 🟢 |
| OLC-1003 | I | Native start OK — waiting for ready… | `MobileStart` returned, awaiting `WaitReady` | app | 🟢 |
| OLC-1004 | I | SOCKS5 proxy ready on port N | Local listener bound | app | 🟢 |
| OLC-1005 | I | Tunnel verified via `<url>` | An end-to-end probe returned 200 | app | 🟢 |
| OLC-1006 | W | Tunnel verify failed via `<url>`: `<reason>` | One probe failed (HTTP n / timeout / "bad URL" — see OLC-1024) | app | 🟢 |
| OLC-1007 | I | Tunnel works — traffic is flowing | First successful verify → `.connected` | app | 🟢 |
| OLC-1008 | E | Conferencing server not responding | `WaitReady`/verify timed out — the **carrier** server (not your VPS) didn't answer (reword + RU, [TODO #282]) | app | 🟡 |
| OLC-1009 | E | Tunnel not responding (server unreachable or TURN/403 reject) | verify failed end-to-end after connect | app | 🟢 |
| OLC-1010 | I | Keep-alive OK | Periodic probe succeeded | app | 🟢 |
| OLC-1011 | W | Keep-alive failed (n/3) — retrying next interval | Transient probe miss | app | 🟢 |
| OLC-1012 | E | Keep-alive lost — connection dropped | 3 consecutive misses → `.failed` + recovery | app | 🟢 |
| OLC-1013 | I | Reconnecting — attempt n/m in Ns | Backoff recovery loop ([#270]) | app | 🟢 |
| OLC-1014 | E | Reconnect failed — tap Retry | Recovery budget spent | app | 🟢 |
| OLC-1015 | I | Waiting for network… | Path lost, holding ([#269]) | app | 🟢 |
| OLC-1016 | I | Latency (ping): N ms | Per-connection RTT probe ([#234]) | app | 🟢 |
| OLC-1017 | E | Latency check failed: `<reason>` | e.g. `handshake … got "CONTROL_PING"` — isolated probe desync ([#274]) | app | 🟢 |
| OLC-1018 | I | Time-to-ready: N ms | Per-connection transport-ready probe ([#242]) | app | 🟢 |
| OLC-1019 | I | SOCKS port N free / busy | Pre-connect port check | app | 🟢 |
| OLC-1020 | I | Speed test via `<provider>` — `<direct\|tunnel>`, carrier/transport | Add connection-type + transport to the header (user request) | app | 🟡 |
| OLC-1021 | W | Speed-test ping sample n failed: `<reason>` | e.g. CFNetwork 310 / timeout — narrow tunnel ([#285]) | app | 🟢 |
| OLC-1022 | I | Speed result: ping=… down=… up=… | `ping=—` means latency sampling failed | app | 🟢 |
| OLC-1023 | I | IP check via `<providers>` — `<direct\|tunnel>` | Add connection-type to the header (user request, [#286]) | app | 🟡 |
| OLC-1024 | W | Tunnel verify "bad URL" | Misleading reason — the SOCKS session couldn't be built; fix the message ([#287]) | app | 🟡 |
| OLC-1025 | W | Keep-alive "active −N s ago" (future timestamp) | `noteActivity(forAtLeast:)` sets the marker ahead → negative "ago"; clamp it ([#287]) | app | 🟡 |

## Server / core — `OLC-2xxx`

| Code | Type | Message | Trigger / meaning | Src | Status |
|---|---|---|---|---|---|
| OLC-2001 | I | Connecting — transport=… carrier=… | Core session start | core | 🟢 |
| OLC-2002 | I | Link connected | Control link established | core | 🟢 |
| OLC-2003 | I | Peer session opened (peer joined the room) | The other side rendezvoused | core | 🟢 |
| OLC-2004 | I | Peer session closed (reason=…) | Peer left / torn down | core | 🟢 |
| OLC-2005 | W | Control keep-alive: missed pong (n) | Server-side liveness degrading (mirror of OLC-1011) | core | 🟢 |
| OLC-2006 | E | Peer lost — 3 missed pongs, closing session | `missed_pongs≥3` → session closed | core | 🟢 |
| OLC-2007 | W | STUN reflexive address timeout (`<stun host>`) | srflx gather failed (non-fatal; relay/host still used) | core | 🟢 |
| OLC-2008 | E | SOCKS connect failed — remote not ready (`<read_err>`) | Tunnel couldn't carry the dial (timeout/EOF/closed pipe) — the main **speed-test failure** signal ([#285]) | core | 🟢 |
| OLC-2009 | E | Control stream desync — frame too large (N > 16384) | Control corruption → liveness reconnect; **upstream core bug**, watch on submodule pull | core | 🟢 |
| OLC-2010 | W | Liveness reconnect — tearing down session | Triggered by OLC-2009 / missed pongs | core | 🟢 |
| OLC-2011 | I | SOCKS5 listening on 127.0.0.1:N | Core proxy bound | core | 🟢 |
| OLC-2012 | D | vp8channel: KCP started / peer latched | Transport handshake detail | core | 🟢 |
| OLC-2013 | I | Server shutting down gracefully | Container stop | core | 🟢 |
| OLC-2014 | W | No peer joined within N s (room empty / key mismatch) | Detect "Link connected" with no peer session → explain the connect timeout ([#275]) | core/app | 🟡 |
| OLC-2015 | E | Carrier join / auth failed (`<carrier>`) | Not seen in healthy captures — needs a failing repro to pin the exact line | core | 🟡 |
| OLC-2016 | D | WebRTC/ICE library noise | `Failed to ping without candidate pairs`, IPv6 `sendto: no route/unreachable`, RTP/RTCP `already closed`, `PayloadType … (EOF)` — bundled pion logs; default-hidden | core | 🟢 |

---

## Notes from the seed captures

- **Throughput collapse is the transport, not the link.** VPS raw ≈ 775/318 Mbps; through `vp8channel`
  (fps 60 / batch 64) ≈ 0.77/0.51 Mbps. vp8channel disguises data as VP8 video → low ceiling by design;
  `datachannel` (where the network allows it) is far faster. See [#285].
- **`OLC-2008` is the speed-test smoking gun** — under the test's parallel connections the narrow pipe
  returns "remote not ready (timeout)", which the client surfaces as CFNetwork 310 (`OLC-1021`).
- **`OLC-2009`** (`frame too large: 2065856101 > 16384`) is a control-stream desync in the Go core — track
  upstream; we can only detect + reconnect (OLC-2010) on our side.
- **Mixed RU/EN** appeared for the same concept (`Port 8808 free` vs `Порт 8808 свободен`) — a localisation
  inconsistency folded into [#283] (build 221; verify on current build).

[#234]: ../TODO.md
[#242]: ../TODO.md
[#269]: ../TODO.md
[#270]: ../TODO.md
[#274]: ../TODO.md
[#275]: ../TODO.md
[#279]: ../TODO.md
[#282]: ../TODO.md
[#283]: ../TODO.md
[#285]: ../TODO.md
[#286]: ../TODO.md
[#287]: ../TODO.md
[TODO #279]: ../TODO.md
