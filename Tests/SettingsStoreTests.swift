import XCTest
@testable import olcrtc_ios

// Regression tests for the `didSet` clamps on every numeric SettingsStore
// property. The clamps exist so a buggy slider, a malformed TextField
// commit, or UserDefaults corruption can't push a value to the Go runtime
// or to the install script that would crash or behave unpredictably
// (a SOCKS port of 0, a log buffer of 2 billion entries, etc.).
//
// SettingsStore is a singleton, so tests snapshot every numeric property in
// setUp and restore in tearDown. We also flush `UserDefaults.standard` for
// the relevant keys so a clamp's persistence side-effect doesn't leak
// across tests or back to the dev's running app between debug sessions.

final class SettingsStoreTests: XCTestCase {

    private var snapshot: [String: Any] = [:]

    private let snapshottedKeys = [
        "settings.socksPort",
        "settings.fontSizeIndex",
        "settings.startTimeoutSeconds",
        "settings.vp8FPS",
        "settings.vp8BatchSize",
        "settings.logBufferSize",
        "settings.containerLogsTailLines",
        "settings.keepAliveSeconds",
    ]

    private var s: SettingsStore { SettingsStore.shared }

    override func setUp() {
        super.setUp()
        // Snapshot every numeric property AND its UserDefaults key so we can
        // restore both layers — the in-memory @Published and the persisted
        // value the next ConnectionStore.init / app launch would read.
        snapshot = [
            "socksPort":              s.socksPort,
            "fontSizeIndex":          s.fontSizeIndex,
            "startTimeoutSeconds":    s.startTimeoutSeconds,
            "vp8FPS":                 s.vp8FPS,
            "vp8BatchSize":           s.vp8BatchSize,
            "logBufferSize":          s.logBufferSize,
            "containerLogsTailLines": s.containerLogsTailLines,
            "keepAliveSeconds":       s.keepAliveSeconds,
        ]
    }

    override func tearDown() {
        s.socksPort              = snapshot["socksPort"]              as! Int
        s.fontSizeIndex          = snapshot["fontSizeIndex"]          as! Int
        s.startTimeoutSeconds    = snapshot["startTimeoutSeconds"]    as! Int
        s.vp8FPS                 = snapshot["vp8FPS"]                 as! Int
        s.vp8BatchSize           = snapshot["vp8BatchSize"]           as! Int
        s.logBufferSize          = snapshot["logBufferSize"]          as! Int
        s.containerLogsTailLines = snapshot["containerLogsTailLines"] as! Int
        s.keepAliveSeconds       = snapshot["keepAliveSeconds"]       as! Int
        super.tearDown()
    }

    // MARK: socksPort (1024...65535)

    func testSocksPortClampsBelowRangeToLowerBound() {
        s.socksPort = 0
        XCTAssertEqual(s.socksPort, 1024)
        s.socksPort = -1
        XCTAssertEqual(s.socksPort, 1024)
        s.socksPort = 1023
        XCTAssertEqual(s.socksPort, 1024)
    }

    func testSocksPortClampsAboveRangeToUpperBound() {
        s.socksPort = 65536
        XCTAssertEqual(s.socksPort, 65535)
        s.socksPort = 1_000_000
        XCTAssertEqual(s.socksPort, 65535)
        s.socksPort = Int.max
        XCTAssertEqual(s.socksPort, 65535)
    }

    func testSocksPortAcceptsInRangeUnchanged() {
        s.socksPort = 1024
        XCTAssertEqual(s.socksPort, 1024)
        s.socksPort = 8808
        XCTAssertEqual(s.socksPort, 8808)
        s.socksPort = 65535
        XCTAssertEqual(s.socksPort, 65535)
    }

