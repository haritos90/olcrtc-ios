import XCTest
@testable import olcrtc_ios

// MARK: - ServerScriptParityTests
//
// Verifies that SSHRunner.installEnv() sets exactly the env var names that
// scripts/srv.sh expects in its # boc olcrtc-ios patches.
//
// Relationship to parity_check.py (the build-phase script):
//   - parity_check.py: every non-boc line in scripts/srv.sh must appear
//     verbatim in upstream olcrtc-upstream/script/srv.sh. Catches upstream changes.
//   - These tests: every OLCRTC_* var read inside boc patches must be set
//     by installEnv(). Catches our own drift between Swift and srv.sh.
//
// Only srv.sh (server-side script) is tested. cnc.sh (client-side CLI) has
// no iOS equivalent — the client is Mobile.xcframework (gomobile bindings).

final class ServerScriptParityTests: XCTestCase {

    // MARK: Required variables always present

    func testEnvCarrier() {
        let env = SSHRunner.installEnv(.init(carrier: "telemost", transport: "datachannel", roomID: "r"))
        XCTAssertTrue(env.contains("OLCRTC_CARRIER=telemost"))
    }

    func testEnvTransport() {
        let env = SSHRunner.installEnv(.init(carrier: "telemost", transport: "datachannel", roomID: "r"))
        XCTAssertTrue(env.contains("OLCRTC_TRANSPORT=datachannel"))
    }

    func testEnvClientIDOmitted() {
        // client-id no longer exists: upstream dropped it from the URI scheme
        // and from srv.sh (YAML config has no client-id field). installEnv must
        // not set OLCRTC_CLIENT_ID.
        let env = SSHRunner.installEnv(.init(carrier: "telemost", transport: "datachannel", roomID: "r"))
        XCTAssertFalse(env.contains("OLCRTC_CLIENT_ID"),
                       "OLCRTC_CLIENT_ID must be absent — client-id was removed upstream")
    }

    func testEnvDNS() {
        let env = SSHRunner.installEnv(.init(carrier: "telemost", transport: "datachannel", roomID: "r"))
        XCTAssertTrue(env.contains("OLCRTC_DNS="))
    }

    func testEnvConfigName() {
        let env = SSHRunner.installEnv(.init(carrier: "telemost", transport: "datachannel", roomID: "r"))
        XCTAssertTrue(env.contains("OLCRTC_CONFIG_NAME="))
    }

    // MARK: Conditional variables

    func testRoomIDSetWhenProvided() {
        let env = SSHRunner.installEnv(.init(carrier: "telemost", transport: "datachannel", roomID: "my-room"))
        XCTAssertTrue(env.contains("OLCRTC_ROOM_ID=my-room"))
    }

    func testRoomIDOmittedWhenEmpty() {
        let env = SSHRunner.installEnv(.init(carrier: "telemost", transport: "datachannel", roomID: ""))
        XCTAssertFalse(env.contains("OLCRTC_ROOM_ID"),
                       "installEnv must omit OLCRTC_ROOM_ID when the room ID is empty")
    }

    func testJitsiURLSetForJitsi() {
        let env = SSHRunner.installEnv(.init(carrier: "jitsi", transport: "datachannel", roomID: "r"))
        XCTAssertTrue(env.contains("OLCRTC_JITSI_URL="),
                      "installEnv must set OLCRTC_JITSI_URL for the jitsi carrier")
    }

    func testJitsiURLAbsentForNonJitsi() {
        let env = SSHRunner.installEnv(.init(carrier: "telemost", transport: "datachannel", roomID: "r"))
        XCTAssertFalse(env.contains("OLCRTC_JITSI_URL"),
                       "OLCRTC_JITSI_URL must not be set for non-jitsi carriers")
    }

    func testVP8VarsSetForVP8Channel() {
        let env = SSHRunner.installEnv(.init(carrier: "wbstream", transport: "vp8channel", roomID: "r"))
        XCTAssertTrue(env.contains("OLCRTC_VP8_FPS="),   "VP8 FPS must be set for vp8channel")
        XCTAssertTrue(env.contains("OLCRTC_VP8_BATCH="), "VP8 batch must be set for vp8channel")
    }

