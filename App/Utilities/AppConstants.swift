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

    /// Public IP-echo services `IPChecker` can query (#286). The user picks which
    /// are active in Settings (persisted in `SettingsStore.enabledIPSources`,
    /// keyed by `label`), so this is the *catalogue* — querying all ten every
    /// time is slow and redundant once sources agree (#216 collapses them).
    /// Every entry returns a **bare IP over HTTPS** with a curl UA (verified
    /// 2026-06); JSON-only endpoints (e.g. `api.2ip.io`) are intentionally out.
    /// The RU / ru-zone block stays reachable when public resolvers are blocked
    /// from Russian carriers — `icanhazip.com` is in the catalogue but off by
    /// default (corporate Falcon MITM strips its certificate in some networks).
    static let ipCheckServices: [(label: String, url: String)] = [
        // International
        ("api.ipify.org",         "https://api.ipify.org"),
        ("ipinfo.io",             "https://ipinfo.io/ip"),
        ("ifconfig.me",           "https://ifconfig.me/ip"),
        ("icanhazip.com",         "https://icanhazip.com"),
        ("ident.me",              "https://ident.me"),
        ("ipapi.co",              "https://ipapi.co/ip"),
        ("checkip.amazonaws.com", "https://checkip.amazonaws.com"),
        // Russian / ru-zone
        ("2ip.ru",                "https://2ip.ru"),
        ("2ip.io",                "https://2ip.io"),
        ("ip.beget.ru",           "https://ip.beget.ru"),
    ]

    /// Labels of `ipCheckServices` enabled out of the box — a fast, balanced
    /// subset (three international + one RU) rather than all ten. The rest are
    /// opt-in via Settings. Used as the fallback when the user's enabled set is
    /// missing (first launch / migration) or empty.
    static let defaultEnabledIPCheckLabels: Set<String> = [
        "api.ipify.org", "ipinfo.io", "ifconfig.me", "2ip.ru",
    ]

    /// Speed-test configuration (#285).
    enum SpeedTest {
        static let pingSamples = 4             // first sample is discarded as warmup

        // Mode-aware payloads + timeouts. The tunnel (vp8channel ≈ <1 Mbps)
        // can't move 5 MB inside 60s, so it gets smaller transfers + more time.
        static let downloadBytesDirect = 5_000_000
        static let downloadBytesTunnel = 1_000_000
        static let uploadBytesDirect   = 2_000_000
        static let uploadBytesTunnel   =   500_000
        static let pingTimeoutDirect: TimeInterval = 5
        static let pingTimeoutTunnel: TimeInterval = 10
        static let xferTimeoutDirect: TimeInterval = 60
        static let xferTimeoutTunnel: TimeInterval = 90

        // User-selectable providers. Cloudflare is parametric (anycast, low RTT,
        // `/__down`+`/__up`+trace, no API key); OVH serves fixed-size files
        // (download + HEAD ping, no upload) and is the non-Cloudflare fallback
        // when Cloudflare is slow/blocked. Both verified to serve real bytes over
        // HTTPS (2026-06).
        static let providers: [SpeedTestProvider] = [
            SpeedTestProvider(id: "cloudflare", label: "speed.cloudflare.com",
                              host: "speed.cloudflare.com", parametric: true, supportsUpload: true,
                              fixedSmallURL: nil, fixedLargeURL: nil),
            SpeedTestProvider(id: "ovh", label: "proof.ovh.net (OVH)",
                              host: "proof.ovh.net", parametric: false, supportsUpload: false,
                              fixedSmallURL: "https://proof.ovh.net/files/1Mb.dat",
                              fixedLargeURL: "https://proof.ovh.net/files/10Mb.dat"),
        ]
        static let defaultProviderID = "cloudflare"
        static func provider(id: String) -> SpeedTestProvider {
            providers.first { $0.id == id } ?? providers[0]
        }
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
