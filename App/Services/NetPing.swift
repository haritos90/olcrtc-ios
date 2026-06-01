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

/// Single-shot gate. `fire()` returns `true` exactly once across all racing
/// callers; every subsequent call returns `false`. Used by `NetPing.tcp` so
/// that the `withCheckedContinuation` is resumed at most once when multiple
/// asynchronous racers (NWConnection state callback, timeout DispatchWorkItem,
/// possibly a third future signal) can fire concurrently — resuming twice
/// crashes Swift Concurrency at runtime.
///
/// `@unchecked Sendable` safety invariant
/// --------------------------------------
/// The compiler can't verify this class is `Sendable` because it has a
/// mutable stored property (`fired`). We claim Sendable manually because:
///
///   1. `fired` is only read or written while `lock` is held.
///   2. `lock` is `NSLock` (which is itself thread-safe).
///   3. There are no other stored properties to coordinate.
///
/// `fire()` is the only method that touches `fired`, and it does so under
/// the lock. No other API reveals or mutates state. Therefore any number
/// of threads can call `fire()` concurrently and observe a consistent
/// single-true-then-all-false sequence. If a future change adds another
/// stored property OR another method that reads/writes `fired` outside
/// the lock, this annotation becomes a lie — drop `@unchecked` and let
/// the compiler reject the build, then redesign.
private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