    func testVP8VarsAbsentForDatachannel() {
        let env = SSHRunner.installEnv(.init(carrier: "telemost", transport: "datachannel", roomID: "r"))
        XCTAssertFalse(env.contains("OLCRTC_VP8_FPS"))
        XCTAssertFalse(env.contains("OLCRTC_VP8_BATCH"))
    }

    // MARK: Alignment between installEnv() and srv.sh boc patches

    func testEnvVarNamesMatchSrvShBocPatches() throws {
        // Load scripts/srv.sh — try bundle first, fall back to source tree
        let scriptURL: URL = Bundle.main.url(forResource: "srv", withExtension: "sh")
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()          // Tests/
                .deletingLastPathComponent()          // olcrtc-ios/
                .appendingPathComponent("scripts/srv.sh")

        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        // Extract lines inside boc/eoc blocks.
        var inBOC = false
        var bocLines: [String] = []
        for line in script.components(separatedBy: "\n") {
            if line.contains("# boc olcrtc-ios") { inBOC = true;  continue }
            if line.contains("# eoc olcrtc-ios") { inBOC = false; continue }
            if inBOC { bocLines.append(line) }
        }

        // Extract all OLCRTC_* variable names read in boc patches.
        let bocText = bocLines.joined(separator: "\n")
        let pattern = try NSRegularExpression(pattern: #"\$\{?(OLCRTC_[A-Z_]+)"#)
        let matches = pattern.matches(in: bocText, range: NSRange(bocText.startIndex..., in: bocText))
        let reads   = Set(matches.compactMap { m -> String? in
            guard let r = Range(m.range(at: 1), in: bocText) else { return nil }
            return String(bocText[r])
        })

        // Variables that are read with default values (${VAR:-default}) and
        // intentionally NOT passed by installEnv() because the script defaults suffice.
        let scriptDefaults: Set<String> = [
            // client-id: removed upstream; the var is still tolerated by older
            // boc patches but installEnv no longer sets it.
            "OLCRTC_CLIENT_ID",
            // SOCKS5 egress proxy — read with ${VAR:-default} in a boc patch;
            // off by default and not exposed in the UI, so installEnv omits it.
            "OLCRTC_SOCKS_PROXY_ADDR", "OLCRTC_SOCKS_PROXY_PORT",
            // deferred transports — read with defaults in boc patches
            "OLCRTC_SEI_FPS", "OLCRTC_SEI_BATCH", "OLCRTC_SEI_FRAG", "OLCRTC_SEI_ACK",
            "OLCRTC_VIDEO_W", "OLCRTC_VIDEO_H", "OLCRTC_VIDEO_FPS", "OLCRTC_VIDEO_BITRATE",
            "OLCRTC_VIDEO_HW", "OLCRTC_VIDEO_CODEC", "OLCRTC_VIDEO_QR_RECOVERY",
            "OLCRTC_VIDEO_QR_SIZE", "OLCRTC_VIDEO_TILE_MODULE", "OLCRTC_VIDEO_TILE_RS",
            "OLCRTC_CACHE_DIR",
        ]

        // Build env string covering all carrier/transport combinations.
        let allEnvs = [
            SSHRunner.installEnv(.init(carrier: "telemost", transport: "datachannel", roomID: "r")),
            SSHRunner.installEnv(.init(carrier: "jitsi",    transport: "datachannel", roomID: "r")),
            SSHRunner.installEnv(.init(carrier: "wbstream", transport: "vp8channel",  roomID: "r")),
        ].joined(separator: " ")

        for varName in reads where !scriptDefaults.contains(varName) {
            XCTAssertTrue(allEnvs.contains(varName),
                "\(varName) is read in a srv.sh boc patch but never set by SSHRunner.installEnv()")
        }
    }
}

// MARK: - OlcrtcURITests

final class OlcrtcURITests: XCTestCase {

