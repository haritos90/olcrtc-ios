import XCTest
@testable import olcrtc_ios

// #432: app-lifecycle logging + keep-alive resilience. Verifies the pure helpers
// that make background behaviour legible in the connection log — the entry line
// keyed on live state (loud when connected without keep-alive), the foreground
// duration line, and the audio-interruption decision the keeper acts on.

@MainActor
final class BackgroundLifecycleTests: XCTestCase {

    // MARK: background-entry message

    func testBackgroundEnterConnectedWithKeeperIsCalm() {
        let msg = TunnelManager.backgroundEnterMessage(connected: true, keeperRunning: true)
        XCTAssertTrue(msg.contains("keep-alive ON"))
        XCTAssertFalse(msg.contains("⚠"))
    }

    func testBackgroundHeartbeatMessageStatesElapsedAndKeeper() {
        let on = TunnelManager.backgroundHeartbeatMessage(elapsedSeconds: 180, keeperRunning: true)
        XCTAssertTrue(on.contains("+3m"))
        XCTAssertTrue(on.contains("keep-alive ON"))
        let off = TunnelManager.backgroundHeartbeatMessage(elapsedSeconds: 45, keeperRunning: false)
        XCTAssertTrue(off.contains("keep-alive OFF"))
    }

    func testBackgroundEnterConnectedWithoutKeeperWarns() {
        let msg = TunnelManager.backgroundEnterMessage(connected: true, keeperRunning: false)
        XCTAssertTrue(msg.contains("⚠"))
        XCTAssertTrue(msg.contains("Background audio"))     // tells the user the fix
        // Classified as a warning by the same rules the Logs tab colours by.
        XCTAssertEqual(LogStore.classify(msg), .warn)
    }

    func testBackgroundEnterDisconnected() {
        let msg = TunnelManager.backgroundEnterMessage(connected: false, keeperRunning: false)
        XCTAssertTrue(msg.contains("not connected"))
        XCTAssertFalse(msg.contains("⚠"))
    }

    // MARK: foreground-return + duration

    func testForegroundMessageIncludesDuration() {
        XCTAssertTrue(TunnelManager.foregroundEnterMessage(backgroundSeconds: 92).contains("1m32s"))
    }

    func testFormatBackgroundDuration() {
        XCTAssertEqual(TunnelManager.formatBackgroundDuration(0), "0s")
        XCTAssertEqual(TunnelManager.formatBackgroundDuration(45), "45s")
        XCTAssertEqual(TunnelManager.formatBackgroundDuration(60), "1m")
        XCTAssertEqual(TunnelManager.formatBackgroundDuration(92), "1m32s")
        XCTAssertEqual(TunnelManager.formatBackgroundDuration(3600), "1h")
        XCTAssertEqual(TunnelManager.formatBackgroundDuration(3660), "1h1m")
        XCTAssertEqual(TunnelManager.formatBackgroundDuration(3900), "1h5m")
    }

    func testFormatBackgroundDurationClampsNegative() {
        XCTAssertEqual(TunnelManager.formatBackgroundDuration(-5), "0s")
    }

    // MARK: keeper interruption decision

    func testInterruptionActionPausesOnBegan() {
        XCTAssertEqual(BackgroundRuntimeKeeper.interruptionAction(began: true, shouldResume: false), .pause)
        XCTAssertEqual(BackgroundRuntimeKeeper.interruptionAction(began: true, shouldResume: true), .pause)
    }

    func testInterruptionActionResumesWhenHinted() {
        XCTAssertEqual(BackgroundRuntimeKeeper.interruptionAction(began: false, shouldResume: true), .resume)
    }

    func testInterruptionActionIgnoresEndedWithoutResumeHint() {
        XCTAssertEqual(BackgroundRuntimeKeeper.interruptionAction(began: false, shouldResume: false), .ignore)
    }
}
