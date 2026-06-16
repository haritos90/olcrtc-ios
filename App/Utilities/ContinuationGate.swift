import Foundation

// MARK: - ContinuationGate (#400)
//
// Single-shot gate shared by the NWConnection-based async wrappers. `fire()`
// returns `true` exactly once across all racing callers; every subsequent call
// returns `false`. It exists so a `withChecked(Throwing)Continuation` is resumed
// at most once when several asynchronous racers — an NWConnection state/receive
// callback and a timeout `DispatchWorkItem` (and any future signal) — can fire
// concurrently. Resuming a continuation twice traps at runtime, so the gate is
// the guard around each resume site.
//
// #400 was: this same type was triplicated as `NetPing.ContinuationGate`,
// `NWHTTPSGet`'s private `ContinuationGate`, and `CarrierEndpoints.ResolveGate`
// — extracted here so the resume-at-most-once contract lives in one place.
//
// `@unchecked Sendable` safety invariant
// --------------------------------------
// The compiler can't verify this class is `Sendable` because it has a mutable
// stored property (`fired`). We claim Sendable manually because:
//
//   1. `fired` is only read or written while `lock` is held.
//   2. `lock` is `NSLock` (which is itself thread-safe).
//   3. There are no other stored properties to coordinate.
//
// `fire()` is the only method that touches `fired`, and it does so under the
// lock. No other API reveals or mutates state. Therefore any number of threads
// can call `fire()` concurrently and observe a consistent single-true-then-all-
// false sequence. If a future change adds another stored property OR another
// method that reads/writes `fired` outside the lock, this annotation becomes a
// lie — drop `@unchecked` and let the compiler reject the build, then redesign.
final class ContinuationGate: @unchecked Sendable {
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
