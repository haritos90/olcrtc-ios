import XCTest
@testable import olcrtc_ios

// Pure helpers behind three reliability/diagnostics features:
//   #438 jittered reconnect backoff, #440 wedge detection, #439 exit geo.

@MainActor
final class RecoveryGeoTests: XCTestCase {

    // MARK: #438 — jittered backoff

    func testJitterStaysWithinQuarterBelowBase() {
        for attempt in 0...6 {
            let base = TunnelManager.backoffDelaySeconds(attempt: attempt)
            for r in [0.0, 0.25, 0.5, 0.75, 0.999] {
                let d = TunnelManager.jitteredBackoffSeconds(attempt: attempt, random: r)
                XCTAssertLessThanOrEqual(d, base + 1e-9)          // never exceeds the cap
                XCTAssertGreaterThanOrEqual(d, base * 0.75 - 1e-9) // never collapses past -25%
            }
        }
    }

    func testJitterEndpointsAndClamping() {
        let base = TunnelManager.backoffDelaySeconds(attempt: 3)
        XCTAssertEqual(TunnelManager.jitteredBackoffSeconds(attempt: 3, random: 0),   base,        accuracy: 1e-9)
        XCTAssertEqual(TunnelManager.jitteredBackoffSeconds(attempt: 3, random: 1),   base * 0.75, accuracy: 1e-9)
        // out-of-range randoms clamp to [0,1]
        XCTAssertEqual(TunnelManager.jitteredBackoffSeconds(attempt: 3, random: -5),  base,        accuracy: 1e-9)
        XCTAssertEqual(TunnelManager.jitteredBackoffSeconds(attempt: 3, random: 9),   base * 0.75, accuracy: 1e-9)
    }

    // MARK: #440 — wedge detection

    func testSignatureMatching() {
        XCTAssertTrue(WedgeDetector.isFailureSignature("sid=5 openstream failed: timeout"))
        XCTAssertTrue(WedgeDetector.isFailureSignature("client reconnect attempt=2"))
        XCTAssertTrue(WedgeDetector.isFailureSignature("remote not ready"))
        XCTAssertFalse(WedgeDetector.isFailureSignature("traffic: session=abc addr=x in=1 out=2"))
        XCTAssertFalse(WedgeDetector.isFailureSignature("SOCKS5 server listening on 127.0.0.1:8808"))
    }

    func testTripsAtThresholdWithinWindow() {
        var d = WedgeDetector(threshold: 3, window: 10)
        XCTAssertFalse(d.record(line: "openstream failed", now: 100))
        XCTAssertFalse(d.record(line: "openstream failed", now: 101))
        XCTAssertTrue(d.record(line: "openstream failed", now: 102))   // 3rd within 10s → trip
    }

    func testOldFailuresPrunedOutOfWindow() {
        var d = WedgeDetector(threshold: 3, window: 10)
        XCTAssertFalse(d.record(line: "dial failed", now: 100))
        XCTAssertFalse(d.record(line: "dial failed", now: 105))
        // 100 is now outside the trailing 10s window (115-10=105), so only 2 remain.
        XCTAssertFalse(d.record(line: "dial failed", now: 115))
    }

    func testNonSignatureLinesDoNotAccumulate() {
        var d = WedgeDetector(threshold: 2, window: 10)
        XCTAssertFalse(d.record(line: "traffic: ...", now: 1))
        XCTAssertFalse(d.record(line: "handshake failed", now: 2))
        XCTAssertFalse(d.record(line: "traffic: ...", now: 3))
        XCTAssertTrue(d.record(line: "handshake failed", now: 4))     // 2 signatures → trip
    }

    func testFiresOncePerBurstThenResets() {
        var d = WedgeDetector(threshold: 2, window: 10)
        _ = d.record(line: "dial failed", now: 1)
        XCTAssertTrue(d.record(line: "dial failed", now: 2))          // trip
        XCTAssertFalse(d.record(line: "dial failed", now: 3))         // window cleared on trip
        XCTAssertTrue(d.record(line: "dial failed", now: 4))          // fresh burst trips again
    }

    // MARK: #439 — exit geo

    func testParseGeoFromIpinfoJSON() {
        let json = #"{"ip":"5.42.103.58","city":"Moscow","region":"Moscow","country":"RU","org":"AS9123 JSC TIMEWEB"}"#
        let geo = IPChecker.parseGeo(Data(json.utf8))
        XCTAssertEqual(geo, IPChecker.ExitGeo(ip: "5.42.103.58", city: "Moscow",
                                              country: "RU", org: "AS9123 JSC TIMEWEB"))
    }

    func testParseGeoNilWhenEmptyOrGarbage() {
        XCTAssertNil(IPChecker.parseGeo(Data("not json".utf8)))
        XCTAssertNil(IPChecker.parseGeo(Data("{}".utf8)))
    }

    func testExitGeoLineFormatting() {
        let full = IPChecker.exitGeoLine(.init(ip: "5.42.103.58", city: "Moscow",
                                               country: "RU", org: "AS9123 JSC TIMEWEB"))
        XCTAssertEqual(full, "→ exit = 5.42.103.58 (Moscow, RU · AS9123 JSC TIMEWEB)")
        // Sparse data still renders cleanly.
        XCTAssertEqual(IPChecker.exitGeoLine(.init(ip: "1.2.3.4", city: nil, country: "US", org: nil)),
                       "→ exit = 1.2.3.4 (US)")
        XCTAssertEqual(IPChecker.exitGeoLine(.init(ip: "1.2.3.4", city: nil, country: nil, org: nil)),
                       "→ exit = 1.2.3.4")
    }
}
