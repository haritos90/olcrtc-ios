import Foundation

// MARK: - BotStore (#417)
//
// The registry of bots (name + platform + token). Mirrors `ServerHostStore`: the
// non-secret fields go to UserDefaults as JSON; each bot's token lives in the iOS
// Keychain under the bot's UUID, so it isn't written to UserDefaults or backups.
// Deploying a bot to a server copies its token into that server's config;
// removing a bot from a server doesn't change this registry.

@MainActor
final class BotStore: ObservableObject {
    @Published var bots: [BotIdentity] = [] {
        didSet { save() }
    }

    private let storeKey = "olcrtc_bots"
    private static let keychainService = "olcrtc.bot.token"

    init() {
        load()
        // Seed a default Telegram bot on first run so the registry is never empty
        // and the per-server sheet always has something to pick.
        if bots.isEmpty {
            bots = [BotIdentity(name: BotIdentity.defaultName, platform: .telegram)]
        }
    }

    func add(_ bot: BotIdentity, token: String) {
        bots.append(bot)
        KeychainHelper.set(token, service: Self.keychainService, account: bot.id.uuidString)
    }

    /// Updates a bot's fields. A non-empty `token` replaces the stored one;
    /// `nil`/empty keeps the existing token (the editor leaves the field blank to
    /// mean "unchanged" — same convention as the SSH password in
    /// `AddServerHostView`).
    func update(_ bot: BotIdentity, token: String?) {
        if let i = bots.firstIndex(where: { $0.id == bot.id }) {
            bots[i] = bot
        }
        if let token, !token.isEmpty {
            KeychainHelper.set(token, service: Self.keychainService, account: bot.id.uuidString)
        }
    }

    func remove(_ bot: BotIdentity) {
        KeychainHelper.delete(service: Self.keychainService, account: bot.id.uuidString)
        bots.removeAll { $0.id == bot.id }
    }

    func remove(at idx: IndexSet) {
        let removed = idx.compactMap { bots.indices.contains($0) ? bots[$0] : nil }
        for b in removed {
            KeychainHelper.delete(service: Self.keychainService, account: b.id.uuidString)
        }
        bots.remove(atOffsets: idx)
    }

    func token(for bot: BotIdentity) -> String {
        KeychainHelper.get(service: Self.keychainService, account: bot.id.uuidString) ?? ""
    }

    /// Whether a token is stored for `bot` — for a UI hint.
    func hasToken(_ bot: BotIdentity) -> Bool {
        !token(for: bot).isEmpty
    }

    /// All configured bot names — the names `checkBots` probes on a server.
    var markers: [String] { bots.map(\.name) }

    // MARK: Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(bots) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }
    private func load() {
        if let data = UserDefaults.standard.data(forKey: storeKey),
           let list = try? JSONDecoder().decode([BotIdentity].self, from: data) {
            bots = list
        }
    }
}
