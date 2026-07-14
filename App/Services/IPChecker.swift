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

    // Endpoints live in AppConstants.ipCheckServices; the user enables a subset
    // in Settings (#286). Preserve the catalogue order; if the user disabled
    // everything, fall back to the defaults so the check never queries nothing.
    private var sources: [(label: String, url: String)] {
        let enabled = SettingsStore.shared.enabledIPSources
        let chosen = AppConstants.ipCheckServices.filter { enabled.contains($0.label) }
        if chosen.isEmpty {
            return AppConstants.ipCheckServices.filter {
                AppConstants.defaultEnabledIPCheckLabels.contains($0.label)
            }
        }
        return chosen
    }

    func checkAll(via mode: RouteMode) async {
        guard !isChecking else { return }
        isChecking = true
        results    = []
        defer { isChecking = false }

        let chosen = sources
        // #324: open the diagnostics session/writer before the first line, the
        // same way SpeedTest does — otherwise IP-check lines never reach
        // diagnostics.log until a speed test happens to create the writer first,
        // yet the Logs tab header already advertises that file.
        LogStore.shared.startSession(.diagnostics)
        LogStore.shared.log(.diagnostics, "---")
        // #286: header records the connection type (direct/tunnel) + how many
        // sources are queried (the user can trim the list in Settings).
        LogStore.shared.log(.diagnostics, "→ IP check (\(mode.label)) — \(chosen.count) source(s)")

        let session = SOCKSSession.make(mode: mode)
        for src in chosen {
            LogStore.shared.log(.diagnostics, "  GET \(src.url)")
            let r = await Self.fetchIP(label: src.label, urlStr: src.url,
                                        mode: mode, session: session)
            if let ip = r.ip {
                LogStore.shared.log(.diagnostics, "  ✓ \(src.label): \(ip)")
            } else {
                LogStore.shared.log(.diagnostics, "  ✗ \(src.label): \(r.error ?? "unknown")")
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

    // MARK: - Exit geo (#439)
    //
    // On connect the log shows the exit IP but not WHERE it is — yet the location
    // governs what the exit can reach (e.g. some destinations are blocked from some
    // regions), so it's the difference between "the app is broken" and "this exit
    // can't reach X". One line at connect time — `→ exit = <ip> (<city>, <CC> ·
    // <org>)` — makes the exit's country obvious at a glance in the connection log.

    /// Parsed geo for the tunnel exit (any field may be absent).
    struct ExitGeo: Equatable {
        var ip: String?
        var city: String?
        var country: String?     // ISO-2, e.g. "RU"
        var org: String?         // e.g. "AS9123 JSC TIMEWEB"
    }

    /// Pure (unit-tested) parse of an `ipinfo.io/json` body. Returns nil only when
    /// nothing usable is present, so a rate-limited/garbage response is silent.
    static func parseGeo(_ data: Data) -> ExitGeo? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func field(_ key: String) -> String? {
            guard let s = (obj[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !s.isEmpty else { return nil }
            return s
        }
        let geo = ExitGeo(ip: field("ip"), city: field("city"),
                          country: field("country"), org: field("org"))
        return geo == ExitGeo() ? nil : geo
    }

    /// Pure (unit-tested) one-line rendering for the connection log. Logs are never
    /// IP-masked (#337), so the full value is shown.
    static func exitGeoLine(_ geo: ExitGeo) -> String {
        var paren: [String] = []
        let place = [geo.city, geo.country].compactMap { $0 }.joined(separator: ", ")
        if !place.isEmpty { paren.append(place) }
        if let org = geo.org { paren.append(org) }
        let suffix = paren.isEmpty ? "" : " (\(paren.joined(separator: " · ")))"
        return "→ exit = \(geo.ip ?? "?")\(suffix)"
    }

    /// Fetches `ipinfo.io/json` through the given (tunnel) session and parses it.
    /// Best-effort: any failure returns nil and is not logged as an error.
    static func fetchExitGeo(session: URLSession) async -> ExitGeo? {
        guard let url = URL(string: "https://ipinfo.io/json") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("curl/8", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await session.data(for: req) else { return nil }
        return parseGeo(data)
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
