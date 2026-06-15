import XCTest
@testable import olcrtc_ios

// #384: full-access import used to call `serverStore.add` blindly, bypassing the
// dedup + duplicate-label checks `AddServerHostView` enforces. `resolveImport`
// re-applies them as a pure decision: re-opening a link refreshes the existing
// VPS card (no duplicate Keychain entry), and a name clashing with a *different*
// host is disambiguated so the two never share a `<prefix>_container.log` (#323).

final class ServerHostImportTests: XCTestCase {

    private func host(_ label: String, _ h: String, port: Int = 22, user: String = "root") -> ServerHost {
        ServerHost(label: label, host: h, port: port, username: user)
    }

    // MARK: add — clean cases

    func testAddNewIntoEmptyList() {
        let candidate = host("TW Moscow", "1.2.3.4")
        XCTAssertEqual(ServerHostStore.resolveImport(candidate, into: []),
                       .addNew(candidate))
    }

    func testDifferentCoordinatesAreAddedNotDeduped() {
        let existing = host("TW Moscow", "1.2.3.4")
        // Same label is impossible here (the labels differ); different host.
        let candidate = host("TW Piter", "5.6.7.8")
        XCTAssertEqual(ServerHostStore.resolveImport(candidate, into: [existing]),
                       .addNew(candidate))
    }

    // MARK: dedup — same SSH coordinates → refresh in place

    func testSameCoordinatesRefreshExistingInPlace() {
        let existing = host("TW Moscow", "1.2.3.4")
        // A re-imported link may carry a different display label, but it's the
        // same VPS (host/port/username) → update the existing card, keep its id.
        let candidate = host("Renamed", "1.2.3.4")
        let outcome = ServerHostStore.resolveImport(candidate, into: [existing])
        XCTAssertEqual(outcome, .updateExisting(existing))
        // The kept host is the existing one (its id/label), NOT the candidate.
        if case .updateExisting(let h) = outcome {
            XCTAssertEqual(h.id, existing.id)
            XCTAssertEqual(h.label, "TW Moscow")
        } else { XCTFail("expected updateExisting") }
    }

    func testHostMatchIsCaseInsensitive() {
        let existing = host("Box", "Example.COM")
        let candidate = host("Box again", "example.com")
        XCTAssertEqual(ServerHostStore.resolveImport(candidate, into: [existing]),
                       .updateExisting(existing))
    }

    func testDifferentPortIsNotADuplicate() {
        let existing = host("Box", "1.2.3.4", port: 22)
        let candidate = host("Box2", "1.2.3.4", port: 2222)
        if case .addNew = ServerHostStore.resolveImport(candidate, into: [existing]) {
            // pass — different port → different VPS
        } else { XCTFail("different port must not dedup") }
    }

    // MARK: #323 — label / logFilePrefix collision with a DIFFERENT host

    func testCollidingLabelOnDifferentHostIsDisambiguated() {
        let existing = host("TW Moscow", "1.2.3.4")
        let candidate = host("TW Moscow", "5.6.7.8")   // same name, different VPS
        let outcome = ServerHostStore.resolveImport(candidate, into: [existing])
        if case .addNew(let h) = outcome {
            XCTAssertEqual(h.label, "TW Moscow (2)")
            XCTAssertNotEqual(h.logFilePrefix, existing.logFilePrefix)
        } else { XCTFail("expected addNew with a disambiguated label") }
    }

    func testCollidingLogFilePrefixOnDifferentHostIsDisambiguated() {
        // Visibly different labels that sanitise to the SAME prefix (#323) must
        // still be treated as a clash and disambiguated.
        let existing = host("TW Moscow #1", "1.2.3.4")
        let candidate = host("TW Moscow-1", "5.6.7.8")
        XCTAssertEqual(existing.logFilePrefix, host("TW Moscow-1", "x").logFilePrefix,
                       "precondition: the two labels share a sanitised prefix")
        let outcome = ServerHostStore.resolveImport(candidate, into: [existing])
        if case .addNew(let h) = outcome {
            XCTAssertNotEqual(h.logFilePrefix, existing.logFilePrefix)
        } else { XCTFail("expected addNew with a disambiguated label") }
    }

    func testDisambiguationSkipsAlreadyTakenSuffix() {
        let hosts = [host("Box", "1.1.1.1"), host("Box (2)", "2.2.2.2")]
        let candidate = host("Box", "3.3.3.3")
        if case .addNew(let h) = ServerHostStore.resolveImport(candidate, into: hosts) {
            XCTAssertEqual(h.label, "Box (3)")
        } else { XCTFail("expected addNew") }
    }
}
