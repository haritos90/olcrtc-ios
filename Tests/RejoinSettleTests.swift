import XCTest
@testable import olcrtc_ios

// Tests for `OlcrtcEngine.rejoinSettleMs` (#271) — the carrier-aware delay the
// engine waits after `MobileStop()` before re-joining the *same* room on an
// auto-reconnect, so the previous session's MUC presence clears first. Pure
// mapping (no Mobile runtime touched), so it's safe to call as a static here.
//
// The actual sleep + `isReconnect` gating live in `OlcrtcEngine.start`, which is
// integration-only (drives the gomobile singleton); this pins the policy values.

final class RejoinSettleTests: XCTestCase {

    // Jitsi/Telemost are XMPP-MUC: presence-unavailable propagates with a lag, so
    // they need the longer settle to avoid colliding with the ghost participant.
    func testJitsiAndTelemostGetTheLongerSettle() {
        XCTAssertEqual(OlcrtcEngine.rejoinSettleMs(carrier: "jitsi"), 3000)
        XCTAssertEqual(OlcrtcEngine.rejoinSettleMs(carrier: "telemost"), 3000)
    }

    // Everything else (wbstream today, plus any future carrier) settles less.
    func testOtherCarriersGetTheDefaultSettle() {
        XCTAssertEqual(OlcrtcEngine.rejoinSettleMs(carrier: "wbstream"), 1500)
        XCTAssertEqual(OlcrtcEngine.rejoinSettleMs(carrier: "something-new"), 1500)
        XCTAssertEqual(OlcrtcEngine.rejoinSettleMs(carrier: ""), 1500)
    }

    // Carrier identifiers must match case-insensitively — the URI / matrix can
    // surface them in any casing.
    func testCarrierMatchIsCaseInsensitive() {
        XCTAssertEqual(OlcrtcEngine.rejoinSettleMs(carrier: "Jitsi"), 3000)
        XCTAssertEqual(OlcrtcEngine.rejoinSettleMs(carrier: "TELEMOST"), 3000)
        XCTAssertEqual(OlcrtcEngine.rejoinSettleMs(carrier: "WbStream"), 1500)
    }

    // The invariant the task rests on: MUC carriers settle *longer* than the
    // default, and every settle is a positive, finite wait.
    func testMucCarriersSettleLongerThanDefault() {
        let muc = OlcrtcEngine.rejoinSettleMs(carrier: "jitsi")
        let other = OlcrtcEngine.rejoinSettleMs(carrier: "wbstream")
        XCTAssertGreaterThan(muc, other)
        XCTAssertGreaterThan(other, 0)
    }
}
