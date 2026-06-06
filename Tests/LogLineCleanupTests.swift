import XCTest
@testable import olcrtc_ios

// #287: log-line cleanups surfaced by the 2026-06 capture — the keep-alive
// "active −N s ago" going negative, and the tunnel-verify "bad URL" that really
// means the SOCKS proxy wasn't ready.

final class LogLineCleanupTests: XCTestCase {

    // MARK: keep-alive skip wording

    func testPositiveAgeReadsAgo() {
        let s = TunnelManager.keepAliveSkipNote(ageSeconds: 12)
        XCTAssertTrue(s.contains("12s ago"))
        // No negated number (note "Keep-alive" legitimately contains a hyphen, so
        // check for a minus glued to the digits, not any "-").
        XCTAssertFalse(s.contains("-12"))
        XCTAssertFalse(s.contains("−12"))   // U+2212
    }

    func testFutureMarkerNeverGoesNegative() {
        // noteActivity(forAtLeast:) parks the marker ahead → a naive age is negative.
        let s = TunnelManager.keepAliveSkipNote(ageSeconds: -30)
        XCTAssertFalse(s.contains("-30"))
        XCTAssertFalse(s.contains("−30"))
        XCTAssertTrue(s.contains("30s reserved"))
    }

    // MARK: verify failure reason

    func testBadURLBecomesProxyNotReady() {
        XCTAssertEqual(TunnelManager.verifyFailureReason(URLError(.badURL)), "proxy not ready")
        XCTAssertEqual(TunnelManager.verifyFailureReason(URLError(.unsupportedURL)), "proxy not ready")
    }

    func testOtherErrorsPassThrough() {
        let e = URLError(.timedOut)
        XCTAssertEqual(TunnelManager.verifyFailureReason(e), e.localizedDescription)
        XCTAssertNotEqual(TunnelManager.verifyFailureReason(e), "proxy not ready")
    }
}
