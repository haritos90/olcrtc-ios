import XCTest
@testable import olcrtc_ios

// #259: pure-logic tests for the single-source VPS display reducer introduced in
// #258 (HostBase / HostOp / HostDisplay + their transitions). These lock in the
// invariants that stop the Manage-VPS status from "jumping":
//   • a probe result is the ONLY thing that sets the base (terminalBase),
//   • while an op runs the card shows the PREVIOUS base, never the target,
//   • phases advance forward only (and cap at the last milestone),
//   • a failure carries previousBase so Retry restores it.
// The reducer is a pure value type — no SwiftUI host or provisioner needed.

final class HostDisplayTests: XCTestCase {

    // MARK: HostBase(VPSReadinessState) mapping

    func testReadinessMapsToBase() {
        XCTAssertEqual(HostBase(.noPodman), .noPodman)
        XCTAssertEqual(HostBase(.noImage), .noImage)
        XCTAssertEqual(HostBase(.imageReady), .imageReady)
        XCTAssertEqual(HostBase(.containerStopped("x")), .stopped)
        XCTAssertEqual(HostBase(.containerRunning("x")), .running)
    }

    func testHasContainerOnlyForStoppedOrRunning() {
        XCTAssertTrue(HostBase.running.hasContainer)
        XCTAssertTrue(HostBase.stopped.hasContainer)
        for b in [HostBase.unknown, .noPodman, .noImage, .imageReady] {
            XCTAssertFalse(b.hasContainer, "\(b) must not report a container")
        }
    }

    func testToneVocabulary() {
        XCTAssertEqual(HostBase.unknown.tone, .unknown)
        XCTAssertEqual(HostBase.noPodman.tone, .unknown)
        XCTAssertEqual(HostBase.noImage.tone, .progress)   // amber: podman ok, image pending
        XCTAssertEqual(HostBase.imageReady.tone, .ok)
        XCTAssertEqual(HostBase.running.tone, .ok)
        XCTAssertEqual(HostBase.stopped.tone, .warn)
    }

    // MARK: HostBase.seed (pre-probe — never asserts running)

    func testSeedNeverAssertsRunning() {
        XCTAssertEqual(HostBase.seed(lastContainerName: nil), .unknown)
        XCTAssertEqual(HostBase.seed(lastContainerName: "olcrtc-server-abc"), .stopped)
    }

    // MARK: HostOp.target / phases

    func testOpTargets() {
        XCTAssertNil(HostOp.check.target)        // status probe → keep base
        XCTAssertNil(HostOp.reboot.target)       // host going down → keep base
        XCTAssertEqual(HostOp.install.target, .running)
        XCTAssertEqual(HostOp.start.target, .running)
        XCTAssertEqual(HostOp.reconfigure.target, .running)
        XCTAssertEqual(HostOp.update.target, .running)
        XCTAssertEqual(HostOp.stop.target, .stopped)
        XCTAssertEqual(HostOp.uninstall.target, .imageReady)
        XCTAssertEqual(HostOp.deepUninstall.target, .noPodman)
    }

    func testEveryOpHasPhasesAndVerb() {
        let ops: [HostOp] = [.check, .install, .start, .stop, .reconfigure,
                             .update, .uninstall, .deepUninstall, .reboot]
        for op in ops {
            XCTAssertGreaterThanOrEqual(op.stepCount, 2, "\(op) needs ≥2 steps to size the bar")
            XCTAssertFalse(op.verb.isEmpty, "\(op) needs a verb")
        }
    }

    // MARK: start — shows the PREVIOUS base, never the optimistic target

    func testStartShowsPreviousBaseNotTarget() {
        // "Start" resolves to .running, but while running from a .stopped base the
        // card must still report .stopped — the optimistic target is never shown.
        let d = HostDisplay.start(.start, from: .stopped)
        XCTAssertTrue(d.isRunning)
        XCTAssertEqual(d.base, .stopped)
        guard case .running(let op, let phase, let note, let prev) = d else {
            return XCTFail("start() must produce .running")
        }
        XCTAssertEqual(op, .start)
        XCTAssertEqual(phase, 0)
        XCTAssertEqual(note, L10n.vpsConnecting.localized())
        XCTAssertEqual(prev, .stopped)
    }

    // MARK: advanced — monotonic, capped, preserves previousBase

    func testAdvanceIsMonotonicAndCapped() {
        var d = HostDisplay.start(.install, from: .imageReady)
        let total = HostOp.install.stepCount
        for i in 1...(total + 5) {            // advance well past the milestone count
            d = d.advanced(note: "step \(i)")
        }
        guard case .running(_, let phase, let note, let prev) = d else {
            return XCTFail("still running")
        }
        XCTAssertEqual(phase, total - 1, "phase caps at the last milestone")
        XCTAssertEqual(note, "step \(total + 5)", "note tracks the latest message")
        XCTAssertEqual(prev, .imageReady, "previous base preserved across phases")
    }

    func testAdvanceNeverGoesBackward() {
        var d = HostDisplay.start(.update, from: .running)
        var last = -1
        for i in 1...10 {
            d = d.advanced(note: "m\(i)")
            guard case .running(_, let phase, _, _) = d else { return XCTFail("not running") }
            XCTAssertGreaterThanOrEqual(phase, last, "phase must never decrease")
            last = phase
        }
    }

    func testAdvanceOnNonRunningIsNoOp() {
        let base = HostDisplay.base(.running)
        XCTAssertEqual(base.advanced(note: "x"), base)
    }

    // MARK: terminalBase — the probe is authoritative (single terminal assignment)

    func testTerminalBaseProbeWins() {
        // Optimistic target was .running, but the probe came back .stopped → the
        // probe wins. This is the exact "no jump" guarantee.
        XCTAssertEqual(HostDisplay.terminalBase(op: .start, probed: .stopped, previous: .running),
                       .stopped)
    }

    func testTerminalBaseFallsBackToTargetThenPrevious() {
        // No probe (op didn't probe) → nominal target.
        XCTAssertEqual(HostDisplay.terminalBase(op: .stop, probed: nil, previous: .running), .stopped)
        // No probe and no target (reboot) → keep the previous base.
        XCTAssertEqual(HostDisplay.terminalBase(op: .reboot, probed: nil, previous: .running), .running)
    }

    // MARK: failure carries previousBase; Retry restores it

    func testFailureCarriesPreviousBaseAndNote() {
        let running = HostDisplay.start(.start, from: .running).advanced(note: "Verifying")
        let failed = running.failed(message: "container exited")
        guard case .failed(let op, let phase, let message, let prev) = failed else {
            return XCTFail("failed() must produce .failed")
        }
        XCTAssertEqual(op, .start)
        XCTAssertEqual(phase, "Verifying")          // the note where it failed
        XCTAssertEqual(message, "container exited")
        XCTAssertEqual(prev, .running)
        XCTAssertEqual(failed.base, .running)       // base under a failure = the previous base
    }

    func testRetryRestoresPreviousBase() {
        let failed = HostDisplay.start(.install, from: .imageReady).failed(message: "ssh timeout")
        guard let restored = failed.retryBase() else {
            return XCTFail("retryBase() must restore the previous base from a failure")
        }
        XCTAssertEqual(restored, .base(.imageReady))
    }

    func testRetryBaseNilWhenNotFailed() {
        XCTAssertNil(HostDisplay.base(.running).retryBase())
        XCTAssertNil(HostDisplay.start(.check, from: .unknown).retryBase())
    }

    func testFailedOnNonRunningIsNoOp() {
        let base = HostDisplay.base(.stopped)
        XCTAssertEqual(base.failed(message: "x"), base)
    }
}
