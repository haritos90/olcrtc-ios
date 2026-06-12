import XCTest
@testable import olcrtc_ios

// #341: pins the compact stat formatting used by the Manage VPS card's
// one-line metrics strip — shared-suffix hoisting ("36G/40G" → "36/40G"),
// uptime shortening ("3 days" → "3d"), and the "—" placeholders that keep
// the fixed-footprint card from collapsing when stats are unknown.
final class VPSStatFormattingTests: XCTestCase {

    func testUsageSharedSuffixHoisted() {
        XCTAssertEqual(ServersView.shortUsage("36G/40G"), "36/40G")
        XCTAssertEqual(ServersView.shortUsage("241M/2048M"), "241/2048M")
    }

    func testUsageMixedUnitsUntouched() {
        XCTAssertEqual(ServersView.shortUsage("980M/20G"), "980M/20G")
    }

    func testUsageMalformedOrMissingFallsBack() {
        XCTAssertEqual(ServersView.shortUsage("garbage"), "garbage")
        XCTAssertEqual(ServersView.shortUsage("36/40"), "36/40")   // no unit suffix
        XCTAssertEqual(ServersView.shortUsage(""), "—")
        XCTAssertEqual(ServersView.shortUsage(nil), "—")
    }

    func testUptimeShortened() {
        XCTAssertEqual(ServersView.shortUptime("3 days"), "3d")
        XCTAssertEqual(ServersView.shortUptime("1 day"), "1d")
        XCTAssertEqual(ServersView.shortUptime("35 min"), "35m")
        XCTAssertEqual(ServersView.shortUptime("4:22"), "4:22")   // <1 day form stays
        XCTAssertEqual(ServersView.shortUptime(""), "—")
        XCTAssertEqual(ServersView.shortUptime(nil), "—")
    }
}
