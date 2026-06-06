import Foundation
import Mobile

// MARK: - TunnelEngine (#243)
//
// The iOS multi-protocol seam. A `TunnelEngine` is a pluggable tunnel backend —
// one conformer per protocol: `OlcrtcEngine` today, vless / xray / reality / awg
// later (#114). `TunnelManager` owns everything generic (the connection state
// machine, keep-alive, backoff auto-reconnect, end-to-end SOCKS verification, and
// background-audio keep-alive); the engine owns the protocol's native runtime —
// for olcrtc, the gomobile singleton exposed by `Mobile.xcframework`.
//
// Why the engine takes the protocol-agnostic `ConnectionDetails` and destructures
// its own case (rather than an `associatedtype Params`): an associated type would
// be more precise but makes `any TunnelEngine` impossible. `TunnelManager` selects
// the engine via `details.engine` using the *same* case it then hands back, so the
// `guard case` always succeeds — the enum is the pragmatic type erasure.
//
// `start` / `ping` / `checkReady` wrap blocking native calls; they are invoked from
// detached tasks, so the protocol is `Sendable` and methods are non-isolated.

/// Thrown by `TunnelEngine.start` with a user-facing reason. The engine logs the
/// protocol-specific failure detail itself; `TunnelManager` only maps this to
/// `state = .failed(message)`.
struct TunnelEngineError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Runtime values captured on MainActor (from `SettingsStore`) and handed to the
/// engine's off-MainActor `start`. Carries SettingsStore defaults; the engine
/// applies any per-connection overrides (e.g. `params.vp8FPS ?? vp8FPS`).
struct EngineStartSettings: Sendable {
    let dns:                   String
    let debugEnabled:          Bool
    let timeoutMs:             Int
    let vp8FPS:                Int
    let vp8Batch:              Int
    let localSocksAuthEnabled: Bool
    let localSocksUser:        String
    let localSocksPass:        String
    /// True only on an auto-reconnect attempt (#270 recovery loop), false on a
    /// user-initiated connect. Drives the engine's room-settle delay (#271): on a
    /// reconnect into the same room we wait after Stop before Start so the prior
    /// session's MUC presence clears first.
    let isReconnect:           Bool
}

/// Runtime values for the isolated per-connection probes (`ping` / `checkReady`),
/// captured on MainActor. `pingURL` is unused by `checkReady`.
struct EngineProbeSettings: Sendable {
    let timeoutMs: Int
    let pingURL:   String
    let vp8FPS:    Int
    let vp8Batch:  Int
}

protocol TunnelEngine: Sendable {
    /// Configure the runtime and start the tunnel on `port`, blocking until it is
    /// ready (SOCKS listener bound + transport connected). Throws
    /// `TunnelEngineError` on start/timeout failure (having logged the detail and
    /// torn down any partially-started runtime). Does **not** verify end-to-end
    /// data flow — that is `TunnelManager`'s generic `verifyTunnel`.
    func start(_ details: ConnectionDetails, port: Int, settings: EngineStartSettings) async throws

    /// Tear down the running tunnel. Idempotent; safe to call when not running.
    func stop()

    /// HTTP round-trip latency via an isolated, non-singleton client (does not
    /// disturb the running tunnel). Returns ms or a localized failure reason.
    func ping(_ details: ConnectionDetails, settings: EngineProbeSettings) async -> PingOutcome

    /// Time-to-ready (transport startup) via an isolated client. Mirror of `ping`.
    func checkReady(_ details: ConnectionDetails, settings: EngineProbeSettings) async -> PingOutcome

    /// Cheap structural validation of the params; `nil` = valid, else a localized
    /// reason. Runs synchronously on MainActor before a connect attempt.
    func validate(_ details: ConnectionDetails) -> String?
}

extension ConnectionDetails {
    /// The engine that runs this protocol. `TunnelManager` dispatches through here
    /// instead of switching on the case itself — the only place protocol identity
    /// is resolved.
    var engine: any TunnelEngine {
        switch self {
        case .olcrtc: return OlcrtcEngine.shared
        }
    }
}

// Bridges the gomobile-generated Go log-writer protocol into a Swift closure.
private final class LogCapture: NSObject, MobileLogWriterProtocol {
    var onLog: ((String) -> Void)?
    func writeLog(_ msg: String?) {
        guard let msg = msg?.trimmingCharacters(in: .whitespacesAndNewlines),
              !msg.isEmpty else { return }
        onLog?(msg)
    }
}

