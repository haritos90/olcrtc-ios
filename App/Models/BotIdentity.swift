import Foundation

// MARK: - BotPlatform (#417)
//
// Which platform a bot talks to. Telegram is the default and is shown first in
// the picker; Max is the second option.

enum BotPlatform: String, Codable, CaseIterable, Identifiable {
    case telegram
    case max

    var id: String { rawValue }

    /// Display label for the platform picker. Names are identical in both
    /// languages (the `ru` L10n entry maps to the same literal).
    var title: String {
        switch self {
        case .telegram: return L10n.botPlatformTelegram.localized()
        case .max:      return L10n.botPlatformMax.localized()
        }
    }
}

// MARK: - BotIdentity (#417)
//
// A reusable bot in the Settings registry. Its `name` also names the systemd
// unit + config file on each server it is deployed to. The token is NOT a field
// here — it lives in the Keychain keyed by `id`, managed by `BotStore` (like
// `ServerHost` + its password), so this struct's Codable JSON is safe in
// UserDefaults / backups.

struct BotIdentity: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String                    // names the systemd unit / config file
    var platform: BotPlatform = .telegram

    /// The seeded first-run bot name. Recommended charset is `[a-z0-9_]` (it
    /// becomes a systemd unit name); the SSH layer sanitises it.
    static let defaultName = "olcrtc_server_bot"
}

// MARK: - BotDeployConfig (#418)
//
// Everything needed to write one server-side `config.json` + systemd unit: a
// `BotIdentity` (name → marker, platform, token from Keychain) plus the
// per-server command/reply fields set in `BotSettingsView`.

struct BotDeployConfig: Equatable {
    var marker: String
    var platform: BotPlatform
    var token: String
    var startCmd: String
    var stopCmd: String
    var startReply: String
    var stopReply: String
    var unknownReply: String
}

// MARK: - DeployedBot (#418)
//
// What `SSHRunner.checkBots` read back for one bot on a server (the token is not
// part of the read-back) plus whether its systemd service is active.

struct DeployedBot: Identifiable, Equatable {
    var id: String { marker }
    var marker: String
    var platform: BotPlatform
    var startCmd: String
    var stopCmd: String
    var startReply: String
    var stopReply: String
    var unknownReply: String
    var active: Bool
}
