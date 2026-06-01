import XCTest
@testable import olcrtc_ios

// Roundtrip + invariant tests for ConnectionStore.
//
// ConnectionStore persists to real UserDefaults (`olcrtc_records_v2`,
// `olcrtc_primary_id`) and real Keychain (via ConnectionSecretStore).
// Tests therefore:
//   1. Snapshot the live UserDefaults state in setUp and restore in tearDown
//      so we never clobber a developer's actual saved connections.
//   2. Track every connection UUID we create and explicitly remove its
//      Keychain entries in tearDown — leaving them would slowly fill the
//      simulator's keychain DB.
//
// The non-isolation strategy is deliberate: ConnectionStore hard-codes
// `UserDefaults.standard`, so we can't redirect it to a fake suite without
// invading production code. Snapshot+restore is the least invasive path.

@MainActor
final class ConnectionStoreTests: XCTestCase {

    private let recordsKey = "olcrtc_records_v2"
    private let primaryKey = "olcrtc_primary_id"

    private var savedRecords: Data?
    private var savedPrimary: String?
    private var createdIDs: [UUID] = []

    override func setUp() async throws {
        try await super.setUp()
        // Stash so we can roll back after.
        savedRecords = UserDefaults.standard.data(forKey: recordsKey)
        savedPrimary = UserDefaults.standard.string(forKey: primaryKey)
        UserDefaults.standard.removeObject(forKey: recordsKey)
        UserDefaults.standard.removeObject(forKey: primaryKey)
    }

    override func tearDown() async throws {
        for id in createdIDs {
            ConnectionSecretStore.remove(connectionID: id)
        }
        createdIDs.removeAll()

        if let d = savedRecords {
            UserDefaults.standard.set(d, forKey: recordsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: recordsKey)
        }
        if let s = savedPrimary {
            UserDefaults.standard.set(s, forKey: primaryKey)
        } else {
            UserDefaults.standard.removeObject(forKey: primaryKey)
        }
        try await super.tearDown()
    }

    // MARK: Test fixture

    private func makeRecord(
        name: String = "Test",
        key: String = "deadbeef",
        socksPass: String = "swordfish"
    ) -> ConnectionRecord {
        let conn = OlcrtcConnection(
            carrier: "telemost",
            transport: "vp8channel",
            roomID: "room-123",
            key: key,
            clientID: "ios-test",
            socksUser: "user",
            socksPass: socksPass
        )
        let r = ConnectionRecord(name: name, details: .olcrtc(conn))
        createdIDs.append(r.id)
        return r
    }

    // MARK: Save / load roundtrip

    func testSaveLoadRoundtripPreservesAllFields() {
        let store1 = ConnectionStore()
        let r = makeRecord(name: "MyServer", key: "abc123", socksPass: "p@ss")
        store1.add(r)

        // Cold-start simulation: brand-new ConnectionStore reads from
        // UserDefaults + Keychain.
        let store2 = ConnectionStore()
        XCTAssertEqual(store2.connections.count, 1)
        guard let loaded = store2.connections.first else {
            XCTFail("Expected one connection after load"); return
        }
        XCTAssertEqual(loaded.id, r.id)
        XCTAssertEqual(loaded.name, "MyServer")
        XCTAssertEqual(loaded.groupName, L10n.groupDefault.localized())
        guard case .olcrtc(let p) = loaded.details else {
            XCTFail("Expected olcrtc details"); return
        }
        XCTAssertEqual(p.carrier, "telemost")
        XCTAssertEqual(p.transport, "vp8channel")
        XCTAssertEqual(p.roomID, "room-123")
        XCTAssertEqual(p.clientID, "ios-test")
        // The whole point of the scrub-and-hydrate dance: secrets survive.
        XCTAssertEqual(p.key, "abc123")
        XCTAssertEqual(p.socksPass, "p@ss")
    }

    func testMultipleRecordsRoundtripIndependently() {
        let store1 = ConnectionStore()
        let r1 = makeRecord(name: "A", key: "key-A", socksPass: "pass-A")
        let r2 = makeRecord(name: "B", key: "key-B", socksPass: "pass-B")
        store1.add(r1)
        store1.add(r2)

        let store2 = ConnectionStore()
        XCTAssertEqual(store2.connections.count, 2)
        let byID = Dictionary(uniqueKeysWithValues: store2.connections.map { ($0.id, $0) })
        guard case .olcrtc(let pA) = byID[r1.id]?.details,
              case .olcrtc(let pB) = byID[r2.id]?.details else {
            XCTFail("Lost a record across reload"); return
        }
        XCTAssertEqual(pA.key,       "key-A")
        XCTAssertEqual(pA.socksPass, "pass-A")
        XCTAssertEqual(pB.key,       "key-B")
        XCTAssertEqual(pB.socksPass, "pass-B")
    }

