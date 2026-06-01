import Foundation
// No `import Mobile`: the gomobile runtime is reached only through the engine
// (OlcrtcEngine) now — TunnelManager is protocol-agnostic (#243).

// MARK: - TunnelManager
//
// Drives a tunnel through a pluggable `TunnelEngine` (#243). The protocol's
// native runtime lives in the engine — for olcrtc, `OlcrtcEngine` wraps the
// gomobile singleton from Mobile.xcframework. This type owns only the generic
// orchestration: the connection state machine, keep-alive, one-shot auto-retry,
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
    case failed(String)

    var isConnected: Bool  { self == .connected }
    var isConnecting: Bool { self == .connecting }

    var label: String {
        switch self {
        case .disconnected:  return L10n.stateDisconnected.localized()
        case .connecting:    return L10n.stateConnecting.localized()
        case .connected:     return L10n.stateConnected.localized()
        case .failed(let m): return L10n.stateErrorPrefix_fmt.formatted(m)
        }
    }

    /// Compact, English-only rendering used by `LogStore` for state-transition
    /// lines (engineering observability, not the user-facing `label`). Keeping
    /// `.failed(reason)` on one line lets you see the cause inline.
    var description: String {
        switch self {
        case .disconnected:  return "disconnected"
        case .connecting:    return "connecting"
        case .connected:     return "connected"
        case .failed(let m): return "failed(\(m))"
        }
    }
}

/// Result of a per-connection latency probe via `TunnelManager.ping` (#234).
enum PingOutcome: Equatable, Sendable {
    case success(ms: Int)
    case failure(String)
}

