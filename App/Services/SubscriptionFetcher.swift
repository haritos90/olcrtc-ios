import Foundation
import Network

// MARK: - SubscriptionFetcher
//
// Downloads the content of a URL, with automatic fallback to
// DNS-over-HTTPS (DoH) when the system DNS fails — common in Russian
// networks where ISPs block authoritative DNS for foreign domains.
//
// Flow:
//  1. Try a normal URLSession GET.
//  2. On .cannotFindHost / .dnsLookupFailed: resolve the hostname via
//     Cloudflare DoH (1.1.1.1/dns-query), then connect directly to the
//     resolved IP with the original Host header and proper TLS validation
//     against the original hostname.
//
// The DoH fallback is intentionally narrow: it only fires on DNS errors,
// not on connection timeouts or HTTP errors. If the server itself is
// blocked (port 443 refused), DoH can't help and we surface the real error.

enum SubscriptionFetcher {

    enum FetchError: LocalizedError {
        case dnsResolutionFailed(String)
        case invalidResponse(Int)
        case noAddressReturned

        var errorDescription: String? {
            switch self {
            case .dnsResolutionFailed(let h): return L10n.subDohFailed_fmt.formatted(h)
            case .invalidResponse(let code):  return L10n.subInvalidResponse_fmt.formatted(code)
            case .noAddressReturned:          return L10n.subNoAddress.localized()
            }
        }
    }

    static func fetch(from url: URL) async throws -> String {
        do {
            return try await directFetch(url: url)
        } catch let error as URLError
            where error.code == .cannotFindHost || error.code == .dnsLookupFailed {
            // System DNS failed — try DoH
            guard let host = url.host else { throw error }
            let ip = try await resolveViaDoH(host: host)
            return try await fetchViaIP(url: url, ip: ip, originalHost: host)
        }
    }

    // MARK: - Session config
    //
    // Ephemeral sessions only: the prior `URLSession.shared` versions of the
    // direct + DoH fetches would inherit the app-wide URL cache, so a
    // negative DNS or 502 result from one network could persist after the
    // device switched networks. `cachePolicy: .reloadIgnoringLocalAndRemoteCacheData`
    // is the per-request belt to ephemeral's session-config braces. We also
    // build a fresh session per call so the in-flight connection pool is
    // discarded between attempts (HTTP/2 connection reuse across a network
    // switch was causing stale-NAT timeouts in testing).

