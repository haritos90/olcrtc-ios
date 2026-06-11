import Foundation

// MARK: - SpeedTest
//
// Measures three values against a selectable speed-test provider:
//   - ping (TTFB, averaged across N samples, warmup discarded)
//   - download throughput
//   - upload throughput
//
// Mode-aware (.direct or .tunnel) — see SOCKSSession for the session factory.
//
// #285: the tunnel is a narrow, high-latency pipe (vp8channel ≈ <1 Mbps), so the
// test degrades gracefully there — serial (not parallel) measurements, scaled-down
// payloads, longer timeouts, and ping failure tolerated (reported "n/a", not an
// error). The provider is user-selectable (Settings) since Cloudflare can be slow
// or blocked. A datachannel hint is surfaced when a slow video-transport tunnel is
// the bottleneck.

/// A selectable speed-test backend. Cloudflare is parametric (any byte count +
/// upload + trace ping); fixed-file providers (e.g. OVH) serve set sizes, have no
/// upload endpoint, and are pinged with a HEAD on the small file.
struct SpeedTestProvider: Identifiable, Equatable {
    let id: String
    let label: String           // shown in Settings + the log header
    let host: String
    let parametric: Bool        // Cloudflare-style `/__down?bytes=N` + `/__up`
    let supportsUpload: Bool
    let fixedSmallURL: String?  // tunnel payload (fixed-file providers)
    let fixedLargeURL: String?  // direct payload (fixed-file providers)

    /// Download URL for the given mode — tunnel gets the small payload.
    func downloadURL(mode: RouteMode) -> String {
        if parametric {
            let n = mode == .tunnel ? AppConstants.SpeedTest.downloadBytesTunnel
                                    : AppConstants.SpeedTest.downloadBytesDirect
            return "https://\(host)/__down?bytes=\(n)"
        }
        return (mode == .tunnel ? fixedSmallURL : fixedLargeURL) ?? ""
    }

    /// Upload endpoint, or nil when the provider has none (upload → n/a).
    var uploadURLString: String? { supportsUpload ? "https://\(host)/__up" : nil }

    /// A cheap HEAD target for the ping samples.
    func pingURL() -> String {
        parametric ? "https://\(host)/cdn-cgi/trace" : (fixedSmallURL ?? "https://\(host)/")
    }
}

/// Snapshot of one speed-test run: ping, download, and upload figures from a single provider.
struct SpeedResult {
    let service     : String       // provider that served the test
    let mode        : RouteMode
    let pingMs      : Double?
    let downloadMbps: Double?
    let uploadMbps  : Double?
    let error       : String?
}

/// Measures ping, download, and upload throughput against the selected provider,
/// optionally routing via the SOCKS5 tunnel to compare direct vs. tunnelled
/// performance. Publishes a single `lastResult`.
@MainActor
final class SpeedTest: ObservableObject {

    @Published var lastResult: SpeedResult?
    @Published var isTesting  = false

    private let pingSamples = AppConstants.SpeedTest.pingSamples

    /// `carrier`/`transport` (when tunnelled) are logged in the header and drive
    /// the datachannel speed hint; the caller passes them from the active record.
    func run(via mode: RouteMode, carrier: String? = nil, transport: String? = nil) async {
        guard !isTesting else { return }
        isTesting = true
        defer { isTesting = false }

        let provider = AppConstants.SpeedTest.provider(id: SettingsStore.shared.speedTestProviderID)

        LogStore.shared.startSession(.speed)
        // #285: header records the provider + connection type (direct/tunnel, and
        // carrier/transport when tunnelled) so a slow run is interpretable.
        var header = "→ Speed test via \(provider.label) (\(mode.label))"
        if mode == .tunnel, let c = carrier, let t = transport { header += " — \(c)/\(t)" }
        LogStore.shared.log(.speed, header)

        // Suppress keep-alive probes for the duration — extra tunnel connections
        // mid-test add congestion and cause keep-alive false failures.
        if mode == .tunnel { SOCKSSession.noteTunnelActivity(forAtLeast: 180) }

        let p: Double?, d: Double?, u: Double?
        if mode == .tunnel {
            // Serialise on the narrow pipe: parallel connections trigger
            // "remote not ready" on vp8channel. Each step tolerates its own
            // failure and still reports the others (partial results).
            p = await measurePing(mode: mode, provider: provider)
            d = await measureDownload(mode: mode, provider: provider)
            u = await measureUpload(mode: mode, provider: provider)
        } else {
            // Direct: parallel for speed.
            async let ping     = measurePing(mode: mode, provider: provider)
            async let download = measureDownload(mode: mode, provider: provider)
            async let upload   = measureUpload(mode: mode, provider: provider)
            (p, d, u) = await (ping, download, upload)
        }

        if mode == .tunnel { SOCKSSession.noteTunnelActivity() }

        // Only an error when *everything* failed; a missing ping or upload is fine.
        let allFailed = p == nil && d == nil && u == nil
        let errorMsg  = allFailed ? L10n.speedAllFailed.localized() : nil
        lastResult = SpeedResult(service: provider.label, mode: mode,
                                 pingMs: p, downloadMbps: d, uploadMbps: u, error: errorMsg)

        // #291 was: ?? (provider.supportsUpload ? "n/a" : "—") — UL is now always
        // attempted (Cloudflare fallback for no-upload providers), so nil means the
        // attempt failed ("n/a"), not "no endpoint" ("—").
        let upStr = u.map { String(format: "%.2fMbps", $0) } ?? "n/a"
        LogStore.shared.log(.speed,
            "  ping=\(p.map { String(format: "%.0fms", $0) } ?? "n/a") " +
            "down=\(d.map { String(format: "%.2fMbps", $0) } ?? "n/a") " +
            "up=\(upStr)")

        // #285: surface the lever — a slow video-transport tunnel is bandwidth-
        // limited by design; datachannel is far faster where the network allows.
        // Only hint on a *measured* slow download (not a total failure, which is
        // a connectivity problem datachannel wouldn't fix).
        let videoTransports = ["vp8channel", "seichannel", "videochannel"]
        if mode == .tunnel, let t = transport, videoTransports.contains(t), let d, d < 5 {
            LogStore.shared.log(.speed, L10n.speedDatachannelHint.localized())
        }
    }

