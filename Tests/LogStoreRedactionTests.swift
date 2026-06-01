import XCTest
@testable import olcrtc_ios

// Verifies LogStore.redactSecrets scrubs encryption credentials before they
// land in the in-memory buffer or on-disk log file. The provisioning install
// script (`scripts/srv.sh`) prints the 64-hex key + the full olcrtc:// URI
// to its install log; the client tails that log and forwards every line
// into LogStore. Without redaction, the user's Logs tab + any log export
// would contain the encryption credential in plaintext.

@MainActor
final class LogStoreRedactionTests: XCTestCase {

    // MARK: bare 64-hex sequences

    func testBareKeyIsRedacted() {
        let key = String(repeating: "a", count: 64)
        let result = LogStore.redactSecrets("Encryption key: \(key)")
        XCTAssertFalse(result.contains(key))
        XCTAssertTrue(result.contains("<redacted-key>"))
    }

    func testMixedCaseHexIsRedacted() {
        let key = "ABcdEF0123456789" + String(repeating: "f", count: 48)
        XCTAssertEqual(key.count, 64)
        let result = LogStore.redactSecrets(key)
        XCTAssertEqual(result, "<redacted-key>")
    }

    func testMultipleKeysInSameLineAllRedacted() {
        let k1 = String(repeating: "a", count: 64)
        let k2 = String(repeating: "b", count: 64)
        let result = LogStore.redactSecrets("\(k1) and \(k2)")
        XCTAssertFalse(result.contains(k1))
        XCTAssertFalse(result.contains(k2))
        XCTAssertEqual(result, "<redacted-key> and <redacted-key>")
    }

    // MARK: olcrtc:// URI key segment

    func testURIKeyPortionRedactedKeepingPrefix() {
        let key = String(repeating: "c", count: 64)
        let uri = "olcrtc://telemost?vp8channel@room#\(key)%client-id-123$auto"
        let result = LogStore.redactSecrets(uri)
        XCTAssertFalse(result.contains(key))
        XCTAssertTrue(result.hasPrefix("olcrtc://telemost?vp8channel@room#"))
        XCTAssertTrue(result.contains("%client-id-123"), "clientID portion must remain visible for debugging")
        XCTAssertTrue(result.contains("$auto"), "mimo tail must remain visible for debugging")
    }

    func testURIKeyOnlyRedactedWhenNoClientIDOrMimo() {
        let key = String(repeating: "d", count: 64)
        let uri = "olcrtc://carrier?transport@roomID#\(key)"
        let result = LogStore.redactSecrets(uri)
        XCTAssertFalse(result.contains(key))
        XCTAssertTrue(result.contains("<redacted>"))
    }

    // MARK: false-positive guards

    func testShorterHexRunsLeftAlone() {
        // 40-hex (git SHA-length), 32-hex (MD5-length), 63 and 65 — none match.
        let lines = [
            "abc " + String(repeating: "a", count: 40),
            String(repeating: "0", count: 32),
            String(repeating: "f", count: 63),
            String(repeating: "f", count: 65),
        ]
        for line in lines {
            let result = LogStore.redactSecrets(line)
            XCTAssertEqual(result, line, "must not match non-64 hex: \(line)")
        }
    }

    func testBenignTextUnchanged() {
        let line = "✓ SSH connected 1.2.3.4:22 (poll 7, 0/3)"
        XCTAssertEqual(LogStore.redactSecrets(line), line)
    }

    func testRedactionIsIdempotent() {
        let key = String(repeating: "e", count: 64)
        let line = "olcrtc://x?y@z#\(key)%c$m and bare \(key)"
        let once = LogStore.redactSecrets(line)
        let twice = LogStore.redactSecrets(once)
        XCTAssertEqual(once, twice)
    }

    // MARK: integration — actual srv.sh-style banner lines

    func testSrvShBannerLineIsRedacted() {
        // Modelled after scripts/srv.sh lines 237-241 / 268 / 287.
        let key = String(repeating: "9", count: 64)
        let banner = """
        =================== INSTALL DONE ===================
        Encryption key: \(key)
        Container: olcrtc-server-abc123
        URI: olcrtc://telemost?vp8channel@room#\(key)%ios-xyz$auto-provisioned
        ====================================================
        """
        let result = LogStore.redactSecrets(banner)
        XCTAssertFalse(result.contains(key), "the 64-hex key must not survive in any form")
    }
}
