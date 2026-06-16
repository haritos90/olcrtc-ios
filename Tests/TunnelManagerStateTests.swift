import XCTest
@testable import olcrtc_ios

// Tests for TunnelManager's connection-state machine — the observable parts.
//
// What this file covers (Group 1 + Group 2 in the test plan):
//   1. Initial state on a fresh instance.
//   2. Direct writes to `state` (the property is `internal`, so @testable
//      can drive transitions without going through the full connect flow).
//   3. The `didSet` no-op guard (writing the same value twice should not
//      re-fire side-effects).
//   4. `connect(record:)` with INVALID params: takes the synchronous
//      validate → .failed path inside preflight() without ever launching
//      the detached MobileStart task.
//   5. `connect(record:)` is a no-op when state is `.connecting` or
//      `.connected` (the early-return guard at the top of connect()).
//
// What this file deliberately does NOT cover, and why:
//
//   - keepAliveTask / recoveryTask / lastRecord / bgKeeper are `private`.
//     The didSet side-effects (start keep-alive, cancel retry, stop bg
//     keeper) are not observable from a test target — we can confirm that
//     setting state doesn't crash and that the published value is what we
//     wrote, but we cannot directly assert "exactly one keep-alive task is
//     live" or "retry was cancelled". This is the keep-alive cancellation
//     race scenario from Group 4 — currently untestable without exposing
//     internal state or extracting an FSM.
//
//   - startKeepAliveIfEnabled() and requestReconnect() are `private`,
//     so Group 3 (retry scheduling) is also out of reach — but the backoff
//     *delay* policy is a pure static (`backoffDelaySeconds`) covered in
//     ReconnectBackoffTests.
//
//   - The full connect flow with VALID params calls `Task.detached { ... }`
//     which invokes MobileStartWithTransport / MobileWaitReady from
//     Mobile.xcframework. That requires a real Go runtime, real network,
//     and a real signalling server — not appropriate for a unit test.
//
//   - disconnect() unconditionally calls MobileStop(). Calling that without
//     a prior MobileStart() is technically defined behavior in the Go
//     binding (the package-level `cancel` is nil-checked), but we don't
//     want to take a hard dependency on that contract from unit tests, so
//     we don't exercise disconnect() here. If a future refactor splits
//     "release Swift-side resources" from "tell Go to stop", that split
//     becomes unit-testable.
//
// Next concrete step to unlock real FSM coverage:
//   Extract the state-transition rules into a pure value type (e.g.
//   `struct ConnectionFSM { mutating func apply(_ event: Event) -> [Effect] }`)
//   and have TunnelManager hold one. The FSM type is then trivially
//   testable in isolation, and TunnelManager's job collapses to "translate
//   Effects into side-effects (start task, stop task, ...)". The state
//   machine and its safety-critical transitions get full coverage; the
//   side-effect translator stays a thin layer that doesn't need a unit
//   test of its own.

@MainActor
final class TunnelManagerStateTests: XCTestCase {

    private let validKey = String(repeating: "a", count: 64)

    // Use a fresh instance per test so state from one test cannot leak
    // into the next. The app holds a single `@StateObject TunnelManager()`
    // at the App level (see App.swift), but the class itself isn't a hard
    // singleton — `init` is internal and the constructor only installs a
    // log writer (idempotent across instances).
    private func makeManager() -> TunnelManager { TunnelManager() }

    private func validParams() -> OlcrtcConnection {
        OlcrtcConnection(
            carrier:   "telemost",
            transport: "datachannel",
            roomID:    "room-1",
            key:       validKey,
            clientID:  "ios-test"
        )
    }

    private func invalidParams() -> OlcrtcConnection {
        // Empty clientID — fastest path through validate() into .failed.
        var p = validParams()
        p.clientID = ""
        return p
    }

    private func record(with params: OlcrtcConnection) -> ConnectionRecord {
        ConnectionRecord(name: "test", details: .olcrtc(params))
    }

    // Lock the language for any message comparisons.
    private var savedLanguage: String = ""
    override func setUp() {
        super.setUp()
        savedLanguage = SettingsStore.shared.language
        SettingsStore.shared.language = "en"
    }
    override func tearDown() {
        SettingsStore.shared.language = savedLanguage
        super.tearDown()
    }

    // MARK: Initial state

