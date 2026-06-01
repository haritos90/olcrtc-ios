import Foundation

// MARK: - AppConstants
//
// Centralised compile-time constants — endpoints, presets, fixed sizes.
// Pure values only: no state, no logic. Anything user-tunable lives in
// SettingsStore instead.
//
// The goal is to keep "what URL do we ping for X?" out of the view and
// service files so that swapping providers is a single-file change.

enum AppConstants {

    /// URLs probed by `TunnelManager.verifyTunnel()` to confirm end-to-end
    /// traffic. Tried in order; the probe succeeds as soon as any returns 200.
    /// Fallbacks matter — `api.ipify.org` and `ipinfo.io` have both been
    /// observed to be blocked from some Russian carriers, leaving the
    /// probe permanently failing with only two entries. `ifconfig.me` is a
    /// third independent provider already trusted by `ipCheckServices`.
    static let tunnelVerifyURLs: [String] = [
        "https://api.ipify.org",
        "https://ipinfo.io/ip",
        "https://ifconfig.me/ip",
    ]

    /// Endpoint probed by `TunnelManager.ping` (#234) to measure per-connection
    /// latency through an isolated MobilePing client. The classic connectivity
    /// "204 No Content" endpoint is ideal for an RTT probe: it returns an empty
    /// body, so the measured time reflects the round trip rather than payload
    /// transfer. Google is reachable from the RU carriers we target.
    static let pingProbeURL = "https://www.google.com/generate_204"

    /// Quick-pick DNS presets shown in Settings → DNS. `IP:port` strings
    /// passed verbatim to the Go runtime and to the server install script.
    /// Yandex is the default — reliable from Russian VPS.
    static let dnsPresets: [(label: String, value: String)] = [
        ("Yandex",     "77.88.8.8:53"),
        ("Cloudflare", "1.1.1.1:53"),
        ("Google",     "8.8.8.8:53"),
    ]

    /// Russian-carrier DNS presets — useful when the device is on cellular and
    /// the ISP intercepts requests to public resolvers (8.8.8.8 etc.). These
    /// resolve only from inside the carrier's network. Labels are L10n keys
    /// so carrier names follow the user's selected language.
    static let ruCarrierDnsPresets: [(label: L10n, value: String)] = [
        (.dnsLabelMts,     "213.87.0.1:53"),
        (.dnsLabelBeeline, "213.234.192.8:53"),
        (.dnsLabelMegafon, "83.149.32.66:53"),
        (.dnsLabelTele2,   "89.104.103.1:53"),
        (.dnsLabelYota,    "83.149.32.66:53"),   // MVNO on MegaFon, shares its DNS
    ]

    /// Public IP-echo services queried in parallel by `IPChecker`.
    /// `icanhazip.com` deliberately omitted — corporate Falcon MITM strips
    /// its certificate in our test environment.
    static let ipCheckServices: [(label: String, url: String)] = [
        ("api.ipify.org", "https://api.ipify.org"),
        ("ipinfo.io",     "https://ipinfo.io/ip"),
        ("ifconfig.me",   "https://ifconfig.me/ip"),
    ]

    /// Cloudflare speed-test configuration. Anycast = low baseline RTT;
    /// `/__down` and `/__up` accept arbitrary payload sizes with no API key.
    enum SpeedTest {
        static let host          = "speed.cloudflare.com"
        static let downloadBytes = 5_000_000   // 5 MB
        static let uploadBytes   = 2_000_000   // 2 MB (uploads are typically slower)
        static let pingSamples   = 4           // first sample is discarded as warmup
    }

    /// DNS-over-HTTPS resolver endpoints used by `SubscriptionFetcher` as a
    /// fallback when system DNS is hijacked (common from RU networks). Tried
    /// in order; first one to return an A record wins. Both speak the JSON
    /// API (`Accept: application/dns-json`), so any provider that supports it
    /// is a drop-in. Avoid resolvers that require POST + DNS wire format.
    static let dohEndpoints: [String] = [
        "https://1.1.1.1/dns-query",
        "https://8.8.8.8/dns-query",
    ]

    /// Uniform request timeout for `SubscriptionFetcher`. Replaces the prior
    /// 30 s direct / 10 s DoH split — same budget for both keeps the worst-case
    /// wall time predictable (max ≈ 2 × timeout: one direct attempt + one
    /// DoH-then-IP attempt). 15 s is long enough for slow mobile + DoH round
    /// trips and short enough to fail fast on truly broken hosts.
    static let subscriptionFetchTimeout: TimeInterval = 15

    /// Default Jitsi server base URL sent as `OLCRTC_JITSI_URL` during install.
    /// The server prefixes short room names with this base and uses it for the
    /// auto-generated room when no room is given. Keep in sync with the
    /// `${OLCRTC_JITSI_URL:-...}` default in `scripts/srv.sh`.
    static let defaultJitsiBaseURL = "https://meet1.arbitr.ru"
}
