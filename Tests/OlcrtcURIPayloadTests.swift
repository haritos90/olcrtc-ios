import XCTest
@testable import olcrtc_ios

// #355: OlcrtcURI parse/encode round-trips for the transport PAYLOAD block —
// in particular that seichannel's sei params (fps/batch/frag/ack-ms) are parsed
// into the sei fields and round-trip, and that vp8channel's vp8-fps/vp8-batch
// stay in the vp8 fields (they used to be conflated, so a sei URI's fps/batch
// wrongly landed in the vp8 fields). The broader URI round-trip/clientID/mimo
// cases live in `OlcrtcURITests` (Tests/ServerScriptParityTests.swift); this
// class focuses on the payload-block contract.

final class OlcrtcURIPayloadTests: XCTestCase {

    // MARK: vp8channel payload

    func testParseVP8ClientFormat() throws {
        let p = try OlcrtcURI.parse(
            "olcrtc://wbstream?vp8channel[vp8-fps=60,vp8-batch=8]@room#aa")
        XCTAssertEqual(p.transport, "vp8channel")
        XCTAssertEqual(p.vp8FPS, 60)
        XCTAssertEqual(p.vp8BatchSize, 8)
        // sei fields untouched for a vp8 URI.
        XCTAssertNil(p.seiFPS)
        XCTAssertNil(p.seiBatch)
        XCTAssertNil(p.seiFrag)
        XCTAssertNil(p.seiACK)
    }

    func testParseVP8ServerScriptFormat() throws {
        let p = try OlcrtcURI.parse(
            "olcrtc://wbstream?vp8channel<vp8-fps=30&vp8-batch=64>@room#aa")
        XCTAssertEqual(p.vp8FPS, 30)
        XCTAssertEqual(p.vp8BatchSize, 64)
    }

    /// Bare fps/batch (no vp8- prefix) on a vp8 transport are accepted as
    /// vp8 aliases (back-compat with older URIs).
    func testParseVP8BareKeysAlias() throws {
        let p = try OlcrtcURI.parse(
            "olcrtc://wbstream?vp8channel[fps=24,batch=4]@room#aa")
        XCTAssertEqual(p.vp8FPS, 24)
        XCTAssertEqual(p.vp8BatchSize, 4)
    }

    // MARK: seichannel payload (#355)

    func testParseSEIServerScriptFormat() throws {
        // The exact form from olcrtc-upstream/docs/sub.md.
        let p = try OlcrtcURI.parse(
            "olcrtc://wbstream?seichannel<fps=60&batch=64&frag=900&ack-ms=2000>@room-01#aa$RU")
        XCTAssertEqual(p.transport, "seichannel")
        XCTAssertEqual(p.seiFPS, 60)
        XCTAssertEqual(p.seiBatch, 64)
        XCTAssertEqual(p.seiFrag, 900)
        XCTAssertEqual(p.seiACK, 2000)
        // sei params must NOT leak into the vp8 fields (the bug #355 fixes).
        XCTAssertNil(p.vp8FPS)
        XCTAssertNil(p.vp8BatchSize)
        XCTAssertEqual(p.mimo, "RU")
    }

    func testParseSEIClientFormat() throws {
        let p = try OlcrtcURI.parse(
            "olcrtc://wbstream?seichannel[fps=15,batch=2,frag=1200,ack-ms=1]@room#bb")
        XCTAssertEqual(p.seiFPS, 15)
        XCTAssertEqual(p.seiBatch, 2)
        XCTAssertEqual(p.seiFrag, 1200)
        XCTAssertEqual(p.seiACK, 1)
    }

    func testParseSEIPartialKeysLeaveRestNil() throws {
        let p = try OlcrtcURI.parse(
            "olcrtc://wbstream?seichannel<fps=45>@room#cc")
        XCTAssertEqual(p.seiFPS, 45)
        XCTAssertNil(p.seiBatch)
        XCTAssertNil(p.seiFrag)
        XCTAssertNil(p.seiACK)
    }

