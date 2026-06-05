import XCTest
import Network
@testable import olcrtc_ios

// Tests for `TunnelManager.pathDecision` (#269) — the pure decision behind
// reconnect-on-network-path-change. It is factored out of `handlePathUpdate`
// precisely so it can be exercised here without constructing an `NWPath`
// (which has no public initializer). The live `NWPathMonitor` wiring and the
// debounced reconnect remain integration-only (they touch the gomobile
// singleton + a real path), consistent with the testing notes in
// `TunnelManagerStateTests`.
//
// The function maps (satisfied, primary, wasSatisfied, lastPrimary, state,
// hasActiveRecord) → NetworkPathAction. The cases below pin every branch.

final class NetworkPathDecisionTests: XCTestCase {

    // Convenience wrapper: defaults describe a healthy, satisfied Wi-Fi session
    // with a baseline already established and an active record — so each test
    // overrides only the dimension it is probing.
    private func decide(satisfied: Bool,
                        primary: NWInterface.InterfaceType? = .wifi,
                        was: Bool? = true,
                        lastPrimary: NWInterface.InterfaceType? = .wifi,
                        state: ConnectionState,
                        record: Bool = true) -> NetworkPathAction {
        TunnelManager.pathDecision(satisfied: satisfied, primary: primary,
                                   wasSatisfied: was, lastPrimary: lastPrimary,
                                   state: state, hasActiveRecord: record)
    }

    // MARK: Guards — never act

    // The very first update establishes a baseline (wasSatisfied == nil) and
    // must do nothing, even if it looks like a loss or a handoff.
    func testNoBaselineYieldsNone() {
        XCTAssertEqual(decide(satisfied: false, was: nil, state: .connected), .none)
        XCTAssertEqual(decide(satisfied: true, primary: .cellular, was: nil,
                              lastPrimary: .wifi, state: .connected), .none)
    }

    // With no active record (user never connected, or disconnected), path noise
    // is ignored — the monitor stays running but inert.
    func testNoActiveRecordYieldsNone() {
        XCTAssertEqual(decide(satisfied: false, state: .connected, record: false), .none)
        XCTAssertEqual(decide(satisfied: true, primary: .cellular, lastPrimary: .wifi,
                              state: .connected, record: false), .none)
    }

    // A down server is not a path problem: `.disconnected` and `.failed` never
    // react (the one-shot retry / user owns those).
    func testDisconnectedAndFailedYieldNone() {
        XCTAssertEqual(decide(satisfied: false, state: .disconnected), .none)
        XCTAssertEqual(decide(satisfied: true, was: false, state: .disconnected), .none)
        XCTAssertEqual(decide(satisfied: false, state: .failed("boom")), .none)
        XCTAssertEqual(decide(satisfied: true, was: false, state: .failed("boom")), .none)
    }

    // MARK: Loss → hold

    // Path lost under a live session → hold `.waitForNetwork` (no route, so
    // don't burn retries). True whether we were connected or mid-connect.
    func testLossWhileConnectedHolds() {
        XCTAssertEqual(decide(satisfied: false, state: .connected), .waitForNetwork)
    }

    func testLossWhileConnectingHolds() {
        XCTAssertEqual(decide(satisfied: false, state: .connecting), .waitForNetwork)
    }

    // Already holding and still no network → nothing new (don't re-log / re-stop).
    func testLossWhileAlreadyWaitingIsIdempotent() {
        XCTAssertEqual(decide(satisfied: false, state: .waitingForNetwork), .none)
    }

    // MARK: Regain → reconnect(.restored)

    // Network back while we were holding → reconnect.
    func testRegainFromWaitingReconnectsRestored() {
        XCTAssertEqual(decide(satisfied: true, state: .waitingForNetwork), .reconnect(.restored))
    }

    // Defensive: satisfied with a previously-unsatisfied baseline counts as a
    // regain even if state somehow stayed `.connected`.
    func testSatisfiedAfterUnsatisfiedBaselineReconnectsRestored() {
        XCTAssertEqual(decide(satisfied: true, was: false, state: .connected),
                       .reconnect(.restored))
    }

    // The "restored" branch wins over an interface diff when waiting: a regain
    // that also changed interface is still `.restored`, not `.interfaceChanged`.
    func testRegainFromWaitingWithInterfaceChangeIsRestored() {
        XCTAssertEqual(decide(satisfied: true, primary: .cellular, was: false,
                              lastPrimary: .wifi, state: .waitingForNetwork),
                       .reconnect(.restored))
    }

    // MARK: Interface swap → reconnect(.interfaceChanged)

    // Still satisfied, still connected, but the primary interface switched
    // (Wi-Fi → cellular handoff) → reconnect onto the new path.
    func testInterfaceSwapWhileConnectedReconnects() {
        XCTAssertEqual(decide(satisfied: true, primary: .cellular, lastPrimary: .wifi,
                              state: .connected),
                       .reconnect(.interfaceChanged))
    }

    // Same interface, satisfied, connected = a trivial path refresh → ignored
    // (this is the debounced-away no-op the TODO calls out).
    func testSameInterfaceRefreshIsNone() {
        XCTAssertEqual(decide(satisfied: true, primary: .wifi, lastPrimary: .wifi,
                              state: .connected),
                       .none)
    }

    // A mid-connect interface wobble is left for the in-flight attempt to
    // resolve (no thrash): `.connecting` reacts to loss, not to a swap.
    func testInterfaceSwapWhileConnectingIsNone() {
        XCTAssertEqual(decide(satisfied: true, primary: .cellular, lastPrimary: .wifi,
                              state: .connecting),
                       .none)
    }
}