    func testEncodeDecodeRoundTrip() throws {
        let conn   = OlcrtcConnection(carrier: "telemost", transport: "datachannel",
                                      roomID: "room-123", key: String(repeating: "a", count: 64),
                                      clientID: "default")
        let parsed = try OlcrtcURI.parse(OlcrtcURI.encode(conn, mimo: "test comment"))
        XCTAssertEqual(parsed.carrier,   conn.carrier)
        XCTAssertEqual(parsed.transport, conn.transport)
        XCTAssertEqual(parsed.roomID,    conn.roomID)
        XCTAssertEqual(parsed.key,       conn.key)
        XCTAssertEqual(parsed.clientID,  conn.clientID)
        XCTAssertEqual(parsed.mimo,      "test comment")
    }

    // A Jitsi room is a full URL. The `@…#` delimiters bracket it cleanly as
    // long as the URL has no `@`/`#`/`?`, so it must survive a round trip even
    // though it contains `://` and `/`.
    func testJitsiURLRoomRoundTrip() throws {
        let url    = "https://meet1.arbitr.ru/olcrtc-ab12cd34"
        let conn   = OlcrtcConnection(carrier: "jitsi", transport: "datachannel",
                                      roomID: url, key: String(repeating: "e", count: 64),
                                      clientID: "default")
        let parsed = try OlcrtcURI.parse(OlcrtcURI.encode(conn))
        XCTAssertEqual(parsed.carrier, "jitsi")
        XCTAssertEqual(parsed.roomID,  url)
    }

    func testVP8RoundTripPreservesParams() throws {
        let conn   = OlcrtcConnection(carrier: "wbstream", transport: "vp8channel",
                                      roomID: "r", key: String(repeating: "b", count: 64),
                                      clientID: "default", vp8FPS: 45, vp8BatchSize: 6)
        let parsed = try OlcrtcURI.parse(OlcrtcURI.encode(conn))
        XCTAssertEqual(parsed.vp8FPS,       45)
        XCTAssertEqual(parsed.vp8BatchSize, 6)
    }

    func testParseServerFormatURI() throws {
        let uri    = "olcrtc://wbstream?vp8channel<vp8-fps=25&vp8-batch=1>@room-abc#" +
                     String(repeating: "c", count: 64) + "%default$auto-provisioned"
        let parsed = try OlcrtcURI.parse(uri)
        XCTAssertEqual(parsed.carrier,      "wbstream")
        XCTAssertEqual(parsed.transport,    "vp8channel")
        XCTAssertEqual(parsed.vp8FPS,       25)
        XCTAssertEqual(parsed.vp8BatchSize, 1)
        XCTAssertEqual(parsed.mimo,         "auto-provisioned")
    }

    func testParseClientFormatURI() throws {
        let uri    = "olcrtc://wbstream?vp8channel[vp8-fps=60,vp8-batch=8]@room-xyz#" +
                     String(repeating: "d", count: 64) + "%default"
        let parsed = try OlcrtcURI.parse(uri)
        XCTAssertEqual(parsed.vp8FPS,       60)
        XCTAssertEqual(parsed.vp8BatchSize, 8)
        XCTAssertEqual(parsed.mimo,         "")
    }

    // New upstream URI format: no %clientID field (removed in olcrtc @ 6ba8fcd).
    func testParseURIWithoutClientID() throws {
        let key = String(repeating: "f", count: 64)
        let uri = "olcrtc://telemost?datachannel@room-123#\(key)"
        let parsed = try OlcrtcURI.parse(uri)
        XCTAssertEqual(parsed.carrier,   "telemost")
        XCTAssertEqual(parsed.transport, "datachannel")
        XCTAssertEqual(parsed.roomID,    "room-123")
        XCTAssertEqual(parsed.key,       key)
        XCTAssertEqual(parsed.clientID,  "default",
                       "clientID must default to 'default' when %field absent")
        XCTAssertEqual(parsed.mimo,      "")
    }

    func testParseURIWithMimoButNoClientID() throws {
        let key = String(repeating: "g", count: 64)
        let uri = "olcrtc://jitsi?datachannel@jitsi-room#\(key)$auto-provisioned"
        let parsed = try OlcrtcURI.parse(uri)
        XCTAssertEqual(parsed.clientID, "default")
        XCTAssertEqual(parsed.mimo,     "auto-provisioned")
    }

