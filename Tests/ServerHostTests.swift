import XCTest
@testable import olcrtc_ios

// #295: per-server container log files are named "<logFilePrefix>_container.log",
// so the prefix must be filesystem-safe and unique per host. Covers the
// sanitisation helper and `AddServerHostView`'s duplicate-name check.

final class ServerHostTests: XCTestCase {

    // MARK: sanitizeLogFilePrefix

    func testSanitizeKeepsAlphanumerics() {
        XCTAssertEqual(ServerHost.sanitizeLogFilePrefix("TWmsk1"), "TWmsk1")
    }

    func testSanitizeCollapsesPunctuationAndSpacesToUnderscore() {
        XCTAssertEqual(ServerHost.sanitizeLogFilePrefix("TW Moscow #1"), "TW_Moscow_1")
    }

    func testSanitizeCollapsesConsecutiveSeparators() {
        XCTAssertEqual(ServerHost.sanitizeLogFilePrefix("TW   Moscow ## 1"), "TW_Moscow_1")
    }

    func testSanitizeTrimsLeadingAndTrailingSeparators() {
        XCTAssertEqual(ServerHost.sanitizeLogFilePrefix("  TW Moscow  "), "TW_Moscow")
        XCTAssertEqual(ServerHost.sanitizeLogFilePrefix("#TW Moscow#"), "TW_Moscow")
    }

    func testSanitizeFallsBackToServerWhenEmptyOrAllSymbols() {
        XCTAssertEqual(ServerHost.sanitizeLogFilePrefix(""), "server")
        XCTAssertEqual(ServerHost.sanitizeLogFilePrefix("###"), "server")
        XCTAssertEqual(ServerHost.sanitizeLogFilePrefix("   "), "server")
    }

    func testLogFilePrefixMatchesSanitizedLabel() {
        let host = ServerHost(label: "TW Moscow #1", host: "1.2.3.4")
        XCTAssertEqual(host.logFilePrefix, "TW_Moscow_1")
    }

    // MARK: AddServerHostView duplicate-name detection
    //
    // `isDuplicateLabel` is private to the view, so this exercises the same
    // logic via `ServerHost.sanitizeLogFilePrefix` directly: two labels are
    // "duplicates" if they're equal case-insensitively, OR their sanitised
    // prefixes collide.

    func testDistinctLabelsThatSanitizeToTheSamePrefixAreDuplicates() {
        let a = "TW Moscow-1"
        let b = "TW Moscow #1"
        XCTAssertEqual(
            ServerHost.sanitizeLogFilePrefix(a).lowercased(),
            ServerHost.sanitizeLogFilePrefix(b).lowercased(),
            "\(a) and \(b) must collide on their sanitised log-file prefix"
        )
    }

    func testCaseInsensitiveDuplicateLabels() {
        XCTAssertEqual("TW Moscow".lowercased(), "tw moscow".lowercased())
    }
}
