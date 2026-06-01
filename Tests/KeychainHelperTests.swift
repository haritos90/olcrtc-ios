import XCTest
@testable import olcrtc_ios

// Roundtrip tests for KeychainHelper. Each test uses a unique service name
// derived from a UUID so parallel runs and prior failures cannot leak state.

final class KeychainHelperTests: XCTestCase {

    private var service: String = ""
    private let account = "test-account"

    override func setUp() {
        super.setUp()
        service = "test.olcrtc.keychain.\(UUID().uuidString)"
    }

    override func tearDown() {
        // Always clean up — leaving Keychain entries around between test runs
        // would slowly fill the simulator's keychain DB.
        KeychainHelper.delete(service: service, account: account)
        super.tearDown()
    }

    // MARK: Basic roundtrip

    func testSetGetReturnsSameValue() {
        XCTAssertTrue(KeychainHelper.set("hunter2", service: service, account: account))
        XCTAssertEqual(KeychainHelper.get(service: service, account: account), "hunter2")
    }

    func testGetOnMissingReturnsNil() {
        XCTAssertNil(KeychainHelper.get(service: service, account: account))
    }

    func testDeleteRemovesValue() {
        _ = KeychainHelper.set("value", service: service, account: account)
        KeychainHelper.delete(service: service, account: account)
        XCTAssertNil(KeychainHelper.get(service: service, account: account))
    }

    func testDeleteOnMissingIsNoOp() {
        // Must not crash or throw — Keychain returns errSecItemNotFound which we swallow.
        KeychainHelper.delete(service: service, account: account)
        XCTAssertNil(KeychainHelper.get(service: service, account: account))
    }

    // MARK: Overwrite (atomic upsert)

    func testSetOverwritesExistingValue() {
        _ = KeychainHelper.set("first", service: service, account: account)
        _ = KeychainHelper.set("second", service: service, account: account)
        XCTAssertEqual(KeychainHelper.get(service: service, account: account), "second")
    }

    func testSetTwiceConsecutivelyReturnsTrue() {
        // The second call hits the SecItemUpdate path. Both must succeed.
        XCTAssertTrue(KeychainHelper.set("v1", service: service, account: account))
        XCTAssertTrue(KeychainHelper.set("v2", service: service, account: account))
    }

    // MARK: Special characters

    func testValueWithSpaces() {
        let value = "value with multiple spaces inside"
        _ = KeychainHelper.set(value, service: service, account: account)
        XCTAssertEqual(KeychainHelper.get(service: service, account: account), value)
    }

    func testValueWithUnicode() {
        let value = "Пароль 🔑 with mixed scripts • 日本語"
        _ = KeychainHelper.set(value, service: service, account: account)
        XCTAssertEqual(KeychainHelper.get(service: service, account: account), value)
    }

    func testValueWithQuotesAndBackslashes() {
        let value = #"Has "quotes" and 'apostrophes' and \backslashes\"#
        _ = KeychainHelper.set(value, service: service, account: account)
        XCTAssertEqual(KeychainHelper.get(service: service, account: account), value)
    }

    func testEmptyValueRoundtrips() {
        _ = KeychainHelper.set("", service: service, account: account)
        XCTAssertEqual(KeychainHelper.get(service: service, account: account), "")
    }

    // MARK: getResult — error vs not-found distinction

    func testGetResultOnMissingReturnsSuccessNil() {
        switch KeychainHelper.getResult(service: service, account: account) {
        case .success(let value):
            XCTAssertNil(value, "Missing key should be .success(nil), not .failure")
        case .failure(let error):
            XCTFail("Expected .success(nil), got .failure(\(error))")
        }
    }

    func testGetResultOnPresentReturnsSuccessValue() {
        _ = KeychainHelper.set("hello", service: service, account: account)
        switch KeychainHelper.getResult(service: service, account: account) {
        case .success(let value):
            XCTAssertEqual(value, "hello")
        case .failure(let error):
            XCTFail("Expected .success(\"hello\"), got .failure(\(error))")
        }
    }
}
