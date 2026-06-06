import XCTest
@testable import olcrtc_ios

// #276/#277/#278: the merged Logs stream. Covers the pure pieces that back the
// view — severity classification (colour-coding), chronological merge ordering,
// the dated timestamp format, and parsing the Go-stamped container/server lines.

@MainActor
final class LogStoreMergedTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Isolate from whatever other suites left in the shared singleton, and
        // make sure ingestion isn't gated by a stricter verbosity level.
        savedLevel = SettingsStore.shared.logLevel
        SettingsStore.shared.logLevel = .verbose
        LogStore.shared.clearAll()
    }

    override func tearDown() {
        LogStore.shared.clearAll()
        SettingsStore.shared.logLevel = savedLevel
        super.tearDown()
    }
    private var savedLevel: LogLevel = .info

    // MARK: classify (#276)

    func testEmojiPrefixesWinOverKeywords() {
        // "⚠ Network lost" contains the "lost" error keyword but the ⚠ prefix is
        // the deliberate severity → warn, not error.
        XCTAssertEqual(LogStore.classify("⚠ Network lost — waiting for connectivity"), .warn)
        XCTAssertEqual(LogStore.classify("✗ Keep-alive lost"), .error)
        XCTAssertEqual(LogStore.classify("✓ Tunnel works — traffic is flowing"), .info)
    }

    func testNoiseIsClassifiedDebugEvenWhenItSaysFailed() {
        XCTAssertEqual(LogStore.classify("[ice] INFO: Failed to send packet, network is unreachable"), .debug)
        XCTAssertEqual(LogStore.classify("traffic: session=7 addr=1.2.3.4 in=10 out=20"), .debug)
        XCTAssertEqual(LogStore.classify("[pc] WARN: stream is already closed"), .debug)
    }

    func testKeywordFallbackForEmojiLessLines() {
        XCTAssertEqual(LogStore.classify("Connection to the conferencing server lost"), .error)
        XCTAssertEqual(LogStore.classify("control missed pong on server missed_pongs=1"), .warn)
        XCTAssertEqual(LogStore.classify("session opened: id=42 device=ios"), .info)
        XCTAssertEqual(LogStore.classify("missed_pongs=3 — session closing"), .error)
    }

    // MARK: dated timestamp (#277)

    func testFormatIsDatedWithMillis() {
        let s = LogStore.format(date: Date())
        let ok = s.range(of: #"^\d{4}\.\d{2}\.\d{2} \d{2}:\d{2}:\d{2}\.\d{3}$"#,
                         options: .regularExpression) != nil
        XCTAssertTrue(ok, "expected yyyy.MM.dd HH:mm:ss.SSS, got \(s)")
    }

    // MARK: parse external (Go) timestamp (#278)

    func testParsesGoTimestampAndStripsIt() {
        let parsed = LogStore.parseExternalTimestamp("2026/06/06 12:34:56 hello world")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.rest, "hello world")
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                                from: parsed!.date)
        XCTAssertEqual(c.year, 2026); XCTAssertEqual(c.month, 6); XCTAssertEqual(c.day, 6)
        XCTAssertEqual(c.hour, 12); XCTAssertEqual(c.minute, 34); XCTAssertEqual(c.second, 56)
    }

    func testReIngestingOurOwnFormatIsANoOp() {
        let d = Date()
        let line = LogStore.format(date: d) + " already stamped"
        let parsed = LogStore.parseExternalTimestamp(line)
        XCTAssertEqual(parsed?.rest, "already stamped")
        // Round-trips to the same display string (millisecond precision retained).
        XCTAssertEqual(parsed.map { LogStore.format(date: $0.date) }, LogStore.format(date: d))
    }

    func testPlainLineHasNoTimestamp() {
        XCTAssertNil(LogStore.parseExternalTimestamp("no timestamp on this line"))
        XCTAssertNil(LogStore.parseExternalTimestamp(""))
    }

    // MARK: merged ordering (#276/#277)

    func testMergedSortsByDateAcrossCategories() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        LogStore.shared.log(.connection, "first",  date: t)
        LogStore.shared.log(.containerLogs, "second", date: t.addingTimeInterval(1))
        // A back-dated container line (parsed from an old Go stamp) must sort
        // *before* the earlier client lines, not cluster at fetch-time.
        LogStore.shared.log(.connection, "older", date: t.addingTimeInterval(-10))

        XCTAssertEqual(LogStore.shared.merged.map(\.text), ["older", "first", "second"])
    }

    func testMergedUsesSeqAsTiebreakerForSameTimestamp() {
        let t = Date(timeIntervalSince1970: 1_700_000_500)
        LogStore.shared.log(.ip, "a", date: t)
        LogStore.shared.log(.speed, "b", date: t)
        LogStore.shared.log(.ip, "c", date: t)
        // Identical timestamps → insertion order preserved via the seq tiebreaker.
        XCTAssertEqual(LogStore.shared.merged.map(\.text), ["a", "b", "c"])
    }

    // MARK: log() honours explicit level + carries source (#276)

    func testLogStoresExplicitLevelAndCategory() {
        LogStore.shared.log(.speed, "forced error", level: .error)
        let entry = LogStore.shared.merged.last
        XCTAssertEqual(entry?.text, "forced error")
        XCTAssertEqual(entry?.level, .error)
        XCTAssertEqual(entry?.category, .speed)
    }

    func testLogInfersLevelWhenNotGiven() {
        LogStore.shared.log(.connection, "✗ MobileStart: boom")
        XCTAssertEqual(LogStore.shared.merged.last?.level, .error)
    }
}
