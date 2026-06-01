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

    /// How many consecutive ports `nextFreePort` will try before giving up.
    static let autoRetryAttempts = 8

    /// Walks up from `startingAt` and returns the first free port, or nil if
    /// none of the next `maxAttempts` ports are free. Used by the connect
    /// preflight so a transient conflict on the user's preferred port slides
    /// one slot up and retries instead of failing the whole connect.
    static func nextFreePort(startingAt: UInt16,
                              maxAttempts: Int = autoRetryAttempts) -> UInt16? {
        for offset in 0..<maxAttempts {
            let candidate = UInt32(startingAt) + UInt32(offset)
            guard candidate <= UInt32(UInt16.max) else { return nil }
            let port = UInt16(candidate)
            if isFree(port) { return port }
        }
        return nil
    }

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
