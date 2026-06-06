import Foundation

// MARK: - Localization
//
// Type-safe localization. The `L10n` enum is the single source of truth for
// every translation key — adding a new string requires (a) a new case here and
// (b) entries in every `L10nTable.<language>` dictionary. The unit test in
// `L10nTests.swift` guarantees no case is missing in any language.
//
// Adding a new language:
//   1. Add a case to `AppLocale`
//   2. Add a corresponding `[L10n: String]` dictionary in L10nTable.swift
//   3. Add it to the `switch` in L10nTable.value(for:in:)
//   4. Tests catch any gaps automatically.
//
// Format strings: cases that end in `_fmt` are passed through `String(format:)`
// via `L10n.formatted(_:)`. Patterns use standard %@/%d/%.0f placeholders.

enum AppLocale: String, CaseIterable, Identifiable {
    case english = "en"
    case russian = "ru"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .russian: return "Русский"
        }
    }

    /// Current locale resolved from SettingsStore. Falls back to English when
    /// the stored value is empty or unknown.
    static var current: AppLocale {
        AppLocale(rawValue: SettingsStore.shared.language) ?? .english
    }
}

enum L10n: String, CaseIterable {

    // MARK: Common
    case ok, cancel, save, close, done, error, edit
    case okPrompt           // "Done"

    // MARK: Tabs
    case tabConnections, tabServers, tabLogs, tabSettings

    // MARK: Routing
    case routingHeader, routingAllTunnel, routingAllDirect, routingViaTunnel, routingDirect

    // MARK: Connection state
    case stateDisconnected, stateConnecting, stateConnected
    case stateConnectFailed                // "Connection failed" (#258 hero)
    case stateWaitingForNetwork            // "Waiting for network…" (#269 hero)
    case stateErrorPrefix_fmt              // "Error: %@"

    // MARK: ConnectionsView
    case emptyNoConnections                 // "No connections yet"
    case emptyNoConnectionsHint             // "Tap + to add a connection manually. If you have a VPS, go to the Servers tab to install and link automatically."
    case actionConnect, actionRetry
    case shareAction, copyURIAction
    case shareConnectionTitle, shareConnectionExplanation, shareConnectionURIHeader
    case primaryRoleMain                    // "primary"
    case copiedURI_fmt                      // "📋 URI copied: %@"

    // MARK: AddConnectionView
    case newConnectionTitle, editConnectionTitle
    case nameField, namePlaceholder         // "Label" / "My server"
    case groupField, groupDefault           // "Group" / "Servers"
    case importByURI                        // "Import from URI"
    case scanQRAction                       // "Scan QR" (#258 sheet shortcut)
    case pasteURIAction                     // "Paste URI" (#258 sheet shortcut)
    case importHint
    case clientIDFooter                     // explanation of client ID field
    case keyPlaceholder
    case roomIDLabel
    case vp8ParamsHeader
    case socksAuthHeader, socksAuthFooter
    case socksUserLabel, socksPassLabel
    case socksUserPlaceholder
    case vp8FpsLabel, vp8BatchLabel
    case globalDefault_fmt                  // "global (%d)"
    case overrideHint

    // MARK: ServersView
    case serversTitle                       // "VPS list"
    case emptyNoServers, emptyNoServersHint
    case newServerTitle, editServerTitle
    case sshAccessHeader
    case hostField, portField, loginField, passwordField
    case actionInstall, actionUninstall, actionUpdate, actionReboot
    case actionChangeRoomTransport         // "Change Room / Transport"
    case actionDownloadContainerLogs       // #278: was "Logs" — clarifies it pulls podman logs
    case actionDone
    case actionRemoveFromList               // "Remove host from list"
    case removeHostConfirmTitle             // "Remove %@?"
    case removeHostConfirmMessage           // explanation about Keychain/uninstall
    case uninstallConfirmTitle             // "Uninstall container?"
    case uninstallConfirmBody              // explanation about what is removed vs kept
    case deepUninstallConfirmBody          // explanation for deep uninstall confirmation
    case rebootConfirmTitle               // "Reboot server?"
    case rebootConfirmBody                // explanation that the entire VPS will reboot
    case carrierTransportMatrix             // "Carrier × Transport"

    // MARK: Container status
    case containerRunning_fmt               // "Container running: %@"
    case containerStopped_fmt               // "Container stopped: %@"
    case containerNotFound                  // "Container not found"
    case containerNotFoundShort             // "not found"
    case containerNotInstalled              // "Container is not installed yet — tap «Install»."

