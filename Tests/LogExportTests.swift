import XCTest
@testable import olcrtc_ios

// #432: self-describing log exports. Verifies the pure formatting helpers that
// make an exported log identifiable from BOTH its filename and its content —
// filename shape, filesystem-safe tokens, and the header block carrying the app
// version+build, device/OS, line count and capture window.

final class LogExportTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!
    // 2026-06-18 20:56:41 UTC
    private var fixedDate: Date {
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = 18
        c.hour = 20; c.minute = 56; c.second = 41
        c.timeZone = utc
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    // MARK: filename

    func testFileNameShape() {
        let name = LogExport.fileName(label: "connection", version: "1.3", build: "263",
                                      date: fixedDate, timeZone: utc)
        XCTAssertEqual(name, "olcrtc-connection-v1-3-b263-20260618-205641.log")
    }

    func testCombinedFileNameShape() {
        let name = LogExport.combinedFileName(version: "1.3", build: "263",
                                              date: fixedDate, timeZone: utc)
        XCTAssertEqual(name, "olcrtc-all-logs-v1-3-b263-20260618-205641.log")
    }

    func testFileStampIsCompactAndColonFree() {
        let stamp = LogExport.fileStamp(fixedDate, timeZone: utc)
        XCTAssertEqual(stamp, "20260618-205641")
        XCTAssertFalse(stamp.contains(":"))
        XCTAssertFalse(stamp.contains(" "))
    }

    // MARK: safeToken

    func testSafeTokenLowercasesAndStripsUnsafeChars() {
        XCTAssertEqual(LogExport.safeToken("My Server #1"), "my-server-1")
        XCTAssertEqual(LogExport.safeToken("prod.container/log"), "prod-container-log")
        XCTAssertEqual(LogExport.safeToken("  spaced  "), "spaced")
    }

    func testSafeTokenCollapsesRunsAndTrimsDashes() {
        XCTAssertEqual(LogExport.safeToken("a---b   c"), "a-b-c")
        XCTAssertEqual(LogExport.safeToken("!!!"), "log")   // empty → fallback
        XCTAssertEqual(LogExport.safeToken("Привет"), "log") // non-ASCII dropped → fallback
    }

    func testSafeTokenNeverEmpty() {
        XCTAssertFalse(LogExport.safeToken("").isEmpty)
    }

    // MARK: header

    func testHeaderCarriesIdentity() {
        let header = LogExport.header(
            title: "Connection", fileName: "connection.log",
            version: "1.3", build: "263",
            device: "iPhone15,2", os: "iOS 18.5",
            lineCount: 412, first: fixedDate, last: fixedDate,
            exportedAt: fixedDate, timeZone: utc)
        // The whole point: version, build, device, OS, count all present and legible.
        XCTAssertTrue(header.contains("olcrtc-ios 1.3 (build 263)"))
        XCTAssertTrue(header.contains("Connection"))
        XCTAssertTrue(header.contains("connection.log"))
        XCTAssertTrue(header.contains("iPhone15,2 · iOS 18.5"))
        XCTAssertTrue(header.contains("412"))
        XCTAssertTrue(header.contains("newest first"))
        XCTAssertTrue(header.contains("2026-06-18 20:56:41"))
    }

    func testHeaderEmptyRangeWhenNoDates() {
        let header = LogExport.header(
            title: "Diagnostics", fileName: "diagnostics.log",
            version: "1.3", build: "263", device: "x", os: "y",
            lineCount: 0, first: nil, last: nil,
            exportedAt: fixedDate, timeZone: utc)
        XCTAssertTrue(header.contains("(empty)"))
    }
}
