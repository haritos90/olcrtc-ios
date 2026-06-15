import XCTest
@testable import olcrtc_ios

// #135 / #366: round-trip + parse-guard tests for the full-access (co-admin)
// share format `olcrtc://host/v1/<base64url(JSON)>` (#366: the familiar olcrtc://
// scheme with a `host/` authority, not a separate olcrtc-host:// scheme). These
// pin the encode/parse contract and the discriminator that tells a full-access
// link apart from a plain connection URI (the `formatVersion` / `v1` guard).

final class FullAccessShareTests: XCTestCase {

    private func sample() -> FullAccessShare {
        FullAccessShare(
            uri: "olcrtc://telemost?vp8channel@room#" + String(repeating: "a", count: 64) + "%ios-1$auto",
            label: "TW Moscow #1",
            sshHost: "203.0.113.7",
            sshPort: 22,
            sshUsername: "root",
            sshPassword: "p@ss w/+rd=ünïcödé")
    }

    func testRoundTripPreservesEveryField() throws {
        let original = sample()
        let link = try XCTUnwrap(original.encoded())
        XCTAssertTrue(link.hasPrefix("olcrtc://host/v1/"))
        let parsed = try FullAccessShare.parse(link)
        XCTAssertEqual(parsed, original)
    }

    // #366: a full-access link is detected as such; a plain connection URI is not.
    func testDiscriminatorTellsFullAccessFromConnectionURI() throws {
        let link = try XCTUnwrap(sample().encoded())
        XCTAssertTrue(FullAccessShare.isFullAccessLink(link))
        XCTAssertFalse(FullAccessShare.isFullAccessLink(
            "olcrtc://telemost?vp8channel@room#" + String(repeating: "a", count: 64)))
    }

    func testBase64urlIsURLSafeNoPaddingOrPlusSlash() throws {
        let link = try XCTUnwrap(sample().encoded())
        let blob = String(link.dropFirst("olcrtc://host/v1/".count))
        XCTAssertFalse(blob.contains("+"))
        XCTAssertFalse(blob.contains("/"))
        XCTAssertFalse(blob.contains("="))
    }

    func testParseRejectsWrongScheme() {
        XCTAssertThrowsError(try FullAccessShare.parse("olcrtc://telemost?vp8channel@room#abc")) {
            XCTAssertEqual($0 as? FullAccessShare.ParseError, .invalidScheme)
        }
    }

    func testParseRejectsUnknownVersion() {
        // A v2 link must be rejected, not silently misparsed, before decoding.
        let blob = FullAccessShare.base64urlEncode(Data("{}".utf8))
        XCTAssertThrowsError(try FullAccessShare.parse("olcrtc://host/v2/\(blob)")) {
            XCTAssertEqual($0 as? FullAccessShare.ParseError, .unsupportedVersion("v2"))
        }
    }

    func testParseRejectsMalformedPayload() {
        XCTAssertThrowsError(try FullAccessShare.parse("olcrtc://host/v1/not_base64_json!!")) {
            XCTAssertEqual($0 as? FullAccessShare.ParseError, .malformedPayload)
        }
    }

    @MainActor
    func testRedactionStillScrubsEmbeddedConnectionKey() {
        // The encoded blob is opaque, but if a caller ever logs the embedded URI
        // (it must not log the blob), LogStore.redactSecrets must still scrub the
        // 64-hex connection key. The SSH password has no wire redaction — which is
        // why the share is gated behind the destructive warning (#135).
        let key = String(repeating: "c", count: 64)
        let redacted = LogStore.redactSecrets("olcrtc://x?y@z#\(key)")
        XCTAssertFalse(redacted.contains(key))
    }
}