    // MARK: VPS readiness state
    case readinessNoPodman                 // "Ready to install (Podman not found)"
    case readinessNoImage                  // "Image not cached (~300 MB on first install)"
    case readinessImageReady               // "Image cached — reinstall takes ~1 min"
    case readinessContainerStopped_fmt     // "Stopped: %@"
    case readinessContainerRunning_fmt     // "Running: %@"

    // MARK: VPS status card (#258/#261 — design-system status pill + op driver)
    case vpsTitleUnknown, vpsTitleReady, vpsTitlePodmanReady, vpsTitleStopped, vpsTitleRunning
    case vpsSubUnknown, vpsSubNoPodman, vpsSubNoImage, vpsSubImageReady, vpsSubStopped, vpsSubRunning
    case vpsVerbChecking, vpsVerbInstalling, vpsVerbStarting, vpsVerbStopping, vpsVerbReconfiguring
    case vpsVerbUpdating, vpsVerbUninstalling, vpsVerbDeepUninstalling, vpsVerbRebooting
    case vpsConnecting                      // "Connecting…" (initial running note)
    case vpsCheckServer                     // "Check server"
    case vpsWorking                         // "Working…"
    case vpsOpFailed_fmt                    // "%@ failed"

    // MARK: ContainerLogsView
    case emptyLogsTitle                     // "Logs are empty"
    case emptyLogsHint_fmt                  // "Container produced nothing on stdout/stderr in the last %@ lines."
    case closeAction

    // MARK: LogsView
    case logsTitle                          // "Logs"
    case logsSearchPlaceholder              // "Search"
    case emptyLogsGeneric                   // "Empty"
    case emptyLogsGenericHint               // "Run an operation in the Connections or Servers tab"
    case noSearchResults                    // "Nothing found"
    case noSearchResultsHint_fmt            // "No matches for «%@»."
    case categoryConnection                 // "Connection"
    case categoryIP                         // "IP"
    case categorySpeed                      // "Speed test"
    case categoryProvisioning               // "VPS"
    case categoryContainerLogs              // "Container"
    case logsAllSources                     // "All sources" — merged-stream filter default (#276)
    case logsSourceLabel                    // "Source" — filter menu label/a11y (#276)
    case logsRefreshFromServer              // "Refresh from server" — in-tab container pull (#278)

    // MARK: SettingsView
    case settingsTitle
    case sectionSOCKS5, sectionDNS, sectionVP8, sectionConnection
    case sectionKeepAlive
    case sectionLogs, sectionFont
    case sectionIPSources                   // "IP-check sources" (#286)
    case ipSourcesFooter                    // explanation of the IP-source toggles (#286)
    case sectionSpeedProvider               // "Speed-test provider" (#285)
    case speedProviderFooter                // explanation of the provider pick-list (#285)
    case speedAllFailed                     // "All measurements failed" (#285)
    case speedDatachannelHint               // tip: switch to datachannel for speed (#285)
    case settingsPortLabel
    case checkPortAction                    // "Check port"
    case randomPortAction                   // "Random"
    case portFree, portBusy                 // "free" / "busy"
    case logPortFree_fmt, logPortBusy_fmt   // "✓ Port %d free" / "✗ Port %d busy" — single key per concept (#287)
    case socksFooter
    case socksPortChangeNote                // "Port change takes effect on the next connection"
    case dnsFreeFormPlaceholder             // "IP:port"
    case dnsFooter
    case vp8Footer
    case startTimeoutLabel                  // "Ready timeout"
    case autoConnectOnLaunchLabel
    case autoRemoveConnectionOnUninstallLabel
    case tunnelCheckLabel                   // "Tunnel check"
    case keepAliveOff                       // "off"
    case backgroundAudioLabel
    case localSocksAuthLabel, localSocksAuthFooter
    case logLevelLabel
    case footerStartTimeout, footerAutoConnect, footerAutoRemove
    case footerKeepAlive, footerBackgroundAudio, footerDebugLogging
    case footerLogBuffer, footerContainerTail
    case logBufferLabel, containerLogsTailLabel
    case clearAllLogsAction
    case copyAllAction                      // "Copy all" (#258 logs overflow)
    case clearCategoryAction                // "Clear this category" (#258 logs overflow)
    case fontSizeLabel, fontPreviewText
    case fontFooter
    case languageLabel
    case themeLabel, themeRefined, themeConsole   // #267 design-direction picker