    // MARK: Secret-scrub invariant
    //
    // This is the security-critical guarantee: nothing in the UserDefaults
    // blob may contain the key or SOCKS password in plain text. Anyone who
    // backs up the device's preferences plist must not get the credentials.

    func testKeyIsNotPersistedToUserDefaults() {
        let store = ConnectionStore()
        let secretKey = "this-must-not-appear-in-userdefaults-\(UUID().uuidString)"
        store.add(makeRecord(key: secretKey))

        guard let blob = UserDefaults.standard.data(forKey: recordsKey),
              let text = String(data: blob, encoding: .utf8) else {
            XCTFail("Expected UserDefaults blob to exist after add"); return
        }
        XCTAssertFalse(text.contains(secretKey),
                       "Encryption key leaked into UserDefaults JSON")
    }

    func testSocksPassIsNotPersistedToUserDefaults() {
        let store = ConnectionStore()
        let secretPass = "this-pass-must-not-appear-\(UUID().uuidString)"
        store.add(makeRecord(socksPass: secretPass))

        guard let blob = UserDefaults.standard.data(forKey: recordsKey),
              let text = String(data: blob, encoding: .utf8) else {
            XCTFail("Expected UserDefaults blob to exist after add"); return
        }
        XCTAssertFalse(text.contains(secretPass),
                       "SOCKS password leaked into UserDefaults JSON")
    }

    func testEmptyKeyDoesNotCreateKeychainEntry() {
        let store = ConnectionStore()
        let r = makeRecord(key: "", socksPass: "")
        store.add(r)

        // Belt-and-braces: save() guards on `!p.key.isEmpty` before writing.
        // If that guard ever gets removed, we'd accidentally create empty
        // Keychain entries that the user can never see or clean up.
        XCTAssertNil(ConnectionSecretStore.key(for: r.id))
        XCTAssertNil(ConnectionSecretStore.socksPass(for: r.id))
    }

    // MARK: Primary-ID semantics

    func testAutoPrimaryOnFirstAdd() {
        let store = ConnectionStore()
        XCTAssertNil(store.primaryID, "Empty store should have no primary")

        let r = makeRecord()
        store.add(r)
        XCTAssertEqual(store.primaryID, r.id,
                       "First add must auto-set primary so single-server case works")
    }

    func testSecondAddDoesNotChangePrimary() {
        let store = ConnectionStore()
        let r1 = makeRecord(name: "First")
        let r2 = makeRecord(name: "Second")
        store.add(r1)
        store.add(r2)
        XCTAssertEqual(store.primaryID, r1.id,
                       "Existing primary must not be overwritten by a later add")
    }

    func testRemoveOfPrimaryFallsBackToFirstRemaining() {
        let store = ConnectionStore()
        let r1 = makeRecord(name: "First")
        let r2 = makeRecord(name: "Second")
        store.add(r1)
        store.add(r2)
        store.setPrimary(r1.id)

        store.remove(at: IndexSet(integer: 0))   // drops r1
        XCTAssertEqual(store.primaryID, r2.id,
                       "Primary must fall back to the first remaining record")
    }

    func testRemoveLastRecordClearsPrimary() {
        let store = ConnectionStore()
        let r = makeRecord()
        store.add(r)
        store.remove(at: IndexSet(integer: 0))
        XCTAssertNil(store.primaryID,
                     "Primary must be nil once the connection list is empty")
    }

    func testPrimaryIDSurvivesColdStart() {
        let store1 = ConnectionStore()
        let r1 = makeRecord(name: "A")
        let r2 = makeRecord(name: "B")
        store1.add(r1)
        store1.add(r2)
        store1.setPrimary(r2.id)

        let store2 = ConnectionStore()
        XCTAssertEqual(store2.primaryID, r2.id,
                       "primaryID must roundtrip through UserDefaults")
    }

    // MARK: Mutation paths

    func testUpdateReplacesInPlaceByID() {
        let store = ConnectionStore()
        var r = makeRecord(name: "Old")
        store.add(r)
        r.name = "New"
        store.update(r)
        XCTAssertEqual(store.connections.count, 1, "Update must not duplicate")
        XCTAssertEqual(store.connections.first?.name, "New")
    }

    func testRemoveDropsKeychainEntries() {
        let store = ConnectionStore()
        let r = makeRecord(key: "kk", socksPass: "ss")
        store.add(r)
        XCTAssertNotNil(ConnectionSecretStore.key(for: r.id),
                        "Sanity: secret should be in Keychain before removal")

        store.remove(at: IndexSet(integer: 0))
        XCTAssertNil(ConnectionSecretStore.key(for: r.id),
                     "Removal must drop the Keychain entry — otherwise the key " +
                     "lingers indefinitely after the user thinks they deleted it")
        XCTAssertNil(ConnectionSecretStore.socksPass(for: r.id))
    }
}
