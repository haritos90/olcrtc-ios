import AppIntents

// MARK: - Tunnel App Intents (#437)
//
// Connect / Disconnect the tunnel from Shortcuts, the Action button, Spotlight, or
// an automation — the iOS-native counterpart to the in-app toggle. These are
// in-binary intents (no extension target), so sideload re-signing stays unaffected.
// They reach the live engine through `TunnelManager.shared` / `ConnectionStore.shared`
// (set in those types' inits).
//
// Strings here are surfaced by the OS at registration time and can't route through
// the runtime L10n table (the same constraint as InfoPlist.strings), so they're
// English literals — a deliberate, documented exception to the L10n rule.
//
// Deployment target is iOS 17, so no `@available` gating is needed (AppIntents is
// iOS 16+).

struct ConnectTunnelIntent: AppIntent {
    static var title: LocalizedStringResource = "Connect olcrtc tunnel"
    static var description = IntentDescription("Start the olcrtc tunnel using your primary connection.")
    // The engine and the local SOCKS proxy run in-process, so connecting needs the
    // app foregrounded — bring it forward, then connect.
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let record = ConnectionStore.shared?.primary else {
            throw TunnelIntentError.noConnection
        }
        // The connect guards (already-connecting, locked secrets) live inside
        // TunnelManager.connect (#393), so this is safe to call unconditionally.
        TunnelManager.shared?.connect(record: record)
        return .result()
    }
}

struct DisconnectTunnelIntent: AppIntent {
    static var title: LocalizedStringResource = "Disconnect olcrtc tunnel"
    static var description = IntentDescription("Stop the olcrtc tunnel.")
    // Tearing down doesn't need the UI, so let it run without foregrounding.
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        TunnelManager.shared?.disconnect()
        return .result()
    }
}

enum TunnelIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noConnection
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noConnection: return "No connection is configured yet — add one in the app first."
        }
    }
}

struct OlcrtcAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConnectTunnelIntent(),
            phrases: ["Connect \(.applicationName)", "Start \(.applicationName) tunnel"],
            shortTitle: "Connect tunnel",
            systemImageName: "bolt.horizontal.circle"
        )
        AppShortcut(
            intent: DisconnectTunnelIntent(),
            phrases: ["Disconnect \(.applicationName)", "Stop \(.applicationName) tunnel"],
            shortTitle: "Disconnect tunnel",
            systemImageName: "bolt.slash.circle"
        )
    }
}