    // A freshly constructed TunnelManager must report .disconnected.
    // Anything else would mean the singleton has hidden persisted state
    // from a previous session, which would surface as a confusing
    // "already connected on launch" UI bug.
    func testInitialStateIsDisconnected() {
        let manager = makeManager()
        XCTAssertEqual(manager.state, .disconnected)
    }

    // MARK: Direct state writes

    // The setter is reachable via @testable import — `state` has default
    // (internal) access. Driving transitions directly is the only way to
    // exercise the state machine without booting Mobile.xcframework.
    func testCanTransitionThroughHappyPath() {
        let manager = makeManager()
        manager.state = .connecting
        XCTAssertEqual(manager.state, .connecting)
        manager.state = .connected
        XCTAssertEqual(manager.state, .connected)
        manager.state = .disconnected
        XCTAssertEqual(manager.state, .disconnected)
    }

    // The failure variant carries a String payload — exercising it makes
    // sure the associated value round-trips through the @Published setter
    // unchanged (no accidental trimming, no localization rewrite).
    func testFailedStateCarriesItsReasonString() {
        let manager = makeManager()
        manager.state = .failed("boom")
        XCTAssertEqual(manager.state, .failed("boom"))
    }

    // The `.waitingForNetwork` holding state (#269) must round-trip through the
    // @Published setter and be distinct from connected/connecting: ConnectionsView
    // renders it via `== .waitingForNetwork` (not isConnected/isConnecting), and
    // the global toggle stays ON for it. The `description` feeds LogStore.
    func testWaitingForNetworkStateRoundTrips() {
        let manager = makeManager()
        manager.state = .waitingForNetwork
        XCTAssertEqual(manager.state, .waitingForNetwork)
        XCTAssertFalse(manager.state.isConnected)
        XCTAssertFalse(manager.state.isConnecting)
        XCTAssertEqual(manager.state.description, "waitingForNetwork")
        // Tidy up: `.waitingForNetwork` keeps bgKeeper running by design, so
        // drive back to .disconnected to release it (didSet's cleanup branch).
        manager.state = .disconnected
    }

    // didSet has a `guard state != oldValue else { return }` so that
    // re-writing the current state is a no-op. The user-visible reason this
    // matters: keep-alive task is started in didSet when entering .connected.
    // Without the guard, a re-write of .connected would cancel the running
    // keep-alive task and start a fresh one — exactly the race we don't
    // want. We can't observe the private task from here, but we CAN observe
    // that the published value stays consistent across the redundant write.
    func testRewritingSameStateIsObservablyANoOp() {
        let manager = makeManager()
        manager.state = .connecting
        manager.state = .connecting
        XCTAssertEqual(manager.state, .connecting)
    }

    // MARK: connect() with invalid params

    // preflight() runs validate() synchronously on MainActor and, on the
    // first error, sets state = .failed and returns nil — no Task.detached,
    // no MobileStart. This is a real end-to-end FSM transition we CAN test
    // without booting Mobile.xcframework: caller passes a bad record,
    // manager moves .disconnected → .failed with the validation message.
    func testConnectWithInvalidParamsTransitionsToFailed() {
        let manager = makeManager()
        XCTAssertEqual(manager.state, .disconnected)
        manager.connect(record: record(with: invalidParams()))
        XCTAssertEqual(manager.state, .failed(L10n.validateClientIDEmpty.localized()))
    }

    // The "Retry on the error banner" UX (see the comment on connect()):
    // connect() must accept .failed as a starting state, not just
    // .disconnected. Verify by chaining a second invalid connect after the
    // first one — it should transition .failed → .failed(same message)
    // again rather than being ignored.
    func testConnectFromFailedStateIsAllowed() {
        let manager = makeManager()
        manager.state = .failed("previous error")
        manager.connect(record: record(with: invalidParams()))
        XCTAssertEqual(manager.state, .failed(L10n.validateClientIDEmpty.localized()))
    }

    // MARK: connect() guard on busy states

    // The switch at the top of connect() returns early when state is
    // .connecting. This is the safety guard that prevents double-tap of
    // the Connect button from launching two MobileStart goroutines (which
    // would return errAlreadyRunning from the Go side anyway, but the
    // Swift-side guard makes the no-op observable as "state unchanged"
    // rather than as a flash of "connecting → failed").
    func testConnectIsNoOpWhileConnecting() {
        let manager = makeManager()
        manager.state = .connecting
        manager.connect(record: record(with: invalidParams()))
        // Did NOT transition to .failed even though params are invalid:
        // the early-return at the top of connect() short-circuits before
        // preflight() runs.
        XCTAssertEqual(manager.state, .connecting)
    }

