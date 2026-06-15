import XCTest
@testable import olcrtc_ios

// #364: batch "ping subscription" orchestration. The native probe and its
// ephemeral-port lease are exercised elsewhere (OlcrtcEngine.ping →
// PortAvailability.freeEphemeralPort, #234); this file pins the PURE
// orchestration decisions that the sequential runner is built on:
//   • each probe gets a UNIQUE, stable-per-node clientID (so a probe never
//     collides on identity with a live tunnel or another probe);
//   • the node a live tunnel currently holds is SKIPPED (never a 2nd client
//     into the live room);
//   • the clientID rewrite touches only the olcrtc clientID, nothing else.

final class BatchPingTests: XCTestCase {

    private let key = String(repeating: "a", count: 64)

    private func record(roomID: String = "room",
                        clientID: String = "default",
                        id: UUID = UUID()) -> ConnectionRecord {
        ConnectionRecord(
            id: id, name: "node",
            details: .olcrtc(OlcrtcConnection(
                carrier: "wbstream", transport: "datachannel",
                roomID: roomID, key: key, clientID: clientID)))
    }

    // MARK: per-probe clientID

    func testBatchPingClientIDIsStablePerRecordAndUnique() {
        let a = UUID(), b = UUID()
        // Stable across calls for the same record.
        XCTAssertEqual(TunnelManager.batchPingClientID(recordID: a),
                       TunnelManager.batchPingClientID(recordID: a))
        // Distinct per record.
        XCTAssertNotEqual(TunnelManager.batchPingClientID(recordID: a),
                          TunnelManager.batchPingClientID(recordID: b))
        // Never the bare "default" a live tunnel would use.
        XCTAssertNotEqual(TunnelManager.batchPingClientID(recordID: a), "default")
    }

    // MARK: skip-while-connected

    func testSkipsOnlyTheLiveNodeWhenConnected() {
        let live = record(roomID: "live")
        let other = record(roomID: "other")
        // Connected to `live`: probing it would join its room a second time → skip.
        XCTAssertTrue(TunnelManager.shouldSkipBatchPing(
            record: live, connectedNode: live, state: .connected))
        // A different node is always probed.
        XCTAssertFalse(TunnelManager.shouldSkipBatchPing(
            record: other, connectedNode: live, state: .connected))
    }

    func testNeverSkipsWhenDisconnected() {
        let live = record(roomID: "live")
        XCTAssertFalse(TunnelManager.shouldSkipBatchPing(
            record: live, connectedNode: nil, state: .disconnected))
        // Even if a stale connectedNode is passed, a non-connected state probes all.
        XCTAssertFalse(TunnelManager.shouldSkipBatchPing(
            record: live, connectedNode: live, state: .connecting))
    }

    // MARK: clientID rewrite

    func testRecordForBatchPingRewritesOnlyClientID() {
        let original = record(roomID: "room-x", clientID: "default")
        let probe = TunnelManager.recordForBatchPing(original, clientID: "olc-ping-abc")
        guard case .olcrtc(let p) = probe.details,
              case .olcrtc(let o) = original.details else {
            return XCTFail("expected olcrtc details")
        }
        XCTAssertEqual(p.clientID, "olc-ping-abc")
        // Everything else is untouched.
        XCTAssertEqual(probe.id, original.id)
        XCTAssertEqual(p.carrier, o.carrier)
        XCTAssertEqual(p.transport, o.transport)
        XCTAssertEqual(p.roomID, o.roomID)
        XCTAssertEqual(p.key, o.key)
    }
}
