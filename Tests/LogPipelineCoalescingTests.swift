import XCTest
@testable import olcrtc_ios

// #332: the log pipeline used to freeze the UI — two synchronous file writes
// per line on the main actor plus a per-line `revision` bump that re-rendered
// the whole Logs tab. This file covers the pieces that fix it and stay
// unit-testable:
//   - `LogUpdateCoalescer`: the pure leading+trailing throttle behind the
//     `revision` bumps (the caller supplies `now`, so tests are deterministic);
//   - `LogStore`: a burst of `log()` calls produces few revision bumps but
//     loses no lines, and redaction happens before the line is buffered (the
//     same redacted string is what `log()` hands the file writer, so an
//     unredacted line can't reach disk either);
//   - `LogRendering.capped`: the rendered-line cap keeps the newest lines and
//     never touches the underlying buffer.

@MainActor
final class LogPipelineCoalescingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        savedLevel = SettingsStore.shared.logLevel
        savedBuffer = SettingsStore.shared.logBufferSize
        SettingsStore.shared.logLevel = .verbose
        SettingsStore.shared.logBufferSize = 5000
        LogStore.shared.clearAll()
    }

    override func tearDown() {
        LogStore.shared.clearAll()
        SettingsStore.shared.logLevel = savedLevel
        SettingsStore.shared.logBufferSize = savedBuffer
        super.tearDown()
    }
    private var savedLevel: LogLevel = .info
    private var savedBuffer: Int = 5000

    // MARK: LogUpdateCoalescer — pure throttle rules

    func testLeadingEdgeFiresImmediately() {
        var c = LogUpdateCoalescer(minInterval: .milliseconds(250))
        let t0 = ContinuousClock.now
        XCTAssertEqual(c.recordEvent(now: t0), .fireNow,
                       "first event after a quiet period must surface at once")
    }

    func testBurstSchedulesExactlyOneTrailingFlush() {
        var c = LogUpdateCoalescer(minInterval: .milliseconds(250))
        let t0 = ContinuousClock.now
        XCTAssertEqual(c.recordEvent(now: t0), .fireNow)
        // 100 ms after the leading fire: throttled, flush due in 150 ms.
        XCTAssertEqual(c.recordEvent(now: t0.advanced(by: .milliseconds(100))),
                       .scheduleFlush(after: .milliseconds(150)))
        // Everything else inside the window is dropped.
        XCTAssertEqual(c.recordEvent(now: t0.advanced(by: .milliseconds(120))), .alreadyScheduled)
        XCTAssertEqual(c.recordEvent(now: t0.advanced(by: .milliseconds(240))), .alreadyScheduled)
        c.flushFired(now: t0.advanced(by: .milliseconds(250)))
        // The flush counts as a fire: the next event inside the window
        // schedules again rather than firing.
        XCTAssertEqual(c.recordEvent(now: t0.advanced(by: .milliseconds(300))),
                       .scheduleFlush(after: .milliseconds(200)))
    }

    func testReArmsAfterQuietPeriod() {
        var c = LogUpdateCoalescer(minInterval: .milliseconds(250))
        let t0 = ContinuousClock.now
        XCTAssertEqual(c.recordEvent(now: t0), .fireNow)
        XCTAssertEqual(c.recordEvent(now: t0.advanced(by: .milliseconds(250))), .fireNow,
                       "an event a full interval later fires immediately again")
    }

    // MARK: LogStore — burst coalescing end to end

    func testRevisionBumpsAreCoalescedUnderBurstButNoLinesAreLost() async throws {
        // Quiet period so the throttle's leading edge is re-armed regardless
        // of what earlier tests logged through the shared singleton.
        try await Task.sleep(for: .milliseconds(300))
        let before = LogStore.shared.revision

        for i in 0..<200 { LogStore.shared.log(.connection, "burst line \(i)") }
        let during = LogStore.shared.revision
        XCTAssertLessThanOrEqual(during - before, 2,
            "a 200-line storm must not bump revision per line")

        // The trailing flush surfaces the rest within the throttle interval.
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertGreaterThan(LogStore.shared.revision, during,
            "the newest lines must still reach observers after the burst")

        // Coalescing drops UI updates, never log lines.
        XCTAssertEqual(LogStore.shared.entries[.connection]?.count, 200)
    }

    // MARK: LogStore — redaction precedes buffering (and therefore disk)

    func testLogRedactsBeforeBuffering() {
        let key = String(repeating: "a", count: 64)
        LogStore.shared.log(.connection, "Encryption key: \(key)")
        let stored = LogStore.shared.entries[.connection]?.last?.text ?? ""
        XCTAssertFalse(stored.contains(key))
        XCTAssertTrue(stored.contains("<redacted-key>"))
    }

    func testLogContainerRedactsBeforeBuffering() {
        let key = String(repeating: "b", count: 64)
        LogStore.shared.logContainer(serverPrefix: "TWtest", "URI: olcrtc://x?y@z#\(key)")
        let stored = LogStore.shared.containerEntries["TWtest"]?.last?.text ?? ""
        XCTAssertFalse(stored.contains(key))
        LogStore.shared.clearContainer(serverPrefix: "TWtest")
    }

    // MARK: LogRendering — rendered-line cap

    func testCappedKeepsTheNewestLines() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let total = LogRendering.renderCap + 50
        let entries = (0..<total).map {
            LogEntry(date: t.addingTimeInterval(Double($0)), category: .connection,
                     text: "line \($0)", seq: $0)
        }
        let newestFirst = LogRendering.filtered(entries, search: "")
        let capped = LogRendering.capped(newestFirst)
        XCTAssertEqual(capped.count, LogRendering.renderCap)
        XCTAssertEqual(capped.first?.text, "line \(total - 1)", "newest line must survive the cap")
        XCTAssertEqual(capped.last?.text, "line 50", "exactly the oldest 50 are dropped")
    }

    func testCappedLeavesSmallListsAlone() {
        let entries = [LogEntry(category: .connection, text: "only")]
        XCTAssertEqual(LogRendering.capped(entries).map(\.text), ["only"])
    }
}