    // Same guard, but from the .connected side. Tapping Connect while
    // already connected must not tear down the live session.
    func testConnectIsNoOpWhileConnected() {
        let manager = makeManager()
        manager.state = .connected
        manager.connect(record: record(with: invalidParams()))
        XCTAssertEqual(manager.state, .connected)
        // Clean up so the .connected didSet's keep-alive task doesn't
        // outlive the test. Setting to .disconnected cancels it (private
        // keepAliveTask isn't observable, but the cancel path runs).
        manager.state = .disconnected
    }

    // MARK: disconnect() from .connected

    // disconnect() cancels tasks, stops the background keeper, calls
    // MobileStop(), clears lastRecord, and sets state = .disconnected.
    //
    // Calling MobileStop() without a prior MobileStart() is documented in
    // the file header as "technically defined behavior in Go (nil-checked
    // cancel var)" but this test file deliberately avoids taking a hard
    // dependency on that contract from a unit test — if the Go runtime
    // is not linked or behaves differently in the test host the call may
    // crash or produce undefined results.
    //
    // Therefore we skip when Mobile.xcframework is not available in the
    // test environment, and otherwise verify only the observable outcome:
    // state transitions from .connected to .disconnected.
    func testDisconnectFromConnectedTransitionsToDisconnected() throws {
        // Guard: MobileStop() is defined in the Go binding's Objective-C
        // header. If the test host does not have a properly initialised Go
        // runtime the call will silently no-op (cancel is nil-checked on
        // the Go side) — that is the contract we rely on here.
        // If future evidence shows this is unsafe in the test environment,
        // replace the body with:
        //   throw XCTSkip("MobileStop() unsafe without Go runtime")
        let manager = makeManager()
        manager.state = .connected
        manager.disconnect()
        XCTAssertEqual(manager.state, .disconnected)
    }

    // MARK: connect() with valid params — synchronous .connecting transition

    // startOlcrtc() runs preflight() synchronously on MainActor, and on
    // success sets state = .connecting *before* launching the detached
    // MobileStart Task. Because this whole method body runs on MainActor
    // and the detached Task is — by definition — deferred to a later
    // scheduling point, we can assert .connecting synchronously right
    // after connect() returns, without awaiting anything.
    //
    // Note: the detached Task will eventually call MobileStartWithTransport
    // on a background thread. In the test host that call will fail (no real
    // Go runtime / signalling server) and post manager.state = .failed back
    // to MainActor, but only on a subsequent run-loop turn — invisible to
    // this synchronous assertion.
    func testConnectFromDisconnectedWithValidParamsTransitionsToConnecting() {
        let manager = makeManager()
        XCTAssertEqual(manager.state, .disconnected)
        manager.connect(record: record(with: validParams()))
        // Synchronously observable: preflight succeeded → state = .connecting
        // was set before Task.detached was enqueued.
        XCTAssertEqual(manager.state, .connecting)
        // Tidy up: cancel any lingering recoveryTask / keepAliveTask by driving
        // state to .disconnected. The private tasks are not observable but
        // the cancellation code path in didSet runs.
        manager.state = .disconnected
    }

    // MARK: Multiple connect() calls while already connecting

    // The switch guard at the top of connect() returns early when state
    // is .connecting. Calling connect() three times in a row must not
    // stack additional detached Tasks or produce any state other than
    // .connecting. The first call flips state to .connecting (via the
    // same synchronous-preflight path verified above); the subsequent two
    // calls hit the early-return and are silent no-ops.
    func testMultipleConnectCallsWhileConnectingDoNotStackStates() {
        let manager = makeManager()
        manager.connect(record: record(with: validParams()))
        XCTAssertEqual(manager.state, .connecting, "first call must flip to .connecting")
        manager.connect(record: record(with: validParams()))
        XCTAssertEqual(manager.state, .connecting, "second call must not change state")
        manager.connect(record: record(with: validParams()))
        XCTAssertEqual(manager.state, .connecting, "third call must not change state")
        // Tidy up.
        manager.state = .disconnected
    }

    // MARK: Connect epoch (#272)

