import XCTest
@testable import olcrtc_ios

// #328: pins the carrier-base-host derivation used by the proxy-loop exclusion
// card. Only the params-derivable host is tested here (no network) — the live
// DNS resolve pass is exercised at runtime, not in unit tests, and the core
// exposes no ICE endpoints (Mobile.objc.h), so this host is the only thing we
// can name from the connection alone.
final class CarrierEndpointsTests: XCTestCase {

    func testJitsiRoomURLYieldsHost() {
        XCTAssertEqual(CarrierEndpoints.host(fromRoomID: "https://meet1.arbitr.ru/myroom"),
                       "meet1.arbitr.ru")
        XCTAssertEqual(CarrierEndpoints.host(fromRoomID: "https://meet.jit.si/room#frag"),
                       "meet.jit.si")
    }

    func testBareHostAndHostPathForms() {
        XCTAssertEqual(CarrierEndpoints.host(fromRoomID: "meet1.arbitr.ru/myroom"), "meet1.arbitr.ru")
        XCTAssertEqual(CarrierEndpoints.host(fromRoomID: "meet1.arbitr.ru:8443/myroom"), "meet1.arbitr.ru")
        XCTAssertEqual(CarrierEndpoints.host(fromRoomID: "meet1.arbitr.ru"), "meet1.arbitr.ru")
    }

    func testOpaqueRoomIDHasNoHost() {
        // telemost / wbstream opaque room IDs are not hosts — nothing to derive.
        XCTAssertNil(CarrierEndpoints.host(fromRoomID: "myroom"))
        XCTAssertNil(CarrierEndpoints.host(fromRoomID: "abc-123-xyz"))
        XCTAssertNil(CarrierEndpoints.host(fromRoomID: ""))
        XCTAssertNil(CarrierEndpoints.host(fromRoomID: "   "))
    }

    func testBaseHostUsesRoomID() {
        let jitsi = OlcrtcConnection(carrier: "jitsi", transport: "datachannel",
                                     roomID: "https://meet1.arbitr.ru/r", key: "", clientID: "default")
        XCTAssertEqual(CarrierEndpoints.baseHost(for: jitsi), "meet1.arbitr.ru")

        let telemost = OlcrtcConnection(carrier: "telemost", transport: "vp8channel",
                                        roomID: "opaque-room-id", key: "", clientID: "default")
        XCTAssertNil(CarrierEndpoints.baseHost(for: telemost))
    }
}