    // MARK: InstallOptionsView
    case installTitle                       // "Install olcrtc"
    case reconfigureTitle                   // "Change Room / Transport"
    case reconfigureInfoFooter              // "Container will be restarted with new flags — no reinstall."
    case parametersHeader                   // "Parameters"
    case roomIDAutoGenHint
    case roomIDTelemostHint
    case roomIDWbstreamHint
    case matrixRecommended_fmt              // "★ Recommended for %@."
    case matrixWorks_fmt                    // "Works with %@."
    case matrixQuestion_fmt                 // "⚠ Working with %@ is uncertain."
    case matrixFail_fmt                     // "✗ Does not work with %@ — choose another transport."
    case matrixUnknown_fmt                  // "No compatibility data for %@."
    case carrierFooter                      // "client-id=ios-<random>..."
    case transportUsesServerDefaults_fmt    // "Server defaults will be used for %@ — advanced parameters are not yet exposed in the iOS settings UI."
    case matrixStatusRecommended, matrixStatusOK, matrixStatusQuestion
    case matrixStatusFail, matrixStatusUnknown
    case transportSectionHeader, roomIDSectionHeader
    case seiSettingsHeader, seiSettingsFooter
    case jitsiServerHeader, jitsiServerFooter   // #256: Jitsi base-URL field
    case actionQR

    // MARK: Status banner

    // MARK: TunnelManager log lines
    case mobileStartOK                      // "✓ MobileStart OK, waiting for WaitReady…"
    case mobileStartFailed_fmt              // "✗ MobileStart: %@"
    case bgKeeperFailed_fmt                 // "⚠ Background runtime keeper failed: %@ (app may be suspended in background)"
    case waitReadyFailed_fmt                // "✗ WaitReady: %@"
    case connectNoPeer                      // #275: WaitReady timed out → no peer joined (likely key/room/carrier)
    case waitReadyOK                        // "✓ WaitReady OK — SOCKS5..."
    case tunnelOK                           // "✓ Tunnel works — traffic is flowing through the server"
    case tunnelFailed                       // "✗ Tunnel not responding (server unreachable or 403 Forbidden IP)"
    case keepAliveOK                        // "♡ Keep-alive OK"
    case keepAliveLost                      // "✗ Keep-alive..."
    case serverConnectionLost               // "Connection to server lost"
    case serverNotResponding                // "Server not responding"
    case disconnectingArrow                 // "→ Disconnecting"
    case netPathLost                        // "⚠ Network lost — waiting for connectivity" (#269)
    case netPathRestored                    // "network restored" (#269 reconnect reason)
    case netPathChanged                     // "network path changed" (#269 reconnect reason)
    case reconnecting_fmt                   // "↻ Reconnecting (%@)" (#269/#270 sink entry)
    case reconnectAttempt_fmt               // "↻ attempt %d/%d in %ds" (#270 backoff)
    case reconnectGaveUp                    // "✗ Reconnect failed — tap Retry" (#270 give-up)
    case rejoinSettle_fmt                   // "⏳ Room settle: %.1fs before re-join" (#271)
    case connectingOlcrtc_fmt               // "→ olcrtc carrier=%@..."
    case portChangedAuto_fmt                // "↪ Port %d is busy, using %d (updated in Settings)"

    // MARK: TunnelManager errors
    case validateClientIDEmpty
    case validateClientIDWhitespace
    case validateKeyLength_fmt
    case validateKeyNonHex
    case validateRoomIDEmpty
    case errorAllPortsBusy_fmt

    // MARK: OlcrtcURI errors
    case uriErrorInvalidScheme
    case uriErrorMissingField_fmt

