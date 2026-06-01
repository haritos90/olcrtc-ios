import Foundation

// MARK: - SpeedTest
//
// Measures three values against a configurable speed-test host:
//   - ping (TTFB, averaged across N samples, warmup discarded)
//   - download throughput
//   - upload throughput
//
// Mode-aware (.direct or .tunnel) — see SOCKSSession for the session factory.
//
// Why Cloudflare? Anycast → low baseline RTT, public /__down + /__up endpoints
// accept arbitrary payload sizes, no API key needed.

/// Snapshot of one speed-test run: ping, download, and upload figures from a single host.
struct SpeedResult {
    let service     : String       // host that served the test
    let mode        : RouteMode
    let pingMs      : Double?
    let downloadMbps: Double?
    let uploadMbps  : Double?
    let error       : String?
}

/// Measures ping, download, and upload throughput against Cloudflare's
/// speed-test endpoints, optionally routing via the SOCKS5 tunnel to compare
/// direct vs. tunnelled performance. Publishes a single `lastResult`.
@MainActor
final class SpeedTest: ObservableObject {

    @Published var lastResult: SpeedResult?
    @Published var isTesting  = false

    // Endpoints & sizes live in AppConstants.SpeedTest so swapping providers
    // is a single-file change.
    private let defaultHost   = AppConstants.SpeedTest.host
    private let downloadBytes = AppConstants.SpeedTest.downloadBytes
    private let uploadBytes   = AppConstants.SpeedTest.uploadBytes
    private let pingSamples   = AppConstants.SpeedTest.pingSamples

    func run(via mode: RouteMode) async {
        guard !isTesting else { return }
        isTesting = true
        defer { isTesting = false }

        LogStore.shared.startSession(.speed)
        LogStore.shared.log(.speed, "→ Speed test via \(defaultHost) (\(mode.label))")

        // Suppress keep-alive probes for the duration of the speed test.
        // Without this, keep-alive opens 3 extra tunnel connections every 30s
        // mid-test, adding congestion and causing keep-alive false failures.
        if mode == .tunnel { SOCKSSession.noteTunnelActivity(forAtLeast: 120) }

        // Parallel: all three measurements run simultaneously for fast results.
        // Previously changed to sequential to fix "ping sample 1 error: 310",
        // but that error was caused by tunnel reconnects every 26s (now fixed
        // via 3-failure keep-alive policy). Sequential mode caused 1-minute+
        // waits due to SOCKS5 connection setup overhead stacking up.
        async let ping     = measurePing(mode: mode)
        async let download = measureDownload(mode: mode)
        async let upload   = measureUpload(mode: mode)
        let (p, d, u) = await (ping, download, upload)

        if mode == .tunnel { SOCKSSession.noteTunnelActivity() }

        let allFailed = p == nil && d == nil && u == nil
        let errorMsg  = allFailed ? "All measurements failed" : nil
        lastResult = SpeedResult(service: defaultHost, mode: mode,
                                 pingMs: p, downloadMbps: d, uploadMbps: u, error: errorMsg)

        LogStore.shared.log(.speed,
            "  ping=\(p.map { String(format: "%.0fms", $0) } ?? "—") " +
            "down=\(d.map { String(format: "%.2fMbps", $0) } ?? "—") " +
            "up=\(u.map { String(format: "%.2fMbps", $0) } ?? "—")")
    }

    // MARK: Measurements

    private func measurePing(mode: RouteMode) async -> Double? {
        guard let url = URL(string: "https://\(defaultHost)/cdn-cgi/trace") else { return nil }

        var samples: [Double] = []
        for i in 0..<pingSamples {
            // Fresh session per sample — avoids HTTP/2 connection reuse across requests,
            // which causes error 310 when the tunnel is busy with download/upload.
            let session = SOCKSSession.make(mode: mode, timeout: 5)
            let start = Date()
            do {
                var req = URLRequest(url: url)
                req.httpMethod = "HEAD"
                _ = try await session.data(for: req)
                if i > 0 {   // discard sample 0 (TLS handshake / cold cache)
                    samples.append(Date().timeIntervalSince(start) * 1000)
                }
            } catch {
                LogStore.shared.log(.speed, "  ping sample \(i) error: \(error.localizedDescription)")
                // Single failure is transient — skip this sample, continue to the next.
                // Only give up if we collect no successful samples at all.
            }
        }
        guard !samples.isEmpty else { return nil }
        return samples.reduce(0, +) / Double(samples.count)
    }

    private func measureDownload(mode: RouteMode) async -> Double? {
        guard let url = URL(string:
            "https://\(defaultHost)/__down?bytes=\(downloadBytes)") else { return nil }
        do {
            let start = Date()
            let (data, _) = try await SOCKSSession.make(mode: mode, timeout: 60).data(from: url)
            let elapsed = Date().timeIntervalSince(start)
            return Double(data.count) * 8 / elapsed / 1_000_000
        } catch {
            LogStore.shared.log(.speed, "  download error: \(error.localizedDescription)")
            return nil
        }
    }

    // POST a fixed buffer of zeros — content doesn't matter, only byte count.
    private func measureUpload(mode: RouteMode) async -> Double? {
        guard let url = URL(string: "https://\(defaultHost)/__up") else { return nil }
        let body = Data(count: uploadBytes)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        do {
            let start = Date()
            _ = try await SOCKSSession.make(mode: mode, timeout: 60).data(for: req)
            let elapsed = Date().timeIntervalSince(start)
            return Double(body.count) * 8 / elapsed / 1_000_000
        } catch {
            LogStore.shared.log(.speed, "  upload error: \(error.localizedDescription)")
            return nil
        }
    }
}
