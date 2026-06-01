import XCTest
@testable import olcrtc_ios

// Validation tests for IPChecker.isValidIP — the strict replacement for the
// old `contains(".")` check that would accept things like "Hello.World".

@MainActor
final class IPCheckerValidationTests: XCTestCase {

    // MARK: IPv4 — valid

    func testValidIPv4() {
        XCTAssertTrue(IPChecker.isValidIP("127.0.0.1"))
        XCTAssertTrue(IPChecker.isValidIP("8.8.8.8"))
        XCTAssertTrue(IPChecker.isValidIP("192.168.1.255"))
        XCTAssertTrue(IPChecker.isValidIP("0.0.0.0"))
    }

    // MARK: IPv4 — invalid

    func testRejectsIPv4WithOutOfRangeOctet() {
        XCTAssertFalse(IPChecker.isValidIP("256.0.0.1"))
        XCTAssertFalse(IPChecker.isValidIP("192.168.1.999"))
    }

    func testRejectsIPv4WithWrongOctetCount() {
        XCTAssertFalse(IPChecker.isValidIP("1.2.3"))
        XCTAssertFalse(IPChecker.isValidIP("1.2.3.4.5"))
    }

    func testRejectsTextWithDots() {
        XCTAssertFalse(IPChecker.isValidIP("Hello.World"))
        XCTAssertFalse(IPChecker.isValidIP("example.com"))
        XCTAssertFalse(IPChecker.isValidIP("a.b.c.d"))
    }

    // MARK: IPv6 — valid

    func testValidIPv6() {
        XCTAssertTrue(IPChecker.isValidIP("::1"))
        XCTAssertTrue(IPChecker.isValidIP("2001:db8::1"))
        XCTAssertTrue(IPChecker.isValidIP("fe80::1"))
        XCTAssertTrue(IPChecker.isValidIP("2001:0db8:85a3:0000:0000:8a2e:0370:7334"))
    }

    // MARK: IPv6 — invalid

    func testRejectsTextWithColons() {
        XCTAssertFalse(IPChecker.isValidIP("Error: 500"))
        XCTAssertFalse(IPChecker.isValidIP("host:port"))
        XCTAssertFalse(IPChecker.isValidIP("z:z:z:z"))
    }

    // MARK: Edge cases

    func testRejectsEmptyString() {
        XCTAssertFalse(IPChecker.isValidIP(""))
    }

    func testRejectsWhitespace() {
        XCTAssertFalse(IPChecker.isValidIP("   "))
        XCTAssertFalse(IPChecker.isValidIP("\n"))
    }

    func testRejectsHTMLResponse() {
        XCTAssertFalse(IPChecker.isValidIP("<html><body>blocked</body></html>"))
    }
}