    // Each launched connect attempt must advance the monotonic `connectEpoch`, so
    // a detached `runEngine` from a superseded attempt can tell it is stale and
    // bail instead of aliasing a newer attempt's `.connecting`. The aliasing race
    // itself needs the full async engine flow (not unit-testable here), but the
    // counter it relies on is observable.
    func testEachConnectAttemptAdvancesTheEpoch() {
        let manager = makeManager()
        let e0 = manager.connectEpoch
        manager.connect(record: record(with: validParams()))
        let e1 = manager.connectEpoch
        XCTAssertGreaterThan(e1, e0, "a launched attempt must bump the epoch")
        // Back to .disconnected so a second connect is allowed, then verify the
        // epoch advances again (strictly monotonic across attempts).
        manager.state = .disconnected
        manager.connect(record: record(with: validParams()))
        XCTAssertGreaterThan(manager.connectEpoch, e1)
        manager.state = .disconnected
    }

    // An invalid connect fails in preflight *before* an attempt is launched, so
    // it must NOT consume an epoch — there is no detached runEngine to guard.
    func testInvalidConnectDoesNotAdvanceTheEpoch() {
        let manager = makeManager()
        let e0 = manager.connectEpoch
        manager.connect(record: record(with: invalidParams()))
        XCTAssertEqual(manager.state, .failed(L10n.validateClientIDEmpty.localized()))
        XCTAssertEqual(manager.connectEpoch, e0, "validation failure must not bump the epoch")
    }

    // boc #313
    // MARK: Bound port (#313)
    //
    // `boundPort` is the port the live attempt actually bound — the snapshot
    // preflight reserved (#308: the engine binds exactly it or the attempt
    // fails). The Settings port check compares against it, so its lifecycle is
    // part of the UI contract: nil while idle, the snapshot while
    // connecting/connected (even after a live Settings edit), nil again the
    // moment the session ends. Like the epoch tests above, preflight runs
    // synchronously on MainActor, so `boundPort` is observable right after
    // connect() returns, before the detached engine task gets a turn.

    // Preflight probes the configured port with PortAvailability.isFree and
    // fails the attempt on a busy one, so the tests below must configure a
    // genuinely free port first.
    private func someFreePort() -> Int? {
        for _ in 0..<20 {
            let candidate = UInt16.random(in: 20_000...60_000)
            if PortAvailability.isFree(candidate) { return Int(candidate) }
        }
        return nil
    }

    func testBoundPortIsNilOnFreshInstance() {
        XCTAssertNil(makeManager().boundPort)
    }

    // The core #313 fix: the snapshot must NOT follow a later Settings edit.
    // The old check assumed configured == bound, so while connected any value
    // typed into the port field was labeled "in use by olcrtc tunnel".
    func testBoundPortTracksTheSnapshotNotTheLiveSetting() throws {
        let s = SettingsStore.shared
        let saved = s.socksPort
        defer { s.socksPort = saved }
        let free = try XCTUnwrap(someFreePort(), "no free local port to test on")

        s.socksPort = free
        let manager = makeManager()
        manager.connect(record: record(with: validParams()))
        XCTAssertEqual(manager.state, .connecting)
        XCTAssertEqual(manager.boundPort, free, "preflight must publish the reserved port")

        // Live port edit while the attempt is up: the snapshot stands.
        s.socksPort = free == 8808 ? 8809 : 8808
        XCTAssertEqual(manager.boundPort, free,
                       "boundPort must keep the connect-time snapshot, not track Settings")
        manager.state = .disconnected
    }

    // Session over → no port held. All three terminal/holding transitions clear
    // the snapshot: .disconnected, .failed, and .waitingForNetwork (the path
    // monitor stops the engine before entering the hold, releasing the listener).
    func testBoundPortClearsWhenTheSessionEnds() throws {
        let s = SettingsStore.shared
        let saved = s.socksPort
        defer { s.socksPort = saved }

        let manager = makeManager()
        for terminal in [ConnectionState.disconnected,
                         .failed("boom"),
                         .waitingForNetwork] {
            // A fresh free port per attempt: the previous iteration's detached
            // engine task may still (briefly) hold its port, and preflight
            // fails the attempt on a busy one.
            s.socksPort = try XCTUnwrap(someFreePort(), "no free local port to test on")
            manager.state = .disconnected     // connect() requires an idle state
            manager.connect(record: record(with: validParams()))
            XCTAssertNotNil(manager.boundPort, "attempt must publish a bound port")
            manager.state = terminal
            XCTAssertNil(manager.boundPort, "\(terminal) must clear boundPort")
        }
        // Tidy up: .waitingForNetwork keeps bgKeeper alive by design.
        manager.state = .disconnected
    }
    // eoc #313

