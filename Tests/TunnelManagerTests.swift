import XCTest
@testable import olcrtc_ios

// Tests for TunnelManager.validate() — the cheap structural checks that run
// on MainActor before the heavy detached Task. Each field has its own failure
// message so the UI surfaces a clear reason without dipping into Go errors.
//
// Validation messages are localized via L10n. To keep tests deterministic
// independent of the runtime language setting, we compare against the L10n
// key's English text directly.

final class TunnelManagerValidationTests: XCTestCase {

    private let validKey = String(repeating: "a", count: 64)

    private func params(clientID: String = "default",
                        key: String? = nil,
                        roomID: String = "room-1") -> OlcrtcConnection {
        OlcrtcConnection(
            carrier:   "telemost",
            transport: "datachannel",
            roomID:    roomID,
            key:       key ?? validKey,
            clientID:  clientID
        )
    }

    // Lock the language to English so message assertions are stable.
    private var savedLanguage: String = ""
    override func setUp() {
        super.setUp()
        savedLanguage = SettingsStore.shared.language
        SettingsStore.shared.language = "en"
    }
    override func tearDown() {
        SettingsStore.shared.language = savedLanguage
        super.tearDown()
    }

    // MARK: Happy path

    func testValidParamsReturnNil() {
        XCTAssertNil(TunnelManager.validate(params: params()))
    }

    // MARK: Client ID

    func testEmptyClientIDFails() {
        XCTAssertEqual(TunnelManager.validate(params: params(clientID: "")),
                       L10n.validateClientIDEmpty.localized())
    }

    func testWhitespaceOnlyClientIDFails() {
        XCTAssertEqual(TunnelManager.validate(params: params(clientID: "   ")),
                       L10n.validateClientIDEmpty.localized())
    }

    func testClientIDWithSpaceFails() {
        XCTAssertEqual(TunnelManager.validate(params: params(clientID: "ios abc")),
                       L10n.validateClientIDWhitespace.localized())
    }

    // MARK: Key

    func testKeyTooShortFails() {
        let short = String(repeating: "a", count: 63)
        XCTAssertEqual(TunnelManager.validate(params: params(key: short)),
                       L10n.validateKeyLength_fmt.formatted(63))
    }

    func testKeyTooLongFails() {
        let long = String(repeating: "a", count: 65)
        XCTAssertEqual(TunnelManager.validate(params: params(key: long)),
                       L10n.validateKeyLength_fmt.formatted(65))
    }

    func testKeyWithNonHexFails() {
        let badHex = String(repeating: "z", count: 64)
        XCTAssertEqual(TunnelManager.validate(params: params(key: badHex)),
                       L10n.validateKeyNonHex.localized())
    }

    func testKeyWithUppercaseHexPasses() {
        let upper = String(repeating: "A", count: 64)
        XCTAssertNil(TunnelManager.validate(params: params(key: upper)))
    }

    // MARK: Room ID

    func testEmptyRoomIDFails() {
        XCTAssertEqual(TunnelManager.validate(params: params(roomID: "")),
                       L10n.validateRoomIDEmpty.localized())
    }

    func testWhitespaceOnlyRoomIDFails() {
        XCTAssertEqual(TunnelManager.validate(params: params(roomID: "  ")),
                       L10n.validateRoomIDEmpty.localized())
    }
}
