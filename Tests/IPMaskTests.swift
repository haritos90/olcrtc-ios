import XCTest
@testable import olcrtc_ios

// #337: pins the screenshot-safe IP masking — IPv4 keeps the last octet, IPv6
// keeps the last group, and anything that isn't an IP literal (hostnames,
// placeholders, error text) passes through untouched so labels aren't mangled.
// Masking is display-only; these are the exact transforms the Connections /
// VPS views apply when SettingsStore.maskIPs is on.
final class IPMaskTests: XCTestCase {

    func testIPv4KeepsLastOctet() {
        XCTAssertEqual(IPMask.mask("203.0.113.12"), "•••.•••.•••.12")
        XCTAssertEqual(IPMask.mask("8.8.8.8"), "•••.•••.•••.8")
        XCTAssertEqual(IPMask.mask("  10.0.0.255 "), "•••.•••.•••.255")
    }

    func testIPv6KeepsLastGroup() {
        XCTAssertEqual(IPMask.mask("2001:db8::1"), "•••:1")
        XCTAssertEqual(IPMask.mask("fe80::1ff:fe23:4567:890a"), "•••:890a")
    }

    func testNonIPPassesThrough() {
        // Hostnames and non-IP text must not be mangled.
        XCTAssertEqual(IPMask.mask("meet1.arbitr.ru"), "meet1.arbitr.ru")
        XCTAssertEqual(IPMask.mask("—"), "—")
        XCTAssertEqual(IPMask.mask("n/a"), "n/a")
        XCTAssertEqual(IPMask.mask(""), "")
        // Not four octets / non-numeric → unchanged.
        XCTAssertEqual(IPMask.mask("203.0.113"), "203.0.113")
        XCTAssertEqual(IPMask.mask("1.2.3.x"), "1.2.3.x")
    }

    func testDisplayGate() {
        // Off → verbatim; on → masked.
        XCTAssertEqual(IPMask.display("203.0.113.12", masked: false), "203.0.113.12")
        XCTAssertEqual(IPMask.display("203.0.113.12", masked: true), "•••.•••.•••.12")
    }
}
