import Foundation

// MARK: - WedgeDetector
//
// #440: detects a "wedged" session from the native core's own log lines. The core
// can sit nominally connected while its carrier link is stuck — repeatedly failing
// to (re)open streams — and its internal reconnect doesn't always break the loop.
// Our keep-alive + end-to-end verify eventually catch it, but only after the full
// budget (~120 s). A burst of failure-signature lines in a short window is a much
// earlier tell, so this feeds `TunnelManager.requestReconnect` to restart in ~10 s.
//
// Pure + unit-tested: the caller feeds `(line, now)` and acts on a `true` return.
// Time is injected (monotonic seconds) so the window logic is deterministic under
// test. Gated OFF by default in Settings — log-text signatures are brittle across
// core versions, so this is opt-in, not a silent behaviour change.

struct WedgeDetector {
    /// Failure-signature count within `window` seconds that trips a restart.
    let threshold: Int
    /// Trailing window, in seconds, the failures must fall within.
    let window: Double

    private(set) var timestamps: [Double] = []

    init(threshold: Int, window: Double) {
        self.threshold = threshold
        self.window = window
    }

    /// Substrings that mark a carrier-level (re)connect failure in a core log line.
    /// Lowercased matching; deliberately narrow so ordinary traffic lines don't trip
    /// it. Kept in one place so the brittle contract is easy to audit against a core
    /// version bump.
    static let signatures: [String] = [
        "remote not ready",
        "openstream failed",
        "open stream failed",
        "reconnect attempt",
        "dial failed",
        "handshake failed",
    ]

    static func isFailureSignature(_ line: String) -> Bool {
        let s = line.lowercased()
        return signatures.contains { s.contains($0) }
    }

    /// Feeds one line seen at `now` (monotonic seconds). Returns true exactly once
    /// per burst — when the count of failure signatures within the trailing window
    /// reaches `threshold` — and clears its window so it won't re-fire until a fresh
    /// burst accumulates.
    mutating func record(line: String, now: Double) -> Bool {
        guard Self.isFailureSignature(line) else { return false }
        timestamps.append(now)
        let cutoff = now - window
        timestamps.removeAll { $0 < cutoff }
        if timestamps.count >= threshold {
            timestamps.removeAll()
            return true
        }
        return false
    }

    /// Clears the window (called when a fresh session connects).
    mutating func reset() { timestamps.removeAll() }
}
