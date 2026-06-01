import Foundation

// MARK: - ConnectionStore
//
// Single source of truth for the saved connection list and the primary
// selection. Protocol-agnostic — stores `ConnectionRecord`s, not olcrtc
// records specifically. When other protocols (vless/xray/...) land,
// they reuse this store without changes.
//
// Persistence: UserDefaults JSON under `olcrtc_records_v2`. Encryption
// keys live in Keychain (never persisted to UserDefaults).

/// Protocol-agnostic store for saved connection records and the active primary
/// selection. Persists to UserDefaults JSON; encryption keys live in Keychain.
@MainActor
final class ConnectionStore: ObservableObject {
    @Published var connections: [ConnectionRecord] = [] {
        didSet { save() }
    }
    @Published var primaryID: UUID? {
        didSet { UserDefaults.standard.set(primaryID?.uuidString, forKey: "olcrtc_primary_id") }
    }

    /// Returns the explicit primary, or the first connection as implicit
    /// fallback (single-server case: that one is "primary" by default).
    var primary: ConnectionRecord? {
        if let id = primaryID, let r = connections.first(where: { $0.id == id }) {
            return r
        }
        return connections.first
    }

    init() { load() }

    func add(_ r: ConnectionRecord) {
        connections.append(r)
        LogStore.shared.log(.connection, "+ added connection: \(r.displayName) [\(r.subtitle)]")
        if primaryID == nil {
            primaryID = r.id
            LogStore.shared.log(.connection, "★ primary set to \(r.displayName) (auto, first record)")
        }
    }

    func remove(at idx: IndexSet) {
        let removed = idx.compactMap { connections.indices.contains($0) ? connections[$0] : nil }
        connections.remove(atOffsets: idx)
        for r in removed {
            // Also drop the keychain entry — leaving it would leak the
            // encryption key indefinitely after the user thought they
            // deleted the connection.
            ConnectionSecretStore.remove(connectionID: r.id)
            LogStore.shared.log(.connection, "− removed connection: \(r.displayName)")
        }
        if let pid = primaryID, !connections.contains(where: { $0.id == pid }) {
            primaryID = connections.first?.id
            if let p = connections.first {
                LogStore.shared.log(.connection, "★ primary fallback → \(p.displayName)")
            }
        }
    }

    func remove(id: UUID) {
        if let idx = connections.firstIndex(where: { $0.id == id }) {
            remove(at: IndexSet(integer: idx))
        }
    }

    func update(_ r: ConnectionRecord) {
        if let i = connections.firstIndex(where: { $0.id == r.id }) {
            connections[i] = r
            LogStore.shared.log(.connection, "✎ updated connection: \(r.displayName)")
        }
    }

    func setPrimary(_ id: UUID) {
        primaryID = id
        if let r = connections.first(where: { $0.id == id }) {
            LogStore.shared.log(.connection, "★ primary → \(r.displayName)")
        }
    }

    func grouped() -> [(group: String, items: [ConnectionRecord])] {
        Dictionary(grouping: connections, by: { $0.groupName })
            .sorted { $0.key < $1.key }
            .map { (group: $0.key, items: $0.value) }
    }

    /// Sorted unique group names already in use. Used by the connection
    /// editor to suggest existing groups via a quick-pick menu.
    var allGroupNames: [String] {
        Array(Set(connections.map(\.groupName))).sorted()
    }

    // MARK: Persistence

    private static let v2Key = "olcrtc_records_v2"

    /// Saves the connection list to UserDefaults with the encryption key
    /// stripped from JSON — the key lives in Keychain instead. This runs
    /// from `didSet` on `connections`, so any in-memory mutation lands on
    /// disk with no key bytes.
    private func save() {
        let scrubbed = connections.map { record -> ConnectionRecord in
            var r = record
            if case .olcrtc(var p) = r.details {
                if !p.key.isEmpty {
                    ConnectionSecretStore.setKey(connectionID: r.id, key: p.key)
                }
                if !p.socksPass.isEmpty {
                    ConnectionSecretStore.setSocksPass(connectionID: r.id, pass: p.socksPass)
                }
                p.key      = ""
                p.socksPass = ""
                r.details = .olcrtc(p)
            }
            return r
        }
        if let data = try? JSONEncoder().encode(scrubbed) {
            UserDefaults.standard.set(data, forKey: Self.v2Key)
        }
    }

    private func load() {
        var list: [ConnectionRecord] = []
        if let data = UserDefaults.standard.data(forKey: Self.v2Key) {
            do {
                list = try JSONDecoder().decode([ConnectionRecord].self, from: data)
            } catch {
                LogStore.shared.log(.connection, "⚠ ConnectionStore: failed to decode saved connections: \(error.localizedDescription)")
            }
        }

        connections = list.map { Self.hydrateSecrets($0) }

        if let s = UserDefaults.standard.string(forKey: "olcrtc_primary_id"),
           let uuid = UUID(uuidString: s) {
            primaryID = uuid
        }
    }

    private static func hydrateSecrets(_ record: ConnectionRecord) -> ConnectionRecord {
        var r = record
        if case .olcrtc(var p) = r.details {
            if let kc = ConnectionSecretStore.key(for: r.id) { p.key = kc }
            if let sp = ConnectionSecretStore.socksPass(for: r.id) { p.socksPass = sp }
            r.details = .olcrtc(p)
        }
        return r
    }
}

