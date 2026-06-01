import Foundation
import Network

// MARK: - IPChecker
//
// Performs external-IP lookups against a small set of public services.
// The caller picks `.direct` or `.tunnel` (see RouteMode in SOCKSSession.swift).
// We surface `mode` on each result so the UI can label rows independently —
// useful once per-host routing rules arrive.

/// Single IP-lookup result from one external service, tagged with the route mode used.
struct IPResult: Identifiable {
    let id    = UUID()
    let label : String      // service name (e.g. "api.ipify.org")
    let ip    : String?
    let error : String?
    let mode  : RouteMode
}

/// Queries three public IP-echo services in parallel, routing each request
/// via direct or tunnel SOCKS5 as requested. Results are published so the UI
/// can show per-service rows with the observed external IP.
@MainActor
final class IPChecker: ObservableObject {

    @Published var results   : [IPResult] = []
    @Published var isChecking = false

    // Endpoints live in AppConstants.ipCheckServices.
    private var sources: [(label: String, url: String)] {
        AppConstants.ipCheckServices
    }

    func checkAll(via mode: RouteMode) async {
        guard !isChecking else { return }
        isChecking = true
        results    = []
        defer { isChecking = false }

        LogStore.shared.log(.ip, "---")
        LogStore.shared.log(.ip, "→ IP check (\(mode.label))")

        let session = SOCKSSession.make(mode: mode)
        for src in sources {
            LogStore.shared.log(.ip, "  GET \(src.url)")
            let r = await Self.fetchIP(label: src.label, urlStr: src.url,
                                        mode: mode, session: session)
            if let ip = r.ip {
                LogStore.shared.log(.ip, "  ✓ \(src.label): \(ip)")
            } else {
                LogStore.shared.log(.ip, "  ✗ \(src.label): \(r.error ?? "unknown")")
            }
            results.append(r)
        }
    }

    private static func fetchIP(label: String, urlStr: String,
                                 mode: RouteMode, session: URLSession) async -> IPResult {
        guard let url = URL(string: urlStr) else {
            return IPResult(label: label, ip: nil, error: "Invalid URL", mode: mode)
        }
        do {
            var req = URLRequest(url: url)
            // Some services (ifconfig.me) return HTML to browsers and plain
            // text to non-browser UAs. Curl UA gives us plain text reliably.
            req.setValue("curl/8", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await session.data(for: req)
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if isValidIP(text) {
                if mode == .tunnel { SOCKSSession.noteTunnelActivity() }
                return IPResult(label: label, ip: text, error: nil, mode: mode)
            }
            return IPResult(label: label, ip: nil, error: "Unparseable response", mode: mode)
        } catch {
            return IPResult(label: label, ip: nil, error: error.localizedDescription, mode: mode)
        }
    }

    /// Strict IP parsing via Apple's Network framework — rejects garbage like
    /// "Hello.World" or "Error: 500" that the old `contains(".")` check accepted.
    ///
    /// For IPv4 we additionally require the standard dotted-quad form: Apple's
    /// `IPv4Address(_:)` follows `inet_aton` and would otherwise accept
    /// abbreviated forms like "1.2.3" (treated as "1.2.0.3").
    static func isValidIP(_ text: String) -> Bool {
        if IPv4Address(text) != nil {
            return text.split(separator: ".", omittingEmptySubsequences: false).count == 4
        }
        return IPv6Address(text) != nil
    }
}