/// Drives the connection state machine
/// (disconnected → connecting → connected | failed), manages keep-alive probes,
/// one-shot auto-retry, and background audio keep-alive. See file header for
/// concurrency and ICE-connected-but-no-data caveats.
@MainActor
final class TunnelManager: ObservableObject {
    /// `nonisolated` so SOCKSSession (called from background tasks) can read
    /// the active port without awaiting MainActor. The value is read from
    /// SettingsStore on every access, so changing the port in Settings
    /// takes effect on the next connect / next URLSession build.
    nonisolated static var socksPort: Int { SettingsStore.shared.socksPort }

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
            case .connecting:
                // cancel-then-nil-synchronously: Task.cancel() is cooperative,
                // so dropping the handle immediately prevents any later branch
                // (or a re-entrant didSet on rapid oscillation) from observing
                // a stale-but-still-running task in `keepAliveTask` / `retryTask`.
                keepAliveTask?.cancel(); keepAliveTask = nil
                retryTask?.cancel();     retryTask = nil
            case .disconnected, .failed:
                keepAliveTask?.cancel(); keepAliveTask = nil
                bgKeeper.stop()
            }
        }
    }

    private var lastRecord: ConnectionRecord?
    private var retryTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private let bgKeeper = BackgroundRuntimeKeeper()

    /// Updated whenever data successfully flows through the tunnel.
    /// `nonisolated` so SOCKSSession / SpeedTest can write from background tasks.
    /// Keep-alive reads this on MainActor; a slight data race on Date is benign.
    nonisolated(unsafe) static var lastTunnelActivityDate: Date? = nil

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
        case .connecting, .connected: return
        }
        lastRecord = record
        start(record: record)
    }

    func disconnect() {
        LogStore.shared.log(.connection, L10n.disconnectingArrow.localized())
        // Cancel both tasks before mutating state so neither task can observe
        // an intermediate state and schedule a spurious auto-retry.
        retryTask?.cancel();     retryTask = nil
        keepAliveTask?.cancel(); keepAliveTask = nil
        bgKeeper.stop()
        activeEngine?.stop()
        lastRecord = nil
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
    // The auto-retry is one-shot per session: keep-alive failing schedules
    // one connect attempt 2 seconds later. If that retry fails (or any
    // initial-connect failure happens), we stop and wait for the user.
    // Without this guard, a server that consistently refuses traffic would
    // loop us forever and burn battery.

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
                    LogStore.shared.log(.connection, "♡ Keep-alive skipped — tunnel active \(Int(Date().timeIntervalSince(last)))s ago")
                    continue
                }

                let ok = await Self.verifyTunnel()
                guard !Task.isCancelled, self.state.isConnected else { return }

                if ok {
                    failCount = 0
                    TunnelManager.lastTunnelActivityDate = Date()
                    LogStore.shared.log(.connection, L10n.keepAliveOK.localized())
                } else {
                    failCount += 1
                    if failCount < 3 {
                        // Failures may be transient — heavy traffic, brief blip.
                        // Warn but keep the connection alive; next interval decides.
                        // 3 consecutive failures = 90s of sustained failure before disconnect.
                        LogStore.shared.log(.connection,
                            "⚠ Keep-alive failed (\(failCount)/3) — retrying next interval")
                    } else {
                        LogStore.shared.log(.connection, L10n.keepAliveLost.localized())
                        self.activeEngine?.stop()
                        self.state = .failed(L10n.serverConnectionLost.localized())
                        self.scheduleAutoRetry()
                        return
                    }
                }
            }
        }
    }

    private func scheduleAutoRetry() {
        // Drop the previous handle synchronously (cooperative cancel + nil)
        // before assigning the new one, matching the discipline in
        // `state.didSet`'s `.connecting` branch and `startKeepAliveIfEnabled`.
        retryTask?.cancel(); retryTask = nil
        guard let record = lastRecord else { return }
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            // Only fire if we're still in .failed — user may have manually
            // disconnected or already retried during the 2s window.
            if case .failed = self.state {
                LogStore.shared.log(.connection,
                    L10n.autoReconnect_fmt.formatted(record.displayName))
                self.connect(record: record)
            }
        }
    }

    // MARK: Generic engine start (#243)

    /// Generic connect path. Selects the engine for the record's protocol, runs
    /// the engine's structural validation + reserves a local SOCKS port (both
    /// synchronously on MainActor), flips to `.connecting`, then hands off to a
    /// detached task. The detached `runEngine` does the blocking native work.
    private func start(record: ConnectionRecord) {
        let engine = record.details.engine
        activeEngine = engine
        LogStore.shared.startSession(.connection)
        if let problem = engine.validate(record.details) {
            LogStore.shared.log(.connection, "✗ \(problem)")
            state = .failed(problem)
            return
        }
        guard let (port, settings) = reservePortAndSettings() else { return }
        state = .connecting
        let details = record.details
        Task.detached { [weak self] in
            await Self.runEngine(engine: engine, details: details,
                                 port: port, settings: settings, manager: self)
        }
    }

    /// Reserves a free local SOCKS port and snapshots the `SettingsStore` values
    /// the engine needs — both on MainActor. Returns nil (and sets `.failed`) if
    /// no port is free in the auto-retry window.
    private func reservePortAndSettings() -> (port: Int, settings: EngineStartSettings)? {
        let s = SettingsStore.shared
        let preferred = UInt16(s.socksPort)
        guard let freePort = PortAvailability.nextFreePort(startingAt: preferred) else {
            let msg = L10n.errorAllPortsBusy_fmt.formatted(Int(preferred),
                                                            Int(preferred) + PortAvailability.autoRetryAttempts - 1)
            LogStore.shared.log(.connection, "✗ \(msg)")
            state = .failed(msg)
            return nil
        }
        if freePort != preferred {
            LogStore.shared.log(.connection,
                L10n.portChangedAuto_fmt.formatted(Int(preferred), Int(freePort)))
        }
        let settings = EngineStartSettings(
            dns:                   s.dnsServer,
            debugEnabled:          s.debugLogging,
            timeoutMs:             s.startTimeoutSeconds * 1000,
            vp8FPS:                s.vp8FPS,
            vp8Batch:              s.vp8BatchSize,
            localSocksAuthEnabled: s.localSocksAuthEnabled,
            localSocksUser:        s.localSocksUser,
            localSocksPass:        s.localSocksPass)
        return (Int(freePort), settings)
    }

    /// Off-MainActor: start the engine (blocking native work), then verify
    /// end-to-end connectivity and post the final state. State reads/writes hop
    /// to MainActor via `manager`. The engine logs its own protocol-specific
    /// milestones and failures and tears down its runtime on failure; this layer
    /// owns only the generic state machine + SOCKS verification.
    private static func runEngine(engine: any TunnelEngine,
                                  details: ConnectionDetails,
                                  port: Int,
                                  settings: EngineStartSettings,
                                  manager: TunnelManager?) async {
        do {
            try await engine.start(details, port: port, settings: settings)
        } catch let e as TunnelEngineError {
            await MainActor.run {
                guard manager?.state == .connecting else { return }
                manager?.state = .failed(e.message)
            }
            return
        } catch {
            await MainActor.run {
                guard manager?.state == .connecting else { return }
                manager?.state = .failed(error.localizedDescription)
            }
            return
        }
        // Guard: user may have disconnected while the engine was starting.
        let stillConnecting = await MainActor.run { manager?.state == .connecting }
        guard stillConnecting else { engine.stop(); return }

        let tunnelOK = await verifyTunnel()
        await MainActor.run {
            // Guard again: disconnect() may have been called during verifyTunnel().
            guard manager?.state == .connecting else {
                engine.stop()
                return
            }
            if tunnelOK {
                LogStore.shared.log(.connection, L10n.tunnelOK.localized())
                manager?.state = .connected
            } else {
                LogStore.shared.log(.connection, L10n.tunnelFailed.localized())
                engine.stop()
                manager?.state = .failed(L10n.serverNotResponding.localized())
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
    private static func verifyTunnel() async -> Bool {
        let session = SOCKSSession.make(mode: .tunnel, timeout: 20)
        return await withTaskGroup(of: (String, Bool).self) { group in
            for urlString in AppConstants.tunnelVerifyURLs {
                guard let url = URL(string: urlString) else { continue }
                group.addTask {
                    do {
                        let (_, response) = try await session.data(from: url)
                        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                        if status == 200 {
                            await MainActor.run {
                                LogStore.shared.log(.connection, "✓ tunnel verify via \(urlString)")
                            }
                            return (urlString, true)
                        }
                        await MainActor.run {
                            LogStore.shared.log(.connection,
                                "✗ tunnel verify via \(urlString): HTTP \(status)")
                        }
                        return (urlString, false)
                    } catch {
                        await MainActor.run {
                            LogStore.shared.log(.connection,
                                "✗ tunnel verify via \(urlString): \(error.localizedDescription)")
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
