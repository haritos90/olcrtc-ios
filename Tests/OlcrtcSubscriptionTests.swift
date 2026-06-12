import XCTest
@testable import olcrtc_ios

// #111: subscription links. Pins the two halves of the import pipeline:
//  - the olcrtc-sub:// → https:// link mapping (an olcrtc-ios convention,
//    documented in docs/uri.md), and
//  - the sub.md payload parser (upstream spec: olcrtc-upstream/docs/sub.md —
//    `#key:` global fields, `olcrtc://` lines, `##key:` per-server fields
//    bound to the nearest preceding URI).

final class OlcrtcSubscriptionTests: XCTestCase {

    // MARK: olcrtc-sub:// → https:// mapping

    func testHTTPSMappingSwapsOnlyTheScheme() throws {
        let url = URL(string: "olcrtc-sub://pool.example.org/sub")!
        XCTAssertEqual(try OlcrtcSubscription.httpsURL(from: url).absoluteString,
                       "https://pool.example.org/sub")
    }

    func testHTTPSMappingPreservesPortPathAndQuery() throws {
        let url = URL(string: "olcrtc-sub://pool.example.org:8443/a/b/sub?token=xyz")!
        XCTAssertEqual(try OlcrtcSubscription.httpsURL(from: url).absoluteString,
                       "https://pool.example.org:8443/a/b/sub?token=xyz")
    }

    func testHTTPSMappingRejectsForeignScheme() {
        // A plain olcrtc:// connection URI is not a subscription link.
        let url = URL(string: "olcrtc://wbstream?datachannel@room#aa")!
        XCTAssertThrowsError(try OlcrtcSubscription.httpsURL(from: url))
    }

    func testHTTPSMappingRejectsMissingHost() {
        let url = URL(string: "olcrtc-sub:///sub")!
        XCTAssertThrowsError(try OlcrtcSubscription.httpsURL(from: url))
    }

    // MARK: sub.md payload parsing

    /// The full example from olcrtc-upstream/docs/sub.md, verbatim.
    private let upstreamExample = """
    #name: Zarazaex Free RU
    #update: 1778011200
    #refresh: 10m
    #color: #4A90E2
    #icon: 🇷🇺
    #used: 10mb/10gb
    #available: 9.99gb

    olcrtc://wbstream?seichannel<fps=60&batch=64&frag=900&ack-ms=2000>@room-01#d823fa01cb3e0609b67322f7cf984c4ee2e4ce2e294936fc24ef38c9e59f4799$RU / olcng free sub / IPv6
    ##name: RU-1
    ##icon: 🇷🇺
    ##color: #4A90E2
    ##used: 500mb/10gb
    ##available: 9.5gb
    ##ip: 203.0.113.10
    ##comment: basic free node

    olcrtc://wbstream?datachannel@abc123xyz#aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa$DE / backup / IPv4
    ##name: DE-Backup
    ##icon: 🇩🇪
    ##color: #2EBD85
    ##comment: reserve route, wbstream+datachannel does not work in guest flow
    """

    func testParsesUpstreamExample() {
        let sub = OlcrtcSubscription.parse(upstreamExample)

        XCTAssertEqual(sub.name, "Zarazaex Free RU")
        XCTAssertEqual(sub.entries.count, 2)
        XCTAssertEqual(sub.skippedURIs, 0)

        let first = sub.entries[0]
        XCTAssertEqual(first.name, "RU-1")
        XCTAssertEqual(first.parsed.carrier, "wbstream")
        XCTAssertEqual(first.parsed.transport, "seichannel")
        XCTAssertEqual(first.parsed.roomID, "room-01")
        XCTAssertEqual(first.parsed.key,
            "d823fa01cb3e0609b67322f7cf984c4ee2e4ce2e294936fc24ef38c9e59f4799")
        XCTAssertEqual(first.parsed.mimo, "RU / olcng free sub / IPv6")

        let second = sub.entries[1]
        XCTAssertEqual(second.name, "DE-Backup")
        XCTAssertEqual(second.parsed.transport, "datachannel")
        XCTAssertEqual(second.parsed.roomID, "abc123xyz")
    }

    func testLocalFieldsBindToNearestPrecedingURI() {
        let body = """
        ##name: orphan — no URI above, must be dropped
        olcrtc://wbstream?datachannel@r1#aa
        ##name: first
        olcrtc://wbstream?datachannel@r2#bb
        ##name: second
        """
        let sub = OlcrtcSubscription.parse(body)
        XCTAssertEqual(sub.entries.count, 2)
        XCTAssertEqual(sub.entries[0].name, "first")
        XCTAssertEqual(sub.entries[1].name, "second")
    }

    func testUnparseableURILineIsCountedNotFatal() {
        let body = """
        olcrtc://broken-no-transport
        olcrtc://wbstream?datachannel@room#cc
        """
        let sub = OlcrtcSubscription.parse(body)
        XCTAssertEqual(sub.entries.count, 1)
        XCTAssertEqual(sub.skippedURIs, 1)
        XCTAssertEqual(sub.entries[0].parsed.roomID, "room")
    }

    func testTolerantOfStrayTextAndUnknownFields() {
        let body = """
        some stray banner text
        #refresh: 10m
        #malformed-no-colon
        olcrtc://wbstream?datachannel@room#dd
        ##unknown: ignored
        """
        let sub = OlcrtcSubscription.parse(body)
        XCTAssertNil(sub.name)
        XCTAssertEqual(sub.entries.count, 1)
        XCTAssertEqual(sub.skippedURIs, 0)
    }

    func testEmptyAndMetadataOnlyBodiesYieldNoEntries() {
        XCTAssertTrue(OlcrtcSubscription.parse("").entries.isEmpty)
        XCTAssertTrue(OlcrtcSubscription.parse("#name: Empty pool\n\n").entries.isEmpty)
    }

    // MARK: record-name fallback chain (##name → $mimo → carrier · transport)

    func testRecordNamePrefersLocalNameThenMimoThenFallback() {
        let body = """
        olcrtc://wbstream?datachannel@r1#aa$Mimo Label
        ##name: Explicit
        olcrtc://wbstream?datachannel@r2#bb$Mimo Only
        olcrtc://wbstream?datachannel@r3#cc
        """
        let sub = OlcrtcSubscription.parse(body)
        XCTAssertEqual(sub.entries.count, 3)
        XCTAssertEqual(sub.entries[0].recordName, "Explicit")
        XCTAssertEqual(sub.entries[1].recordName, "Mimo Only")
        XCTAssertEqual(sub.entries[2].recordName, "wbstream · datachannel")
    }
}