    // Encoder must NOT emit %clientID when it is "default".
    func testEncodeDefaultClientIDOmitted() {
        let conn = OlcrtcConnection(carrier: "telemost", transport: "datachannel",
                                    roomID: "r", key: String(repeating: "h", count: 64),
                                    clientID: "default")
        let uri = OlcrtcURI.encode(conn)
        XCTAssertFalse(uri.contains("%"), "URI must not contain % when clientID is 'default'")
    }

    // Encoder must emit %clientID when it is non-default (preserves existing connections).
    func testEncodeNonDefaultClientIDPresent() {
        let conn = OlcrtcConnection(carrier: "telemost", transport: "datachannel",
                                    roomID: "r", key: String(repeating: "i", count: 64),
                                    clientID: "ios-abc12345")
        let uri = OlcrtcURI.encode(conn)
        XCTAssertTrue(uri.contains("%ios-abc12345"),
                      "URI must contain %clientID when clientID is non-default")
    }

    func testInvalidSchemeThrows() {
        XCTAssertThrowsError(try OlcrtcURI.parse("https://example.com"))
    }

    func testEmptyRoomIDThrows() {
        XCTAssertThrowsError(try OlcrtcURI.parse(
            "olcrtc://telemost?datachannel@#" + String(repeating: "e", count: 64) + "%default"
        ))
    }

    // MARK: Edge cases (P3 Code Review)

    func testMissingTransportDelimiterThrows() {
        // No "?" between carrier and transport
        XCTAssertThrowsError(try OlcrtcURI.parse(
            "olcrtc://telemost-datachannel@room#" + String(repeating: "a", count: 64)
        ))
    }

    func testMissingRoomDelimiterThrows() {
        // No "@" between transport and roomID
        XCTAssertThrowsError(try OlcrtcURI.parse(
            "olcrtc://telemost?datachannel.roomID#" + String(repeating: "a", count: 64)
        ))
    }

    func testMissingKeyDelimiterThrows() {
        // No "#" between roomID and key
        XCTAssertThrowsError(try OlcrtcURI.parse(
            "olcrtc://telemost?datachannel@room.key"
        ))
    }

    func testEmptyKeyThrows() {
        XCTAssertThrowsError(try OlcrtcURI.parse(
            "olcrtc://telemost?datachannel@room#"
        ))
    }

    func testEmptyCarrierThrows() {
        XCTAssertThrowsError(try OlcrtcURI.parse(
            "olcrtc://?datachannel@room#" + String(repeating: "a", count: 64)
        ))
    }

    func testRoomIDWithSpecialCharsParsedRaw() throws {
        // Special chars in roomID survive parsing — the server-side validator
        // can reject them later if it doesn't like them.
        let key = String(repeating: "a", count: 64)
        let parsed = try OlcrtcURI.parse("olcrtc://telemost?datachannel@room-with-dashes_and.dots#\(key)")
        XCTAssertEqual(parsed.roomID, "room-with-dashes_and.dots")
    }

    func testWhitespaceAroundURIIsTrimmed() throws {
        let key = String(repeating: "a", count: 64)
        let parsed = try OlcrtcURI.parse("  \n olcrtc://telemost?datachannel@room#\(key) \n  ")
        XCTAssertEqual(parsed.roomID, "room")
        XCTAssertEqual(parsed.key, key)
    }

    func testMimoWithEqualsAndPercent() throws {
        // $mimo is opaque — anything after $ is preserved verbatim.
        let key = String(repeating: "a", count: 64)
        let parsed = try OlcrtcURI.parse(
            "olcrtc://telemost?datachannel@room#\(key)%ios-abc12345$comment=v1&extra%data"
        )
        XCTAssertEqual(parsed.clientID, "ios-abc12345")
        XCTAssertEqual(parsed.mimo,     "comment=v1&extra%data")
    }

    func testVP8PayloadWithUnknownKeysIgnored() throws {
        // Forward-compat: unknown keys in the payload block are silently dropped.
        let key = String(repeating: "a", count: 64)
        let parsed = try OlcrtcURI.parse(
            "olcrtc://wbstream?vp8channel[vp8-fps=30,unknown-key=99,vp8-batch=4]@room#\(key)"
        )
        XCTAssertEqual(parsed.vp8FPS,       30)
        XCTAssertEqual(parsed.vp8BatchSize, 4)
    }
}
