import XCTest
@testable import olcrtc_ios

// #356: subscription re-import dedup + #refresh handling.
//
// Two layers under test:
//   1. ConnectionStore.diffSubscription — the pure add/update/remove diff,
//      tested without any persistence.
//   2. ConnectionStore.importSubscription / isRefreshDue — the live store path.
//      Like ConnectionStoreTests, this snapshots+restores the real UserDefaults
//      keys (records, primary, sub-meta) and cleans up Keychain entries.

@MainActor
final class SubscriptionDedupTests: XCTestCase {

    private let recordsKey = "olcrtc_records_v2"
    private let primaryKey = "olcrtc_primary_id"
    private let metaKey     = "olcrtc_sub_meta_v1"

    private var savedRecords: Data?
    private var savedPrimary: String?
    private var savedMeta: Data?
    private var createdIDs: [UUID] = []

    override func setUp() async throws {
        try await super.setUp()
        savedRecords = UserDefaults.standard.data(forKey: recordsKey)
        savedPrimary = UserDefaults.standard.string(forKey: primaryKey)
        savedMeta    = UserDefaults.standard.data(forKey: metaKey)
        UserDefaults.standard.removeObject(forKey: recordsKey)
        UserDefaults.standard.removeObject(forKey: primaryKey)
        UserDefaults.standard.removeObject(forKey: metaKey)
    }

    override func tearDown() async throws {
        for id in createdIDs { ConnectionSecretStore.remove(connectionID: id) }
        createdIDs.removeAll()
        for d in [(recordsKey, savedRecords), (metaKey, savedMeta)] {
            if let data = d.1 { UserDefaults.standard.set(data, forKey: d.0) }
            else { UserDefaults.standard.removeObject(forKey: d.0) }
        }
        if let s = savedPrimary { UserDefaults.standard.set(s, forKey: primaryKey) }
        else { UserDefaults.standard.removeObject(forKey: primaryKey) }
        try await super.tearDown()
    }

    // MARK: Fixtures

    private let source = "olcrtc-sub://pool.example.org/sub"

    private func sub(_ body: String) -> OlcrtcSubscription {
        OlcrtcSubscription.parse(body)
    }

    private let twoNodes = """
    #name: Pool
    olcrtc://wbstream?datachannel@room-a#aa
    ##name: A
    olcrtc://wbstream?datachannel@room-b#bb
    ##name: B
    """

    private let onlyB = """
    #name: Pool
    olcrtc://wbstream?datachannel@room-b#bb
    ##name: B
    """

    // MARK: Pure diff

    func testFirstImportAddsAll() {
        let diff = ConnectionStore.diffSubscription(
            sub(twoNodes), source: source, group: "Pool", existing: [])
        XCTAssertEqual(diff.toAdd.count, 2)
        XCTAssertTrue(diff.toUpdate.isEmpty)
        XCTAssertTrue(diff.toRemove.isEmpty)
        // Provenance is stamped on the new records.
        XCTAssertEqual(diff.toAdd[0].subSourceURL, source)
        XCTAssertNotNil(diff.toAdd[0].subNodeKey)
    }

    func testReimportSameListIsNoOp() {
        let first = ConnectionStore.diffSubscription(
            sub(twoNodes), source: source, group: "Pool", existing: [])
        // Feed the first import's records back as "existing".
        let second = ConnectionStore.diffSubscription(
            sub(twoNodes), source: source, group: "Pool", existing: first.toAdd)
        XCTAssertTrue(second.toAdd.isEmpty, "Re-import of identical list must not duplicate")
        XCTAssertTrue(second.toUpdate.isEmpty, "Unchanged nodes need no update")
        XCTAssertTrue(second.toRemove.isEmpty)
    }

    func testReimportRenamedNodeUpdatesInPlaceKeepingID() {
        let first = ConnectionStore.diffSubscription(
            sub(twoNodes), source: source, group: "Pool", existing: [])
        let renamed = """
        #name: Pool
        olcrtc://wbstream?datachannel@room-a#aa
        ##name: A-renamed
        olcrtc://wbstream?datachannel@room-b#bb
        ##name: B
        """
        let second = ConnectionStore.diffSubscription(
            sub(renamed), source: source, group: "Pool", existing: first.toAdd)
        XCTAssertTrue(second.toAdd.isEmpty)
        XCTAssertEqual(second.toUpdate.count, 1)
        XCTAssertEqual(second.toUpdate.first?.name, "A-renamed")
        // Same room/key → same node identity → same record id (key/primary kept).
        let original = first.toAdd.first { $0.name == "A" }
        XCTAssertEqual(second.toUpdate.first?.id, original?.id)
    }

