import Foundation
import Network
import os   // #372: OSAllocatedUnfairLock guards `lastTunnelActivityDate`
// No `import Mobile`: the gomobile runtime is reached only through the engine
// (OlcrtcEngine) now — TunnelManager is protocol-agnostic (#243). `Network` is
// used for the NWPathMonitor that drives reconnect-on-path-change (#269).

// MARK: - TunnelManager
//
// Drives a tunnel through a pluggable `TunnelEngine` (#243). The protocol's
// native runtime lives in the engine — for olcrtc, `OlcrtcEngine` wraps the
// gomobile singleton from Mobile.xcframework. This type owns only the generic
// orchestration: the connection state machine, keep-alive, backoff auto-reconnect,
// end-to-end SOCKS verification, and background-audio keep-alive.
//
// Lifecycle:
//   disconnected → connecting → connected | failed(reason)
//
// Why a single-flight manager? The olcrtc runtime is itself a package-level
// singleton (mobile.go: package-scoped `cancel`, `done`, `ready`). Two parallel
// Starts return errAlreadyRunning, so mirroring single-flight here avoids
// surprises. `connect()` dispatches by `record.details` to select the engine.
//
// Concurrency: the `state == .disconnected` guard runs synchronously on
// the main actor. Because we set `state = .connecting` before launching
// the background Task, a second tap on Connect lands on `.connecting`
// and bails. The Task is detached on purpose — MobileStart blocks until
// the Go runtime spins up, and we don't want to freeze the main actor.
//
// IMPORTANT: MobileWaitReady returns success as soon as the SOCKS5
// listener is bound AND the WebRTC ICE state is "connected". But "ICE
// connected" doesn't guarantee data actually flows — the TURN relay can
// reject the client IP (we've seen `403 Forbidden IP` on corporate networks)
// while ICE still reports connected via a direct candidate that doesn't
// carry data. That's why verifyTunnel() does an actual end-to-end probe
// before we report `.connected`.
//
// Background: BackgroundRuntimeKeeper plays a silent AVAudio loop while
// the tunnel is connected so iOS doesn't suspend the app. Requires the
// `audio` UIBackgroundModes entitlement in Info.plist.

enum ConnectionState: Equatable, CustomStringConvertible {
    case disconnected
    case connecting
    case connected
    /// Holding state (#269): the network path went away under a live session.
    /// We tear the dead session down but keep the app alive, waiting for the
    /// path to return rather than burning reconnect attempts with no route.
    case waitingForNetwork
    case failed(String)

    var isConnected: Bool  { self == .connected }
    var isConnecting: Bool { self == .connecting }

    var label: String {
        switch self {
        case .disconnected:      return L10n.stateDisconnected.localized()
        case .connecting:        return L10n.stateConnecting.localized()
        case .connected:         return L10n.stateConnected.localized()
        case .waitingForNetwork: return L10n.stateWaitingForNetwork.localized()
        case .failed(let m):     return L10n.stateErrorPrefix_fmt.formatted(m)
        }
    }

    /// Compact, English-only rendering used by `LogStore` for state-transition
    /// lines (engineering observability, not the user-facing `label`). Keeping
    /// `.failed(reason)` on one line lets you see the cause inline.
    var description: String {
        switch self {
        case .disconnected:      return "disconnected"
        case .connecting:        return "connecting"
        case .connected:         return "connected"
        case .waitingForNetwork: return "waitingForNetwork"
        case .failed(let m):     return "failed(\(m))"
        }
    }
}

/// Result of a per-connection latency probe via `TunnelManager.ping` (#234).
enum PingOutcome: Equatable, Sendable {
    case success(ms: Int)
    case failure(String)
}

/// Outcome of evaluating a network-path change (#269). A pure value so the
/// decision in `TunnelManager.pathDecision` is unit-testable without
/// constructing an `NWPath`, which has no public initializer.
enum NetworkPathAction: Equatable, Sendable {
    case none              // baseline-only / nothing actionable
    case waitForNetwork    // path lost under a live session → hold and wait
    case reconnect(NetworkReconnectReason)
}

/// Why a network-driven reconnect (#269) was requested — selects the log line.
enum NetworkReconnectReason: Equatable, Sendable {
    case restored          // path returned after an `unsatisfied` gap
    case interfaceChanged  // primary interface switched (e.g. Wi-Fi → cellular)
}

/// Drives the connection state machine
/// (disconnected → connecting → connected | failed), manages keep-alive probes,
/// backoff auto-reconnect, and background audio keep-alive. See file header for
/// concurrency and ICE-connected-but-no-data caveats.
@MainActor
final class TunnelManager: ObservableObject {
    /// `nonisolated` so SOCKSSession (called from background tasks) can read
    /// the active port without awaiting MainActor. The value is read from
    /// SettingsStore on every access, so changing the port in Settings
    /// takes effect on the next connect / next URLSession build.
    nonisolated static var socksPort: Int { SettingsStore.shared.socksPort }

    // boc #313
    /// The SOCKS port the live attempt actually bound — the snapshot `preflight`
    /// reserved (#308 guarantees the engine binds exactly it or the attempt
    /// fails). Non-nil while connecting/connected, nil once the session ends.
    /// `socksPort` above re-reads SettingsStore on every access, so after a
    /// live port edit in Settings it no longer answers "which port does the
    /// tunnel hold?" — the Settings port check compares against this instead.
    @Published private(set) var boundPort: Int? {
        // #351: mirror every write into the nonisolated `liveBoundPort` so
        // SOCKSSession (off MainActor) can target the port the live session
        // actually bound rather than the live-editable configured one.
        didSet { TunnelManager.liveBoundPort = boundPort }
    }
    // eoc #313