    // MARK: Provisioning
    case provisioningSSHConnecting          // "Connecting via SSH…"
    case provisioningRebootSSH              // "Reboot: connecting via SSH…"
    case provisioningUninstallSSH           // "Delete: connecting via SSH…"
    case provisioningRebooting              // "Rebooting…"
    case provisioningUninstalling           // "Removing container and files…"
    case provisioningUpdating               // "Updating binary…"
    case provisioningReconfiguring          // "Reconfiguring container…"
    case provisioningStatusFetching         // "Container status…"
    case provisioningLogsFetching           // "Container logs…"
    case installStep1Upload                 // "[1/3] Uploading script…"
    case installStep2Launch                 // "[2/3] Running install script…"
    case installStep3PollRetry_fmt          // "[3/3] Server temporarily unavailable, retry (%d)…"
    case installPhaseWaiting, installPhaseSystemDeps, installPhaseClone, installPhasePullImage, installPhaseDeps, installPhaseBuild, installPhaseStart
    case installFailedNoURI_fmt             // "Script finished without URI. Last lines:\n%@"
    case installTimeout25min                // "Install timed out (25 minutes)"
    case installResultSuccess_fmt           // "olcrtc server installed (%@/%@)"
    case uninstallResultSuccess             // "Server cleaned up"
    case updateResultSuccess                // "Binary updated"
    case provisioningStarting, startResultSuccess, actionStart
    case provisioningStopping, stopResultSuccess, actionStop
    case scanningContainers, actionScanVPS, scanNoContainers
    case scanRestoreAction
    case actionDeepUninstall, deepUninstallResultSuccess
    case reconfigureResultSuccess_fmt       // "Parameters updated (%@/%@)"
    case rebootResultSuccess                // "Reboot command sent"
    case logsBytesReceived_fmt              // "Logs received (%d bytes)"
    case provisionPasswordMissing           // "Password not found in Keychain"
    case provisionSSHPrefix_fmt             // "SSH: %@"
    case provisionCommandPrefix_fmt         // "Command: %@"
    case provisionParsePrefix_fmt           // "Failed to parse output: %@"
    case sshAttemptFailed_fmt               // "✗ SSH attempt %d/2..."
    case sshRetryIn4s                       // "  retry in 4 s…"
    case sshPortNotResponding_fmt           // "Port %d on %@ did not respond — verify SSH is open and the VPS is reachable"
    case serverUnreachable_fmt              // "Server %@ is not responding — check the VPS is online and SSH port is reachable"

    // MARK: NetPing
    case pingTCPOK_fmt                      // "TCP/%d responded in %@ ms"
    case pingTCPFail_fmt                    // "TCP/%d unreachable"

    // MARK: ConnectionsView per-connection health check (#274 — merges #234 + #242)
    case pingNoFreePort                     // "No free local port available for ping"
    case pingFailed                         // "Ping failed"
    case healthCheckAction                  // "Health check" — menu item + chip a11y (#274)
    case healthResult_fmt                   // "🩺 Health %@ — ready %@ · RTT %@" (#274)

    // MARK: ServersView alerts
    case alertPasswordMissingShort          // "Password not found"

    // MARK: AddServerHostView
    case nameSettingLabel                   // "Name"
    case sectionDescription                 // "Description"
    case testSSHAction                      // "Test SSH"

    // MARK: ConnectionsView misc
    case diagnosticsTitle                   // "Diagnostics" (#258 merged card)
    case ipCheckTitle                       // "IP check"
    case ipCheckRun                         // "Check IP"
    case speedTestRun                       // "Run test"

    // MARK: #236/#237 — UI strings localized after the i18n pass
    case ipChecking                         // "Checking…"
    case ipNotChecked                       // "Not checked yet"
    case ipDnsLeak                          // "IPs differ — possible DNS leak"
    case ipSourcesAgree_fmt                 // "✓ %@ (%d sources)"
    case socksProxyAddr_fmt                 // "SOCKS5 proxy: 127.0.0.1:%@"
    case portInUseByTunnel                  // "in use by tunnel"
    case roomPrefix_fmt                     // "room: %@"
    case qrCodeURIA11y                      // "Connection URI QR Code"
    case qrCodeHintA11y                     // "Scan this code to import the connection on another device"
    case cameraUnavailableTitle             // "Camera not available"
    case cameraUnavailableBody              // "QR scanning requires a physical device with a camera."
    case sectionCarrier                     // "Carrier"
    case labelTransport                     // "Transport"
    // #283: friendly display names for the raw carrier/transport IDs
    case carrierTelemost, carrierWbstream, carrierJitsi
    case transportDatachannel, transportVp8channel, transportSeichannel, transportVideochannel
    case fieldRoomID                        // "Room ID"
    case fieldJitsiURL                      // "https://meet.example.org" (#256)

    // MARK: DNS carrier labels (RU operator names — localizable)
    case dnsLabelMts, dnsLabelBeeline, dnsLabelMegafon
    case dnsLabelTele2, dnsLabelYota

    // MARK: SubscriptionFetcher errors
    case subDohFailed_fmt                   // "DoH could not resolve %@"
    case subInvalidResponse_fmt             // "HTTP %d"
    case subNoAddress                       // "DoH returned an empty address list"
}

extension L10n {
    /// Returns the localized string for the current (or explicit) locale.
    func localized(_ locale: AppLocale = .current) -> String {
        L10nTable.value(for: self, in: locale)
    }

    /// Convenience for cases whose pattern contains %@/%d/%.0f placeholders.
    /// Cases that use this convention end with `_fmt`.
    func formatted(_ args: CVarArg...) -> String {
        String(format: self.localized(), arguments: args)
    }
}