    func testReimportDroppedNodeIsRemoved() {
        let first = ConnectionStore.diffSubscription(
            sub(twoNodes), source: source, group: "Pool", existing: [])
        let onlyA = """
        #name: Pool
        olcrtc://wbstream?datachannel@room-a#aa
        ##name: A
        """
        let second = ConnectionStore.diffSubscription(
            sub(onlyA), source: source, group: "Pool", existing: first.toAdd)
        XCTAssertEqual(second.toRemove.count, 1)
        let droppedB = first.toAdd.first { $0.name == "B" }
        XCTAssertEqual(second.toRemove.first, droppedB?.id)
    }

    func testRecordsFromOtherSourcesAreUntouched() {
        let first = ConnectionStore.diffSubscription(
            sub(twoNodes), source: source, group: "Pool", existing: [])
        // A different subscription's records must not be removed by this one.
        let other = ConnectionStore.diffSubscription(
            sub("olcrtc://wbstream?datachannel@room-x#xx"),
            source: "olcrtc-sub://other.example.org/sub", group: "Other", existing: [])
        let mixed = first.toAdd + other.toAdd
        let second = ConnectionStore.diffSubscription(
            sub(onlyB), source: source, group: "Pool", existing: mixed)
        // Only this source's missing node (A) is removed; the other source is safe.
        XCTAssertEqual(second.toRemove.count, 1)
        XCTAssertFalse(second.toRemove.contains(other.toAdd[0].id))
    }

    func testDuplicateNodesWithinOneListCollapse() {
        let dupBody = """
        olcrtc://wbstream?datachannel@room-a#aa
        olcrtc://wbstream?datachannel@room-a#aa
        """
        let diff = ConnectionStore.diffSubscription(
            sub(dupBody), source: source, group: "Pool", existing: [])
        XCTAssertEqual(diff.toAdd.count, 1, "Identical nodes in one list collapse to one record")
    }

    // MARK: #363 — per-node metadata carried onto records

    private let nodesWithMeta = """
    #name: Pool
    olcrtc://wbstream?datachannel@room-a#aa
    ##name: A
    ##ip: 203.0.113.10
    ##comment: free node
    ##used: 500mb/10gb
    ##available: 9.5gb
    """

    func testNodeMetadataLandsOnAddedRecord() {
        let diff = ConnectionStore.diffSubscription(
            sub(nodesWithMeta), source: source, group: "Pool", existing: [])
        let r = diff.toAdd.first
        XCTAssertEqual(r?.subIP, "203.0.113.10")
        XCTAssertEqual(r?.subComment, "free node")
        XCTAssertEqual(r?.subUsed, "500mb/10gb")
        XCTAssertEqual(r?.subAvailable, "9.5gb")
    }

    func testNodeMetadataUpdatesInPlaceOnReimport() {
        let first = ConnectionStore.diffSubscription(
            sub(nodesWithMeta), source: source, group: "Pool", existing: [])
        let changed = """
        #name: Pool
        olcrtc://wbstream?datachannel@room-a#aa
        ##name: A
        ##ip: 198.51.100.7
        ##comment: rotated IP
        """
        let second = ConnectionStore.diffSubscription(
            sub(changed), source: source, group: "Pool", existing: first.toAdd)
        XCTAssertEqual(second.toUpdate.count, 1, "Changed ##ip/##comment must update in place")
        XCTAssertEqual(second.toUpdate.first?.subIP, "198.51.100.7")
        XCTAssertEqual(second.toUpdate.first?.subComment, "rotated IP")
        XCTAssertEqual(second.toUpdate.first?.id, first.toAdd.first?.id, "id kept across update")
    }

