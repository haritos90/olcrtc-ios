import XCTest
@testable import olcrtc_ios

// #371: the IP-pinned DoH fallback now drives an NWConnection HTTPS GET so it
// can connect to the resolved IP while sending the CORRECT SNI/Host = the
// original hostname (the old path rewrote the URL host to the IP, poisoning the
// SNI on CDN/SNI-vhosted fronts like GitHub Pages). The network leg itself needs
// a live server, but the raw-HTTP-response parser is pure — these cover the
// status-line + body split and chunked de-framing it relies on.
final class SubscriptionFetcherTests: XCTestCase {

    // MARK: parse — status line + body split

    func testParseSimple200() {
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nhello world".utf8)
        let parsed = NWHTTPSGet.parse(raw)
        XCTAssertEqual(parsed?.0, 200)
        XCTAssertEqual(parsed?.1, Data("hello world".utf8))
    }

    func testParseNon200StatusIsReported() {
        let raw = Data("HTTP/1.1 404 Not Found\r\n\r\nnope".utf8)
        XCTAssertEqual(NWHTTPSGet.parse(raw)?.0, 404)
    }

    func testParseEmptyBody() {
        let raw = Data("HTTP/1.1 204 No Content\r\nServer: x\r\n\r\n".utf8)
        let parsed = NWHTTPSGet.parse(raw)
        XCTAssertEqual(parsed?.0, 204)
        XCTAssertEqual(parsed?.1, Data())
    }

    func testParseMissingHeaderBodySeparatorReturnsNil() {
        // No CRLFCRLF terminator → can't locate the body boundary.
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain".utf8)
        XCTAssertNil(NWHTTPSGet.parse(raw))
    }

    func testParseMalformedStatusLineReturnsNil() {
        let raw = Data("GARBAGE\r\n\r\nbody".utf8)
        XCTAssertNil(NWHTTPSGet.parse(raw))
    }

    // MARK: parse — chunked transfer-encoding is de-framed

    func testParseChunkedBodyIsDechunked() {
        // "Wiki" (4) + "pedia" (5) + "" (0) — classic chunked example.
        let body = "4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n"
        let raw = Data(("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" + body).utf8)
        let parsed = NWHTTPSGet.parse(raw)
        XCTAssertEqual(parsed?.0, 200)
        XCTAssertEqual(parsed?.1, Data("Wikipedia".utf8))
    }

    func testDechunkHandlesChunkExtensions() {
        // A chunk-size line may carry ;ext — only the hex prefix counts.
        let body = Data("5;foo=bar\r\nhello\r\n0\r\n\r\n".utf8)
        XCTAssertEqual(NWHTTPSGet.dechunk(body), Data("hello".utf8))
    }

    func testDechunkMalformedReturnsNil() {
        // Non-hex size line → malformed framing.
        let body = Data("zz\r\nhello\r\n".utf8)
        XCTAssertNil(NWHTTPSGet.dechunk(body))
    }

    // Header matching for chunked is case-insensitive (servers vary the casing).
    func testParseChunkedCaseInsensitiveHeader() {
        let body = "3\r\nabc\r\n0\r\n\r\n"
        let raw = Data(("HTTP/1.1 200 OK\r\nTRANSFER-ENCODING: CHUNKED\r\n\r\n" + body).utf8)
        XCTAssertEqual(NWHTTPSGet.parse(raw)?.1, Data("abc".utf8))
    }
}