    /// #351: nonisolated mirror of `boundPort`. SOCKSSession builds tunnel-mode
    /// URLSessions from a background task and can't await MainActor, so it reads
    /// this instead of the configured `socksPort` while a session is live —
    /// otherwise a live port edit in Settings would point keep-alive's verify
    /// probe (and other in-app SOCKS traffic) at the wrong port and tear down a
    /// healthy tunnel (#313 follow-up). Kept in lockstep by `boundPort.didSet`.
    /// `nonisolated(unsafe)`: written only on MainActor (via `boundPort`), read
    /// from background tasks; a stale read across the brief connect/disconnect
    /// window is benign (falls back to the configured port in `socksPort`).
    nonisolated(unsafe) private(set) static var liveBoundPort: Int? = nil

    /// #351: the port in-app SOCKS traffic should target *now* — the live
    /// session's bound port while connected, else the configured port. Tunnel
    /// verify, IP check, and speed test all route through here via SOCKSSession.
    nonisolated static var activeSocksPort: Int { liveBoundPort ?? socksPort }

    @Published var state: ConnectionState = .disconnected {
        didSet {
            guard state != oldValue else { return }
            // Engineering-level observability for the state machine itself.
            // Side-effects below are already logged through their own helpers;
            // this line captures the bare transition so "what was the
            // connection doing at HH:MM:SS?" is answerable from LogStore alone.
            LogStore.shared.log(.connection, "→ state: \(oldValue) → \(state)")
            switch state {
            case .connected:
                startKeepAliveIfEnabled()
                if SettingsStore.shared.backgroundAudio {
                    do {
                        try bgKeeper.start()
                    } catch {
                        // The tunnel itself is up — leave state as .connected.
                        // But warn loudly so a user investigating "why did my
                        // app suspend?" finds the cause in the Logs tab.
                        LogStore.shared.log(.connection,
                            L10n.bgKeeperFailed_fmt.formatted(error.localizedDescription))
                    }
                }
            case .connecting, .waitingForNetwork:
                // cancel-then-nil-synchronously: Task.cancel() is cooperative,
                // so dropping the handle immediately prevents any later branch
                // (or a re-entrant didSet on rapid oscillation) from observing a
                // stale-but-still-running `keepAliveTask`. NOT `recoveryTask` —
                // the recovery loop itself drives these `.connecting` attempts, so
                // it must survive its own transitions (it's cancelled only by
                // disconnect()/connect(), or a network loss).
                // `.waitingForNetwork` deliberately leaves `bgKeeper` running so
                // a backgrounded app isn't suspended while it waits for the path
                // to return (#269) — it must stay alive to reconnect on its own.
                keepAliveTask?.cancel(); keepAliveTask = nil
                // #313: a network hold releases the listener (`handlePathUpdate`
                // stops the engine before entering this state), so the bound-port
                // snapshot is stale. `.connecting` must NOT clear it — preflight
                // sets the snapshot just before flipping to `.connecting`.
                if state == .waitingForNetwork { boundPort = nil }
            case .disconnected, .failed:
                keepAliveTask?.cancel(); keepAliveTask = nil
                bgKeeper.stop()
                boundPort = nil  // #313: session over — the engine no longer holds a port
            }
        }
    }

    private var lastRecord: ConnectionRecord?
    private var keepAliveTask: Task<Void, Never>?
    private let bgKeeper = BackgroundRuntimeKeeper()

    // MARK: Recovery (#270) — capped exponential-backoff auto-reconnect
    //
    // Both keep-alive loss and #269's network events feed `requestReconnect`, the
    // single recovery sink. It retries with capped exponential backoff
    // (base·2^attempt, clamped) and gives up after `maxReconnectAttempts`, then
    // waits for the user — the deliberate battery cap the old one-shot protected.
    // A verified connect ends the loop, so the backoff resets for the next drop.
    private var recoveryTask: Task<Void, Never>?
    // `nonisolated` so the pure `backoffDelaySeconds` (also nonisolated, for
    // testing off the MainActor) can read them without a Swift 6 isolation error.
    private nonisolated static let reconnectBaseDelaySeconds: Double = 2
    private nonisolated static let maxReconnectDelaySeconds: Double = 60
    private nonisolated static let maxReconnectAttempts = 6   // 2+4+8+16+32+60 ≈ 122 s, then wait for user

    // MARK: Same-port wait-and-retry (#333)
    //
    // The core's SOCKS listener tears down asynchronously, so right after our own
    // disconnect the configured port can still read busy for a second or two — an
    // immediate reconnect would fail the #308 "port busy" check on our *own* ghost.
    // Mitigation that keeps the #308 contract intact (bind exactly the configured
    // port, typed busy error, NO sliding): if the port is busy *and we disconnected
    // ourselves recently*, poll the SAME port briefly before surfacing the error.
    // The window is gated on a self-disconnect so a genuinely busy port (another
    // app) still fails fast.
    private nonisolated static let selfDisconnectGhostWindow: TimeInterval = 10  // only wait if we let go this recently
    private nonisolated static let portReleasePollInterval: Double = 0.25        // ~250 ms between probes
    private nonisolated static let portReleaseMaxWait: Double = 5                // give up after ~5 s → typed busy error

    /// When we last tore down our own listener (disconnect / keep-alive loss /
    /// recovery teardown). Gates the same-port wait above so we only ever wait on
    /// *our* ghost, never on a port a different app is holding. `nonisolated(unsafe)`:
    /// written on MainActor, read by the nonisolated wait decision; a stale read is
    /// benign (worst case we skip the wait and fail fast as before).
    nonisolated(unsafe) private static var lastSelfDisconnectDate: Date? = nil

