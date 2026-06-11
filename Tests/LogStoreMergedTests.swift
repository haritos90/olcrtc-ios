import XCTest
@testable import olcrtc_ios

// #294: Logs reverted to per-source tabs (Connection / Diagnostics / VPS /
// Container) — there's no merged stream to test anymore. This file (kept
// under its historical name so history stays linkable) now covers the pure
// pieces that still back the per-tab views: severity classification
// (colour-coding, #276), the dated timestamp format (#277), parsing the
// Go-stamped container/server lines (#278), per-category buffers, and the
// per-server container-log buffers/files (#295).

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

    // MARK: per-category buffers (#294)

    func testLogAppendsToItsOwnCategoryOnly() {
        LogStore.shared.log(.connection, "conn line")
        LogStore.shared.log(.diagnostics, "diag line")
        LogStore.shared.log(.provisioning, "vps line")

        XCTAssertEqual(LogStore.shared.entries[.connection]?.map(\.text), ["conn line"])
        XCTAssertEqual(LogStore.shared.entries[.diagnostics]?.map(\.text), ["diag line"])
        XCTAssertEqual(LogStore.shared.entries[.provisioning]?.map(\.text), ["vps line"])
    }

    // MARK: log() honours explicit level + carries category (#276)

    func testLogStoresExplicitLevelAndCategory() {
        LogStore.shared.log(.diagnostics, "forced error", level: .error)
        let entry = LogStore.shared.entries[.diagnostics]?.last
        XCTAssertEqual(entry?.text, "forced error")
        XCTAssertEqual(entry?.level, .error)
        XCTAssertEqual(entry?.category, .diagnostics)
    }

    func testLogInfersLevelWhenNotGiven() {
        LogStore.shared.log(.connection, "✗ MobileStart: boom")
        XCTAssertEqual(LogStore.shared.entries[.connection]?.last?.level, .error)
    }

    // MARK: per-server container logs (#295)

    func testLogContainerAppendsToItsOwnServerBuffer() {
        LogStore.shared.startContainerSession(serverPrefix: "TWmsk1")
        LogStore.shared.startContainerSession(serverPrefix: "TWspb2")
        LogStore.shared.clearContainer(serverPrefix: "TWmsk1")
        LogStore.shared.clearContainer(serverPrefix: "TWspb2")

        LogStore.shared.logContainer(serverPrefix: "TWmsk1", "from msk1")
        LogStore.shared.logContainer(serverPrefix: "TWspb2", "from spb2")

        XCTAssertEqual(LogStore.shared.containerEntries["TWmsk1"]?.map(\.text), ["from msk1"])
        XCTAssertEqual(LogStore.shared.containerEntries["TWspb2"]?.map(\.text), ["from spb2"])
    }

    func testClearAllAlsoClearsContainerBuffers() {
        LogStore.shared.startContainerSession(serverPrefix: "TWmsk1")
        LogStore.shared.logContainer(serverPrefix: "TWmsk1", "line")
        XCTAssertFalse(LogStore.shared.containerEntries["TWmsk1"]?.isEmpty ?? true)

        LogStore.shared.clearAll()
        XCTAssertTrue(LogStore.shared.containerEntries["TWmsk1"]?.isEmpty ?? true)
    }

    func testNoteContainerTargetCarriesServerPrefix() {
        let id = UUID()
        LogStore.shared.noteContainerTarget(hostID: id, containerName: "olcrtc", serverPrefix: "TWmsk1")
        XCTAssertEqual(LogStore.shared.lastContainerTarget?.hostID, id)
        XCTAssertEqual(LogStore.shared.lastContainerTarget?.containerName, "olcrtc")
        XCTAssertEqual(LogStore.shared.lastContainerTarget?.serverPrefix, "TWmsk1")
    }

    // MARK: LogRendering (#294 — replaces the old merged-stream rendering)

    func testLogRenderingFiltersBySearchAndIsNewestFirst() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = [
            LogEntry(date: t, category: .connection, text: "older"),
            LogEntry(date: t.addingTimeInterval(1), category: .connection, text: "newer match"),
        ]
        let all = LogRendering.filtered(entries, search: "")
        XCTAssertEqual(all.map(\.text), ["newer match", "older"])

        let filtered = LogRendering.filtered(entries, search: "match")
        XCTAssertEqual(filtered.map(\.text), ["newer match"])
    }
}