    // MARK: Measurements

    private func measurePing(mode: RouteMode, provider: SpeedTestProvider) async -> Double? {
        guard let url = URL(string: provider.pingURL()) else { return nil }
        let timeout = mode == .tunnel ? AppConstants.SpeedTest.pingTimeoutTunnel
                                      : AppConstants.SpeedTest.pingTimeoutDirect
        var samples: [Double] = []
        for i in 0..<pingSamples {
            // Fresh session per sample — avoids HTTP/2 connection reuse, which
            // causes error 310 when the tunnel is busy with download/upload.
            let session = SOCKSSession.make(mode: mode, timeout: timeout)
            let start = Date()
            do {
                var req = URLRequest(url: url)
                req.httpMethod = "HEAD"
                _ = try await session.data(for: req)
                if i > 0 { samples.append(Date().timeIntervalSince(start) * 1000) }  // discard warmup
            } catch {
                // Tolerated (#285): one failed sample is skipped; we only return
                // nil ("ping n/a") if *every* sample fails.
                LogStore.shared.log(.speed, "  ping sample \(i): n/a (\(error.localizedDescription))")
            }
        }
        guard !samples.isEmpty else { return nil }
        return samples.reduce(0, +) / Double(samples.count)
    }

    private func measureDownload(mode: RouteMode, provider: SpeedTestProvider) async -> Double? {
        guard let url = URL(string: provider.downloadURL(mode: mode)) else { return nil }
        let timeout = mode == .tunnel ? AppConstants.SpeedTest.xferTimeoutTunnel
                                      : AppConstants.SpeedTest.xferTimeoutDirect
        do {
            let start = Date()
            let (data, _) = try await SOCKSSession.make(mode: mode, timeout: timeout).data(from: url)
            let elapsed = Date().timeIntervalSince(start)
            return Double(data.count) * 8 / elapsed / 1_000_000
        } catch {
            LogStore.shared.log(.speed, "  download: n/a (\(error.localizedDescription))")
            return nil
        }
    }

    // POST a fixed buffer of zeros — content doesn't matter, only byte count.
    private func measureUpload(mode: RouteMode, provider: SpeedTestProvider) async -> Double? {
        // boc #291: OVH (and any fixed-file provider) has no upload sink, so UL used
        // to show nothing. Fall back to Cloudflare's parametric /__up so upload is
        // still measured against a real endpoint.
        let uploadProvider = AppConstants.SpeedTest.uploadProvider(for: provider)
        if uploadProvider.id != provider.id {
            LogStore.shared.log(.speed,
                "  upload: \(provider.label) has no upload endpoint — using \(uploadProvider.label)")
        }
        guard let urlStr = uploadProvider.uploadURLString, let url = URL(string: urlStr) else {
            return nil   // no upload endpoint even after fallback → reported as "—"
        }
        // eoc #291
        let bytes = mode == .tunnel ? AppConstants.SpeedTest.uploadBytesTunnel
                                    : AppConstants.SpeedTest.uploadBytesDirect
        let timeout = mode == .tunnel ? AppConstants.SpeedTest.xferTimeoutTunnel
                                      : AppConstants.SpeedTest.xferTimeoutDirect
        let body = Data(count: bytes)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        do {
            let start = Date()
            _ = try await SOCKSSession.make(mode: mode, timeout: timeout).data(for: req)
            let elapsed = Date().timeIntervalSince(start)
            return Double(body.count) * 8 / elapsed / 1_000_000
        } catch {
            LogStore.shared.log(.speed, "  upload: n/a (\(error.localizedDescription))")
            return nil
        }
    }
}
