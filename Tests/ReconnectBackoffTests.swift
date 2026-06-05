import XCTest
@testable import olcrtc_ios

// Tests for `TunnelManager.backoffDelaySeconds` (#270) — the capped exponential
// backoff behind the single recovery sink (`requestReconnect`). The sink/loop
// itself is integration-only (it drives the gomobile engine), but the *delay
// policy* is a pure static, so the schedule and its guardrails are pinned here.
//
// Policy: base = 2 s, cap = 60 s, so the sequence is 2, 4, 8, 16, 32, 60, 60, …
// with `maxReconnectAttempts = 6` attempts before the loop gives up.

final class ReconnectBackoffTests: XCTestCase {

    private func delay(_ n: Int) -> Double { TunnelManager.backoffDelaySeconds(attempt: n) }

    // The doubling schedule, attempt by attempt, up to the cap.
    func testDoublingSequence() {
        XCTAssertEqual(delay(0), 2,  "attempt 0 → base")
        XCTAssertEqual(delay(1), 4)
        XCTAssertEqual(delay(2), 8)
        XCTAssertEqual(delay(3), 16)
        XCTAssertEqual(delay(4), 32)
    }

    // 2·2^5 = 64 would exceed the 60 s cap → clamped.
    func testClampsAtMaxDelay() {
        XCTAssertEqual(delay(5), 60, "64 capped to 60")
        XCTAssertEqual(delay(6), 60)
        XCTAssertEqual(delay(10), 60)
    }

    // A pathologically large attempt index must not overflow `1 << shift` or
    // escape the cap — the shift is clamped internally.
    func testLargeAttemptStaysCappedAndFinite() {
        let d = delay(1_000)
        XCTAssertEqual(d, 60)
        XCTAssertTrue(d.isFinite)
    }

    // Defensive: a negative attempt clamps to the base, never negative/NaN.
    func testNegativeAttemptClampsToBase() {
        XCTAssertEqual(delay(-1), 2)
        XCTAssertEqual(delay(-100), 2)
    }

    // The schedule must be monotonically non-decreasing and bounded by the cap —
    // the property the battery-cap guarantee rests on.
    func testMonotonicNonDecreasingAndBounded() {
        var previous = 0.0
        for n in 0...12 {
            let d = delay(n)
            XCTAssertGreaterThanOrEqual(d, previous, "delay must not decrease at attempt \(n)")
            XCTAssertLessThanOrEqual(d, 60, "delay must stay within the cap at attempt \(n)")
            previous = d
        }
    }
}
