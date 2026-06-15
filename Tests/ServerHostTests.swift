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

    // #323 was: empty/all-symbol labels all collapsed to the literal "server",
    // so two such hosts collided on one log file. Now each keeps the "server"
    // base but gets a stable hash suffix, so distinct labels stay distinct.
    func testSanitizeFallsBackToServerBaseWhenEmptyOrAllSymbols() {
        XCTAssertTrue(ServerHost.sanitizeLogFilePrefix("").hasPrefix("server_"))
        XCTAssertTrue(ServerHost.sanitizeLogFilePrefix("###").hasPrefix("server_"))
        XCTAssertTrue(ServerHost.sanitizeLogFilePrefix("   ").hasPrefix("server_"))
        // Distinct all-symbol labels no longer collapse to the same prefix.
        XCTAssertNotEqual(ServerHost.sanitizeLogFilePrefix("###"),
                          ServerHost.sanitizeLogFilePrefix("@@@"))
    }

    // #323: two differently-named Cyrillic hosts must NOT collide (the original
    // bug: both → "server"). The prefix must also stay byte-stable across calls
    // so the on-disk container-log filename survives app restarts.
    func testNonASCIILabelsGetDistinctStablePrefixes() {
        // Both pure-Cyrillic (no ASCII core) → "server_<hash>". (A label with an
        // ASCII digit/letter, e.g. "Москва-1", keeps that core instead — covered
        // by testMixedASCIINonASCIILabelKeepsCoreAndDisambiguates.)
        let a = ServerHost.sanitizeLogFilePrefix("Москва")
        let b = ServerHost.sanitizeLogFilePrefix("Питер")
        XCTAssertTrue(a.hasPrefix("server_"))
        XCTAssertTrue(b.hasPrefix("server_"))
        XCTAssertNotEqual(a, b, "distinct Cyrillic names must map to distinct log prefixes")
        // Deterministic — same input, same output (not Swift's salted hashValue).
        XCTAssertEqual(a, ServerHost.sanitizeLogFilePrefix("Москва"))
        // Filesystem-safe: only ASCII alphanumerics + underscore.
        XCTAssertTrue(a.allSatisfy { ($0.isASCII && $0.isLetter) || $0.isNumber || $0 == "_" })
    }

    // #323: a label that mixes ASCII with non-ASCII keeps its readable ASCII
    // core but is still disambiguated by the hash, so "Питер msk" and
    // "Москва msk" both keep "msk" yet don't collide.
    func testMixedASCIINonASCIILabelKeepsCoreAndDisambiguates() {
        let a = ServerHost.sanitizeLogFilePrefix("Питер msk")
        let b = ServerHost.sanitizeLogFilePrefix("Москва msk")
        XCTAssertTrue(a.hasPrefix("msk_"))
        XCTAssertTrue(b.hasPrefix("msk_"))
        XCTAssertNotEqual(a, b)
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