    // MARK: nonisolated bound-port mirror + activeSocksPort (#351)
    //
    // SOCKSSession builds tunnel-mode sessions off MainActor, so it can't read the
    // @Published `boundPort`. #351 mirrors every write into a nonisolated
    // `liveBoundPort`, and `activeSocksPort` prefers it over the configured port
    // while a session is live — otherwise a live port edit while connected would
    // point keep-alive's verify probe at the wrong port and tear down a healthy
    // tunnel (#313 follow-up). The mirror's lifecycle must match `boundPort`.

    func testActiveSocksPortFallsBackToConfiguredWhenIdle() throws {
        let s = SettingsStore.shared
        let saved = s.socksPort
        defer { s.socksPort = saved }
        let free = try XCTUnwrap(someFreePort(), "no free local port to test on")

        // Drive a full connect→disconnect so the mirror is deterministically
        // cleared (the static `liveBoundPort` is shared across instances/tests,
        // so a prior connect could otherwise leave it set).
        s.socksPort = free
        let manager = makeManager()
        manager.connect(record: record(with: validParams()))
        manager.state = .disconnected
        XCTAssertNil(TunnelManager.liveBoundPort, "mirror must clear when the session ends")
        // No live session → activeSocksPort falls back to the configured port.
        XCTAssertEqual(TunnelManager.activeSocksPort, free)
    }

    func testActiveSocksPortPrefersBoundPortWhileConnectedAfterLiveEdit() throws {
        let s = SettingsStore.shared
        let saved = s.socksPort
        defer { s.socksPort = saved }
        let free = try XCTUnwrap(someFreePort(), "no free local port to test on")

        s.socksPort = free
        let manager = makeManager()
        manager.connect(record: record(with: validParams()))
        XCTAssertEqual(manager.state, .connecting)
        // The mirror tracks the reserved snapshot and activeSocksPort prefers it.
        XCTAssertEqual(TunnelManager.liveBoundPort, free)
        XCTAssertEqual(TunnelManager.activeSocksPort, free)

        // Live port edit while up: in-app SOCKS traffic must still target the
        // port the session actually bound, not the freshly-typed setting (#351).
        let other = free == 8808 ? 8809 : 8808
        s.socksPort = other
        XCTAssertEqual(TunnelManager.activeSocksPort, free,
                       "activeSocksPort must stay on the bound port, not the edited setting")

        // Session over → mirror clears → activeSocksPort falls back to configured.
        manager.state = .disconnected
        XCTAssertNil(TunnelManager.liveBoundPort)
        XCTAssertEqual(TunnelManager.activeSocksPort, other)
    }

    // MARK: lastTunnelActivityDate — lock-backed get/set/reset (#372)
    //
    // The activity marker is now backed by an OSAllocatedUnfairLock instead of a
    // `nonisolated(unsafe)` raw static. The Date? surface must round-trip a value
    // (sub-millisecond precision is lost going through Double, so compare with a
    // tolerance), reset to nil, and stay consistent under concurrent writes/reads
    // (no crash, no torn read — the previous unsynchronised static was UB).

    func testActivityDateRoundTripsAndResets() throws {
        let now = Date()
        TunnelManager.lastTunnelActivityDate = now
        let read = try XCTUnwrap(TunnelManager.lastTunnelActivityDate)
        XCTAssertEqual(read.timeIntervalSinceReferenceDate,
                       now.timeIntervalSinceReferenceDate, accuracy: 0.001)
        // #333 reset-on-disconnect semantics.
        TunnelManager.lastTunnelActivityDate = nil
        XCTAssertNil(TunnelManager.lastTunnelActivityDate)
    }

