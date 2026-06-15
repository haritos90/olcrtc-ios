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
    /// endpoint in order; the first one to return a valid A (or, failing that,
    /// AAAA) record wins (#356).
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
        // #356 (audit A5): try A (IPv4, type 1) first, then AAAA (IPv6, type 28).
        // IPv4 is preferred when both exist (broadest reachability); AAAA is the
        // fallback for v6-only nodes — common where IPv4 DNS is poisoned but the
        // v6 record resolves. The returned literal is bracketed by `fetchViaIP`.
        if let v4 = try? await queryDoH(host: host, endpoint: endpoint, type: 1) {
            return v4
        }
        return try await queryDoH(host: host, endpoint: endpoint, type: 28)
    }

    /// Single DoH query for one record `type` (1 = A, 28 = AAAA). Throws
    /// `noAddressReturned` when the endpoint returns no answer of that type.
    private static func queryDoH(host: String, endpoint: String, type: Int) async throws -> String {
        guard var comps = URLComponents(string: endpoint) else {
            throw FetchError.dnsResolutionFailed(host)
        }
        comps.queryItems = [
            URLQueryItem(name: "name", value: host),
            URLQueryItem(name: "type", value: String(type)),
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
        guard let ip = response.Answer?.first(where: { $0.type == type })?.data else {
            throw FetchError.noAddressReturned
        }
        return ip
    }

    // MARK: - Fetch via resolved IP

    // boc #371: connect to the resolved `ip` while sending the CORRECT SNI and
    // Host = originalHost.
    //
    // #371 was: `comps.host = ip` rewrote the request URL to the raw IP, so
    // URLSession put the IP into the TLS ClientHello SNI. SNI-vhosted / CDN
    // fronts (GitHub Pages, Cloudflare) then served a *default* certificate
    // that failed the originalHost validation — defeating the DoH fallback
    // exactly where subscriptions are commonly hosted.
    //
    // There is no public URLSession seam to set SNI independently of the URL
    // host (URLSession derives SNI from the URL), so we drop to NWConnection:
    // the endpoint connects to the IP, but `tlsServerName` (SNI) and the Host
    // header both carry originalHost, and the certificate is validated against
    // originalHost via the verify block (same security posture as the old
    // TLSHostOverrideDelegate — full chain validation against the system trust
    // store + hostname match on originalHost, not the IP).
    private static func fetchViaIP(url: URL, ip: String, originalHost: String) async throws -> String {
        let scheme = url.scheme?.lowercased() ?? "https"
        // The DoH fallback only ever fetches HTTPS subscription URLs (ATS /
        // #008–#009 posture). Guard so a non-TLS scheme can't slip through this
        // path and skip certificate validation entirely.
        guard scheme == "https" else { throw URLError(.badURL) }
        let port = UInt16(url.port ?? 443)
        // Path + query, as sent on the request line.
        var pathAndQuery = url.path.isEmpty ? "/" : url.path
        if let q = url.query, !q.isEmpty { pathAndQuery += "?\(q)" }

        let (data, status) = try await NWHTTPSGet.get(
            ip: ip, port: port, host: originalHost, pathAndQuery: pathAndQuery,
            timeout: AppConstants.subscriptionFetchTimeout)
        if !(200..<300).contains(status) {
            throw FetchError.invalidResponse(status)
        }
        guard let str = String(data: data, encoding: .utf8)
                     ?? String(data: data, encoding: .isoLatin1),
              !str.isEmpty else {
            throw URLError(.cannotDecodeRawData)
        }
        return str
    }
    // eoc #371
}

// MARK: - DoH JSON response

private struct DoHResponse: Decodable {
    struct Answer: Decodable {
        let type: Int    // 1 = A record, 28 = AAAA record (#356)
        let data: String // IP address string
    }
    let Answer: [Answer]?
}

// MARK: - IP-pinned HTTPS GET with explicit SNI (#371)

// A minimal one-shot HTTPS GET over NWConnection that connects to a fixed IP
// but presents `host` as the TLS SNI *and* the HTTP Host header, validating
// the server certificate against `host` (not the IP).
//
// Why NWConnection rather than URLSession: URLSession derives the TLS SNI from
// the request URL's host, so the only way to reach a pinned IP through it is to
// rewrite the URL host to the IP — which puts the IP into the ClientHello SNI
// and breaks SNI-vhosted / CDN fronts (the #371 bug). NWConnection lets us set
// the endpoint (IP) and the SNI (`host`) independently.
//
// Security invariant (parity with the prior TLSHostOverrideDelegate):
//
//   sec_protocol_options_set_tls_server_name sets SNI = host.
//   The verify block runs full chain validation against the iOS system trust
//   store via SecTrustEvaluateWithError, with an SSL policy whose hostname is
//   `host` (NOT the IP). Self-signed / untrusted chains and hostname mismatches
//   are rejected. As before, replacing the trust's policies drops any attached
//   OCSP revocation policy — acceptable for a subscription fetcher (revocation
//   is rarely enforced by iOS apps outside payment flows).
//
// `internal` (not `private`) only so the pure response parser (`parse`/`dechunk`)
// is reachable from the test target; the networking `get` is not unit-tested.
enum NWHTTPSGet {

    enum HTTPError: Error { case malformedResponse, connection(Error), timedOut }

