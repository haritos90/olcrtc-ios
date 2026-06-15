import Foundation

// MARK: - ServerHostStore
//
// Saves the list of SSH-reachable VPS hosts. Non-secret fields go to
// UserDefaults as JSON; the password lives in iOS Keychain under a
// per-host UUID key. See KeychainHelper for the underlying primitives.

@MainActor
final class ServerHostStore: ObservableObject {
    @Published var hosts: [ServerHost] = [] {
        didSet { save() }
    }

    private let storeKey = "olcrtc_server_hosts"
    private static let keychainService = "olcrtc.serverhost.password"

    init() { load() }

    func add(_ host: ServerHost, password: String) {
        hosts.append(host)
        KeychainHelper.set(password, service: Self.keychainService, account: host.id.uuidString)
        LogStore.shared.log(.provisioning,
            "+ added VPS: \(host.label) [\(host.username)@\(host.host):\(host.port)]")
    }

    func update(_ host: ServerHost, password: String?) {
        if let i = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[i] = host
            LogStore.shared.log(.provisioning,
                "✎ updated VPS: \(host.label) [\(host.username)@\(host.host):\(host.port)]" +
                ((password ?? "").isEmpty ? "" : " (password changed)"))
        }
        if let pw = password, !pw.isEmpty {
            KeychainHelper.set(pw, service: Self.keychainService, account: host.id.uuidString)
        }
    }

    func remove(at idx: IndexSet) {
        let removed = idx.compactMap { hosts.indices.contains($0) ? hosts[$0] : nil }
        for h in removed {
            KeychainHelper.delete(service: Self.keychainService, account: h.id.uuidString)
        }
        hosts.remove(atOffsets: idx)
        for h in removed {
            LogStore.shared.log(.provisioning, "− removed VPS: \(h.label) [\(h.host)]")
        }
    }

    func password(for host: ServerHost) -> String? {
        KeychainHelper.get(service: Self.keychainService, account: host.id.uuidString)
    }

    // MARK: Full-access import (#384)

    /// How a full-access-imported host folds into the current list.
    enum ImportOutcome: Equatable {
        case addNew(ServerHost)          // new VPS — label disambiguated if it clashed
        case updateExisting(ServerHost)  // same SSH coordinates → refresh in place (dedup)
    }

    /// #384: decide how a full-access-imported `candidate` folds into `hosts`,
    /// applying the same rules `AddServerHostView` enforces but WITHOUT mutating
    /// the store or Keychain — pure, so it's unit-testable. The caller applies
    /// the outcome (`add` / `update`).
    ///
    /// • Dedup — a host with the SAME SSH coordinates (host/port/username) is the
    ///   same VPS re-imported, so refresh it in place (the caller re-writes the
    ///   password) instead of adding a 2nd card + Keychain entry. The existing
    ///   label is kept (renaming on re-import could itself create a clash).
    /// • #323 — otherwise, if the label (or its sanitised `logFilePrefix`) clashes
    ///   with a *different* host, append " (n)" until both are unique, so the two
    ///   hosts never share a `<prefix>_container.log`.
    nonisolated static func resolveImport(_ candidate: ServerHost,
                                          into hosts: [ServerHost]) -> ImportOutcome {
        if let existing = hosts.first(where: { sameCoordinates($0, candidate) }) {
            return .updateExisting(existing)
        }
        guard labelCollides(candidate.label, with: hosts) else { return .addNew(candidate) }
        var disambiguated = candidate
        var n = 2
        while labelCollides("\(candidate.label) (\(n))", with: hosts) { n += 1 }
        disambiguated.label = "\(candidate.label) (\(n))"
        return .addNew(disambiguated)
    }

    /// Two hosts are the same VPS iff host (case-insensitive), port and username
    /// match — the SSH coordinates a full-access link carries.
    nonisolated private static func sameCoordinates(_ a: ServerHost, _ b: ServerHost) -> Bool {
        a.host.lowercased() == b.host.lowercased()
            && a.port == b.port
            && a.username == b.username
    }

    /// Mirrors `AddServerHostView.isDuplicateLabel`: a label clashes if it equals
    /// another host's label case-insensitively OR sanitises to the same
    /// `logFilePrefix` (the shared-container-log case #323 guards against).
    nonisolated private static func labelCollides(_ label: String, with hosts: [ServerHost]) -> Bool {
        let lowered = label.lowercased()
        let prefix = ServerHost.sanitizeLogFilePrefix(label).lowercased()
        return hosts.contains {
            $0.label.lowercased() == lowered
                || ServerHost.sanitizeLogFilePrefix($0.label).lowercased() == prefix
        }
    }

    // MARK: Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(hosts) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }
    private func load() {
        if let data = UserDefaults.standard.data(forKey: storeKey),
           let list = try? JSONDecoder().decode([ServerHost].self, from: data) {
            hosts = list
        }
    }
}
