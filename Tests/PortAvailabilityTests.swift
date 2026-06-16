import XCTest
import Darwin
@testable import olcrtc_ios

// Integration-style tests for PortAvailability.isFree.
// We bind a real TCP socket on 127.0.0.1, verify isFree flips to false,
// then close it and verify isFree returns true again.

final class PortAvailabilityTests: XCTestCase {

    // Pick a high port unlikely to clash with anything else on the test machine.
    // Seeded random per-test reduces flakiness if multiple test runs overlap.
    private var testPort: UInt16 = 0

    override func setUp() {
        super.setUp()
        testPort = UInt16.random(in: 50_000...60_000)
    }

    func testPortIsFreeWhenNothingBound() throws {
        // Tolerant of transient collisions — retry up to 5 times before skipping.
        testPort = try findFreePort()
        XCTAssertTrue(PortAvailability.isFree(testPort),
                      "Expected free port \(testPort) to report free")
    }

    func testPortIsBusyWhileBound() throws {
        // Find a free port first to avoid colliding with another process.
        testPort = try findFreePort()
        let sock = try bind127(port: testPort)
        defer { close(sock) }

        XCTAssertFalse(PortAvailability.isFree(testPort),
                       "Expected bound port \(testPort) to report busy")
    }

    func testPortBecomesFreeAfterClose() throws {
        testPort = try findFreePort()
        let sock = try bind127(port: testPort)
        XCTAssertFalse(PortAvailability.isFree(testPort))
        close(sock)

        // Without SO_REUSEADDR, the kernel may keep the port in TIME_WAIT briefly.
        // Poll up to ~1 s — in practice it's usually freed immediately.
        var free = false
        for _ in 0..<10 {
            if PortAvailability.isFree(testPort) { free = true; break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(free, "Port \(testPort) should be free shortly after close()")
    }

    // MARK: PortAvailability.state — three explicit outcomes (#300)
    //
    // #300 was: a single isFree() bool plus a SettingsView heuristic
    // ("configured port == configured tunnel port") that reported
    // "in use by tunnel" even while the tunnel was disconnected. `state`
    // now requires the caller to assert the live tunnel state explicitly
    // via `tunnelHoldsPort`.

    func testStateFreeWhenNothingBoundAndTunnelDoesNotHoldPort() throws {
        testPort = try findFreePort()
        XCTAssertEqual(PortAvailability.state(testPort, tunnelHoldsPort: false), .free)
    }

    func testStateBusyOtherWhenBoundAndTunnelDoesNotHoldPort() throws {
        testPort = try findFreePort()
        let sock = try bind127(port: testPort)
        defer { close(sock) }

        XCTAssertEqual(PortAvailability.state(testPort, tunnelHoldsPort: false), .busyOther)
    }

    func testStateBusyOursWhenTunnelHoldsPortEvenIfPortAppearsFree() throws {
        // The tunnel's own listener may not be probeable via a second bind
        // attempt depending on socket options, so this also covers the case
        // where the socket-level probe alone can't tell "ours" from "free".
        testPort = try findFreePort()
        XCTAssertEqual(PortAvailability.state(testPort, tunnelHoldsPort: true), .busyOurs)
    }

    func testStateBusyOursTakesPriorityWhenPortAlsoBoundByUs() throws {
        testPort = try findFreePort()
        let sock = try bind127(port: testPort)
        defer { close(sock) }

        // Even though the socket-level probe would report busy, the
        // tunnel-state signal is authoritative for labeling it "ours".
        XCTAssertEqual(PortAvailability.state(testPort, tunnelHoldsPort: true), .busyOurs)
    }

    // MARK: port-busy error mapping (#308)
    //
    // #308 removed nextFreePort (the auto-slide): the configured SOCKS port is now
    // always bound, and a late bind race is mapped to a clear "port busy" reason.

    func testStartErrorMapsBindInUseToPortBusy() {
        let port = 1080
        let raw = "listen tcp 127.0.0.1:1080: bind: address already in use"
        let mapped = OlcrtcEngine.startErrorReason(raw, port: port)
        XCTAssertEqual(mapped, L10n.errorPortBusy_fmt.formatted(port))
        XCTAssertNotEqual(mapped, raw)
    }

    func testStartErrorPassesOtherFailuresThrough() {
        let raw = "carrier auth failed: 403 Forbidden"
        XCTAssertEqual(OlcrtcEngine.startErrorReason(raw, port: 1080), raw)
    }

    // MARK: same-port wait-and-retry decision (#333)
    //
    // After our own disconnect the core's listener tears down asynchronously, so
    // the configured port can read busy on our ghost for a second or two. The
    // connect path waits-and-retries the SAME port — but ONLY when the port is
    // busy AND we let go of it ourselves recently. The #308 contract is intact:
    // no port sliding, and a foreign-held port still fails fast (no wait). The
    // pure verdict is `TunnelManager.shouldWaitForOwnPortRelease`.

    // #394: the verdict now also requires the busy port to be the very port our
    // last session released (`configuredPort == releasedPort`) — a foreign holder
    // on a different port, or a port the user re-pointed, fails fast per #308.
    // These cases all use the matching-port pair so they isolate the timing logic.
    func testNoWaitWhenPortIsAlreadyFree() {
        // The overwhelmingly common case: free port → connect immediately.
        XCTAssertFalse(TunnelManager.shouldWaitForOwnPortRelease(
            portFree: true, selfDisconnectedAgo: 1, configuredPort: 1080, releasedPort: 1080))
        // Even a free port we just released needs no wait.
        XCTAssertFalse(TunnelManager.shouldWaitForOwnPortRelease(
            portFree: true, selfDisconnectedAgo: nil, configuredPort: 1080, releasedPort: 1080))
    }

    func testNoWaitWhenBusyButNoRecentSelfDisconnect() {
        // Busy and we never disconnected ourselves → a foreign app holds it.
        // Fail fast (#308), don't wait on someone else's listener.
        XCTAssertFalse(TunnelManager.shouldWaitForOwnPortRelease(
            portFree: false, selfDisconnectedAgo: nil, configuredPort: 1080, releasedPort: nil))
    }

    func testNoWaitWhenSelfDisconnectIsStale() {
        // Busy, but our last self-disconnect is older than the ghost window —
        // the ghost would be long gone, so a busy port now is someone else's.
        XCTAssertFalse(TunnelManager.shouldWaitForOwnPortRelease(
            portFree: false, selfDisconnectedAgo: 30, configuredPort: 1080, releasedPort: 1080))
    }

    func testWaitsWhenBusyOnOurOwnRecentGhost() {
        // Busy + we disconnected ourselves a moment ago, on the SAME port we just
        // released → wait-and-retry the same port rather than failing on our ghost.
        XCTAssertTrue(TunnelManager.shouldWaitForOwnPortRelease(
            portFree: false, selfDisconnectedAgo: 0, configuredPort: 1080, releasedPort: 1080))
        XCTAssertTrue(TunnelManager.shouldWaitForOwnPortRelease(
            portFree: false, selfDisconnectedAgo: 2, configuredPort: 1080, releasedPort: 1080))
    }

    func testNoWaitOnNegativeAge() {
        // Defensive: a clock skew producing a negative "ago" must not be treated
        // as "within the window".
        XCTAssertFalse(TunnelManager.shouldWaitForOwnPortRelease(
            portFree: false, selfDisconnectedAgo: -5, configuredPort: 1080, releasedPort: 1080))
    }

    // #394: busy + recent self-disconnect, but NOT on the port we released.
    func testNoWaitWhenBusyPortIsNotTheOneWeReleased() {
        // A foreign app holds a DIFFERENT port than the one our last session let go
        // → no ghost of ours there, fail fast (#308) instead of waiting 5 s.
        XCTAssertFalse(TunnelManager.shouldWaitForOwnPortRelease(
            portFree: false, selfDisconnectedAgo: 1, configuredPort: 9050, releasedPort: 1080))
        // The user re-pointed the SOCKS port between sessions; the busy configured
        // port is not the one we released → fail fast.
        XCTAssertFalse(TunnelManager.shouldWaitForOwnPortRelease(
            portFree: false, selfDisconnectedAgo: 1, configuredPort: 1081, releasedPort: 1080))
        // We disconnected recently but never recorded a released port (e.g. a
        // failed-before-bind attempt) → nothing of ours to wait on.
        XCTAssertFalse(TunnelManager.shouldWaitForOwnPortRelease(
            portFree: false, selfDisconnectedAgo: 1, configuredPort: 1080, releasedPort: nil))
    }

    // MARK: freeEphemeralPort

    func testFreeEphemeralPortIsInRangeAndFree() throws {
        guard let port = PortAvailability.freeEphemeralPort() else {
            throw XCTSkip("No free ephemeral port found on this runner")
        }
        XCTAssertGreaterThanOrEqual(port, 49_152)
        // Upper bound is UInt16.max (65535) by type; assert the lower IANA edge
        // and that the returned port genuinely binds free.
        XCTAssertTrue(PortAvailability.isFree(port),
                      "freeEphemeralPort returned \(port) but it is not bindable")
    }

    func testFreeEphemeralPortReturnsNilWhenNoAttempts() {
        // Zero attempts must short-circuit to nil rather than loop or crash.
        XCTAssertNil(PortAvailability.freeEphemeralPort(maxAttempts: 0))
    }

    // MARK: helpers

    /// Picks a high random port and verifies it's free, retrying up to
    /// `maxAttempts` times. Throws `XCTSkip` if no free port is found —
    /// on a noisy CI runner this prevents the test from hanging in an
    /// unbounded loop. The test isn't broken, it just can't run here.
    private func findFreePort(maxAttempts: Int = 5) throws -> UInt16 {
        for _ in 0..<maxAttempts {
            let candidate = UInt16.random(in: 50_000...60_000)
            if PortAvailability.isFree(candidate) { return candidate }
        }
        throw XCTSkip("Could not find a free port after \(maxAttempts) attempts on this runner")
    }

    /// Binds a fresh socket on 127.0.0.1:<port>. Returns the FD on success.
    private func bind127(port: UInt16) throws -> Int32 {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw NSError(domain: "PortAvailabilityTests", code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "socket() failed"])
        }
        var addr = sockaddr_in()
        addr.sin_len    = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port   = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let err = errno
            close(sock)
            throw NSError(domain: "PortAvailabilityTests", code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "bind() failed (\(err))"])
        }
        return sock
    }
}
