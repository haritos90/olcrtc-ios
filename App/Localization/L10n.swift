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
    case tabConfig                          // #301: "Config" tab (placeholder)
    case configComingSoonTitle              // #301: placeholder title
    case configComingSoonHint               // #301: placeholder hint
    case autoDetectedContainer_fmt          // #302: "Auto-detected existing container: %@"

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
    // #135: full-access (co-admin) share — carries SSH creds; destructive.
    case shareFullAccessTitle               // "Share full access (SSH)"
    case shareFullAccessHeader              // "Full access (SSH)"
    case shareFullAccessWarning             // destructive warning
    case shareFullAccessReveal              // "Reveal full-access link"
    case shareFullAccessCopy                // "Copy full-access link"
    case shareFullAccessCopied_fmt          // "🔑 Full-access link copied: %@"
    // #366: receiving a full-access (olcrtc://host/v1/…) link — confirm import.
    case fullAccessImportTitle              // "Import full access?"
    case fullAccessImportBody_fmt           // warning + "saves SSH creds for %@"
    case fullAccessImportAddAction          // "Add full access"
    case fullAccessImportInvalid            // "This full-access link is invalid."

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
    // #365: per-connection seichannel params (shown only for transport == seichannel)
    case seiParamsHeader                    // "SEI parameters"
    case seiFpsLabel                        // "FPS"
    case seiBatchLabel                      // "Batch size"
    case seiFragLabel                       // "Fragment size"
    case seiAckLabel                        // "ACK timeout (ms)"
    case seiParamsHint                      // explanation: only sent for seichannel transport

    // MARK: ServersView
    case serversTitle                       // "VPS list"
    case emptyNoServers, emptyNoServersHint
    case newServerTitle, editServerTitle
    case sshAccessHeader
    case hostField, portField, loginField, passwordField
    case actionInstall, actionUninstall, actionUpdate, actionReboot
    case actionChangeRoomTransport         // "Change Room / Transport"
    // #339 was: actionDownloadContainerLogs ("Download container logs") — the
    // action shows the logs in the Logs tab now, it doesn't download a file.
    case actionContainerLogs                // "Container logs"
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

    // MARK: #303 Recover connection from server
    case actionRecoverConnection           // "Recover connection" (host overflow menu)
    case recoverConfirmTitle               // "Recover connection from this server?"
    case recoverConfirmBody                // explanation: reads server.yaml + key, adds a connection
    case recoverConfirmAction              // "Recover" (confirm button)
    case provisioningRecovering            // "Reading server config…" (status step)
    case recoverResultSuccess_fmt          // "Recovered %@/%@ — connection added"
    case recoverErrorMissingYAML           // "Server config not found"
    case recoverErrorMissingField_fmt      // "Server config is missing '%@'"

    // MARK: #314 Generate new key (fallback when #303 recovery can't read server.yaml)
    case rotateKeyConfirmTitle             // "Server config unreadable — generate a new key?"
    case rotateKeyConfirmBody              // warning: rotation cuts off all other clients
    case rotateKeyConfirmAction            // "Generate new key" (destructive confirm button)
    case provisioningRotatingKey           // "Generating new server key…" (status step)
    case rotateKeyResultSuccess            // "New encryption key active" (provisioner status)
    case rotateKeyResultAdded_fmt          // "New key generated — %@/%@ connection added"
    case rotateKeyFailedNoURI              // rotation script printed no OLCRTC_URI=

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

    // #339 was: MARK ContainerLogsView (emptyLogsTitle, emptyLogsHint_fmt) —
    // the sheet is gone; closeAction stays (sheet chrome + ShareConnectionView).
    case closeAction

    // MARK: LogsView
    case logsTitle                          // "Logs"
    case logsSearchPlaceholder              // "Search"
    case emptyLogsGeneric                   // "Empty"
    case emptyLogsGenericHint               // "Run an operation in the Connections or Servers tab"
    case noSearchResults                    // "Nothing found"
    case noSearchResultsHint_fmt            // "No matches for «%@»."
    case categoryConnection                 // "Connection"
    // #294 was: categoryIP ("IP") + categorySpeed ("Speed test") — merged
    // into one Diagnostics tab/category.
    case categoryDiagnostics                // "Diagnostics"
    case categoryProvisioning               // "VPS"
    case categoryContainerLogs              // "Container"

    // MARK: #294 — per-source Logs tabs
    case logsTabDescConnection              // "connection logs"
    case logsTabDescDiagnostics             // "IP and speed test logs"
    case logsTabDescVPS                     // "VPS provisioning logs"
    case logsTabDescContainer               // "Server container extracted logs"
    case logsFileNameLabel_fmt              // "File: %@"
    case logsContainerSelectServer          // "Server" — picker label for the Container tab
    case logsContainerNoServers             // "No servers configured" — Container tab with zero hosts

    // MARK: #295 — per-server container log files
    case duplicateServerNameError           // "A server with this name already exists"

    // MARK: #296 — Container tab always-present load button
    // #338 was: logsDownloadFromServer ("Download logs from server") — the
    // bare text button became the source card's "Fetch" OlcButton.
    case logsCheckServer                    // "Check server" — mirrors vpsCheckServer, gated by readiness
    case logsContainerEmptyHint             // "Logs need to be loaded from the server."

    // MARK: #316 — single-stack Logs tab
    case logsSegConnection                  // "Conn" — abbreviated segment label; full name in accessibilityLabel
    case logsSegDiagnostics                 // "Diag"
    case logsSegVPS                         // "VPS"
    case logsSegContainer                   // "Container"
    case logsLineCount_fmt                  // "%d lines" — file-header row, right-aligned
    case logsPeerCount_fmt                  // #367: "👥 %d peers" — live server peer count

    // MARK: #338 — inline container fetch with progress
    case logsFetchAction                    // "Fetch" — source-card button
    case logsFetchFromHost_fmt              // "Fetch from %@" — empty-state CTA
    case logsPhaseConnecting                // "Connecting…" — fetch phase 1/3 (covers the scan-first fallback)
    case logsPhaseCommand_fmt               // "podman logs --tail %d %@" — fetch phase 2/3
    case logsPhaseReceiving                 // "Receiving output…" — fetch phase 3/3

    // MARK: #332 — rendered-line cap
    case logsRenderTruncated_fmt            // "Showing the newest %d lines…" — notice above a capped log body

    // MARK: SettingsView
    case settingsTitle
    case sectionSOCKS5, sectionDNS, sectionVP8, sectionConnection
    // #343 was: sectionKeepAlive, sectionFont — keep-alive folded into the
    // Connection section, the font section header became "Appearance".
    case sectionLogs
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
    // MARK: #300 — three explicit port-check log lines (free / busy by
    // someone else / busy because our own tunnel reserved it), replacing
    // the old binary logPortBusy_fmt which couldn't tell those apart.
    case logPortFree_fmt                    // "✓ Port %d free"
    case logPortBusyOther_fmt               // "✗ Port %d busy"
    case logPortBusyOlcrtc_fmt              // "✓ Port %d in use by olcrtc tunnel"
    // #343 was: socksFooter — cut per the one-short-footer rule (§7)
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
    case localSocksAuthLabel                // #343 was: + localSocksAuthFooter (footer cut, §7)
    case logLevelLabel
    // #343 was: footerStartTimeout/AutoConnect/AutoRemove/BackgroundAudio/
    // DebugLogging + footerContainerTail — per-row footers cut when the
    // Connection and Logs groups merged into single sections (§7).
    case footerKeepAlive
    case footerLogBuffer
    case logBufferLabel, containerLogsTailLabel
    case clearAllLogsAction
    case copyAllAction                      // "Copy all" (#258 logs overflow)
    case clearCategoryAction                // "Clear this category" (#258 logs overflow)
    case fontSizeLabel, fontPreviewText
    case fontFooter
    case languageLabel
    // #299 was: themeRefined/themeConsole/directionLabel — the Refined/Console
    // "design direction" picker was removed when Theme became real colour schemes.
    case themeLabel                         // "Theme" — the appearance-scheme picker label
    // #340 — appearance scheme picker (System / Light / Dark / Gray)
    case appearanceLabel                    // "Appearance"
    case appearanceSystem                   // "System"
    case appearanceLight                    // "Light"
    case appearanceDark                     // "Dark"
    case appearanceGray                     // "Gray" (#299)
    // #342 — fixed-footprint hero footer
    case heroDisconnectedHint_fmt           // "Flip the switch to connect via %@."

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
    case waitingForPortRelease              // "⏳ Waiting for port release…" (#333: own-ghost same-port wait)
    case netPathRestored                    // "network restored" (#269 reconnect reason)
    case netPathChanged                     // "network path changed" (#269 reconnect reason)
    case reconnecting_fmt                   // "↻ Reconnecting (%@)" (#269/#270 sink entry)
    case reconnectAttempt_fmt               // "↻ attempt %d/%d in %ds" (#270 backoff)
    case reconnectGaveUp                    // "✗ Reconnect failed — tap Retry" (#270 give-up)
    case rejoinSettle_fmt                   // "⏳ Room settle: %.1fs before re-join" (#271)
    case connectingOlcrtc_fmt               // "→ olcrtc carrier=%@..."
    // #308 was: portChangedAuto_fmt ("↪ Port %d is busy, using %d") — removed with
    // the auto-slide; the configured SOCKS port is now always bound (see errorPortBusy_fmt).

    // MARK: TunnelManager errors
    case validateClientIDEmpty
    case validateClientIDWhitespace
    case validateKeyLength_fmt
    case validateKeyNonHex
    case validateRoomIDEmpty
    // #308 was: errorAllPortsBusy_fmt (port-range "all busy") — replaced by the
    // single-port errorPortBusy_fmt now that the port no longer slides.
    case errorPortBusy_fmt                  // "Port %d is busy — free it or change the port in Settings" (OLC-1026)
    // #375: the encryption key couldn't be read from Keychain because the device
    // was still locked at launch (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly).
    // Shown instead of the misleading "Key must be 64 hex characters (got: 0)".
    case errorSecretsLocked                 // "Unlock the device and reopen the app to load your saved key."

    // MARK: OlcrtcURI errors
    case uriErrorInvalidScheme
    case uriErrorMissingField_fmt
    case uriErrorMixedBrackets               // #355 (audit S1): payload [...]/<...> brackets mismatched

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
    case healthResultRTT_fmt                // #407: "🩺 Health %@ — RTT %@" (RTT-only fast path)

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

    // MARK: #311 — speed-tile metric labels/units + upload-fallback log line
    case speedLabelPing, speedLabelDL, speedLabelUL  // "Ping"/"DL"/"UL" — universal abbreviations, ru = en
    // #342 was: units baked into the formats ("%.0f ms"/"%.1f Mbps") — now
    // number-only, the unit renders separately via OlcMetric(unit:).
    case speedPingValue_fmt                  // "%.0f"
    case speedRateValue_fmt                  // "%.1f"
    case speedUnitMs                         // "ms" — Latin in both languages
    case speedUnitMbps                       // "Mbps" — Latin in both languages
    case speedUploadFallback_fmt             // "  upload: %@ has no upload endpoint — using %@" — diagnostic log line, deliberately English (ru = en)

    // MARK: #236/#237 — UI strings localized after the i18n pass
    case ipChecking                         // "Checking…"
    case ipNotChecked                       // "Not checked yet"
    case ipDnsLeak                          // "IPs differ — possible DNS leak"
    case ipSourcesAgree_fmt                 // "✓ %@ (%d sources)"
    case socksProxyAddr_fmt                 // "SOCKS5 proxy: 127.0.0.1:%@"
    // #300 was: portInUseByTunnel ("in use by tunnel") — relabeled to make
    // explicit that *this app's* tunnel reserved the port (vs. some other
    // process), and gated on live tunnel state at the call site.
    case portInUseByOlcrtc                  // "in use by olcrtc tunnel"
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

    // MARK: Subscription import (#111: olcrtc-sub:// links)
    case subImportTitle                     // "Import subscription"
    case subImportConfirm_fmt               // "Add %d connection(s) from “%@”?"
    case subImportAddAction                 // "Add"
    case subInvalidLink                     // bad olcrtc-sub:// link
    case subEmptyList                       // fetched, but no valid olcrtc:// lines
    case subImportPastedSource              // #361: source label for a pasted raw sub.md body

    // MARK: #363 — surfaced subscription metadata (group detail + per-node)
    case subMetaSource                      // "Source"
    case subMetaServers                     // "Servers"
    case subMetaRefresh                     // "Refresh"
    case subMetaRefreshNever                // "Never"
    case subMetaRefreshInterval_fmt         // "every %@"
    case subMetaUsed                        // "Used"
    case subMetaAvailable                   // "Available"
    case subMetaMultipleSources_fmt         // "%d sources" — #396: group sharing a #name across sources
    case pullToRefreshSubscriptions         // #411: hint that the Connections pull-to-refresh re-fetches subscriptions

    // MARK: #364 — batch "ping group"
    case pingGroupAction                    // "Ping all"
    case pingGroupResult_fmt                // "📡 Pinged %@: %d ok, %d failed"

    // MARK: #346 — VPS-card mini-stat labels (abbreviations; ru = en per operator)
    case vpsStatPing, vpsStatDisk, vpsStatRAM, vpsStatUp
    case scanRestored_fmt                   // "Restored: %@" — #303 restore alert (real ru)

    // MARK: #337 — screenshot-safe IP masking
    case maskIPsLabel                       // "Hide IP addresses" — Settings toggle
    case maskIPsFooter                      // explanation: display-only, copy stays real, logs unmasked

    // MARK: #328 — active-carrier endpoints with one-tap copy (proxy-loop exclusions)
    case carrierEndpointsTitle              // "Carrier endpoints"
    case carrierEndpointsHint               // "Add these as DIRECT rules in your proxy app so its own traffic doesn't loop through olcrtc."
    case carrierEndpointHost                // "Host"
    case carrierEndpointResolvedIPs         // "Resolved IPs"
    case carrierEndpointResolving           // "Resolving…"
    case carrierEndpointUnresolved          // "Could not resolve"
    case carrierEndpointNoHost              // "This carrier's room ID isn't a host — nothing to exclude."
    case carrierEndpointCopied_fmt          // "📋 Copied: %@"
    case carrierEndpointRefresh             // "Re-resolve" — IPs rotate
    // #406: carrier endpoints behind a Diagnostics button + a copy-all action.
    case carrierEndpointsCheckAction        // "Check" — opens the sheet
    case carrierEndpointsConnectHint        // diagnostics subtitle when disconnected
    case carrierEndpointsReadyHint          // diagnostics subtitle when connected
    case carrierEndpointCopyAll             // "Copy host & IPs"

    // MARK: #359 — accessibility for the hero connect toggle + icon toolbar buttons
    case a11yConnectToggle                  // "Connect"
    case a11yConnectHintSelectFirst         // "Select a connection first"
    case a11yStateConnected, a11yStateConnecting, a11yStateDisconnected  // toggle a11y value

    // MARK: #360 — in-app update checker (GitHub Releases)
    case updateCheckLabel                   // "Check for updates" — Settings toggle
    case updateCheckFooter                  // explanation: anonymous, opt-out, links only
    case updateAvailableTitle_fmt           // "Update available — %@"
    case updateAvailableBody                // explanation: a newer build is on GitHub; sideload it
    case updateOpenReleasePage              // "Open release page"
    case updateInstallSideStore             // "Install with SideStore"
    case updateInstallLiveContainer         // "Install with LiveContainer"
    case updateLater                        // "Later"

    // MARK: Bot settings (#416–#420)
    case botPlatformTelegram, botPlatformMax            // platform names; ru = en
    // status + recoverable errors (Provisioner / SSHRunner)
    case botDeploying, botDeploySuccess, botChecking, botRemoving, botRemoveSuccess
    case botErrorNoSystemd, botErrorNoPython, botErrorNoRoot, botErrorGeneric_fmt
    case botErrorNotActive                  // #423: installed but the service didn't start
    // per-server sheet (#419)
    case botSheetTitle                      // "Bot" — sheet title + action button/menu label
    case botSheetFooter                     // generic how-it-works line
    case botSelectLabel                     // "Bot" — picker: which registry bot
    case botCommandsHeader, botRepliesHeader
    case botStartCmdLabel, botStopCmdLabel
    case botStartReplyLabel, botStopReplyLabel, botUnknownReplyLabel
    case botDefaultStartReply, botDefaultStopReply, botDefaultUnknownReply  // seed values
    case botCheckAction                     // "Check server"
    case botDeployAction                    // "Deploy bot"
    case botRemoveAction                    // "Remove bot from server"
    case botStatusRunning                   // "Running"
    case botStatusInstalledIdle             // "Installed, not running"
    case botStatusNone                      // "No bot on this server"
    case botNoBotsTitle, botNoBotsHint      // empty-registry state
    case botMissingTokenError               // selected bot has no token yet
    case botUnknownFound_fmt                // "Found a bot “%@” that isn't in your Settings."
    case botRemoveConfirmTitle, botRemoveConfirmBody
    // settings registry (#420)
    case sectionBots                        // "Bots" — Settings section + subscreen title
    case botsFooter                         // detection / delete caveat
    case botsEmptyHint                      // list empty
    case botAddTitle, botEditTitle          // editor titles
    case botAddAction, botDeleteAction
    case botNameLabel, botNamePlaceholder, botPlatformLabel
    case botTokenLabel, botTokenPlaceholder // masked, paste-only
    case botTokenSavedHint, botTokenNoneHint
    case botCopyTokenAction, botTokenCopied
    case botNameTakenError
    case botTokenStatusSaved, botTokenStatusMissing // #428: read-only status in the per-server sheet
    case botTokenManageHint                 // #428: "token is set in Settings → Bots"
    case botTokenCreateHint                 // #428: "create the bot on the platform first"
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
