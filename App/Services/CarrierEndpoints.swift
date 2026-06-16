import Foundation
import Network

// MARK: - CarrierEndpoints (#328)
//
// Derives the carrier endpoints an external proxy app (e.g. Shadowrocket)
// must route DIRECT so the olcrtc tunnel's own carrier traffic doesn't loop
// back through the SOCKS port.
//
// IMPORTANT — accuracy honesty: `Mobile.objc.h` exposes NO live ICE / STUN /
// TURN endpoint API (only Start/Stop/Check/Ping), so we cannot read the
// addresses the running session actually negotiated. We therefore derive the
// *carrier base host* purely from the connection params:
//   • jitsi — the roomID is (or contains) a room URL, so its host IS the
//     signalling host (e.g. meet1.arbitr.ru).
//   • telemost / wbstream — the roomID is an opaque ID, not a host; we can't
//     name a host from params alone, so we report "no host" rather than guess.
// IPs rotate, so the caller copies BOTH the host and the freshly resolved IPs.
// This is a best-effort exclusion hint, not an ICE-level guarantee.

enum CarrierEndpoints {

    /// The carrier base host for a connection, when derivable from its params.
    /// nil when the roomID carries no host (telemost / wbstream opaque IDs).
    static func baseHost(for params: OlcrtcConnection) -> String? {
        host(fromRoomID: params.roomID)
    }

    /// Extracts a host from a roomID that is a full URL or a `host/path` /
    /// bare-host string. Returns nil for opaque IDs (no dot, no scheme).
    static func host(fromRoomID roomID: String) -> String? {
        let raw = roomID.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }

        // Full URL form (jitsi room URLs): let URLComponents pull the host.
        if raw.contains("://"), let host = URLComponents(string: raw)?.host, !host.isEmpty {
            return host
        }

        // `host/path` or bare host: take the authority up to the first slash.
        let authority = raw.split(separator: "/", maxSplits: 1).first.map(String.init) ?? raw
        // Strip an optional `user@` and `:port`.
        let hostPart = authority.split(separator: "@").last.map(String.init) ?? authority
        let host = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
        // Heuristic: a real host has a dot (a label like "myroom" doesn't).
        guard host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") else { return nil }
        return host
    }

    /// Resolves a host to its current A/AAAA addresses. IPs rotate per carrier
    /// load-balancing, so this is called on demand (and can be re-run). Uses
    /// the system resolver via NWEndpoint — no extra entitlement needed.
    static func resolve(host: String, timeout: TimeInterval = 5) async -> [String] {
        await withCheckedContinuation { continuation in
            let gate = ContinuationGate() // #400 was: ResolveGate (local copy)
            // Port is irrelevant for resolution; 443 is a valid placeholder.
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: 443)
            let conn = NWConnection(to: endpoint, using: .tcp)

            var timeoutItem: DispatchWorkItem?

            func finish(_ ips: [String]) {
                if gate.fire() {
                    timeoutItem?.cancel()
                    conn.cancel()
                    continuation.resume(returning: ips)
                }
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // #387: read the resolved address only once the path is
                    // actually up. `.preparing` could still expose the unresolved
                    // hostname, which `resolvedIP` would then hand back as a fake
                    // "resolved IP". #387 was: also matched `.preparing`.
                    finish(Self.resolvedIP(from: conn.currentPath?.remoteEndpoint).map { [$0] } ?? [])
                case .failed, .cancelled:
                    finish([])
                default:
                    break
                }
            }
            conn.start(queue: .global())

            timeoutItem = DispatchWorkItem { finish([]) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem!)
        }
    }

    /// Pulls the dotted/colon address string out of a resolved NWEndpoint.
    private static func resolvedIP(from endpoint: NWEndpoint?) -> String? {
        guard case let .hostPort(host, _)? = endpoint else { return nil }
        switch host {
        case .ipv4(let addr): return "\(addr)".split(separator: "%").first.map(String.init)
        case .ipv6(let addr): return "\(addr)".split(separator: "%").first.map(String.init)
        // #387 was: `.name(let name, _): return name.contains(".") ? name : nil`
        // — a `.name` here means the endpoint is still the unresolved hostname
        // (which has a dot), so returning it handed the domain back as a fake
        // "resolved IP". Report no address instead so the card stays honest.
        case .name: return nil
        @unknown default: return nil
        }
    }
}

// #400: the resolve continuation's single-shot gate (resume-at-most-once across
// the state callback and the timeout) is now the shared `ContinuationGate` in
// App/Utilities/ContinuationGate.swift — previously a local `ResolveGate` copy.
