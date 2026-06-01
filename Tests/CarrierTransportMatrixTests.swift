import XCTest
@testable import olcrtc_ios

// Pins the contract for `CarrierTransportMatrix.requiresRoomID`.
// The YAML binary requires an explicit room ID for every carrier, so
// `autoGeneratesRoomID` is empty. If anyone flips the defensive default
// (unknown carrier → requires) or re-adds an auto-gen carrier by accident,
// these tests fail.

final class CarrierTransportMatrixTests: XCTestCase {

    func testEveryKnownCarrierRequiresRoomID() {
        for carrier in CarrierTransportMatrix.carriers {
            XCTAssertTrue(
                CarrierTransportMatrix.requiresRoomID(carrier: carrier),
                "expected \(carrier) to require a room ID"
            )
        }
    }

    func testUnknownCarrierRequiresRoomID() {
        // Defensive default: a carrier we haven't catalogued falls through to
        // "requires" because the server will reject it anyway. Set.contains
        // returns false for unknowns, so the function naturally defaults to
        // "requires" without an extra `if`.
        XCTAssertTrue(CarrierTransportMatrix.requiresRoomID(carrier: "unknown-future-carrier"))
    }

    func testAutoGenSetIsEmpty() {
        // The YAML binary requires an explicit room ID for every carrier, so
        // no carrier auto-generates one. When #226 wires Jitsi room-URL
        // auto-generation, add "jitsi" here and match it in scripts/srv.sh.
        XCTAssertTrue(CarrierTransportMatrix.autoGeneratesRoomID.isEmpty)
    }
}
