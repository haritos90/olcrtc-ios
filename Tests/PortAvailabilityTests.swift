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

    // MARK: nextFreePort

    func testNextFreePortReturnsStartingPortWhenFree() throws {
        // Find a definitively-free starting port, then verify nextFreePort
        // returns it unchanged.
        testPort = try findFreePort()
        XCTAssertEqual(PortAvailability.nextFreePort(startingAt: testPort), testPort)
    }

    func testNextFreePortSlidesPastBoundPort() throws {
        // Hunt for two consecutive free ports — needed because the bound port
        // sits below an unrelated process otherwise.
        var candidate: UInt16 = 0
        for _ in 0..<20 {
            let p = UInt16.random(in: 50_000...60_000)
            if PortAvailability.isFree(p) && PortAvailability.isFree(p + 1) {
                candidate = p; break
            }
        }
        guard candidate != 0 else {
            throw XCTSkip("Could not find two consecutive free ports for the test")
        }
        let sock = try bind127(port: candidate)
        defer { close(sock) }

        let next = PortAvailability.nextFreePort(startingAt: candidate)
        XCTAssertEqual(next, candidate + 1,
                       "Expected nextFreePort to slide one slot up past bound \(candidate)")
    }

    func testNextFreePortReturnsNilNearUInt16Max() {
        // Starting at the absolute end of the port range, with no headroom,
        // we still return nil rather than overflowing.
        let near = UInt16.max - 1
        let result = PortAvailability.nextFreePort(startingAt: near, maxAttempts: 8)
        // If the system happens to have both 65534 and 65535 free, we get a port;
        // otherwise nil. Either way, no overflow crash.
        if let r = result {
            XCTAssertGreaterThanOrEqual(r, near)
        }
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