// MARK: - OlcrtcEngine
//
// The olcrtc backend. Wraps the gomobile `Mobile*` singleton — the one place in
// the app that talks to `Mobile.xcframework`. A singleton itself, mirroring the
// Go side (package-scoped `cancel` / `done` / `ready`): two parallel Starts
// return errAlreadyRunning, so there is exactly one runtime to own.
//
// `@unchecked Sendable`: the only stored property (`logCapture`) is assigned once
// in `init` and never mutated; the underlying runtime is a process-global the Go
// side guards internally.
final class OlcrtcEngine: TunnelEngine, @unchecked Sendable {
    static let shared = OlcrtcEngine()

    private let logCapture = LogCapture()

    private init() {
        logCapture.onLog = { msg in
            Task { @MainActor in LogStore.shared.log(.connection, msg) }
        }
        MobileSetLogWriter(logCapture)
        MobileSetProviders()
        // SetDebug is re-applied on each start so toggling debug in Settings takes
        // effect for the next session.
    }

    func validate(_ details: ConnectionDetails) -> String? {
        guard case .olcrtc(let params) = details else { return nil }
        // Validation lives on TunnelManager (its unit tests target it directly);
        // structural rules are stateless, so delegating keeps a single source.
        return TunnelManager.validate(params: params)
    }

    func stop() { MobileStop() }

    /// Carrier-aware room-settle (#271): milliseconds to wait after `MobileStop()`
    /// before re-joining the *same* room on an auto-reconnect, so the previous
    /// session's MUC presence clears first. Jitsi/Telemost (XMPP-MUC) propagate
    /// `presence-unavailable` with a lag and reject a too-fast re-join into the
    /// "ghost"; others settle less. Fresh connects skip it. `internal` so
    /// `RejoinSettleTests` can pin the mapping.
    static func rejoinSettleMs(carrier: String) -> Int {
        switch carrier.lowercased() {
        case "jitsi", "telemost": return 3000   // XMPP-MUC presence cleanup lag
        default:                  return 1500   // wbstream + anything new
        }
    }

