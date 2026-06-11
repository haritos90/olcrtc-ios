import Foundation
import Darwin

// MARK: - PortAvailability
//
// Tiny synchronous probe to check whether the local SOCKS5 port we're about
// to hand to the Go runtime is actually free. Without this, a port conflict
// surfaces as a generic "MobileStart failed" deep in the log with no
// actionable hint — the user just sees "connection failed" and gives up.
//
// We mirror the address+family the Go side binds on (127.0.0.1, AF_INET).
// The probe creates a one-shot socket, binds it, and closes it. SO_REUSEADDR
// is intentionally OFF — we want an honest "is anyone here?" answer, not a
// "I could share this if needed" answer.

enum PortAvailability {

    // #308 was: nextFreePort(startingAt:maxAttempts:) + autoRetryAttempts — the
    // connect preflight used to slide the user's busy SOCKS port one slot up and
    // bind the next free one. Removed: the SOCKS port is the contract with external
    // SOCKS clients (Shadowrocket, browsers) configured to point at exactly it, so
    // silently bumping it broke them. The preflight now does a single isFree() check
    // on the configured port and fails fast (reverses closed #108/#148).

    /// Returns a free local TCP port in the IANA ephemeral range
    /// (49152–65535), or nil if none of `maxAttempts` random candidates is
    /// free. Used by the isolated per-connection ping client
    /// (`TunnelManager.ping`, #234) so its temporary SOCKS listener never
    /// collides with the live tunnel's port. Picks at random rather than
    /// walking sequentially so two near-simultaneous pings are unlikely to
    /// land on the same port. The chosen port is bound a moment later by the
    /// Go side; the benign TOCTOU gap means a rare conflict just fails one
    /// ping, which the user can re-trigger.
    static func freeEphemeralPort(maxAttempts: Int = 20) -> UInt16? {
        for _ in 0..<maxAttempts {
            let candidate = UInt16.random(in: 49_152...65_535)
            if isFree(candidate) { return candidate }
        }
        return nil
    }

    /// Returns true if 127.0.0.1:<port> can be bound right now.
    /// Synchronous and fast (microseconds) — safe to call before MobileStart.
    static func isFree(_ port: UInt16) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_len    = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port   = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bindResult == 0
    }
}