    /// Performs `GET pathAndQuery` against `ip:port` with TLS SNI/Host = `host`.
    /// Returns the response body bytes and the parsed HTTP status code.
    static func get(ip: String, port: UInt16, host: String,
                    pathAndQuery: String, timeout: TimeInterval) async throws -> (Data, Int) {
        // TLS with an explicit SNI + a custom verify block bound to `host`.
        let tlsOptions = NWProtocolTLS.Options()
        let sec = tlsOptions.securityProtocolOptions
        sec_protocol_options_set_tls_server_name(sec, host)
        let verifyHost = host
        sec_protocol_options_set_verify_block(sec, { _, secTrustRef, complete in
            // `sec_trust_copy_ref` returns a +1 (retained) `Unmanaged<SecTrust>`;
            // take ownership so ARC releases it after the block.
            let trust = sec_trust_copy_ref(secTrustRef).takeRetainedValue()
            // Validate the chain against the original hostname, not the IP.
            let policy = SecPolicyCreateSSL(true, verifyHost as CFString)
            SecTrustSetPolicies(trust, policy)
            var err: CFError?
            complete(SecTrustEvaluateWithError(trust, &err))
        }, DispatchQueue.global())

        let params = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        let endpoint = NWEndpoint.hostPort(
            host: .init(ip),
            port: NWEndpoint.Port(rawValue: port) ?? 443)
        let conn = NWConnection(to: endpoint, using: params)

        // The minimal HTTP/1.1 request: Host carries the original hostname,
        // Connection: close so the server finishes the body and EOFs the
        // stream, which is our read terminator.
        let request =
            "GET \(pathAndQuery) HTTP/1.1\r\n" +
            "Host: \(host)\r\n" +
            "Accept: text/plain,text/markdown,*/*\r\n" +
            "User-Agent: olcrtc-ios\r\n" +
            "Connection: close\r\n\r\n"

        let gate = ContinuationGate()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, Int), Error>) in
            var collected = Data()
            let timeoutItem = DispatchWorkItem {
                if gate.fire() { conn.cancel(); cont.resume(throwing: HTTPError.timedOut) }
            }

            func fail(_ error: Error) {
                if gate.fire() { timeoutItem.cancel(); conn.cancel(); cont.resume(throwing: error) }
            }
            func succeed() {
                guard gate.fire() else { return }
                timeoutItem.cancel(); conn.cancel()
                guard let (status, body) = Self.parse(collected) else {
                    cont.resume(throwing: HTTPError.malformedResponse); return
                }
                cont.resume(returning: (body, status))
            }

            // Drain the connection until EOF (Connection: close), then parse.
            func receiveLoop() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { chunk, _, isComplete, error in
                    if let chunk, !chunk.isEmpty { collected.append(chunk) }
                    if let error { fail(HTTPError.connection(error)); return }
                    if isComplete { succeed(); return }
                    receiveLoop()
                }
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: Data(request.utf8), completion: .contentProcessed { sendErr in
                        if let sendErr { fail(HTTPError.connection(sendErr)) }
                    })
                    receiveLoop()
                case .failed(let error):
                    fail(HTTPError.connection(error))
                case .cancelled:
                    fail(HTTPError.timedOut)
                default:
                    break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
        }
    }

    /// Splits a raw HTTP/1.1 response into (status code, body). Returns nil on a
    /// malformed status line or missing header/body separator. De-chunks a
    /// `Transfer-Encoding: chunked` body so the parsed text is the real payload.
    static func parse(_ raw: Data) -> (Int, Data)? {
        let sep = Data("\r\n\r\n".utf8)
        guard let range = raw.range(of: sep) else { return nil }
        let headerData = raw.subdata(in: raw.startIndex..<range.lowerBound)
        let body = raw.subdata(in: range.upperBound..<raw.endIndex)
        guard let headerText = String(data: headerData, encoding: .utf8),
              let statusLine = headerText.split(separator: "\r\n",
                                                omittingEmptySubsequences: false).first else {
            return nil
        }
        // "HTTP/1.1 200 OK" → 200
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }

        let chunked = headerText.lowercased().contains("transfer-encoding: chunked")
        let payload = chunked ? (dechunk(body) ?? body) : body
        return (status, payload)
    }

    /// Decodes an HTTP/1.1 `Transfer-Encoding: chunked` body. Returns nil if the
    /// framing is malformed (caller falls back to the raw bytes).
    static func dechunk(_ body: Data) -> Data? {
        var out = Data()
        var idx = body.startIndex
        let crlf = Data("\r\n".utf8)
        while idx < body.endIndex {
            guard let lineEnd = body.range(of: crlf, in: idx..<body.endIndex) else { return nil }
            let sizeLine = body.subdata(in: idx..<lineEnd.lowerBound)
            // A chunk-size line may carry ;extensions — take the hex prefix only.
            let sizeStr = String(data: sizeLine, encoding: .utf8)?
                .split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeStr.trimmingCharacters(in: .whitespaces), radix: 16) else { return nil }
            idx = lineEnd.upperBound
            if size == 0 { break }   // last chunk
            let dataEnd = body.index(idx, offsetBy: size, limitedBy: body.endIndex) ?? body.endIndex
            out.append(body.subdata(in: idx..<dataEnd))
            // Skip the trailing CRLF after the chunk data.
            idx = body.index(dataEnd, offsetBy: 2, limitedBy: body.endIndex) ?? body.endIndex
        }
        return out
    }
}

/// Single-shot gate: `fire()` returns `true` exactly once across racing callers
/// (NWConnection callbacks + the timeout work item), so the continuation is
/// resumed at most once. Mirrors `NetPing.ContinuationGate`.
private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