    private static func makeEphemeralSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy   = .reloadIgnoringLocalAndRemoteCacheData
        cfg.urlCache             = nil
        cfg.timeoutIntervalForRequest = AppConstants.subscriptionFetchTimeout
        return URLSession(configuration: cfg)
    }

    // MARK: - Direct fetch

    private static func directFetch(url: URL) async throws -> String {
        var req = URLRequest(url: url, timeoutInterval: AppConstants.subscriptionFetchTimeout)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.setValue("text/plain,text/markdown,*/*", forHTTPHeaderField: "Accept")
        let session = makeEphemeralSession()
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FetchError.invalidResponse(http.statusCode)
        }
        guard let str = String(data: data, encoding: .utf8)
                     ?? String(data: data, encoding: .isoLatin1),
              !str.isEmpty else {
            throw URLError(.cannotDecodeRawData)
        }
        return str
    }

    // MARK: - DNS-over-HTTPS resolution

    /// Resolves `host` via the AppConstants.dohEndpoints list. Tries each
    /// endpoint in order; the first one to return a valid A record wins.
    /// If every endpoint fails (network unreachable, all blocked, malformed
    /// response), throws the LAST error so the caller sees a real diagnostic
    /// instead of the first stale one — typically the last is the most
    /// representative of the current network condition.
    private static func resolveViaDoH(host: String) async throws -> String {
        var lastError: Error = FetchError.dnsResolutionFailed(host)
        for endpoint in AppConstants.dohEndpoints {
            do {
                return try await resolveViaDoH(host: host, endpoint: endpoint)
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError
    }

    /// Single-endpoint DoH probe. Exposed `internal` so tests can drive the
    /// URL-building + JSON-decoding path against a known endpoint string
    /// without spinning up the whole fallback loop.
    static func resolveViaDoH(host: String, endpoint: String) async throws -> String {
        guard var comps = URLComponents(string: endpoint) else {
            throw FetchError.dnsResolutionFailed(host)
        }
        comps.queryItems = [
            URLQueryItem(name: "name", value: host),
            URLQueryItem(name: "type", value: "A"),
        ]
        guard let dohURL = comps.url else {
            throw FetchError.dnsResolutionFailed(host)
        }
        var req = URLRequest(url: dohURL, timeoutInterval: AppConstants.subscriptionFetchTimeout)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.setValue("application/dns-json", forHTTPHeaderField: "Accept")

        let session = makeEphemeralSession()
        defer { session.finishTasksAndInvalidate() }
        let (data, _) = try await session.data(for: req)
        let response = try JSONDecoder().decode(DoHResponse.self, from: data)
        guard let ip = response.Answer?.first(where: { $0.type == 1 })?.data else {
            throw FetchError.noAddressReturned
        }
        return ip
    }

    // MARK: - Fetch via resolved IP

    // Connects to `ip` but validates the TLS certificate against `originalHost`.
    // This is the key trick: the cert was issued for the hostname, not the IP,
    // so we must override URLSession's default host-matching and substitute
    // our own SecTrust evaluation with the correct policy hostname.
    private static func fetchViaIP(url: URL, ip: String, originalHost: String) async throws -> String {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        comps.host = ip
        guard let ipURL = comps.url else { throw URLError(.badURL) }

        var req = URLRequest(url: ipURL, timeoutInterval: AppConstants.subscriptionFetchTimeout)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.setValue(originalHost, forHTTPHeaderField: "Host")
        req.setValue("text/plain,text/markdown,*/*", forHTTPHeaderField: "Accept")

        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy   = .reloadIgnoringLocalAndRemoteCacheData
        cfg.urlCache             = nil
        cfg.timeoutIntervalForRequest = AppConstants.subscriptionFetchTimeout
        let delegate = TLSHostOverrideDelegate(expectedHost: originalHost)
        let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FetchError.invalidResponse(http.statusCode)
        }
        guard let str = String(data: data, encoding: .utf8)
                     ?? String(data: data, encoding: .isoLatin1),
              !str.isEmpty else {
            throw URLError(.cannotDecodeRawData)
        }
        return str
    }
}

// MARK: - DoH JSON response

private struct DoHResponse: Decodable {
    struct Answer: Decodable {
        let type: Int    // 1 = A record
        let data: String // IP address string
    }
    let Answer: [Answer]?
}

// MARK: - TLS delegate

// Validates the server certificate against the original hostname, not the
// IP address we physically connected to.
//
// Security invariant (audited 2026-05-15):
//
//   SecPolicyCreateSSL(true, hostname) creates a policy with TWO checks:
//     1. Chain validation against the iOS system trust store (same CA roots
//        as a normal HTTPS connection — self-signed certs are rejected).
//     2. Hostname matching against `expectedHost` (not the IP).
//
//   SecTrustSetPolicies replaces the connection's default policy (which checked
//   hostname against the IP and would always fail) with our custom policy.
//   SecTrustEvaluateWithError then runs both checks above.
//
//   Trade-off: SecTrustSetPolicies replaces ALL existing policies, including any
//   OCSP revocation policy the system may have attached. Certificate revocation
//   checking is therefore not enforced. This is acceptable for a subscription
//   fetcher — revocation is rarely enforced by iOS apps outside of payment flows.
private final class TLSHostOverrideDelegate: NSObject, URLSessionDelegate {
    let expectedHost: String
    init(expectedHost: String) { self.expectedHost = expectedHost }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // Replace the default policy (hostname = IP address) with one that
        // checks against the original domain. Chain validation is unchanged.
        let policy = SecPolicyCreateSSL(true, expectedHost as CFString)
        SecTrustSetPolicies(serverTrust, [policy] as CFTypeRef)

        var cfError: CFError?
        if SecTrustEvaluateWithError(serverTrust, &cfError) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