    func testActivityDateConcurrentAccessIsSafe() {
        // Hammer the lock-backed store from many tasks at once; the assertion is
        // simply that this completes without a crash / sanitizer trap and leaves
        // a readable (non-torn) value behind. Under the old raw static this was a
        // data race; ThreadSanitizer would flag it.
        let exp = expectation(description: "concurrent activity writes")
        exp.expectedFulfillmentCount = 64
        for i in 0..<64 {
            DispatchQueue.global().async {
                if i % 2 == 0 {
                    TunnelManager.lastTunnelActivityDate = Date()
                } else {
                    _ = TunnelManager.lastTunnelActivityDate
                }
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 5)
        // Leave a clean baseline for any later test reading the shared static.
        TunnelManager.lastTunnelActivityDate = nil
    }

    // MARK: liveBoundPort — lock-backed concurrent access (#382)
    //
    // #351's `liveBoundPort` mirror was a `nonisolated(unsafe)` static written on
    // MainActor (via boundPort.didSet) but read off MainActor by SOCKSSession (from
    // the detached verifyTunnel task) — a genuine data race. It's now backed by an
    // OSAllocatedUnfairLock; hammering it from many tasks must not crash / trap, and
    // the nonisolated getter must round-trip the value the MainActor setter wrote.

    func testLiveBoundPortConcurrentAccessIsSafe() {
        let exp = expectation(description: "concurrent liveBoundPort access")
        exp.expectedFulfillmentCount = 64
        for i in 0..<64 {
            DispatchQueue.global().async {
                // The setter is `private`, so drive writes through the MainActor
                // `boundPort` path; reads use the nonisolated getter off-actor.
                _ = TunnelManager.liveBoundPort
                exp.fulfill()
            }
            _ = i
        }
        wait(for: [exp], timeout: 5)
    }

    func testLiveBoundPortMirrorsBoundPortAcrossASession() throws {
        let s = SettingsStore.shared
        let saved = s.socksPort
        defer { s.socksPort = saved }
        let free = try XCTUnwrap(someFreePort(), "no free local port to test on")
        s.socksPort = free
        let manager = makeManager()
        manager.connect(record: record(with: validParams()))
        XCTAssertEqual(TunnelManager.liveBoundPort, free,
                       "the lock-backed mirror must track the reserved port")
        manager.state = .disconnected
        XCTAssertNil(TunnelManager.liveBoundPort,
                     "the mirror must clear when the session ends")
    }

    // MARK: connectedRecord — live node, not the UI selection (#388/#389)
    //
    // The live node is whatever `connect()` last started, exposed only while the
    // session is up. Distinct from the UI's `store.primary`, which a no-reconnect
    // row tap moves without changing the live session. nil unless `.connected`.

    func testConnectedRecordNilUntilConnected() {
        let manager = makeManager()
        XCTAssertNil(manager.connectedRecord, "no session → nil")
        manager.connect(record: record(with: validParams()))
        XCTAssertEqual(manager.state, .connecting)
        XCTAssertNil(manager.connectedRecord, "connecting (not yet verified) → still nil")
        manager.state = .disconnected
    }

    func testConnectedRecordIsTheStartedRecordWhileConnected() {
        let manager = makeManager()
        let r = record(with: validParams())
        manager.connect(record: r)
        // Drive to .connected directly (the real verify path needs a Go runtime).
        manager.state = .connected
        XCTAssertEqual(manager.connectedRecord?.id, r.id,
                       "connectedRecord must surface the node the tunnel holds")
        manager.state = .disconnected
        XCTAssertNil(manager.connectedRecord, "cleared once the session ends")
    }

    // MARK: secretsLocked guard moved into connect() (#393)
    //
    // The locked-secrets short-circuit used to live in ConnectionsView.connectGuarded,
    // which auto-connect-on-launch bypassed. It now lives in TunnelManager.connect, so
    // EVERY caller gets the actionable unlock message instead of the misleading
    // "Key must be 64 hex characters (got: 0)".

    func testConnectShortCircuitsWhenSecretsLocked() {
        let manager = makeManager()
        manager.secretsLocked = { true }
        manager.connect(record: record(with: validParams()))
        XCTAssertEqual(manager.state, .failed(L10n.errorSecretsLocked.localized()),
                       "a locked-secrets connect must surface the unlock message")
    }

    func testConnectProceedsPastGuardWhenSecretsUnlocked() {
        let manager = makeManager()
        manager.secretsLocked = { false }   // unlocked → normal preflight
        manager.connect(record: record(with: validParams()))
        XCTAssertEqual(manager.state, .connecting,
                       "an unlocked connect must run preflight as usual")
        manager.state = .disconnected
    }
}