    func testGroupMetadataLandsOnSubscriptionMeta() {
        let store = ConnectionStore()
        let body = """
        #name: Pool
        #refresh: 10m
        #used: 1gb/10gb
        #available: 9gb
        olcrtc://wbstream?datachannel@room-a#aa
        ##name: A
        olcrtc://wbstream?datachannel@room-b#bb
        ##name: B
        """
        store.importSubscription(sub(body), source: source)
        store.connections.forEach { createdIDs.append($0.id) }
        guard let info = store.subscriptionInfo(for: store.connections) else {
            return XCTFail("imported group must expose subscription info")
        }
        XCTAssertEqual(info.source, source)
        XCTAssertEqual(info.meta.name, "Pool")
        XCTAssertEqual(info.meta.used, "1gb/10gb")
        XCTAssertEqual(info.meta.available, "9gb")
        XCTAssertEqual(info.meta.serverCount, 2)
        XCTAssertEqual(info.meta.refreshInterval, 600)
    }

    func testManualGroupHasNoSubscriptionInfo() {
        let store = ConnectionStore()
        let manual = ConnectionRecord(
            name: "Manual", groupName: "Mine",
            details: .olcrtc(OlcrtcConnection(
                carrier: "wbstream", transport: "datachannel",
                roomID: "r", key: "k", clientID: "default")))
        store.add(manual)
        createdIDs.append(manual.id)
        XCTAssertNil(store.subscriptionInfo(for: store.connections))
    }

    // MARK: Live store path

    func testStoreReimportDoesNotDuplicate() {
        let store = ConnectionStore()
        store.importSubscription(sub(twoNodes), source: source)
        store.connections.forEach { createdIDs.append($0.id) }
        XCTAssertEqual(store.connections.count, 2)

        store.importSubscription(sub(twoNodes), source: source)
        XCTAssertEqual(store.connections.count, 2, "Re-import must not add duplicates")
    }

    func testStoreReimportUpdatesAndRemoves() {
        let store = ConnectionStore()
        store.importSubscription(sub(twoNodes), source: source)
        store.connections.forEach { createdIDs.append($0.id) }
        let idA = store.connections.first { $0.name == "A" }?.id

        let renamedOnlyA = """
        #name: Pool
        olcrtc://wbstream?datachannel@room-a#aa
        ##name: A2
        """
        store.importSubscription(sub(renamedOnlyA), source: source)
        XCTAssertEqual(store.connections.count, 1, "B dropped from the list → removed")
        XCTAssertEqual(store.connections.first?.id, idA, "A kept its id across rename")
        XCTAssertEqual(store.connections.first?.name, "A2")
    }

    // MARK: Refresh bookkeeping

    func testRefreshIntervalParsing() {
        XCTAssertEqual(sub("#refresh: 10m\nolcrtc://wbstream?datachannel@r#a").refreshInterval, 600)
        XCTAssertEqual(sub("#refresh: 6h\nolcrtc://wbstream?datachannel@r#a").refreshInterval, 21600)
        XCTAssertEqual(sub("#refresh: 1d\nolcrtc://wbstream?datachannel@r#a").refreshInterval, 86400)
        XCTAssertEqual(sub("#refresh: 30s\nolcrtc://wbstream?datachannel@r#a").refreshInterval, 30)
        XCTAssertEqual(sub("#refresh: 45\nolcrtc://wbstream?datachannel@r#a").refreshInterval, 45)
        XCTAssertNil(sub("olcrtc://wbstream?datachannel@r#a").refreshInterval)
    }

    func testIsRefreshDueRespectsInterval() {
        let store = ConnectionStore()
        let body = "#refresh: 10m\n" + twoNodes
        store.importSubscription(sub(body), source: source)
        store.connections.forEach { createdIDs.append($0.id) }

        // Just imported → not due yet.
        XCTAssertFalse(store.isRefreshDue(source: source, now: Date()))
        // 11 minutes later → due.
        XCTAssertTrue(store.isRefreshDue(source: source,
                                         now: Date().addingTimeInterval(11 * 60)))
        // Unknown source → never due.
        XCTAssertFalse(store.isRefreshDue(source: "olcrtc-sub://nope/sub"))
    }

    func testNoRefreshFieldIsNeverDue() {
        let store = ConnectionStore()
        store.importSubscription(sub(twoNodes), source: source)   // no #refresh
        store.connections.forEach { createdIDs.append($0.id) }
        XCTAssertFalse(store.isRefreshDue(source: source,
                                          now: Date().addingTimeInterval(86400 * 365)))
    }
}
