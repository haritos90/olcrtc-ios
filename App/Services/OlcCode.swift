import Foundation

// MARK: - OlcCode (#279)
//
// Stable diagnostic codes for the messages catalogued in
// `docs/diagnostic-messages.md`. Emitting a line with a code prefixes it as
// `[OLC-####] ` so the code is visible in the Logs tab and matched by the
// Logs search (LogsView's `localizedStandardContains`), and so a user hitting
// a code can look it up in the catalog / README troubleshooting.
//
// SCOPE (#279): only the CLIENT block (`OLC-1xxx`) is wired here — those map
// 1:1 to existing client log points (TunnelManager / OlcrtcEngine). The server
// block (`OLC-2xxx`) is emitted by the Go core / captured via `podman logs`,
// so its wiring needs the maintainer's real container captures (see the task
// note) and is intentionally not represented as emittable cases.
//
// The raw value is the bare code; `tag` is the bracketed prefix. Keep this in
// sync with the `OLC-1xxx` table in docs/diagnostic-messages.md.

enum OlcCode: String {
    case sessionStart   = "OLC-1001"   // new log session (app launch / diagnostic)
    case connecting     = "OLC-1002"   // connect attempt began
    case nativeStartOK  = "OLC-1003"   // MobileStart returned, awaiting WaitReady
    case socksReady     = "OLC-1004"   // local SOCKS5 listener bound
    case verifyOK       = "OLC-1005"   // an end-to-end probe returned 200
    case verifyFailed   = "OLC-1006"   // one probe failed (HTTP n / timeout / reason)
    case keepAliveOK    = "OLC-1010"   // periodic probe succeeded
    case keepAliveRetry = "OLC-1011"   // transient probe miss (n/3)
    case keepAliveLost  = "OLC-1012"   // 3 consecutive misses → failed + recovery
    case reconnecting   = "OLC-1013"   // backoff recovery loop (#270)
    case reconnectFailed = "OLC-1014"  // recovery budget spent — tap Retry
    case waitingNetwork = "OLC-1015"   // path lost, holding (#269)
    case tunnelWorks    = "OLC-1007"   // first successful verify → connected
    case tunnelDown     = "OLC-1009"   // verify failed end-to-end after connect
    case portBusy       = "OLC-1026"   // configured SOCKS port held by another process (#308)

    /// Bracketed prefix prepended to a logged line (trailing space included).
    var tag: String { "[\(rawValue)] " }
}
