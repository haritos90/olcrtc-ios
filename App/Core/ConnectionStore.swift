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

    /// #375: true when the last secret hydration hit a Keychain *read error* (as
    /// opposed to a genuinely-absent key) for at least one connection — the
    /// classic case is the device being locked before first unlock, so the
    /// `AfterFirstUnlockThisDeviceOnly` key can't be read yet and would otherwise
    /// be cached as "" (later surfacing as the misleading "key length 0"). The UI
    /// observes this to show "unlock the device and reopen", and the app
    /// re-hydrates on the next foreground (see `rehydrateSecrets`).
    @Published private(set) var secretsLocked = false

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

    // MARK: Subscriptions (#356)
    //
    // Re-importing the same olcrtc-sub:// link must diff against the records it
    // produced last time — add new nodes, update changed ones in place (keeping
    // their UUID/keychain entry and primary selection), drop nodes the source
    // no longer lists — instead of blind-appending duplicates (the #111 bug).
    // Records are tied to a source by `subSourceURL` and matched by `subNodeKey`.

    /// Per-source refresh bookkeeping, persisted alongside the connection list.
    /// `refreshInterval` is the `#refresh` interval (seconds) last seen for the
    /// source; `lastRefresh` is when we last imported it. Both feed `isRefreshDue`.
    /// #363 adds the surfaced group-level metadata (name + `#used`/`#available`
    /// quota + node count) so a group detail view can render it without re-fetch.
    /// Synthesised Codable: old metas decode the new fields as nil with no migration.
    struct SubscriptionMeta: Codable, Equatable {
        var refreshInterval: TimeInterval?
        var lastRefresh    : Date
        var name           : String?   // #363: global #name (group label)
        var used           : String?   // #363: global #used (e.g. "10mb/10gb")
        var available      : String?   // #363: global #available
        var serverCount    : Int?      // #363: number of nodes last imported
    }

    /// sourceURL → meta. Persisted under `olcrtc_sub_meta_v1`.
    @Published private(set) var subscriptionMeta: [String: SubscriptionMeta] = [:] {
        didSet { saveSubMeta() }
    }

    /// Pure diff used by `importSubscription` (and exercised directly in tests).
    /// `existing` is the current record list; `source` selects the records that
    /// belong to this subscription. Returns the records to insert, the updated
    /// versions of matched records (same id), and the ids to remove.
    struct SubscriptionDiff: Equatable {
        var toAdd   : [ConnectionRecord] = []
        var toUpdate: [ConnectionRecord] = []
        var toRemove: [UUID] = []
    }

    static func diffSubscription(_ sub: OlcrtcSubscription,
                                 source: String,
                                 group: String,
                                 existing: [ConnectionRecord]) -> SubscriptionDiff {
        // Records previously imported from this exact source, keyed by node.
        var byKey: [String: ConnectionRecord] = [:]
        for r in existing where r.subSourceURL == source {
            if let k = r.subNodeKey { byKey[k] = r }
        }
        var diff = SubscriptionDiff()
        var seen = Set<String>()
        for entry in sub.entries {
            let key = entry.nodeKey
            // De-dup within a single list too: keep the first occurrence.
            guard seen.insert(key).inserted else { continue }
            let params = connection(from: entry)
            if let prior = byKey[key] {
                // Update in place: keep id (and thus keychain + primary), refresh
                // the protocol params, name, group, provenance, and #363 metadata.
                var updated = prior
                updated.name      = entry.recordName
                updated.groupName = group
                updated.details   = .olcrtc(params)
                updated.subSourceURL = source
                updated.subNodeKey   = key
                updated.subIP        = entry.ip          // #363
                updated.subComment   = entry.comment
                updated.subUsed      = entry.used
                updated.subAvailable = entry.available
                if updated != prior { diff.toUpdate.append(updated) }
            } else {
                var added = ConnectionRecord(
                    name: entry.recordName, groupName: group,
                    details: .olcrtc(params),
                    subSourceURL: source, subNodeKey: key)
                added.subIP        = entry.ip            // #363
                added.subComment   = entry.comment
                added.subUsed      = entry.used
                added.subAvailable = entry.available
                diff.toAdd.append(added)
            }
        }
        // Anything from this source not in the new list is removed.
        for (key, r) in byKey where !seen.contains(key) {
            diff.toRemove.append(r.id)
        }
        return diff
    }

    /// Builds the protocol params for a subscription entry (#355 sei params
    /// carried through; #356 dedup uses the result).
    private static func connection(from entry: OlcrtcSubscription.Entry) -> OlcrtcConnection {
        // #401: the Parsed → connection mapping (sei defaults 30/10/1200/1) now
        // lives in OlcrtcConnection.init(from:), shared with the import paths.
        OlcrtcConnection(from: entry.parsed)
    }

    /// Applies a (re-)import of `sub` fetched from `source`. Diffs against the
    /// existing records for that source so re-opening the same link updates in
    /// place instead of duplicating, then records the refresh bookkeeping.
    /// Returns the diff so the caller can report add/update/remove counts.
    @discardableResult
    func importSubscription(_ sub: OlcrtcSubscription, source: String) -> SubscriptionDiff {
        let group = sub.name ?? ConnectionRecord.defaultGroupName
        let diff  = Self.diffSubscription(sub, source: source, group: group, existing: connections)

        if !diff.toRemove.isEmpty {
            for id in diff.toRemove { ConnectionSecretStore.remove(connectionID: id) }
            connections.removeAll { diff.toRemove.contains($0.id) }
        }
        for updated in diff.toUpdate {
            if let i = connections.firstIndex(where: { $0.id == updated.id }) {
                connections[i] = updated
            }
        }
        for added in diff.toAdd { connections.append(added) }
        if primaryID == nil, let first = connections.first { primaryID = first.id }
        // Repair a dangling primary if the diff removed the selected record.
        if let pid = primaryID, !connections.contains(where: { $0.id == pid }) {
            primaryID = connections.first?.id
        }

        subscriptionMeta[source] = SubscriptionMeta(
            refreshInterval: sub.refreshInterval, lastRefresh: Date(),
            name: sub.name, used: sub.used, available: sub.available,   // #363
            serverCount: sub.entries.count)

        LogStore.shared.log(.connection,
            "⬇ subscription \(source): +\(diff.toAdd.count) ~\(diff.toUpdate.count) −\(diff.toRemove.count)")
        return diff
    }

    /// Whether a source is due for a refresh, given its stored `#refresh`
    /// interval and the time of the last import (#356). Unknown source or no
    /// interval → false (we never nag about a list that didn't ask for it).
    func isRefreshDue(source: String, now: Date = Date()) -> Bool {
        guard let meta = subscriptionMeta[source], let interval = meta.refreshInterval,
              interval > 0 else { return false }
        return now.timeIntervalSince(meta.lastRefresh) >= interval
    }

    // MARK: Refresh-due trigger (#362)
    //
    // #356 added `isRefreshDue` + the stored interval/lastRefresh but nothing
    // ever called them. #362 wires a trigger: on app launch and from a manual
    // pull-to-refresh, find the sources whose `#refresh` interval has elapsed
    // and silently re-fetch + re-import them (the diff dedups, so this updates
    // servers in place). The re-fetch is injectable for tests; it defaults to
    // SubscriptionFetcher.fetch.

    /// Every known subscription source whose `#refresh` interval has elapsed.
    func dueSources(now: Date = Date()) -> [String] {
        subscriptionMeta.keys.filter { isRefreshDue(source: $0, now: now) }
    }

    /// Re-fetches and re-imports every refresh-due source (#362). Each source's
    /// canonical link is mapped to its HTTPS fetch URL the same way the initial
    /// import does (`olcrtc-sub://` → https swap; a plain https source is fetched
    /// as-is). A fetch/parse failure for one source is logged and skipped — it
    /// must not abort the others or surface a modal on a background refresh.
    /// Returns the sources that were successfully refreshed.
    @discardableResult
    func refreshDueSources(
        now: Date = Date(),
        fetch: (URL) async throws -> String = { try await SubscriptionFetcher.fetch(from: $0) }
    ) async -> [String] {
        var refreshed: [String] = []
        for source in dueSources(now: now) {
            guard let fetchURL = Self.fetchURL(for: source) else {
                LogStore.shared.log(.connection,
                    "⚠ subscription refresh: can't derive fetch URL for \(source) — skipped")
                continue
            }
            do {
                let body = try await fetch(fetchURL)
                importSubscription(OlcrtcSubscription.parse(body), source: source)
                refreshed.append(source)
            } catch {
                LogStore.shared.log(.connection,
                    "✗ subscription refresh failed for \(fetchURL.host ?? source): \(error.localizedDescription)")
            }
        }
        return refreshed
    }

    /// Maps a stored subscription `source` link to the HTTPS URL it is fetched
    /// from: `olcrtc-sub://` is scheme-swapped to https (same as the import
    /// path); a plain `https://` source is used directly. Anything else → nil.
    static func fetchURL(for source: String) -> URL? {
        guard let url = URL(string: source) else { return nil }
        switch url.scheme?.lowercased() {
        case "olcrtc-sub": return try? OlcrtcSubscription.httpsURL(from: url)
        case "https":      return url
        default:           return nil
        }
    }

    func grouped() -> [(group: String, items: [ConnectionRecord])] {
        Dictionary(grouping: connections, by: { $0.groupName })
            .sorted { $0.key < $1.key }
            .map { (group: $0.key, items: $0.value) }
    }

    /// #363: the (source, meta) for a group, if any of its records came from a
    /// subscription. Returns nil for a purely manual group so the UI shows no
    /// metadata section.
    ///
    /// #396 was: returned only the FIRST record's source + that one source's
    /// meta. But groups are keyed by `#name`, so two subscriptions sharing a
    /// `#name` land in one group — the footer then showed only one source's
    /// quota plus a `serverCount` that mismatched the listed rows. Now the
    /// returned info reflects ALL sources/records grouped under the name:
    ///   • `source` — the single source if there's one, else a "N sources" label;
    ///   • `serverCount` — the actual number of subscription-backed rows here
    ///     (not one source's stored count);
    ///   • `used`/`available` — joined across the distinct sources (server-
    ///     provided free text; can't be summed, so they're listed);
    ///   • `name` — the (shared) group name; `refreshInterval`/`lastRefresh` —
    ///     the soonest-due source (smallest interval, then earliest refresh).
    func subscriptionInfo(for items: [ConnectionRecord]) -> (source: String, meta: SubscriptionMeta)? {
        // Distinct sources backing this group, in first-seen order.
        var sources: [String] = []
        for r in items {
            if let s = r.subSourceURL, !sources.contains(s) { sources.append(s) }
        }
        let metas = sources.compactMap { subscriptionMeta[$0] }
        guard let first = metas.first else { return nil }

        // Rows that actually came from a subscription — the real server count for
        // the group, independent of any single source's stored `serverCount`.
        let backedCount = items.filter { $0.subSourceURL != nil }.count

        if sources.count == 1 {
            // Single-source group: correct the count to the listed rows, keep the
            // rest of the stored meta as-is.
            var meta = first
            meta.serverCount = backedCount
            return (sources[0], meta)
        }

        // Multi-source group sharing a `#name`. Synthesise an aggregate meta.
        let usedParts      = metas.compactMap { $0.used }.filter { !$0.isEmpty }
        let availableParts = metas.compactMap { $0.available }.filter { !$0.isEmpty }
        // Soonest-due source drives the refresh display: smallest positive
        // interval first, then the earliest lastRefresh.
        let soonest = metas.min { a, b in
            let ia = a.refreshInterval ?? .greatestFiniteMagnitude
            let ib = b.refreshInterval ?? .greatestFiniteMagnitude
            if ia != ib { return ia < ib }
            return a.lastRefresh < b.lastRefresh
        }
        let aggregate = SubscriptionMeta(
            refreshInterval: soonest?.refreshInterval,
            lastRefresh:     soonest?.lastRefresh ?? first.lastRefresh,
            name:            first.name,
            used:            usedParts.isEmpty      ? nil : usedParts.joined(separator: ", "),
            available:       availableParts.isEmpty ? nil : availableParts.joined(separator: ", "),
            serverCount:     backedCount)
        // `source` is shown as a host label; with several, surface the count
        // instead of an arbitrary one.
        return (L10n.subMetaMultipleSources_fmt.formatted(sources.count), aggregate)
    }

    /// Sorted unique group names already in use. Used by the connection
    /// editor to suggest existing groups via a quick-pick menu.
    var allGroupNames: [String] {
        Array(Set(connections.map(\.groupName))).sorted()
    }

    // MARK: Persistence

    private static let v2Key      = "olcrtc_records_v2"
    private static let subMetaKey = "olcrtc_sub_meta_v1"   // #356

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

        // #375: hydrate secrets, tracking whether any read hit a Keychain ERROR
        // (device locked before first unlock) vs. a genuinely-absent key. On an
        // error we flag `secretsLocked` so the UI can prompt to unlock + reopen,
        // and `rehydrateSecrets()` (called on foreground) retries the read.
        var sawReadError = false
        connections = list.map { record in
            let (hydrated, readError) = Self.hydrateSecrets(record)
            if readError { sawReadError = true }
            return hydrated
        }
        secretsLocked = sawReadError

        if let s = UserDefaults.standard.string(forKey: "olcrtc_primary_id"),
           let uuid = UUID(uuidString: s) {
            primaryID = uuid
        }

        // #356: subscription refresh bookkeeping. Assigned directly (not via the
        // published setter inside `load()` semantics) — the didSet re-save is a
        // harmless no-op writing the same bytes back.
        if let data = UserDefaults.standard.data(forKey: Self.subMetaKey),
           let decoded = try? JSONDecoder().decode([String: SubscriptionMeta].self, from: data) {
            subscriptionMeta = decoded
        }
    }

    /// Persists `subscriptionMeta` (#356). Runs from its `didSet`.
    private func saveSubMeta() {
        if let data = try? JSONEncoder().encode(subscriptionMeta) {
            UserDefaults.standard.set(data, forKey: Self.subMetaKey)
        }
    }

    /// #375: re-read every connection's secrets from Keychain and clear
    /// `secretsLocked` if the read now succeeds. Call on app foreground
    /// (`.scenePhase == .active`) so a key that was unreadable at a locked-device
    /// launch is hydrated before the user can hit Connect — turning a misleading
    /// "key length 0" into a working connection once the device is unlocked.
    ///
    /// Cheap no-op unless we're actually in the locked state: when nothing was
    /// locked the in-memory keys are already correct, so we skip the re-read (and
    /// the `connections` reassignment's `save()` round-trip) entirely.
    func rehydrateSecrets() {
        guard secretsLocked else { return }
        var sawReadError = false
        connections = connections.map { record in
            let (hydrated, readError) = Self.hydrateSecrets(record)
            if readError { sawReadError = true }
            return hydrated
        }
        secretsLocked = sawReadError
    }

    /// Hydrates a record's secrets from Keychain. The second tuple element is
    /// true when a read hit a genuine Keychain ERROR (`.failure`) rather than a
    /// missing key (`.success(nil)`) — #375: the locked-before-first-unlock case,
    /// where caching the resulting "" would later look like "key length 0". On an
    /// error we leave the existing in-memory value untouched (don't clobber a key
    /// hydrated by an earlier successful pass).
    private static func hydrateSecrets(_ record: ConnectionRecord) -> (ConnectionRecord, readError: Bool) {
        var r = record
        var readError = false
        if case .olcrtc(var p) = r.details {
            switch ConnectionSecretStore.keyResult(for: r.id) {
            case .success(let kc?): p.key = kc
            case .success(nil):     break          // genuinely absent — leave as-is
            case .failure:          readError = true   // locked / unreadable — retry on foreground
            }
            if let sp = ConnectionSecretStore.socksPass(for: r.id) { p.socksPass = sp }
            r.details = .olcrtc(p)
        }
        return (r, readError)
    }
}

