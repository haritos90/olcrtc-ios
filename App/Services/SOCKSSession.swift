import Foundation

// MARK: - RouteMode
//
// Per-request choice of whether to use the local olcrtc SOCKS5 tunnel
// or hit the network directly. Different from `RoutingMode`, which is
// the user's overall routing policy. Per-request decisions are made by
// IP checks and the speed test based on the current tunnel state.

enum RouteMode: String {
    case direct
    case tunnel

    var label: String {
        switch self {
        case .direct: return L10n.routingDirect.localized()
        case .tunnel: return L10n.routingViaTunnel.localized()
        }
    }
}

// MARK: - SOCKSSession
//
// Single source of truth for building URLSessions that optionally route
// through the local SOCKS5 listener. Used by TunnelManager (for tunnel
// verification), IPChecker, and SpeedTest. Without this helper the same
// proxy dictionary appeared in three places and drifted independently.
//
// NOTE on the dictionary keys: kCFNetworkProxiesSOCKS* constants are
// macOS-only. iOS accepts the literal string keys below and routes
// URLSession through the in-process socks5 proxy at the given port.

enum SOCKSSession {
    static func make(mode: RouteMode, timeout: TimeInterval = 20) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest  = timeout
        cfg.timeoutIntervalForResource = timeout + 10
        if mode == .tunnel {
            cfg.connectionProxyDictionary = [
                "SOCKSEnable": 1,
                "SOCKSProxy" : "127.0.0.1",
                "SOCKSPort"  : TunnelManager.socksPort
            ] as [AnyHashable: Any]
        }
        return URLSession(configuration: cfg)
    }

    /// Notify TunnelManager that a successful tunnel request just completed.
    /// Call after any successful transfer through the SOCKS5 tunnel so keep-alive
    /// skips its HTTP probe when the tunnel is clearly busy.
    static func noteTunnelActivity(forAtLeast seconds: TimeInterval = 0) {
        TunnelManager.lastTunnelActivityDate = Date().addingTimeInterval(seconds)
    }
}
