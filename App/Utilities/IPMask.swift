import Foundation

// MARK: - IPMask (#337)
//
// Display-only masking for screenshot-safe mode (SettingsStore.maskIPs).
// Masks IP addresses so a shared screenshot doesn't leak the real address;
// the underlying stored values and copy actions stay untouched (callers gate
// on `SettingsStore.maskIPs` and only swap what they render).
//
// Strategy: keep the LAST segment as a coarse hint, blank the rest with the
// `•` bullet — IPv4 `203.0.113.12` → `•••.•••.•••.12`, IPv6 keeps the final
// group. Non-IP text (hostnames, "—", errors) passes through unchanged: the
// callers also mask hostnames separately, but a bare label like "n/a" must
// never be mangled.

enum IPMask {
    /// One masked segment placeholder.
    private static let dot = "•••"

    /// Masks an IPv4/IPv6 literal for display, keeping only the last segment.
    /// Returns the input unchanged when it isn't a recognisable IP literal.
    static func mask(_ ip: String) -> String {
        let s = ip.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return ip }

        // IPv6: colon-separated, keep the final group. Detected before IPv4
        // since an embedded `.` (IPv4-mapped) shouldn't route it to the v4 path.
        if s.contains(":") {
            let groups = s.split(separator: ":", omittingEmptySubsequences: false)
            guard groups.count >= 2, let last = groups.last, !last.isEmpty else { return ip }
            return "\(dot):\(last)"
        }

        // IPv4: exactly four dot-separated numeric octets, keep the last.
        let octets = s.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              octets.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else { return ip }
        return "\(dot).\(dot).\(dot).\(octets[3])"
    }

    /// Masks `ip` only when the screenshot-safe toggle is on; otherwise returns
    /// it verbatim. Convenience for the display sites so they don't repeat the
    /// `SettingsStore.maskIPs ? … : …` ternary.
    static func display(_ ip: String, masked: Bool) -> String {
        masked ? mask(ip) : ip
    }
}
