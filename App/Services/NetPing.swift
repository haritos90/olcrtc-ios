import Foundation
import Network

// MARK: - NetPing
//
// Lightweight TCP reachability check. Used by the VPS management screen
// to test whether port 22 (or any other) responds before the user tries
// the heavier install / uninstall flows.
//
// Why TCP and not ICMP? iOS does not expose raw ICMP sockets without an
// entitlement (SimplePing/raw socket APIs are non-public). Trying a TCP
// connection to the target port gives us a clean yes/no for "is the SSH
// daemon reachable from this device" and a real RTT.

enum NetPing {
    /// Returns success flag + RTT in ms when reachable.
    static func tcp(host: String, port: UInt16, timeout: TimeInterval = 5) async
        -> (success: Bool, ms: Double?)
    {
        await withCheckedContinuation { continuation in
            let conn = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port) ?? .any,
                using: .tcp
            )
            // Lock holder shared between the connection callback and the
            // timeout dispatch — needs to be a reference type with internal
            // synchronisation so we can capture it from @Sendable closures
            // under Swift strict concurrency.
            let gate = ContinuationGate()
            let start = Date()

            var timeoutItem: DispatchWorkItem?

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if gate.fire() {
                        timeoutItem?.cancel()
                        conn.cancel()
                        continuation.resume(returning: (true, Date().timeIntervalSince(start) * 1000))
                    }
                case .failed, .cancelled:
                    if gate.fire() {
                        timeoutItem?.cancel()
                        conn.cancel()
                        continuation.resume(returning: (false, nil))
                    }
                default:
                    break
                }
            }

            conn.start(queue: .global())

            timeoutItem = DispatchWorkItem {
                if gate.fire() {
                    conn.cancel()
                    continuation.resume(returning: (false, nil))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem!)
        }
    }
}

// #400: `ContinuationGate` (the resume-at-most-once gate `NetPing.tcp` uses) now
// lives in App/Utilities/ContinuationGate.swift, shared with the subscription
// fetcher and CarrierEndpoints — previously each duplicated its own copy.