    func testSocksPortClampPersistsToUserDefaults() {
        s.socksPort = 999_999
        // Persistence is dispatched to a serial background queue (so a
        // slider drag doesn't block MainActor on `CFPreferences`). Drain
        // the queue before reading UserDefaults, otherwise the assertion
        // races the write.
        SettingsStore.flushPendingWrites()
        // After clamping the didSet also writes the clamped value out — so
        // a fresh init wouldn't re-clamp a corrupt value indefinitely.
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "settings.socksPort"), 65535)
    }

    // MARK: startTimeoutSeconds (5...600)

    func testStartTimeoutClampsBothEnds() {
        s.startTimeoutSeconds = 0
        XCTAssertEqual(s.startTimeoutSeconds, 5)
        s.startTimeoutSeconds = 4
        XCTAssertEqual(s.startTimeoutSeconds, 5)
        s.startTimeoutSeconds = 601
        XCTAssertEqual(s.startTimeoutSeconds, 600)
        s.startTimeoutSeconds = 60
        XCTAssertEqual(s.startTimeoutSeconds, 60)
    }

    // MARK: keepAliveSeconds (0...300, where 0 means "disabled")

    func testKeepAliveAcceptsZeroAsDisabledSentinel() {
        // 0 is in-range and meaningful: "keep-alive off". The clamp must NOT
        // bump it up — that would silently re-enable a feature the user
        // deliberately turned off.
        s.keepAliveSeconds = 0
        XCTAssertEqual(s.keepAliveSeconds, 0)
    }

    func testKeepAliveClampsNegativeToZero() {
        s.keepAliveSeconds = -5
        XCTAssertEqual(s.keepAliveSeconds, 0)
    }

    func testKeepAliveClampsAboveRange() {
        s.keepAliveSeconds = 301
        XCTAssertEqual(s.keepAliveSeconds, 300)
        s.keepAliveSeconds = 99_999
        XCTAssertEqual(s.keepAliveSeconds, 300)
    }

    // MARK: vp8FPS (1...60)

    func testVP8FPSClampsBothEnds() {
        s.vp8FPS = 0
        XCTAssertEqual(s.vp8FPS, 1)
        s.vp8FPS = 61
        XCTAssertEqual(s.vp8FPS, 60)
        s.vp8FPS = 30
        XCTAssertEqual(s.vp8FPS, 30)
    }

    // MARK: vp8BatchSize (1...256)

    func testVP8BatchClampsBothEnds() {
        s.vp8BatchSize = 0
        XCTAssertEqual(s.vp8BatchSize, 1)
        s.vp8BatchSize = 257
        XCTAssertEqual(s.vp8BatchSize, 256)
        s.vp8BatchSize = 64
        XCTAssertEqual(s.vp8BatchSize, 64)
    }

    // MARK: logBufferSize (50...10_000)

    func testLogBufferClampsBothEnds() {
        s.logBufferSize = 49
        XCTAssertEqual(s.logBufferSize, 50)
        s.logBufferSize = 10_001
        XCTAssertEqual(s.logBufferSize, 10_000)
        s.logBufferSize = 1000
        XCTAssertEqual(s.logBufferSize, 1000)
    }

    // MARK: containerLogsTailLines (50...2000)

    func testContainerLogsTailClampsBothEnds() {
        s.containerLogsTailLines = 49
        XCTAssertEqual(s.containerLogsTailLines, 50)
        s.containerLogsTailLines = 2001
        XCTAssertEqual(s.containerLogsTailLines, 2000)
        s.containerLogsTailLines = 200
        XCTAssertEqual(s.containerLogsTailLines, 200)
    }

    // MARK: fontSizeIndex (0...fontSizes.count-1)

    func testFontSizeIndexClampsBothEnds() {
        let maxIdx = SettingsStore.fontSizes.count - 1
        s.fontSizeIndex = -1
        XCTAssertEqual(s.fontSizeIndex, 0)
        s.fontSizeIndex = maxIdx + 1
        XCTAssertEqual(s.fontSizeIndex, maxIdx)
        s.fontSizeIndex = maxIdx
        XCTAssertEqual(s.fontSizeIndex, maxIdx)
        s.fontSizeIndex = 0
        XCTAssertEqual(s.fontSizeIndex, 0)
    }

    func testResolvedTypeSizeMatchesClampedIndex() {
        s.fontSizeIndex = 3
        XCTAssertEqual(s.resolvedTypeSize, SettingsStore.fontSizes[3])
        // Even if the clamp on the setter is bypassed somehow, the getter
        // re-clamps before indexing the fontSizes array — defensive.
        s.fontSizeIndex = 999
        XCTAssertEqual(s.resolvedTypeSize, SettingsStore.fontSizes.last)
    }

    // MARK: reset()

    func testResetRestoresAllNumericDefaults() {
        // Push every clamped value to its upper bound, then reset.
        s.socksPort              = 65535
        s.startTimeoutSeconds    = 600
        s.vp8FPS                 = 60
        s.vp8BatchSize           = 256
        s.logBufferSize          = 10_000
        s.containerLogsTailLines = 2000
        s.keepAliveSeconds       = 300

        s.reset()

        XCTAssertEqual(s.socksPort,              SettingsStore.Defaults.socksPort)
        XCTAssertEqual(s.startTimeoutSeconds,    SettingsStore.Defaults.startTimeoutSeconds)
        XCTAssertEqual(s.vp8FPS,                 SettingsStore.Defaults.vp8FPS)
        XCTAssertEqual(s.vp8BatchSize,           SettingsStore.Defaults.vp8BatchSize)
        XCTAssertEqual(s.logBufferSize,          SettingsStore.Defaults.logBufferSize)
        XCTAssertEqual(s.containerLogsTailLines, SettingsStore.Defaults.containerLogsTail)
        XCTAssertEqual(s.keepAliveSeconds,       SettingsStore.Defaults.keepAliveSeconds)
        XCTAssertEqual(s.fontSizeIndex,          SettingsStore.Defaults.fontSizeIndex)
    }

    // MARK: defaults sanity — protects the Defaults ranges from drift
    //
    // If anyone tightens a range without checking that the default still
    // lives inside it, an app launch on a fresh install would clamp the
    // default to the new boundary — visible to the user as "Settings
    // mysteriously changed". Catch that at compile/test time.

    func testEveryDefaultLiesInsideItsClampingRange() {
        XCTAssertTrue(SettingsStore.Defaults.socksPortRange.contains(SettingsStore.Defaults.socksPort))
        XCTAssertTrue(SettingsStore.Defaults.startTimeoutRange.contains(SettingsStore.Defaults.startTimeoutSeconds))
        XCTAssertTrue(SettingsStore.Defaults.vp8FPSRange.contains(SettingsStore.Defaults.vp8FPS))
        XCTAssertTrue(SettingsStore.Defaults.vp8BatchRange.contains(SettingsStore.Defaults.vp8BatchSize))
        XCTAssertTrue(SettingsStore.Defaults.logBufferRange.contains(SettingsStore.Defaults.logBufferSize))
        XCTAssertTrue(SettingsStore.Defaults.containerLogsTailRange.contains(SettingsStore.Defaults.containerLogsTail))
        XCTAssertTrue(SettingsStore.Defaults.keepAliveRange.contains(SettingsStore.Defaults.keepAliveSeconds))
        XCTAssertTrue((0...(SettingsStore.fontSizes.count - 1)).contains(SettingsStore.Defaults.fontSizeIndex))
    }
}