    // MARK: encode

    func testEncodeEmitsSEIPayload() {
        let conn = OlcrtcConnection(
            carrier: "wbstream", transport: "seichannel",
            roomID: "room-01", key: "aa", clientID: "default",
            seiFPS: 60, seiBatch: 64, seiFrag: 900, seiACK: 2000)
        let uri = OlcrtcURI.encode(conn)
        XCTAssertEqual(uri,
            "olcrtc://wbstream?seichannel[fps=60,batch=64,frag=900,ack-ms=2000]@room-01#aa")
    }

    func testSEIEncodeParseRoundTrip() throws {
        let conn = OlcrtcConnection(
            carrier: "telemost", transport: "seichannel",
            roomID: "abc", key: "ff", clientID: "default",
            seiFPS: 24, seiBatch: 8, seiFrag: 1000, seiACK: 500)
        let p = try OlcrtcURI.parse(OlcrtcURI.encode(conn))
        XCTAssertEqual(p.transport, "seichannel")
        XCTAssertEqual(p.seiFPS, 24)
        XCTAssertEqual(p.seiBatch, 8)
        XCTAssertEqual(p.seiFrag, 1000)
        XCTAssertEqual(p.seiACK, 500)
        XCTAssertEqual(p.carrier, "telemost")
        XCTAssertEqual(p.roomID, "abc")
    }

    // MARK: percent-encoded payload normalization (#398)

    /// #398: the percent-decode fallback now lives in OlcrtcURI.parse, so an
    /// encoded URI (the OS often percent-encodes `[ ] , < > &` when forming a
    /// deep link / QR URL) parses through the single entry point every caller
    /// uses — not just the old handleConnectionURL fallback.
    func testParsePercentEncodedClientPayload() throws {
        // "[vp8-fps=60,vp8-batch=8]" with [, ], and , percent-encoded.
        let p = try OlcrtcURI.parse(
            "olcrtc://wbstream?vp8channel%5Bvp8-fps=60%2Cvp8-batch=8%5D@room#aa")
        XCTAssertEqual(p.transport, "vp8channel")
        XCTAssertEqual(p.vp8FPS, 60)
        XCTAssertEqual(p.vp8BatchSize, 8)
        XCTAssertEqual(p.roomID, "room")
        XCTAssertEqual(p.key, "aa")
    }

    func testParsePercentEncodedServerScriptPayload() throws {
        // "<fps=60&batch=64&frag=900&ack-ms=2000>" with <, >, & encoded.
        let p = try OlcrtcURI.parse(
            "olcrtc://wbstream?seichannel%3Cfps=60%26batch=64%26frag=900%26ack-ms=2000%3E@room-01#aa")
        XCTAssertEqual(p.transport, "seichannel")
        XCTAssertEqual(p.seiFPS, 60)
        XCTAssertEqual(p.seiBatch, 64)
        XCTAssertEqual(p.seiFrag, 900)
        XCTAssertEqual(p.seiACK, 2000)
    }

    /// A genuinely-malformed URI (no `@`) must still throw its real diagnostic,
    /// not get masked by the decode retry.
    func testParseStillThrowsOnMalformedAfterDecodeRetry() {
        XCTAssertThrowsError(try OlcrtcURI.parse("olcrtc://wbstream%3Fvp8channel"))
    }

    // MARK: mixed-bracket error (audit S1 — now localized)

    func testMixedBracketsThrowsLocalizedError() {
        // `[ … > … ]` — a `>` appears before the closing `]`, so the brackets
        // are mismatched.
        XCTAssertThrowsError(
            try OlcrtcURI.parse("olcrtc://wbstream?vp8channel[fps=60>x]@room#aa")
        ) { error in
            // Routed through L10n now (was a hardcoded English literal).
            XCTAssertEqual((error as? OlcrtcURI.ParseError)?.errorDescription,
                           L10n.uriErrorMixedBrackets.localized())
        }
    }
}