    func start(_ details: ConnectionDetails, port: Int, settings s: EngineStartSettings) async throws {
        guard case .olcrtc(let params) = details else {
            throw TunnelEngineError("internal: OlcrtcEngine received non-olcrtc details")
        }
        await MainActor.run {
            LogStore.shared.log(.connection,
                L10n.connectingOlcrtc_fmt.formatted(params.carrier, params.transport, params.clientID))
        }

        // MobileSet* thread-safety:
        //   These run from a detached Task (off-MainActor) against the package-level
        //   Go singleton. Setter thread-safety isn't documented in the gomobile
        //   header, so it was verified in `olcrtc-upstream/mobile/mobile.go`:
        //     - SetDNS / SetVP8Options — `mu.Lock()` / `defer mu.Unlock()` around
        //       the shared `defaults` struct.
        //     - SetDebug — `logger.SetVerbose(...)` writes `atomic.Bool`;
        //       `log.SetFlags(...)` is internally synchronised by stdlib `log`.
        //   No iOS-side serialisation is needed. If upstream drops these locks,
        //   wrap each call on a dedicated `.sync` DispatchQueue.
        MobileStop()
        // #271: on an auto-reconnect into the same room, the session we just
        // stopped sends MUC presence-unavailable, but Jitsi/Telemost clear the old
        // participant with a lag — re-joining too fast collides with that "ghost"
        // and the join fails (see the ghost-participant note in upstream
        // server.go). Wait a short, carrier-aware settle after Stop before Start;
        // a fresh connect (`isReconnect == false`) has no prior presence, so skips it.
        if s.isReconnect {
            let settleMs = Self.rejoinSettleMs(carrier: params.carrier)
            if settleMs > 0 {
                await MainActor.run {
                    LogStore.shared.log(.connection,
                        L10n.rejoinSettle_fmt.formatted(Double(settleMs) / 1000.0))
                }
                try? await Task.sleep(for: .milliseconds(settleMs))
            }
        }
        MobileSetDebug(s.debugEnabled)
        MobileSetDNS(s.dns)
        let vp8FPS   = params.vp8FPS       ?? s.vp8FPS
        let vp8Batch = params.vp8BatchSize ?? s.vp8Batch
        if params.transport == "vp8channel" {
            MobileSetVP8Options(vp8FPS, vp8Batch)
        }
        // Native control-stream liveness (#230): ping the control stream every
        // `interval`, count a miss after `timeout`, tear down after `failures`
        // misses. Gentle values (≈ the app-level keep-alive) so it complements —
        // not pre-empts — verifyTunnel(); the two layers catch different deaths
        // (control-stream vs data-path/TURN).
        MobileSetLivenessOptions(30_000, 10_000, 3)

        let (socksUser, socksPass): (String, String) = s.localSocksAuthEnabled
            ? (s.localSocksUser, s.localSocksPass)
            : (params.socksUser, params.socksPass)

        var startErr: NSError?
        let ok = MobileStartWithTransport(
            params.carrier, params.transport,
            params.roomID, params.clientID, params.key,
            port, socksUser, socksPass, &startErr)
        guard ok else {
            let msg = startErr?.localizedDescription ?? "Start failed"
            await MainActor.run { LogStore.shared.log(.connection, L10n.mobileStartFailed_fmt.formatted(msg)) }
            throw TunnelEngineError(msg)
        }
        await MainActor.run { LogStore.shared.log(.connection, L10n.mobileStartOK.localized()) }

        var waitErr: NSError?
        let ready = MobileWaitReady(s.timeoutMs, &waitErr)
        guard ready else {
            let msg = waitErr?.localizedDescription ?? "Timeout"
            MobileStop()
            // #275: WaitReady failing means the WebRTC transport never reached
            // ready — i.e. no peer rendezvoused in the room ("Link connected" with
            // no "session opened"). Keep the raw Go reason in the log for
            // debugging, but surface a diagnostic that names the likely causes
            // instead of a bare "Timeout".
            let diagnostic = await MainActor.run { () -> String in
                LogStore.shared.log(.connection, L10n.waitReadyFailed_fmt.formatted(msg))
                let d = L10n.connectNoPeer.localized()
                LogStore.shared.log(.connection, d)
                return d
            }
            throw TunnelEngineError(diagnostic)
        }
        await MainActor.run {
            LogStore.shared.log(.connection, L10n.waitReadyOK.localized())
            LogStore.shared.log(.connection, "✓ SOCKS5 proxy ready on port \(port)")
        }
    }

    func ping(_ details: ConnectionDetails, settings s: EngineProbeSettings) async -> PingOutcome {
        guard case .olcrtc(let params) = details else { return .failure(L10n.pingFailed.localized()) }
        guard let port = PortAvailability.freeEphemeralPort() else {
            return .failure(L10n.pingNoFreePort.localized())
        }
        let vp8FPS   = params.vp8FPS       ?? s.vp8FPS
        let vp8Batch = params.vp8BatchSize ?? s.vp8Batch
        return await Task.detached {
            var result: Int64 = -1
            var err: NSError?
            let ok = MobilePing(
                params.carrier, params.transport, params.roomID,
                params.clientID, params.key,
                Int(port), s.timeoutMs, s.pingURL, vp8FPS, vp8Batch,
                &result, &err)
            guard ok, result >= 0 else {
                return .failure(err?.localizedDescription ?? L10n.pingFailed.localized())
            }
            return .success(ms: Int(result))
        }.value
    }

    func checkReady(_ details: ConnectionDetails, settings s: EngineProbeSettings) async -> PingOutcome {
        guard case .olcrtc(let params) = details else { return .failure(L10n.pingFailed.localized()) }
        guard let port = PortAvailability.freeEphemeralPort() else {
            return .failure(L10n.pingNoFreePort.localized())
        }
        let vp8FPS   = params.vp8FPS       ?? s.vp8FPS
        let vp8Batch = params.vp8BatchSize ?? s.vp8Batch
        return await Task.detached {
            var result: Int64 = -1
            var err: NSError?
            let ok = MobileCheck(
                params.carrier, params.transport, params.roomID,
                params.clientID, params.key,
                Int(port), s.timeoutMs, vp8FPS, vp8Batch,
                &result, &err)
            guard ok, result >= 0 else {
                return .failure(err?.localizedDescription ?? L10n.pingFailed.localized())
            }
            return .success(ms: Int(result))
        }.value
    }
}