    /// #333: should the connect path wait for the configured port to free up rather
    /// than failing immediately? Only when the port is currently busy AND we
    /// released our own listener within `selfDisconnectGhostWindow`. Pure → tested.
    nonisolated static func shouldWaitForOwnPortRelease(portFree: Bool,
                                                        selfDisconnectedAgo: TimeInterval?) -> Bool {
        guard !portFree else { return false }
        guard let ago = selfDisconnectedAgo, ago >= 0 else { return false }
        return ago <= selfDisconnectGhostWindow
    }

    // MARK: Network-path monitoring (#269)
    //
    // The gomobile session is bound to whatever network path it started on, so
    // a Wi-Fi↔cellular handoff (or a drop-then-regain) silently kills it — we'd
    // otherwise only notice ~90 s later when keep-alive gives up. An always-on
    // `NWPathMonitor` (started lazily on the first connect, never torn down —
    // it's cheap) watches for that. The reaction is decided by the pure
    // `pathDecision`; this layer tracks the last-seen path and feeds a regain or
    // interface swap into the shared recovery sink (`requestReconnect`, #270).
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "com.alexk.olcrtc.pathmonitor")
    private var pathMonitorStarted = false
    private var lastPathSatisfied: Bool?                  // nil until the first update (baseline)
    private var lastPrimaryInterface: NWInterface.InterfaceType?

    // boc #372: `lastTunnelActivityDate` is written from several concurrent
    // contexts — `noteActivity`, `SOCKSSession.noteTunnelActivity`, and the
    // keep-alive loop — and read by keep-alive. It was a plain
    // `nonisolated(unsafe) static var Date?`, an unsynchronised shared mutable
    // static (a data race / UB). Back it with an `OSAllocatedUnfairLock` (iOS
    // 16+; app targets 17+), storing the time as a `Double`
    // (timeIntervalSinceReferenceDate) so the guarded value is a trivially
    // copyable scalar. The `Date?` get/set/reset surface below is preserved
    // verbatim, so every existing call site — including the #333 reset-on-
    // disconnect (`= nil`) — keeps working with no change.
    // #372 was: nonisolated(unsafe) static var lastTunnelActivityDate: Date? = nil
    private static let activityClock = OSAllocatedUnfairLock<Double?>(initialState: nil)

    /// Timestamp of the last observed tunnel activity (`nil` = none / reset).
    /// `nonisolated` so SOCKSSession / SpeedTest write it from background tasks
    /// and keep-alive reads it on MainActor — all serialized through the lock.
    nonisolated static var lastTunnelActivityDate: Date? {
        get {
            activityClock.withLock { stored in
                stored.map { Date(timeIntervalSinceReferenceDate: $0) }
            }
        }
        set {
            activityClock.withLock { stored in
                stored = newValue?.timeIntervalSinceReferenceDate
            }
        }
    }
    // eoc #372

    /// Call this whenever a successful request through the tunnel is observed.
    /// Pass `forAtLeast` to suppress keep-alive probes for a known busy period
    /// (e.g. speed test duration) — sets the timestamp ahead by that many seconds.
    nonisolated func noteActivity(forAtLeast seconds: TimeInterval = 0) {
        TunnelManager.lastTunnelActivityDate = Date().addingTimeInterval(seconds)
    }

    /// Engine for the current / last connection, selected by `connect(record:)`.
    /// `disconnect()` and the keep-alive failure path stop it. Nil until the first
    /// connect — so a `.connected` state written directly (e.g. in a unit test)
    /// has no engine to stop, which is harmless.
    private var activeEngine: (any TunnelEngine)?

    /// Monotonic connect-attempt counter (#272). `preflight` bumps it at the start
    /// of every attempt; each detached `runEngine` captures the value and only
    /// posts a result while it is still current. Without it, a fast
    /// disconnect→reconnect can alias `state == .connecting` and let a stale
    /// `runEngine` (resuming after `verifyTunnel`) post `.connected` for the wrong
    /// session. `private(set)` so a test can observe that attempts advance it.
    private(set) var connectEpoch = 0

    // No init: engine runtimes initialise lazily on first use via
    // `ConnectionDetails.engine`, so there's nothing protocol-specific to wire
    // up at construction anymore (#243).

    /// Starts a tunnel for the given record. Dispatches to a protocol-specific
    /// path based on `record.details`. Today only .olcrtc is supported; when
    /// other protocols come online they get their own `start...` method.
    ///
    /// Accepts both `.disconnected` and `.failed` states so the user can
    /// hit "Retry" right on the error banner without first flipping
    /// the global toggle off.
    func connect(record: ConnectionRecord) {
        switch state {
        case .disconnected, .failed: break
        // `.waitingForNetwork` is an active session the path monitor will
        // reconnect on its own once connectivity returns — a manual connect now
        // (no route) would only fail, so treat it like .connecting/.connected.
        case .connecting, .connected, .waitingForNetwork: return
        }
        // A manual connect supersedes any in-flight auto-recovery loop (#270).
        recoveryTask?.cancel(); recoveryTask = nil
        lastRecord = record
        start(record: record)
    }

    func disconnect() {
        LogStore.shared.log(.connection, L10n.disconnectingArrow.localized())
        // Cancel every background task before mutating state so none can observe
        // an intermediate state and schedule a spurious auto-retry / reconnect.
        // The path monitor itself keeps running, but with `lastRecord == nil`
        // its handler is a no-op (see `pathDecision`), so the next connect starts
        // from a clean baseline.
        recoveryTask?.cancel();  recoveryTask = nil
        keepAliveTask?.cancel(); keepAliveTask = nil
        bgKeeper.stop()
        activeEngine?.stop()
        lastRecord = nil
        // #333: stopping our own listener opens the async-teardown window during
        // which the port reads busy on our ghost. Record it so the *next* connect
        // can wait-and-retry the same port (gated on this being recent).
        TunnelManager.lastSelfDisconnectDate = Date()
        // #333 fold-in: a future activity reservation (e.g. noteActivity(forAtLeast:)
        // from a speed test) parks `lastTunnelActivityDate` ahead; if it survived
        // teardown it would suppress keep-alive on the NEXT session for one interval.
        // Clear it so each session starts with a clean keep-alive baseline.
        TunnelManager.lastTunnelActivityDate = nil
        state = .disconnected
    }

    // MARK: Keep-alive + auto-reconnect
    //
    // While the tunnel is .connected and the user has set
    // `keepAliveSeconds > 0`, fire `verifyTunnel()` periodically and
    // downgrade the state if it fails. iOS suspends the whole app when
    // backgrounded, so this Task naturally pauses then — no special
    // background handling needed.
    //
    // On sustained failure (3 consecutive misses ≈ 90 s) the keep-alive loop
    // hands off to the shared recovery sink (`requestReconnect`, #270) rather
    // than just dropping — see the Recovery section for the backoff policy.

    private func startKeepAliveIfEnabled() {
        keepAliveTask?.cancel(); keepAliveTask = nil
        let interval = SettingsStore.shared.keepAliveSeconds
        guard interval > 0 else { return }

        keepAliveTask = Task { @MainActor [weak self] in
            var failCount = 0  // consecutive failures; resets on any success or recent activity
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                guard self.state.isConnected else { return }

                // If data flowed through the tunnel recently (e.g. speed test, IP check),
                // the tunnel is clearly alive — skip the HTTP probe this round.
                // "Recently" = within the last keep-alive interval, same logic as WireGuard's
                // "if we received a packet, no need to send a handshake" heuristic.
                if let last = TunnelManager.lastTunnelActivityDate,
                   Date().timeIntervalSince(last) < Double(interval) {
                    failCount = 0
                    // #287: `noteActivity(forAtLeast:)` parks the marker in the
                    // *future* to reserve a known-busy window (e.g. a speed test),
                    // which made the "ago" math go negative ("active −N s ago").
                    let age = Date().timeIntervalSince(last)
                    LogStore.shared.log(.connection, Self.keepAliveSkipNote(ageSeconds: age))
                    continue
                }

                let ok = await Self.verifyTunnel()
                guard !Task.isCancelled, self.state.isConnected else { return }

                if ok {
                    failCount = 0
                    TunnelManager.lastTunnelActivityDate = Date()
                    LogStore.shared.log(.connection, L10n.keepAliveOK.localized(), code: .keepAliveOK)  // OLC-1010
                } else {
                    failCount += 1
                    if failCount < 3 {
                        // Failures may be transient — heavy traffic, brief blip.
                        // Warn but keep the connection alive; next interval decides.
                        // 3 consecutive failures = 90s of sustained failure before disconnect.
                        LogStore.shared.log(.connection,
                            "⚠ Keep-alive failed (\(failCount)/3) — retrying next interval",
                            code: .keepAliveRetry)  // OLC-1011
                    } else {
                        LogStore.shared.log(.connection, L10n.keepAliveLost.localized(), code: .keepAliveLost)  // OLC-1012
                        self.activeEngine?.stop()
                        self.state = .failed(L10n.serverConnectionLost.localized())
                        self.requestReconnect(reason: self.lastRecord?.displayName ?? "")
                        return
                    }
                }
            }
        }
    }

    /// Single recovery sink (#270). Both keep-alive loss and #269's network
    /// events call this. Runs capped exponential-backoff reconnects until one
    /// connects *and* verifies (loop ends → backoff resets), or the attempt
    /// budget is spent (→ `.failed`, wait for the user). Idempotent: while a loop
    /// is live, further requests are no-ops so triggers can't stack.
    private func requestReconnect(reason: String) {
        guard lastRecord != nil, recoveryTask == nil else { return }
        LogStore.shared.log(.connection, L10n.reconnecting_fmt.formatted(reason), code: .reconnecting)  // OLC-1013
        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.recoveryTask = nil }
            var attempt = 0
            while !Task.isCancelled {
                let delay = Self.backoffDelaySeconds(attempt: attempt)
                LogStore.shared.log(.connection,
                    L10n.reconnectAttempt_fmt.formatted(attempt + 1, Self.maxReconnectAttempts, Int(delay)))
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let record = self.lastRecord else { return }
                // Tear down whatever is bound to the old/dead path, then attempt a
                // fresh connect and await its verified outcome.
                self.activeEngine?.stop()
                let ok = await self.connectAndAwait(record)
                if Task.isCancelled || ok { return }   // superseded, or connected → done
                attempt += 1
                if attempt >= Self.maxReconnectAttempts {
                    LogStore.shared.log(.connection, L10n.reconnectGaveUp.localized(), code: .reconnectFailed)  // OLC-1014
                    self.state = .failed(L10n.reconnectGaveUp.localized())
                    return
                }
            }
        }
    }

    /// Capped exponential backoff before reconnect attempt `n` (#270):
    /// base·2^n clamped to `maxReconnectDelaySeconds`. n=0 → base. Pure → tested.
    nonisolated static func backoffDelaySeconds(attempt: Int) -> Double {
        let shift = min(max(attempt, 0), 20)            // clamp so 1<<shift can't overflow
        let delay = reconnectBaseDelaySeconds * Double(1 << shift)
        return min(delay, maxReconnectDelaySeconds)
    }

    // MARK: Network-path reconnect (#269)
    //
    // While we hold an active session, react to the network path changing:
    //   • path lost     → cancel recovery, hold `.waitingForNetwork` (don't burn
    //                     retries with no route), wait for the path to return;
    //   • path regained → reconnect;
    //   • interface swap while still satisfied (Wi-Fi↔cellular) → reconnect onto
    //                     the new path.
    // Regain/swap feed the shared backoff sink (`requestReconnect`, #270), so a
    // network round-trip resets the backoff. Follow-ups: #271 adds a room-settle
    // delay, #272 a generation guard for the in-flight-reconnect race.

    private func startPathMonitorIfNeeded() {
        guard !pathMonitorStarted else { return }
        pathMonitorStarted = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            // Snapshot the two facts we need off the monitor's queue, then hop
            // to MainActor for every state decision.
            let satisfied = path.status == .satisfied
            let primary   = Self.primaryInterface(of: path)
            Task { @MainActor in self?.handlePathUpdate(satisfied: satisfied, primary: primary) }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    /// Translates a path update into a side-effect via the pure `pathDecision`,
    /// then refreshes the last-seen baseline.
    private func handlePathUpdate(satisfied: Bool, primary: NWInterface.InterfaceType?) {
        let action = Self.pathDecision(
            satisfied: satisfied, primary: primary,
            wasSatisfied: lastPathSatisfied, lastPrimary: lastPrimaryInterface,
            state: state, hasActiveRecord: lastRecord != nil)
        // Update the baseline regardless of what we do with this transition.
        lastPathSatisfied    = satisfied
        lastPrimaryInterface = primary

        switch action {
        case .none:
            break
        case .waitForNetwork:
            // Stop spending reconnect attempts with no route; cancel any live
            // recovery loop — a fresh one starts (below) when the path returns.
            recoveryTask?.cancel(); recoveryTask = nil
            LogStore.shared.log(.connection, L10n.netPathLost.localized(), code: .waitingNetwork)  // OLC-1015
            activeEngine?.stop()
            state = .waitingForNetwork
        case .reconnect(let reason):
            let text = reason == .restored
                ? L10n.netPathRestored.localized()
                : L10n.netPathChanged.localized()
            requestReconnect(reason: text)
        }
    }

    /// The primary interface a path routes over, by priority; nil for an
    /// unsatisfied path. `nonisolated` because it runs on the monitor queue.
    nonisolated private static func primaryInterface(of path: NWPath) -> NWInterface.InterfaceType? {
        for type in [NWInterface.InterfaceType.wifi, .cellular, .wiredEthernet, .other]
            where path.usesInterfaceType(type) {
            return type
        }
        return nil
    }

    /// Pure decision for a network-path update (#269) — factored out of
    /// `handlePathUpdate` so it's unit-testable without an `NWPath`.
    ///
    /// - `wasSatisfied == nil` means no baseline yet (first update) → `.none`.
    /// - Only an active session reacts; `.disconnected` and `.failed` (a down
    ///   server isn't a path problem) are ignored.
    /// - `.connecting` reacts only to a *loss* (→ wait); a mid-connect interface
    ///   wobble is left for the in-flight attempt to resolve, avoiding thrash.
    nonisolated static func pathDecision(satisfied: Bool,
                                         primary: NWInterface.InterfaceType?,
                                         wasSatisfied: Bool?,
                                         lastPrimary: NWInterface.InterfaceType?,
                                         state: ConnectionState,
                                         hasActiveRecord: Bool) -> NetworkPathAction {
        guard wasSatisfied != nil, hasActiveRecord else { return .none }
        switch state {
        case .disconnected, .failed: return .none
        case .connected, .connecting, .waitingForNetwork: break
        }
        guard satisfied else {
            // Already holding → nothing new to do.
            return state == .waitingForNetwork ? .none : .waitForNetwork
        }
        if wasSatisfied == false || state == .waitingForNetwork {
            return .reconnect(.restored)
        }
        if state == .connected, primary != lastPrimary {
            return .reconnect(.interfaceChanged)
        }
        return .none
    }

    // MARK: Generic engine start (#243)

    /// Synchronous preflight on MainActor: select the engine, run structural
    /// validation, reserve a free SOCKS port + snapshot settings, and flip to
    /// `.connecting`. Returns the launch params, or nil if it already set
    /// `.failed` (validation) / couldn't reserve a port. Shared by the
    /// fire-and-forget `start` (`isReconnect: false`) and the awaitable
    /// `connectAndAwait` (`isReconnect: true`, #270) — the flag rides into
    /// `EngineStartSettings` to drive the engine's room-settle delay (#271).
    private func preflight(_ record: ConnectionRecord, isReconnect: Bool)
        -> (engine: any TunnelEngine, details: ConnectionDetails, port: Int, settings: EngineStartSettings, epoch: Int)? {
        startPathMonitorIfNeeded()
        let engine = record.details.engine
        activeEngine = engine
        LogStore.shared.startSession(.connection)
        if let problem = engine.validate(record.details) {
            LogStore.shared.log(.connection, "✗ \(problem)")
            state = .failed(problem)
            return nil
        }
        guard let (port, settings) = reservePortAndSettings(isReconnect: isReconnect) else { return nil }
        // #313: record the port this attempt binds (#308: exactly the reserved
        // snapshot, never slid) — set before `.connecting` so the didSet for
        // that state can't observe a stale value.
        boundPort = port
        // New attempt → new epoch (bumped before `.connecting` so the value
        // `runEngine` captures is the one live for this attempt, #272).
        connectEpoch &+= 1
        state = .connecting
        return (engine, record.details, port, settings, connectEpoch)
    }

    /// True iff `epoch` is still the current attempt *and* we're mid-connect — the
    /// guard every `runEngine` MainActor hop uses before mutating state (#272).
    /// The `state == .connecting` half catches user-disconnect / network-loss
    /// supersession; the epoch half catches a disconnect→reconnect that returns
    /// to `.connecting` under a *different* attempt.
    private func isLiveAttempt(_ epoch: Int) -> Bool {
        connectEpoch == epoch && state == .connecting
    }

    /// User-initiated connect: preflight, then hand the blocking native work to a
    /// detached task (fire-and-forget — a failure lands in `.failed` and waits
    /// for the user, it does NOT enter the recovery loop, so a bad manual connect
    /// can't spin a backoff).
    private func start(record: ConnectionRecord) {
        // #333: in the common case the configured port is free, so preflight runs
        // synchronously here and flips to `.connecting` in the same turn (the
        // responsive, test-observable fast path). Only when the port is busy on
        // *our own* recent ghost do we detour through an async same-port wait,
        // then preflight once it frees up.
        if shouldWaitForOwnPortReleaseNow() {
            state = .connecting   // optimistic: hold the toggle ON while we wait
            Task { [weak self] in
                guard let self else { return }
                await self.waitForOwnPortRelease()
                // The wait may have been superseded (user flipped off → .disconnected)
                // — only proceed if we're still the pending attempt.
                guard self.state == .connecting else { return }
                guard let (engine, details, port, settings, epoch) = self.preflight(record, isReconnect: false) else { return }
                Task.detached { [weak self] in
                    await Self.runEngine(engine: engine, details: details,
                                         port: port, settings: settings, epoch: epoch, manager: self)
                }
            }
            return
        }
        guard let (engine, details, port, settings, epoch) = preflight(record, isReconnect: false) else { return }
        Task.detached { [weak self] in
            await Self.runEngine(engine: engine, details: details,
                                 port: port, settings: settings, epoch: epoch, manager: self)
        }
    }

    /// Awaitable single connect attempt for the recovery loop (#270): the same
    /// preflight + engine path as `start`, but returns whether it connected *and*
    /// verified, so the loop can stop (success) or back off (failure).
    @discardableResult
    private func connectAndAwait(_ record: ConnectionRecord) async -> Bool {
        if shouldWaitForOwnPortReleaseNow() { await waitForOwnPortRelease() }   // #333
        guard let (engine, details, port, settings, epoch) = preflight(record, isReconnect: true) else { return false }
        return await Task.detached {
            await Self.runEngine(engine: engine, details: details,
                                 port: port, settings: settings, epoch: epoch, manager: self)
        }.value
    }

    /// #333: is the configured SOCKS port busy *because* we just tore down our own
    /// listener (within `selfDisconnectGhostWindow`)? Reads live state on MainActor
    /// and delegates the verdict to the pure `shouldWaitForOwnPortRelease`.
    private func shouldWaitForOwnPortReleaseNow() -> Bool {
        let port = UInt16(SettingsStore.shared.socksPort)
        let ago = TunnelManager.lastSelfDisconnectDate.map { Date().timeIntervalSince($0) }
        return Self.shouldWaitForOwnPortRelease(portFree: PortAvailability.isFree(port),
                                                selfDisconnectedAgo: ago)
    }

    /// #333: poll the SAME configured port until it frees up — up to
    /// `portReleaseMaxWait`, every `portReleasePollInterval` — before the
    /// preflight's #308 check runs. Keeps the #308 contract: we never slide to
    /// another port; on timeout the preflight surfaces the typed busy error as
    /// usual. Only called when `shouldWaitForOwnPortReleaseNow()` is true, so a
    /// foreign-held port is never waited on (it still fails fast).
    private func waitForOwnPortRelease() async {
        let port = UInt16(SettingsStore.shared.socksPort)
        LogStore.shared.log(.connection, L10n.waitingForPortRelease.localized())
        let deadline = Date().addingTimeInterval(Self.portReleaseMaxWait)
        while Date() < deadline {
            if PortAvailability.isFree(port) { return }
            try? await Task.sleep(for: .seconds(Self.portReleasePollInterval))
        }
        // Fell through → still busy; preflight's isFree() check fails fast with the
        // typed busy error (no special handling needed here).
    }

    /// Checks the configured SOCKS port is free and snapshots the `SettingsStore`
    /// values the engine needs — both on MainActor. Returns nil (and sets
    /// `.failed`) if the configured port is busy.
    private func reservePortAndSettings(isReconnect: Bool) -> (port: Int, settings: EngineStartSettings)? {
        let s = SettingsStore.shared
        let configuredPort = UInt16(s.socksPort)
        // #308: always bind the *configured* port — never auto-slide to another.
        // The port is the contract with external SOCKS clients (Shadowrocket,
        // browsers) pointed at exactly it, so a single isFree() check that fails
        // fast on a busy port is correct; the user frees it or changes the setting.
        // #308 was: PortAvailability.nextFreePort auto-slide + portChangedAuto log.
        guard PortAvailability.isFree(configuredPort) else {
            let msg = L10n.errorPortBusy_fmt.formatted(Int(configuredPort))
            LogStore.shared.log(.connection, "✗ \(msg)", code: .portBusy)  // OLC-1026 (docs/diagnostic-messages.md)
            state = .failed(msg)
            return nil
        }
        let settings = EngineStartSettings(
            dns:                   s.dnsServer,
            debugEnabled:          s.debugLogging,
            timeoutMs:             s.startTimeoutSeconds * 1000,
            vp8FPS:                s.vp8FPS,
            vp8Batch:              s.vp8BatchSize,
            localSocksAuthEnabled: s.localSocksAuthEnabled,
            localSocksUser:        s.localSocksUser,
            localSocksPass:        s.localSocksPass,
            isReconnect:           isReconnect)
        return (Int(configuredPort), settings)
    }

    /// Off-MainActor: start the engine (blocking native work), then verify
    /// end-to-end connectivity and post the final state. State reads/writes hop
    /// to MainActor via `manager`. The engine logs its own protocol-specific
    /// milestones and failures and tears down its runtime on failure; this layer
    /// owns only the generic state machine + SOCKS verification.
    @discardableResult
    private static func runEngine(engine: any TunnelEngine,
                                  details: ConnectionDetails,
                                  port: Int,
                                  settings: EngineStartSettings,
                                  epoch: Int,
                                  manager: TunnelManager?) async -> Bool {
        do {
            try await engine.start(details, port: port, settings: settings)
        } catch let e as TunnelEngineError {
            await MainActor.run {
                guard manager?.isLiveAttempt(epoch) == true else { return }
                manager?.state = .failed(e.message)
            }
            return false
        } catch {
            await MainActor.run {
                guard manager?.isLiveAttempt(epoch) == true else { return }
                manager?.state = .failed(error.localizedDescription)
            }
            return false
        }
        // Guard: a disconnect or a newer attempt (#272) may have superseded us
        // while the engine was starting.
        let stillLive = await MainActor.run { manager?.isLiveAttempt(epoch) == true }
        guard stillLive else { engine.stop(); return false }

        let tunnelOK = await verifyTunnel()
        return await MainActor.run {
            // Guard again: disconnect() / a newer attempt may have intervened
            // during verifyTunnel() — only the still-current attempt posts a result.
            guard manager?.isLiveAttempt(epoch) == true else {
                engine.stop()
                return false
            }
            if tunnelOK {
                LogStore.shared.log(.connection, L10n.tunnelOK.localized(), code: .tunnelWorks)  // OLC-1007
                manager?.state = .connected
                return true
            } else {
                LogStore.shared.log(.connection, L10n.tunnelFailed.localized(), code: .tunnelDown)  // OLC-1009
                engine.stop()
                manager?.state = .failed(L10n.serverNotResponding.localized())
                return false
            }
        }
    }

    // MARK: Validation
    //
    // Cheap structural checks that surface friendlier errors than the Go
    // runtime would. Anything expensive to verify (network reachability,
    // room existence) is left to MobileStart/WaitReady.
    nonisolated static func validate(params: OlcrtcConnection) -> String? {
        let clientID = params.clientID.trimmingCharacters(in: .whitespaces)
        if clientID.isEmpty            { return L10n.validateClientIDEmpty.localized() }
        if clientID.contains(where: \.isWhitespace) { return L10n.validateClientIDWhitespace.localized() }

        let key = params.key
        if key.count != 64             { return L10n.validateKeyLength_fmt.formatted(key.count) }
        if key.contains(where: { !$0.isHexDigit }) { return L10n.validateKeyNonHex.localized() }

        if params.roomID.trimmingCharacters(in: .whitespaces).isEmpty {
            return L10n.validateRoomIDEmpty.localized()
        }
        return nil
    }

    // End-to-end tunnel probe: HTTPS request(s) through the local SOCKS5
    // listener. Iterates through `AppConstants.tunnelVerifyURLs` until one
    // returns 200 — fallbacks matter because individual probe hosts have
    // been observed to be blocked from some carriers.
    //
    // Without this, ICE-connected-but-TURN-rejected states would be reported
    // as .connected to the UI.
    /// #287: wording for the "keep-alive skipped" line. `noteActivity(forAtLeast:)`
    /// can park the activity marker in the future, so a naive "ago" goes negative —
    /// report the reserved window instead of "active −N s ago".
    nonisolated static func keepAliveSkipNote(ageSeconds: Double) -> String {
        ageSeconds < 0
            ? "♡ Keep-alive skipped — tunnel busy (\(Int(-ageSeconds))s reserved)"
            : "♡ Keep-alive skipped — tunnel active \(Int(ageSeconds))s ago"
    }

    /// #287: a valid verify URL only reports "bad URL" when the SOCKS session
    /// itself can't be built (e.g. the proxy is gone mid-teardown). Translate that
    /// to a truthful reason; pass everything else through unchanged.
    nonisolated static func verifyFailureReason(_ error: Error) -> String {
        if let u = error as? URLError, u.code == .badURL || u.code == .unsupportedURL {
            return "proxy not ready"
        }
        return error.localizedDescription
    }

    private static func verifyTunnel() async -> Bool {
        let session = SOCKSSession.make(mode: .tunnel, timeout: 20)
        // #333 fold-in: tear the session down once we have a verdict so the losing /
        // cancelled probe tasks don't linger in flight against the (about-to-close)
        // SOCKS listener. `finishTasksAndInvalidate` lets the winner's transfer
        // complete, then releases the session and any sockets it held.
        defer { session.finishTasksAndInvalidate() }
        return await withTaskGroup(of: (String, Bool).self) { group in
            for urlString in AppConstants.tunnelVerifyURLs {
                guard let url = URL(string: urlString) else { continue }
                group.addTask {
                    do {
                        let (_, response) = try await session.data(from: url)
                        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                        if status == 200 {
                            await MainActor.run {
                                LogStore.shared.log(.connection, "✓ tunnel verify via \(urlString)",
                                                    code: .verifyOK)  // OLC-1005
                            }
                            return (urlString, true)
                        }
                        await MainActor.run {
                            LogStore.shared.log(.connection,
                                "✗ tunnel verify via \(urlString): HTTP \(status)",
                                code: .verifyFailed)  // OLC-1006
                        }
                        return (urlString, false)
                    } catch {
                        let reason = Self.verifyFailureReason(error)
                        await MainActor.run {
                            LogStore.shared.log(.connection,
                                "✗ tunnel verify via \(urlString): \(reason)",
                                code: .verifyFailed)  // OLC-1006
                        }
                        return (urlString, false)
                    }
                }
            }
            for await (_, success) in group {
                if success {
                    group.cancelAll()
                    return true
                }
            }
            return false
        }
    }

    // MARK: Per-connection probes (#234 latency, #242 time-to-ready)
    //
    // Both spin up an isolated, non-singleton client (separate from the tunnel
    // this manager drives), so they are safe to run while connected. The engine
    // owns the native probe + ephemeral-port reservation; this layer just
    // snapshots the relevant settings on MainActor and routes to the record's
    // engine. `.success(ms:)` is HTTP latency for ping, time-to-ready for check.

    /// Measures HTTP latency for one connection via an isolated client (#234).
    func ping(_ details: ConnectionDetails) async -> PingOutcome {
        let engine = details.engine
        if let problem = engine.validate(details) { return .failure(problem) }
        return await engine.ping(details, settings: probeSettings())
    }

    /// Measures WebRTC time-to-ready for one connection via an isolated client (#242).
    func checkReady(_ details: ConnectionDetails) async -> PingOutcome {
        let engine = details.engine
        if let problem = engine.validate(details) { return .failure(problem) }
        return await engine.checkReady(details, settings: probeSettings())
    }

    // MARK: Batch ping a group (#364)
    //
    // Health-check every connection in a group at once. The single-node `ping`
    // already runs an isolated, non-singleton client that leases an EPHEMERAL
    // port per probe (OlcrtcEngine.ping → PortAvailability.freeEphemeralPort) — it
    // never touches the configured SOCKS port (#308). The batch only adds
    // orchestration: it runs the probes SEQUENTIALLY (one room at a time, no
    // parallel native clients fighting over the gomobile primitives), gives each
    // probe a UNIQUE clientID so two pings — or a ping racing the live tunnel — in
    // the same room don't collide on identity, and SKIPS the node the live tunnel
    // currently holds (pinging it would join its own room as a second client).

    /// Per-probe clientID for a batch ping (#364): the record's own id keeps it
    /// stable across re-runs while still being unique per node, so a probe never
    /// rendezvouses under the same clientID as a live tunnel (which uses the
    /// connection's configured clientID, e.g. "default"). Pure → tested.
    nonisolated static func batchPingClientID(recordID: UUID) -> String {
        "olc-ping-\(recordID.uuidString.prefix(8))"
    }

    /// Whether a batch ping should SKIP this record: true only when the live
    /// tunnel is connected to *this same node*. Pinging it would join the node's
    /// room a second time; the live RTT is already known. Other nodes (and the
    /// disconnected case) are always probed. Pure → tested.
    nonisolated static func shouldSkipBatchPing(record: ConnectionRecord,
                                                connectedNode: ConnectionRecord?,
                                                state: ConnectionState) -> Bool {
        guard state.isConnected, let live = connectedNode else { return false }
        return live.id == record.id
    }

    /// Rewrites a record's olcrtc clientID to `clientID` for an isolated probe,
    /// leaving every other field untouched. Non-olcrtc records pass through.
    nonisolated static func recordForBatchPing(_ record: ConnectionRecord,
                                               clientID: String) -> ConnectionRecord {
        guard case .olcrtc(var p) = record.details else { return record }
        p.clientID = clientID
        var r = record
        r.details = .olcrtc(p)
        return r
    }

    /// Sequentially pings every record in `group`, returning id → outcome. Skips
    /// the node the live tunnel currently holds (#308: never a second client into
    /// the live room; the engine already leases an ephemeral port per probe).
    /// `onResult` fires on MainActor after each probe so the UI can badge rows as
    /// they complete rather than waiting for the whole group.
    @discardableResult
    func pingGroup(_ group: [ConnectionRecord],
                   connectedNode: ConnectionRecord?,
                   // No `@escaping`: `onResult` is called inline (never stored), and
                   // since `pingGroup` is `@MainActor`-isolated each callback already
                   // runs on the main actor — the UI can mutate @State directly.
                   onResult: (UUID, PingOutcome) -> Void) async -> [UUID: PingOutcome] {
        var results: [UUID: PingOutcome] = [:]
        let state = self.state
        for record in group {
            guard !Self.shouldSkipBatchPing(record: record,
                                            connectedNode: connectedNode, state: state) else {
                continue
            }
            let probeRecord = Self.recordForBatchPing(
                record, clientID: Self.batchPingClientID(recordID: record.id))
            let outcome = await ping(probeRecord.details)
            results[record.id] = outcome
            onResult(record.id, outcome)
        }
        return results
    }

    /// Snapshots the `SettingsStore` values the probes need, on MainActor.
    private func probeSettings() -> EngineProbeSettings {
        let s = SettingsStore.shared
        return EngineProbeSettings(
            timeoutMs: s.startTimeoutSeconds * 1000,
            pingURL:   AppConstants.pingProbeURL,
            vp8FPS:    s.vp8FPS,
            vp8Batch:  s.vp8BatchSize)
    }
}
