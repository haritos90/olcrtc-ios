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
