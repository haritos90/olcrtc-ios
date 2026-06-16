import Foundation

// MARK: - L10nTable
//
// Per-language translation dictionaries. Every key in `L10n` must appear in
// every dictionary — the unit test in `L10nTests.swift` enforces this.
//
// Missing translations fall back to English; missing in English too falls back
// to the case's raw name (which makes the gap visible without crashing).

enum L10nTable {

    static func value(for key: L10n, in locale: AppLocale) -> String {
        switch locale {
        case .english: return english[key] ?? key.rawValue
        case .russian: return russian[key] ?? english[key] ?? key.rawValue
        }
    }

    // MARK: English (canonical / fallback)

    static let english: [L10n: String] = [
        // Common
        .ok:                "OK",
        .cancel:            "Cancel",
        .save:              "Save",
        .close:             "Close",
        .done:              "Done",
        .error:             "Error",
        .edit:              "Edit",
        .okPrompt:          "Done",

        // Tabs
        .tabConnections:    "Connections",
        .tabServers:        "Manage VPS",
        .tabLogs:           "Logs",
        .tabSettings:       "Settings",
        .tabConfig:         "Config",
        .configComingSoonTitle: "Coming soon",
        .configComingSoonHint:  "Routing options — direct/tunnel modes and per-app rules — will live here.",
        .autoDetectedContainer_fmt: "Auto-detected existing container: %@",

        // Routing
        .routingHeader:     "Routing",
        .routingAllTunnel:  "All through tunnel",
        .routingAllDirect:  "All direct",
        .routingViaTunnel:  "via tunnel",
        .routingDirect:     "direct",

        // Connection state
        .stateDisconnected: "Disconnected",
        .stateConnecting:   "Connecting…",
        .stateConnected:    "Connected",
        .stateConnectFailed: "Connection failed",
        .stateWaitingForNetwork: "Waiting for network…",
        .stateErrorPrefix_fmt: "Error: %@",

        // ConnectionsView
        .emptyNoConnections:         "No connections yet",
        // #303 was: "Tap + to add a connection manually. If you have a VPS, go to the Servers tab to install and link automatically."
        .emptyNoConnectionsHint:     "Tap + to add a connection manually. If you have a VPS, go to the Servers tab to install and link automatically — or, if olcrtc is already running there, use \"Recover connection\".",
        .actionConnect:              "Connect",
        .actionRetry:                "Retry",
        .shareAction:                "Share",
        .copyURIAction:              "Copy URI",
        .shareConnectionTitle:       "Share connection",
        .shareConnectionExplanation: "Share this URI to let others connect through your server. It contains the carrier, room ID, and encryption key — your server SSH credentials are not included.",
        .shareConnectionURIHeader:   "Connection URI",
        .primaryRoleMain:            "primary",
        .copiedURI_fmt:              "📋 URI copied: %@",
        // #135: full-access (co-admin) share
        .shareFullAccessTitle:       "Share full access (SSH)",
        .shareFullAccessHeader:      "Full access (SSH)",
        .shareFullAccessWarning:     "This link contains your SSH login and password. Anyone with it can fully control this VPS — install, reconfigure, reboot, or wipe it. Share only with someone you trust to co-administer the server.",
        .shareFullAccessReveal:      "Reveal full-access link",
        .shareFullAccessCopy:        "Copy full-access link",
        .shareFullAccessCopied_fmt:  "🔑 Full-access link copied: %@",
        // #366
        .fullAccessImportTitle:      "Import full access?",
        .fullAccessImportBody_fmt:   "This link grants full SSH control of the VPS “%@” — its address, login and password will be saved on this device. Only import links you trust.",
        .fullAccessImportAddAction:  "Add full access",
        .fullAccessImportInvalid:    "This full-access link is invalid.",

        // AddConnectionView
        .newConnectionTitle:         "New connection",
        .editConnectionTitle:        "Edit connection",
        .nameField:                  "Label",
        .namePlaceholder:            "My server",
        .groupField:                 "Group",
        // #344 was: "Servers" — the Connections tab lists *connections*, not
        // servers (display-only; the persisted raw group value stays "Servers"
        // and is mapped via ConnectionRecord.displayGroupName).
        .groupDefault:               "Connections",
        .importByURI:                "Import from URI",
        .scanQRAction:               "Scan QR",
        .pasteURIAction:             "Paste URI",
        .importHint:                 "Tap Paste to import a URI or a subscription from the clipboard, or Scan QR. The fields below fill in automatically.", // #381 was: "If you have a URI from the server — paste it here and tap «Parse». The fields below will be filled in automatically." — buttons are Scan QR / Paste (Paste also imports subscriptions since #361), there is no "Parse" button.
        .clientIDFooter:             "Your device identifier in the room. 'default' works for single-device setups. Use a unique value when multiple devices share the same room.",
        .keyPlaceholder:             "64-char hex key",
        .roomIDLabel:                "Room ID",
        .vp8ParamsHeader:            "VP8 parameters",
        .socksAuthHeader:            "SOCKS5 authentication",
        .socksAuthFooter:            "Username and password that apps must supply to use the local SOCKS5 proxy. Only needed if other apps on this device should be restricted from using the tunnel.",
        .socksUserLabel:             "User",
        .socksPassLabel:             "SOCKS password",
        .socksUserPlaceholder:       "empty = no auth",
        .vp8FpsLabel:                "FPS",
        .vp8BatchLabel:              "Batch size",
        .globalDefault_fmt:          "global (%d)",
        .overrideHint:               "Overrides global settings for this connection only. «×» resets to global.",
        // #365: per-connection seichannel params
        .seiParamsHeader:            "SEI parameters",
        .seiFpsLabel:                "FPS",
        .seiBatchLabel:              "Batch size",
        .seiFragLabel:               "Fragment size",
        .seiAckLabel:                "ACK timeout (ms)",
        .seiParamsHint:              "Tuning for the SEI channel. Sent only when the transport is seichannel; stored either way.",

        // ServersView
        .serversTitle:               "VPS list",
        .emptyNoServers:             "No servers",
        .emptyNoServersHint:         "Add a VPS to install olcrtc from here",
        .newServerTitle:             "New server",
        .editServerTitle:            "Edit",
        .sshAccessHeader:            "SSH access",
        .hostField:                  "Host",
        .portField:                  "Port",
        .loginField:                 "Login",
        .passwordField:              "Password",
        .actionInstall:              "Install",
        .actionUninstall:            "Remove container from server",
        .actionUpdate:               "Update binary (git pull + rebuild)",
        .actionReboot:               "Reboot",
        .actionChangeRoomTransport:  "Change Room / Transport",
        .actionContainerLogs:        "Container logs",   // #339 was: "Download container logs"
        .actionDone:                 "Done",
        .actionRemoveFromList:       "Remove host from list",
        .removeHostConfirmTitle:     "Remove %@?",
        .removeHostConfirmMessage:   "The host will be removed from this device's list. The container on the VPS is NOT touched — use Uninstall first if you want to wipe it. SSH password is removed from Keychain.",
        .uninstallConfirmTitle:      "Uninstall container?",
        .uninstallConfirmBody:       "Only the container (running process) will be removed. Podman, the golang image (~300 MB) and the Go module cache remain on the server. Reinstallation will be fast (~1–2 min).",
        .deepUninstallConfirmBody:   "Removes container, Go cache (~300 MB), and encryption key. Podman and image stay.",
        .rebootConfirmTitle:         "Reboot server?",
        .rebootConfirmBody:          "This will reboot the entire VPS. The olcrtc container will restart automatically once the server is back online.",
        .carrierTransportMatrix:     "Carrier × Transport",

        // #303: Recover connection from server
        .actionRecoverConnection:    "Recover connection",
        .recoverConfirmTitle:        "Recover connection from this server?",
        .recoverConfirmBody:         "Reads the carrier, room, transport and encryption key already deployed on this server (read-only) and adds them as a new connection here.",
        .recoverConfirmAction:       "Recover",
        .provisioningRecovering:     "Reading server config…",
        .recoverResultSuccess_fmt:   "Recovered %@/%@ — connection added",
        .recoverErrorMissingYAML:    "Server config not found — the deployed server.yaml could not be read.",
        .recoverErrorMissingField_fmt: "Server config is missing '%@'",

        // #314: generate-new-key fallback (server.yaml unreadable/unparseable)
        .rotateKeyConfirmTitle:      "Server config unreadable — generate a new key?",
        .rotateKeyConfirmBody:       "The deployed server.yaml could not be read, so the existing connection cannot be recovered. This generates a new encryption key on the server, repairs its config, restarts it, and adds the resulting connection here. Warning: all other devices using this server will lose access until they import the new connection.",
        .rotateKeyConfirmAction:     "Generate new key",
        .provisioningRotatingKey:    "Generating new server key…",
        .rotateKeyResultSuccess:     "New encryption key active",
        .rotateKeyResultAdded_fmt:   "New key generated — %@/%@ connection added",
        .rotateKeyFailedNoURI:       "Key rotation finished but the server did not print a URI — check the provisioning log.",

        // Container status
        .containerRunning_fmt:       "Container running: %@",
        .containerStopped_fmt:       "Container stopped: %@",
        .containerNotFound:          "Container not found",
        .containerNotFoundShort:     "not found",
        .containerNotInstalled:      "Container is not installed yet — tap «Install».",
        .readinessNoPodman:              "Ready to install (Podman not found, full setup ~5–7 min)",
        .readinessNoImage:               "Podman ready — first install pulls image (~300 MB, ~3–5 min)",
        .readinessImageReady:            "Image cached — reinstall takes ~1–2 min",
        .readinessContainerStopped_fmt:  "Stopped: %@",
        .readinessContainerRunning_fmt:  "Running: %@",

        // VPS status card (#258/#261)
        .vpsTitleUnknown:         "Status unknown",
        .vpsTitleReady:           "Ready to install",
        .vpsTitlePodmanReady:     "Podman ready",
        .vpsTitleStopped:         "Stopped",
        .vpsTitleRunning:         "Running",
        .vpsSubUnknown:           "Tap Check to probe",
        .vpsSubNoPodman:          "Full setup ~5–7 min",
        .vpsSubNoImage:           "First install pulls image (~300 MB)",
        .vpsSubImageReady:        "Image cached — fast reinstall",
        .vpsSubStopped:           "Container present, not running",
        .vpsSubRunning:           "Server process up — not a connection test",
        .vpsVerbChecking:         "Checking",
        .vpsVerbInstalling:       "Installing",
        .vpsVerbStarting:         "Starting",
        .vpsVerbStopping:         "Stopping",
        .vpsVerbReconfiguring:    "Reconfiguring",
        .vpsVerbUpdating:         "Updating",
        .vpsVerbUninstalling:     "Uninstalling",
        .vpsVerbDeepUninstalling: "Deep uninstalling",
        .vpsVerbRebooting:        "Rebooting",
        .vpsConnecting:           "Connecting…",
        .vpsCheckServer:          "Check server",
        .vpsWorking:              "Working…",
        .vpsOpFailed_fmt:         "%@ failed",

        // ContainerLogsView
        // #339 was: emptyLogsTitle + emptyLogsHint_fmt (ContainerLogsView sheet, deleted)
        .closeAction:                "Close",

        // LogsView
        .logsTitle:                  "Logs",
        .logsSearchPlaceholder:      "Search",
        .emptyLogsGeneric:           "Empty",
        // #316 was: "…Connections or Servers tab" — the VPS tab is named "Manage VPS".
        .emptyLogsGenericHint:       "Run an operation in the Connections or Manage VPS tab",
        .noSearchResults:            "Nothing found",
        .noSearchResultsHint_fmt:    "No matches for «%@».",
        .categoryConnection:         "Connection",
        .categoryDiagnostics:        "Diagnostics",
        .categoryProvisioning:       "VPS",
        .categoryContainerLogs:      "Container",

        // #294: per-source Logs tabs
        // #316 was: lowercase fragments shown under the tab title — now they
        // open the empty-state hint, so they read as sentences.
        .logsTabDescConnection:      "Connection logs",
        .logsTabDescDiagnostics:     "IP and speed test logs",
        .logsTabDescVPS:             "VPS provisioning logs",
        .logsTabDescContainer:       "Server container extracted logs",
        .logsFileNameLabel_fmt:      "File: %@",
        .logsContainerSelectServer:  "Server",
        .logsContainerNoServers:     "No servers configured",

        // #295: per-server container log files
        .duplicateServerNameError:   "A server with this name already exists",

        // #296: Container tab always-present load button
        // #338 was: logsDownloadFromServer ("Download logs from server")
        .logsCheckServer:            "Check server",
        .logsContainerEmptyHint:     "Logs need to be loaded from the server.",
        // #316: single-stack Logs tab — segmented-control short labels + line count
        .logsSegConnection:          "Conn",
        .logsSegDiagnostics:         "Diag",
        .logsSegVPS:                 "VPS",
        .logsSegContainer:           "Container",
        .logsLineCount_fmt:          "%d lines",
        .logsPeerCount_fmt:          "👥 %d peers",
        // #338: inline container fetch — source card + monotonic phases
        .logsFetchAction:            "Fetch",
        .logsFetchFromHost_fmt:      "Fetch from %@",
        .logsPhaseConnecting:        "Connecting…",
        .logsPhaseCommand_fmt:       "podman logs --tail %d %@",
        .logsPhaseReceiving:         "Receiving output…",
        // #332: rendered-line cap notice
        .logsRenderTruncated_fmt:    "Showing the newest %d lines — Share or Copy all exports the full history.",

        // SettingsView
        .settingsTitle:              "Settings",
        .sectionSOCKS5:              "SOCKS5",
        .sectionDNS:                 "DNS",
        .sectionVP8:                 "vp8channel",
        .sectionConnection:          "Connection",
        .sectionLogs:                "Logs",
        .sectionIPSources:           "IP-check sources",
        .ipSourcesFooter:            "Services queried by the IP check. The RU-zone options stay reachable when public resolvers are blocked. If none are selected, the defaults are used.",
        .sectionSpeedProvider:       "Speed-test provider",
        .speedProviderFooter:        "Server the speed test runs against. Switch if Cloudflare is slow or blocked on your network.",
        .speedAllFailed:             "All measurements failed",
        .speedDatachannelHint:       "Tip: video transports (vp8channel/sei/video) trade bandwidth for looking like a call. For more speed, Reconfigure the server to datachannel where your network allows it.",
        .settingsPortLabel:          "Port",
        .checkPortAction:            "Check port",
        .randomPortAction:           "Random",
        .portFree:                   "free",
        .portBusy:                   "busy",
        .logPortFree_fmt:            "✓ Port %d free",
        .logPortBusyOther_fmt:       "✗ Port %d busy",
        .logPortBusyOlcrtc_fmt:      "✓ Port %d in use by olcrtc tunnel",
        .socksPortChangeNote:        "Port change takes effect on the next connection.",
        .dnsFreeFormPlaceholder:     "IP:port",
        .dnsFooter:                  "Passed to the Go runtime and to the server install script. Format: IP:port. RU carrier presets only resolve from inside that carrier's network.",
        .vp8Footer:                  "MobileSetVP8Options only applies when transport=vp8channel. For wbstream this is the default channel. Defaults (60/64) are tuned for Telemost.",
        .startTimeoutLabel:          "Ready timeout",
        .autoConnectOnLaunchLabel:   "Auto-connect on launch",
        .autoRemoveConnectionOnUninstallLabel: "Remove linked connection when VPS is uninstalled",
        .tunnelCheckLabel:           "Tunnel check",
        .keepAliveOff:               "off",
        .backgroundAudioLabel:       "Background work (audio)",
        .localSocksAuthLabel:        "Require proxy authentication",
        .logLevelLabel:              "Log level",
        .footerKeepAlive:            "Sends a periodic end-to-end probe through SOCKS5 every N seconds. On failure the tunnel reconnects automatically. Set to 0 to disable.",
        .footerLogBuffer:            "Maximum number of lines kept in memory per log category.",
        .logBufferLabel:             "Log buffer",
        .containerLogsTailLabel:     "Container logs (tail)",
        .clearAllLogsAction:         "Clear all logs",
        .copyAllAction:              "Copy all",
        .clearCategoryAction:        "Clear this category",
        .fontSizeLabel:              "Font size",
        .fontPreviewText:            "Preview text — this is how labels and headings will look across the app.",
        .fontFooter:                 "Applied app-wide (via SwiftUI dynamicTypeSize). Smaller = denser, larger = easier to read.",
        .languageLabel:              "Language",
        .themeLabel:                 "Theme",

        // #340/#299: appearance scheme picker (System / Light / Dark / Gray)
        .appearanceLabel:            "Appearance",
        .appearanceSystem:           "System",
        .appearanceLight:            "Light",
        .appearanceDark:             "Dark",
        .appearanceGray:             "Gray",
        // #342: fixed-footprint hero footer
        .heroDisconnectedHint_fmt:   "Flip the switch to connect via %@.",

        // InstallOptionsView
        .installTitle:               "Install olcrtc",
        .reconfigureTitle:           "Change Room / Transport",
        .reconfigureInfoFooter:      "The container will be restarted with the new -carrier/-id/-transport flags. No reinstall (no apt-get / go build).",
        .parametersHeader:           "Parameters",
        .roomIDAutoGenHint:          "Room ID will be generated by the server.",
        .roomIDTelemostHint:         "Create a meeting on telemost.yandex.ru and paste its ID (the part after /j/ in the link).",
        .roomIDWbstreamHint:         "Create a room on stream.wb.ru under your account and paste its ID.",
        .matrixRecommended_fmt:      "★ Recommended for %@.",
        .matrixWorks_fmt:            "Works with %@.",
        .matrixQuestion_fmt:         "⚠ Working with %@ is uncertain.",
        .matrixFail_fmt:             "✗ Does not work with %@ — choose another transport.",
        .matrixUnknown_fmt:          "No compatibility data for %@.",
        .carrierFooter:          "client-id=ios-<random> (auto-generated) · key=hex64 (auto-generated) · DNS and VP8 from Settings",
        .matrixStatusRecommended:    "recommended",
        .matrixStatusOK:             "works",
        .matrixStatusQuestion:       "uncertain",
        .matrixStatusFail:           "doesn't work",
        .matrixStatusUnknown:        "no data",
        .transportSectionHeader:     "Transport",
        .roomIDSectionHeader:        "Room ID",
        .jitsiServerHeader:          "Jitsi server",
        .jitsiServerFooter:          "Shared public instance — point at your own Jitsi for reliability and to avoid overloading it.",
        .seiSettingsHeader:          "SEI Settings",
        .seiSettingsFooter:          "SEI params sent to srv.sh for seichannel.",
        .actionQR:                   "QR",

        // Status banner

        // TunnelManager log lines
        .mobileStartOK:              "✓ MobileStart OK, waiting for WaitReady…",
        .mobileStartFailed_fmt:      "✗ MobileStart: %@",
        .bgKeeperFailed_fmt:         "⚠ Background audio keeper failed: %@ — app may be suspended after backgrounding",
        .transportUsesServerDefaults_fmt: "Server defaults will be used for %@ tunables — advanced parameters are not yet exposed in the iOS settings UI.",
        .waitReadyFailed_fmt:        "✗ WaitReady: %@",
        .connectNoPeer:              "No peer joined in time — check the key matches the server, the room is correct, or try another carrier/transport.",
        .waitReadyOK:                "✓ WaitReady OK — SOCKS5 listening, verifying tunnel…",
        .tunnelOK:                   "✓ Tunnel works — traffic is flowing through the server",
        .tunnelFailed:               "✗ Tunnel not responding (server unreachable or 403 Forbidden IP)",
        .keepAliveOK:                "♡ Keep-alive OK",
        .keepAliveLost:              "✗ Keep-alive: tunnel not responding",
        .serverConnectionLost:       "Connection to the conferencing server lost",
        .serverNotResponding:        "Conferencing server not responding",
        .disconnectingArrow:         "→ Disconnecting",
        .netPathLost:                "⚠ Network lost — waiting for connectivity",
        .waitingForPortRelease:      "⏳ Waiting for port release…",
        .netPathRestored:            "network restored",
        .netPathChanged:             "network path changed",
        .reconnecting_fmt:           "↻ Reconnecting (%@)",
        .reconnectAttempt_fmt:       "↻ attempt %d/%d in %ds",
        .reconnectGaveUp:            "✗ Reconnect failed — tap Retry",
        .rejoinSettle_fmt:           "⏳ Room settle: %.1fs before re-join",
        .connectingOlcrtc_fmt:       "→ olcrtc carrier=%@ transport=%@ clientID=%@",

        // TunnelManager errors
        .validateClientIDEmpty:      "Client ID cannot be empty",
        .validateClientIDWhitespace: "Client ID must not contain spaces",
        .validateKeyLength_fmt:      "Key must be 64 hex characters (got: %d)",
        .validateKeyNonHex:          "Key contains non-hex characters",
        .validateRoomIDEmpty:        "Room ID cannot be empty",
        .errorPortBusy_fmt:          "Port %d is busy — free it or change the port in Settings",
        .errorSecretsLocked:         "Unlock the device and reopen the app to load your saved key.",

        // OlcrtcURI errors
        .uriErrorInvalidScheme:      "URI must start with olcrtc://",
        .uriErrorMissingField_fmt:   "Missing field: %@",
        .uriErrorMixedBrackets:      "URI payload brackets are mismatched (expected [...] or <...>)",

        // Provisioning
        .provisioningSSHConnecting:  "Connecting via SSH…",
        .provisioningRebootSSH:      "Reboot: connecting via SSH…",
        .provisioningUninstallSSH:   "Delete: connecting via SSH…",
        .provisioningRebooting:      "Rebooting…",
        .provisioningUninstalling:   "Removing container and files…",
        .provisioningUpdating:       "Updating binary…",
        .provisioningReconfiguring:  "Reconfiguring container…",
        .provisioningStatusFetching: "Container status…",
        .provisioningLogsFetching:   "Container logs…",
        .installStep1Upload:         "[1/3] Uploading script…",
        .installStep2Launch:         "[2/3] Running install script…",
        .installStep3PollRetry_fmt:  "[3/3] Server temporarily unavailable, retry (%d)…",
        .installPhaseWaiting:        "Waiting…",
        .installPhaseSystemDeps:     "Installing system dependencies…",
        .installPhaseClone:          "Cloning repository…",
        .installPhasePullImage:      "Pulling Go image…",
        .installPhaseDeps:           "Downloading Go modules…",
        .installPhaseBuild:          "Building olcrtc…",
        .installPhaseStart:          "Starting olcrtc…",
        .installFailedNoURI_fmt:     "Script finished without URI. Last lines:\n%@",
        .installTimeout25min:        "Install timed out (25 minutes)",
        .installResultSuccess_fmt:   "olcrtc server installed (%@/%@)",
        .uninstallResultSuccess:     "Server cleaned up",
        .updateResultSuccess:        "Binary updated",
        .provisioningStarting:       "Starting server…",
        .startResultSuccess:         "Server started",
        .actionStart:                "Start server",
        .provisioningStopping:       "Stopping server…",
        .stopResultSuccess:          "Server stopped",
        .actionStop:                 "Stop server",
        .scanningContainers:         "Scanning for olcrtc containers…",
        .actionScanVPS:              "Scan for installed olcrtc",
        .scanNoContainers:           "No olcrtc containers found on this server.",
        .scanRestoreAction:          "Restore",
        .actionDeepUninstall:        "Wipe all olcrtc data from server",
        .deepUninstallResultSuccess:          "All olcrtc data removed",
        .reconfigureResultSuccess_fmt: "Parameters updated (%@/%@)",
        .rebootResultSuccess:        "Reboot command sent",
        .logsBytesReceived_fmt:      "Logs received (%d bytes)",
        .provisionPasswordMissing:   "Password not found in Keychain",
        .provisionSSHPrefix_fmt:     "SSH: %@",
        .provisionCommandPrefix_fmt: "Command: %@",
        .provisionParsePrefix_fmt:   "Failed to parse output: %@",
        .sshAttemptFailed_fmt:       "✗ SSH attempt %d/2 failed: %@",
        .sshRetryIn4s:               "  retry in 4 s…",
        .sshPortNotResponding_fmt:   "Port %d on %@ did not respond — verify SSH is open and the VPS is reachable",
        .serverUnreachable_fmt:      "Server %@ is not responding — check the VPS is online and SSH port is reachable",

        // NetPing
        .pingTCPOK_fmt:              "TCP/%d responded in %@ ms",
        .pingTCPFail_fmt:             "TCP/%d unreachable",

        // ConnectionsView per-connection ping (#234)
        .pingNoFreePort:             "No free local port available for ping",
        .pingFailed:                 "Ping failed",
        .healthCheckAction:          "Health check",
        .healthResult_fmt:           "🩺 Health %@ — ready %@ · RTT %@",
        .healthResultRTT_fmt:        "🩺 Health %@ — RTT %@",

        // ServersView alerts
        .alertPasswordMissingShort:  "Password not found",

        // AddServerHostView
        .nameSettingLabel:           "Name",
        .sectionDescription:         "Description",
        .testSSHAction:              "Test SSH",

        // ConnectionsView misc
        .diagnosticsTitle:           "Diagnostics",
        .ipCheckTitle:               "IP check",
        .ipCheckRun:                 "Check IP",
        .speedTestRun:               "Run test",

        // #311 — speed-tile metric labels/units + upload-fallback log line
        .speedLabelPing:             "Ping",
        .speedLabelDL:               "DL",
        .speedLabelUL:               "UL",
        // #342 was: "%.0f ms" / "%.1f Mbps" — unit moved to OlcMetric(unit:)
        .speedPingValue_fmt:         "%.0f",
        .speedRateValue_fmt:         "%.1f",
        .speedUnitMs:                "ms",
        .speedUnitMbps:              "Mbps",
        .speedUploadFallback_fmt:    "  upload: %@ has no upload endpoint — using %@",

        // #236/#237 — UI strings localized after the i18n pass
        .ipChecking:                 "Checking…",
        .ipNotChecked:               "Not checked yet",
        .ipDnsLeak:                  "IPs differ — possible DNS leak",
        .ipSourcesAgree_fmt:         "✓ %@ (%d sources)",
        .socksProxyAddr_fmt:         "SOCKS5 proxy: 127.0.0.1:%@",
        .portInUseByOlcrtc:          "in use by olcrtc tunnel",
        .roomPrefix_fmt:             "room: %@",
        .qrCodeURIA11y:              "Connection URI QR Code",
        .qrCodeHintA11y:             "Scan this code to import the connection on another device",
        .cameraUnavailableTitle:     "Camera not available",
        .cameraUnavailableBody:      "QR scanning requires a physical device with a camera.",
        .sectionCarrier:             "Carrier",
        .labelTransport:             "Transport",
        .carrierTelemost:            "Telemost",
        .carrierWbstream:            "WB Stream",
        .carrierJitsi:               "Jitsi",
        .transportDatachannel:       "DataChannel",
        .transportVp8channel:        "VP8",
        .transportSeichannel:        "SEI",
        .transportVideochannel:      "Video",
        .fieldRoomID:                "Room ID",
        .fieldJitsiURL:              "https://meet.example.org",

        // DNS carrier labels
        .dnsLabelMts:                "MTS",
        .dnsLabelBeeline:            "Beeline",
        .dnsLabelMegafon:            "MegaFon",
        .dnsLabelTele2:              "Tele2",
        .dnsLabelYota:               "Yota",

        // SubscriptionFetcher
        .subDohFailed_fmt:           "DoH could not resolve %@",
        .subInvalidResponse_fmt:     "HTTP %d",
        .subNoAddress:               "DoH returned an empty address list",

        // #111: subscription import (olcrtc-sub:// links)
        .subImportTitle:             "Import subscription",
        .subImportConfirm_fmt:       "Add %d connection(s) from “%@”?",
        .subImportAddAction:         "Add",
        .subInvalidLink:             "Subscription link must look like olcrtc-sub://host/path",
        .subEmptyList:               "The subscription contains no valid connections",
        .subImportPastedSource:      "pasted list",

        // #363: surfaced subscription metadata
        .subMetaSource:              "Source",
        .subMetaServers:             "Servers",
        .subMetaRefresh:             "Refresh",
        .subMetaRefreshNever:        "Never",
        .subMetaRefreshInterval_fmt: "every %@",
        .subMetaUsed:                "Used",
        .subMetaAvailable:           "Available",
        .subMetaMultipleSources_fmt: "%d sources",   // #396

        // #364: batch "ping group"
        .pingGroupAction:            "Ping all",
        .pingGroupResult_fmt:        "📡 Pinged %@: %d ok, %d failed",

        // #346: VPS-card mini-stat labels (abbreviations; ru = en per operator)
        .vpsStatPing:                "Ping",
        .vpsStatDisk:                "Disk",
        .vpsStatRAM:                 "RAM",
        .vpsStatUp:                  "Up",
        .scanRestored_fmt:           "Restored: %@",

        // #337: screenshot-safe IP masking
        .maskIPsLabel:               "Hide IP addresses",
        .maskIPsFooter:              "Masks IP addresses on the Connections diagnostics and VPS cards for safe screenshots. Display-only — copy actions and stored values stay real. Logs are not masked.",

        // #328: active-carrier endpoints with one-tap copy
        .carrierEndpointsTitle:      "Carrier endpoints",
        .carrierEndpointsHint:       "Add these as DIRECT rules in your proxy app so its own traffic doesn't loop through olcrtc.",
        .carrierEndpointHost:        "Host",
        .carrierEndpointResolvedIPs: "Resolved IPs",
        .carrierEndpointResolving:   "Resolving…",
        .carrierEndpointUnresolved:  "Could not resolve",
        .carrierEndpointNoHost:      "This carrier's room ID isn't a host — nothing to exclude.",
        .carrierEndpointCopied_fmt:  "📋 Copied: %@",
        .carrierEndpointRefresh:     "Re-resolve",
        .carrierEndpointsCheckAction: "Check",
        .carrierEndpointsConnectHint: "Connect to a server to inspect its carrier endpoints.",
        .carrierEndpointsReadyHint:  "Endpoints to route DIRECT in your proxy app.",
        .carrierEndpointCopyAll:     "Copy host & IPs",

        // #359: accessibility for the hero connect toggle + icon toolbar buttons
        .a11yConnectToggle:          "Connect",
        .a11yConnectHintSelectFirst: "Select a connection first",
        .a11yStateConnected:         "Connected",
        .a11yStateConnecting:        "Connecting",
        .a11yStateDisconnected:      "Disconnected",

        // #360: in-app update checker (GitHub Releases)
        .updateCheckLabel:           "Check for updates",
        .updateCheckFooter:          "Once a day, checks GitHub Releases for a newer build and tells you how to sideload it. Anonymous — no account, no install id, no download is sent. Turn off to never contact GitHub.",
        .updateAvailableTitle_fmt:   "Update available — %@",
        .updateAvailableBody:        "A newer build is on GitHub. Open the release page or, if you sideload, tap your installer below to fetch the unsigned build.",
        .updateOpenReleasePage:      "Open release page",
        .updateInstallSideStore:     "Install with SideStore",
        .updateInstallLiveContainer: "Install with LiveContainer",
        .updateLater:                "Later",
    ]

    // MARK: Russian

    static let russian: [L10n: String] = [
        // Common
        .ok:                "OK",
        .cancel:            "Отмена",
        .save:              "Сохранить",
        .close:             "Закрыть",
        .done:              "Готово",
        .error:             "Ошибка",
        .edit:              "Изменить",
        .okPrompt:          "Готово",

        // Tabs
        .tabConnections:    "Подключения",
        .tabServers:        "Управление VPS",
        .tabLogs:           "Логи",
        .tabSettings:       "Настройки",
        .tabConfig:         "Конфиг",
        .configComingSoonTitle: "Скоро",
        .configComingSoonHint:  "Здесь появятся настройки маршрутизации — режимы «напрямую/через туннель» и правила по приложениям.",
        .autoDetectedContainer_fmt: "Обнаружен существующий контейнер: %@",

        // Routing
        .routingHeader:     "Маршрутизация",
        .routingAllTunnel:  "Всё через туннель",
        .routingAllDirect:  "Всё напрямую",
        .routingViaTunnel:  "через туннель",
        .routingDirect:     "напрямую",

        // Connection state
        .stateDisconnected: "Отключено",
        .stateConnecting:   "Подключение…",
        .stateConnected:    "Подключено",
        .stateConnectFailed: "Сбой подключения",
        .stateWaitingForNetwork: "Ожидание сети…",
        .stateErrorPrefix_fmt: "Ошибка: %@",

        // ConnectionsView
        .emptyNoConnections:         "Нет подключений",
        // #303 was: "Нажми + чтобы добавить подключение вручную. Если есть VPS — перейди во вкладку Управление VPS для автоматической установки."
        .emptyNoConnectionsHint:     "Нажми + чтобы добавить подключение вручную. Если есть VPS — перейди во вкладку Управление VPS для автоматической установки. Если olcrtc уже запущен на сервере, используй «Восстановить подключение».",
        .actionConnect:              "Подключить",
        .actionRetry:                "Повторить",
        .shareAction:                "Поделиться",
        .copyURIAction:              "Скопировать URI",
        .shareConnectionTitle:       "Поделиться подключением",
        .shareConnectionExplanation: "Отправь этот URI чтобы другой пользователь мог подключиться через твой сервер. Содержит carrier, room ID и ключ шифрования — SSH-данные сервера не включены.",
        .shareConnectionURIHeader:   "URI подключения",
        // #135: full-access (co-admin) share
        .shareFullAccessTitle:       "Поделиться полным доступом (SSH)",
        .shareFullAccessHeader:      "Полный доступ (SSH)",
        .shareFullAccessWarning:     "Эта ссылка содержит SSH-логин и пароль. Любой, у кого она есть, получит полный контроль над VPS — установка, перенастройка, перезагрузка и удаление. Делись только с тем, кому доверяешь администрирование сервера.",
        .shareFullAccessReveal:      "Показать ссылку полного доступа",
        .shareFullAccessCopy:        "Скопировать ссылку полного доступа",
        .shareFullAccessCopied_fmt:  "🔑 Ссылка полного доступа скопирована: %@",
        // #366
        .fullAccessImportTitle:      "Импортировать полный доступ?",
        .fullAccessImportBody_fmt:   "Эта ссылка даёт полный SSH-доступ к серверу «%@» — его адрес, логин и пароль будут сохранены на этом устройстве. Импортируйте только доверенные ссылки.",
        .fullAccessImportAddAction:  "Добавить полный доступ",
        .fullAccessImportInvalid:    "Недействительная ссылка полного доступа.",
        .primaryRoleMain:            "основной",
        .copiedURI_fmt:              "📋 URI скопирован: %@",

        // AddConnectionView
        .newConnectionTitle:         "Новое подключение",
        .editConnectionTitle:        "Редактирование",
        .nameField:                  "Метка",
        .namePlaceholder:            "Мой сервер",
        .groupField:                 "Группа",
        .groupDefault:               "Подключения",   // #344 was: "Основная"
        .importByURI:                "Импорт по ссылке",
        .scanQRAction:               "Сканировать QR",
        .pasteURIAction:             "Вставить URI",
        .importHint:                 "Нажми «Вставить», чтобы импортировать URI или подписку из буфера обмена, либо «Сканировать QR». Поля ниже заполнятся автоматически.", // #381 was: "Если у тебя есть URI с сервера — вставь сюда и нажми «Распознать». Поля ниже заполнятся автоматически." — кнопки «Сканировать QR» / «Вставить» (с #361 «Вставить» импортирует и подписки), кнопки «Распознать» нет.
        .clientIDFooter:             "Идентификатор устройства в комнате. «default» подходит для одного устройства. Используй уникальное значение если несколько устройств подключаются к одной комнате.",
        .keyPlaceholder:             "64-символьный hex-ключ",
        .roomIDLabel:                "Идентификатор комнаты",
        .vp8ParamsHeader:            "VP8 параметры",
        .socksAuthHeader:            "SOCKS5 авторизация",
        .socksAuthFooter:            "Логин и пароль для доступа к локальному SOCKS5-прокси. Нужно только если хочешь ограничить другие приложения от использования туннеля.",
        .socksUserLabel:             "Пользователь",
        .socksPassLabel:             "Пароль SOCKS",
        .socksUserPlaceholder:       "пусто = без auth",
        .vp8FpsLabel:                "FPS",
        .vp8BatchLabel:              "Batch size",
        .globalDefault_fmt:          "глобальный (%d)",
        .overrideHint:               "Переопределяют глобальные настройки только для этого подключения. «×» сбрасывает к глобальному.",
        // #365: параметры seichannel для соединения
        .seiParamsHeader:            "Параметры SEI",
        .seiFpsLabel:                "FPS",
        .seiBatchLabel:              "Размер пакета",
        .seiFragLabel:               "Размер фрагмента",
        .seiAckLabel:                "Таймаут ACK (мс)",
        .seiParamsHint:              "Настройки SEI-канала. Отправляются только при транспорте seichannel, но сохраняются в любом случае.",

        // ServersView
        .serversTitle:               "Список VPS",
        .emptyNoServers:             "Нет серверов",
        .emptyNoServersHint:         "Добавь VPS чтобы установить olcrtc прямо отсюда",
        .newServerTitle:             "Новый сервер",
        .editServerTitle:            "Изменить",
        .sshAccessHeader:            "Доступ по SSH",
        .hostField:                  "Хост",
        .portField:                  "Порт",
        .loginField:                 "Логин",
        .passwordField:              "Пароль",
        .actionInstall:              "Установить",
        .actionUninstall:            "Удалить контейнер с сервера",
        .actionUpdate:               "Обновить бинарник (git pull + rebuild)",
        .actionReboot:               "Reboot",
        .actionChangeRoomTransport:  "Изменить Room / Transport",
        .actionContainerLogs:        "Логи контейнера",   // #339 was: "Скачать логи контейнера"
        .actionDone:                 "Готово",
        .actionRemoveFromList:       "Удалить из списка",
        .removeHostConfirmTitle:     "Удалить %@?",
        .removeHostConfirmMessage:   "Сервер исчезнет из списка на этом устройстве. Контейнер на VPS НЕ затрагивается — если хочешь его вычистить, сначала нажми Uninstall. Пароль SSH удаляется из Keychain.",
        .uninstallConfirmTitle:      "Удалить контейнер?",
        .uninstallConfirmBody:       "Будет удалён только контейнер (запущенный процесс). Podman, образ golang (~300 МБ) и кеш Go-модулей остаются на сервере. Повторная установка займёт ~1–2 мин.",
        .deepUninstallConfirmBody:   "Удаляет контейнер, кеш Go (~300 МБ) и ключ шифрования. Podman и образ остаются.",
        .rebootConfirmTitle:         "Перезагрузить сервер?",
        .rebootConfirmBody:          "Будет выполнена перезагрузка всего VPS. Контейнер olcrtc запустится автоматически после того, как сервер поднимется.",
        .carrierTransportMatrix:     "Carrier × Transport",

        // #303: Recover connection from server
        .actionRecoverConnection:    "Восстановить подключение",
        .recoverConfirmTitle:        "Восстановить подключение с этого сервера?",
        .recoverConfirmBody:         "Считывает carrier, room, transport и ключ шифрования, уже развёрнутые на этом сервере (только чтение), и добавляет их как новое подключение здесь.",
        .recoverConfirmAction:       "Восстановить",
        .provisioningRecovering:     "Чтение конфигурации сервера…",
        .recoverResultSuccess_fmt:   "Восстановлено %@/%@ — подключение добавлено",
        .recoverErrorMissingYAML:    "Конфигурация сервера не найдена — не удалось прочитать развёрнутый server.yaml.",
        .recoverErrorMissingField_fmt: "В конфигурации сервера отсутствует поле «%@»",

        // #314: generate-new-key fallback (server.yaml unreadable/unparseable)
        .rotateKeyConfirmTitle:      "Конфигурация сервера нечитаема — создать новый ключ?",
        .rotateKeyConfirmBody:       "Развёрнутый server.yaml не удалось прочитать, поэтому восстановить существующее подключение нельзя. Будет создан новый ключ шифрования на сервере, конфигурация восстановлена, сервер перезапущен, а полученное подключение добавлено здесь. Внимание: все другие устройства, использующие этот сервер, потеряют доступ, пока не импортируют новое подключение.",
        .rotateKeyConfirmAction:     "Создать новый ключ",
        .provisioningRotatingKey:    "Создание нового ключа сервера…",
        .rotateKeyResultSuccess:     "Новый ключ шифрования активен",
        .rotateKeyResultAdded_fmt:   "Новый ключ создан — подключение %@/%@ добавлено",
        .rotateKeyFailedNoURI:       "Ротация ключа завершилась, но сервер не вывел URI — проверь журнал provisioning.",

        // Container status
        .containerRunning_fmt:       "Контейнер работает: %@",
        .containerStopped_fmt:       "Контейнер остановлен: %@",
        .containerNotFound:          "Контейнер не найден",
        .containerNotFoundShort:     "не найден",
        .containerNotInstalled:      "Контейнер ещё не установлен — нажми «Установить».",
        .readinessNoPodman:              "Готов к установке (Podman не найден, полная установка ~5–7 мин)",
        .readinessNoImage:               "Podman установлен — первый раз скачает образ (~300 МБ, ~3–5 мин)",
        .readinessImageReady:            "Образ в кеше — переустановка займёт ~1–2 мин",
        .readinessContainerStopped_fmt:  "Остановлен: %@",
        .readinessContainerRunning_fmt:  "Работает: %@",

        // VPS status card (#258/#261)
        .vpsTitleUnknown:         "Статус неизвестен",
        .vpsTitleReady:           "Готов к установке",
        .vpsTitlePodmanReady:     "Podman готов",
        .vpsTitleStopped:         "Остановлен",
        .vpsTitleRunning:         "Работает",
        .vpsSubUnknown:           "Нажмите «Проверить»",
        .vpsSubNoPodman:          "Полная установка ~5–7 мин",
        .vpsSubNoImage:           "Первая установка тянет образ (~300 МБ)",
        .vpsSubImageReady:        "Образ в кэше — быстрая переустановка",
        .vpsSubStopped:           "Контейнер есть, не запущен",
        .vpsSubRunning:           "Серверный процесс запущен — это не проверка подключения",
        .vpsVerbChecking:         "Проверка",
        .vpsVerbInstalling:       "Установка",
        .vpsVerbStarting:         "Запуск",
        .vpsVerbStopping:         "Остановка",
        .vpsVerbReconfiguring:    "Переконфигурация",
        .vpsVerbUpdating:         "Обновление",
        .vpsVerbUninstalling:     "Удаление",
        .vpsVerbDeepUninstalling: "Полное удаление",
        .vpsVerbRebooting:        "Перезагрузка",
        .vpsConnecting:           "Подключение…",
        .vpsCheckServer:          "Проверить сервер",
        .vpsWorking:              "Выполняется…",
        .vpsOpFailed_fmt:         "Сбой: %@",

        // ContainerLogsView
        // #339 was: emptyLogsTitle + emptyLogsHint_fmt (ContainerLogsView sheet, deleted)
        .closeAction:                "Закрыть",

        // LogsView
        .logsTitle:                  "Логи",
        .logsSearchPlaceholder:      "Поиск",
        .emptyLogsGeneric:           "Пусто",
        // #316 was: "…во вкладке Connections или VPS" — вкладка называется "Управление VPS".
        .emptyLogsGenericHint:       "Запусти операцию во вкладке Connections или Управление VPS",
        .noSearchResults:            "Ничего не найдено",
        .noSearchResultsHint_fmt:    "По запросу «%@» совпадений нет.",
        .categoryConnection:         "Подключение",
        .categoryDiagnostics:        "Диагностика",
        .categoryProvisioning:       "VPS",
        .categoryContainerLogs:      "Контейнер",

        // #294: per-source Logs tabs
        // #316 was: lowercase fragments (под заголовком таба) — теперь
        // открывают подсказку пустого состояния, читаются как предложения.
        .logsTabDescConnection:      "Логи подключения",
        .logsTabDescDiagnostics:     "Логи проверки IP и скорости",
        .logsTabDescVPS:             "Логи установки VPS",
        .logsTabDescContainer:       "Логи контейнера сервера",
        .logsFileNameLabel_fmt:      "Файл: %@",
        .logsContainerSelectServer:  "Сервер",
        .logsContainerNoServers:     "Нет настроенных серверов",

        // #295: per-server container log files
        .duplicateServerNameError:   "Сервер с таким именем уже существует",

        // #296: Container tab always-present load button
        // #338 was: logsDownloadFromServer ("Загрузить логи с сервера")
        .logsCheckServer:            "Проверить сервер",
        .logsContainerEmptyHint:     "Логи нужно загрузить с сервера.",
        // #316: single-stack Logs tab — короткие подписи сегментов + счётчик строк
        .logsSegConnection:          "Подкл",
        .logsSegDiagnostics:         "Диаг",
        .logsSegVPS:                 "VPS",
        .logsSegContainer:           "Контейнер",
        .logsLineCount_fmt:          "%d стр.",
        .logsPeerCount_fmt:          "👥 %d участн.",
        // #338: inline container fetch — карточка источника + фазы
        .logsFetchAction:            "Загрузить",
        .logsFetchFromHost_fmt:      "Загрузить с %@",
        .logsPhaseConnecting:        "Подключение…",
        // deliberately English — a literal command line, not translated
        .logsPhaseCommand_fmt:       "podman logs --tail %d %@",
        .logsPhaseReceiving:         "Получение вывода…",
        // #332: rendered-line cap notice
        .logsRenderTruncated_fmt:    "Показаны последние %d строк — «Поделиться» или «Копировать всё» выгружает полную историю.",

        // SettingsView
        .settingsTitle:              "Настройки",
        .sectionSOCKS5:              "SOCKS5",
        .sectionDNS:                 "DNS",
        .sectionVP8:                 "vp8channel",
        .sectionConnection:          "Подключение",
        .sectionLogs:                "Логи",
        .sectionIPSources:           "Источники проверки IP",
        .ipSourcesFooter:            "Сервисы, опрашиваемые при проверке IP. Варианты из ru-зоны остаются доступны, когда публичные резолверы заблокированы. Если ничего не выбрано, используются значения по умолчанию.",
        .sectionSpeedProvider:       "Провайдер спидтеста",
        .speedProviderFooter:        "Сервер, против которого идёт тест скорости. Смените, если Cloudflare медленный или заблокирован в вашей сети.",
        .speedAllFailed:             "Все измерения не удались",
        .speedDatachannelHint:       "Подсказка: видео-транспорты (vp8channel/sei/video) жертвуют скоростью ради вида видеозвонка. Для большей скорости смените транспорт сервера на datachannel там, где это позволяет сеть.",
        .settingsPortLabel:          "Порт",
        .checkPortAction:            "Проверить порт",
        .randomPortAction:           "Случайный",
        .portFree:                   "свободен",
        .portBusy:                   "занят",
        .logPortFree_fmt:            "✓ Порт %d свободен",
        .logPortBusyOther_fmt:       "✗ Порт %d занят",
        .logPortBusyOlcrtc_fmt:      "✓ Порт %d занят туннелем olcrtc",
        .socksPortChangeNote:        "Изменение порта применится при следующем подключении.",
        .dnsFreeFormPlaceholder:     "IP:port",
        .dnsFooter:                  "Передаётся в Go-рантайм и в скрипт установки сервера. Формат: IP:port. Пресеты RU-операторов резолвят только внутри сети соответствующего оператора.",
        .vp8Footer:                  "MobileSetVP8Options применяется только если transport=vp8channel. Для wbstream это дефолтный канал. Значения по умолчанию (60/64) — для Telemost.",
        .startTimeoutLabel:          "Таймаут готовности",
        .autoConnectOnLaunchLabel:   "Авто-подключение при запуске",
        .autoRemoveConnectionOnUninstallLabel: "Удалять связанное соединение при удалении VPS",
        .tunnelCheckLabel:           "Проверка туннеля",
        .keepAliveOff:               "выкл",
        .backgroundAudioLabel:       "Фоновая работа (audio)",
        .localSocksAuthLabel:        "Требовать аутентификацию прокси",
        .logLevelLabel:              "Уровень логирования",
        .footerKeepAlive:            "Раз в N секунд делает end-to-end запрос через SOCKS5. При неудаче туннель переподключается. 0 — отключить.",
        .footerLogBuffer:            "Максимальное количество строк в памяти для каждой категории логов.",
        .logBufferLabel:             "Буфер логов",
        .containerLogsTailLabel:     "Логи контейнера (tail)",
        .clearAllLogsAction:         "Очистить все логи",
        .copyAllAction:              "Копировать всё",
        .clearCategoryAction:        "Очистить категорию",
        .fontSizeLabel:              "Размер шрифта",
        .fontPreviewText:            "Превью текста — так будут выглядеть подписи и заголовки в приложении.",
        .fontFooter:                 "Применяется ко всему приложению (через SwiftUI dynamicTypeSize). Меньше = плотнее, больше = удобнее читать.",
        .languageLabel:              "Язык",
        .themeLabel:                 "Тема",

        // #340/#299: переключатель оформления (Системное / Светлое / Тёмное / Серое)
        .appearanceLabel:            "Оформление",
        .appearanceSystem:           "Системное",
        .appearanceLight:            "Светлое",
        .appearanceDark:             "Тёмное",
        .appearanceGray:             "Серая",
        // #342: подсказка в подвале hero-карточки
        .heroDisconnectedHint_fmt:   "Переведи переключатель, чтобы подключиться через %@.",

        // InstallOptionsView
        .installTitle:               "Установка olcrtc",
        .reconfigureTitle:           "Изменить Room / Transport",
        .reconfigureInfoFooter:      "Контейнер будет перезапущен с новыми флагами -carrier/-id/-transport. Переустановка не нужна (apt-get / go build не запускаются).",
        .parametersHeader:           "Параметры",
        .roomIDAutoGenHint:          "Room ID будет сгенерирован сервером.",
        .roomIDTelemostHint:         "Создай встречу на telemost.yandex.ru и вставь ID (часть после /j/ в ссылке).",
        .roomIDWbstreamHint:         "Создай комнату на stream.wb.ru под своей учёткой и вставь её ID.",
        .matrixRecommended_fmt:      "★ Рекомендуется для %@.",
        .matrixWorks_fmt:            "Работает с %@.",
        .matrixQuestion_fmt:         "⚠ Работа с %@ под вопросом.",
        .matrixFail_fmt:             "✗ Не работает с %@ — выбери другой транспорт.",
        .matrixUnknown_fmt:          "Нет данных о совместимости с %@.",
        .carrierFooter:          "client-id=ios-<случайный> (генерируется) · key=hex64 (генерируется) · DNS и VP8 из настроек",
        .matrixStatusRecommended:    "рекомендуется",
        .matrixStatusOK:             "работает",
        .matrixStatusQuestion:       "под вопросом",
        .matrixStatusFail:           "не работает",
        .matrixStatusUnknown:        "нет данных",
        .transportSectionHeader:     "Транспорт",
        .roomIDSectionHeader:        "Room ID",
        .jitsiServerHeader:          "Сервер Jitsi",
        .jitsiServerFooter:          "Общий публичный сервер — укажите свой Jitsi для надёжности, чтобы не перегружать чужой.",
        .seiSettingsHeader:          "SEI-настройки",
        .seiSettingsFooter:          "SEI-параметры передаются в srv.sh для seichannel.",
        .actionQR:                   "QR",

        // Status banner

        // TunnelManager log lines
        .mobileStartOK:              "✓ MobileStart OK, ожидаем WaitReady…",
        .mobileStartFailed_fmt:      "✗ MobileStart: %@",
        .bgKeeperFailed_fmt:         "⚠ Фоновый audio-keeper не запустился: %@ — приложение может быть остановлено в фоне",
        .transportUsesServerDefaults_fmt: "Будут использованы серверные дефолты для %@ — расширенные параметры пока не вынесены в настройки iOS.",
        .waitReadyFailed_fmt:        "✗ WaitReady: %@",
        .connectNoPeer:              "Пир не присоединился вовремя — проверьте, что ключ совпадает с сервером, верна комната, или смените carrier/transport.",
        .waitReadyOK:                "✓ WaitReady OK — SOCKS5 слушает, проверяем туннель…",
        .tunnelOK:                   "✓ Туннель работает — данные идут через сервер",
        .tunnelFailed:               "✗ Туннель не отвечает (сервер недоступен или 403 Forbidden IP)",
        .keepAliveOK:                "♡ Keep-alive OK",
        .keepAliveLost:              "✗ Keep-alive: туннель не отвечает",
        .serverConnectionLost:       "Связь с сервером видеосвязи потеряна",
        .serverNotResponding:        "Сервер видеосвязи не отвечает",
        .disconnectingArrow:         "→ Отключение",
        .netPathLost:                "⚠ Сеть потеряна — ожидание подключения",
        .waitingForPortRelease:      "⏳ Ожидание освобождения порта…",
        .netPathRestored:            "сеть восстановлена",
        .netPathChanged:             "сеть изменилась",
        .reconnecting_fmt:           "↻ Переподключение (%@)",
        .reconnectAttempt_fmt:       "↻ попытка %d/%d через %d с",
        .reconnectGaveUp:            "✗ Не удалось переподключиться — нажмите «Повторить»",
        .rejoinSettle_fmt:           "⏳ Очистка комнаты: %.1f с до повторного входа",
        .connectingOlcrtc_fmt:       "→ olcrtc carrier=%@ transport=%@ clientID=%@",

        // TunnelManager errors
        .validateClientIDEmpty:      "Client ID не может быть пустым",
        .validateClientIDWhitespace: "Client ID не должен содержать пробелы",
        .validateKeyLength_fmt:      "Ключ должен быть 64 hex-символа (получено: %d)",
        .validateKeyNonHex:          "Ключ содержит не-hex символы",
        .validateRoomIDEmpty:        "Room ID не может быть пустым",
        .errorPortBusy_fmt:          "Порт %d занят — освободите его или смените порт в Настройках",
        .errorSecretsLocked:         "Разблокируйте устройство и снова откройте приложение, чтобы загрузить сохранённый ключ.",

        // OlcrtcURI errors
        .uriErrorInvalidScheme:      "URI должен начинаться с olcrtc://",
        .uriErrorMissingField_fmt:   "Не найдено поле: %@",
        .uriErrorMixedBrackets:      "Скобки полезной нагрузки URI не совпадают (ожидается [...] или <...>)",

        // Provisioning
        .provisioningSSHConnecting:  "Подключение по SSH…",
        .provisioningRebootSSH:      "Reboot: подключение по SSH…",
        .provisioningUninstallSSH:   "Удаление: подключение по SSH…",
        .provisioningRebooting:      "Перезагрузка…",
        .provisioningUninstalling:   "Удаление контейнера и файлов…",
        .provisioningUpdating:       "Обновление бинарника…",
        .provisioningReconfiguring:  "Изменение параметров контейнера…",
        .provisioningStatusFetching: "Статус контейнера…",
        .provisioningLogsFetching:   "Логи контейнера…",
        .installStep1Upload:         "[1/3] Загружаем скрипт…",
        .installStep2Launch:         "[2/3] Запускаем скрипт установки…",
        .installStep3PollRetry_fmt:  "[3/3] Сервер временно недоступен, повтор (%d)…",
        .installPhaseWaiting:        "Ожидание…",
        .installPhaseSystemDeps:     "Установка системных пакетов…",
        .installPhaseClone:          "Клонирование репозитория…",
        .installPhasePullImage:      "Загрузка образа Go…",
        .installPhaseDeps:           "Загрузка Go-модулей…",
        .installPhaseBuild:          "Сборка olcrtc…",
        .installPhaseStart:          "Запуск olcrtc…",
        .installFailedNoURI_fmt:     "Скрипт завершился без URI. Последние строки:\n%@",
        .installTimeout25min:        "Таймаут установки (25 минут)",
        .installResultSuccess_fmt:   "Сервер olcrtc установлен (%@/%@)",
        .uninstallResultSuccess:     "Сервер очищен",
        .updateResultSuccess:        "Бинарник обновлён",
        .provisioningStarting:       "Запускаем сервер…",
        .startResultSuccess:         "Сервер запущен",
        .actionStart:                "Запустить сервер",
        .provisioningStopping:       "Останавливаем сервер…",
        .stopResultSuccess:          "Сервер остановлен",
        .actionStop:                 "Остановить сервер",
        .scanningContainers:         "Сканируем VPS на наличие olcrtc…",
        .actionScanVPS:              "Найти установленный olcrtc",
        .scanNoContainers:           "На сервере не найдено olcrtc-контейнеров.",
        .scanRestoreAction:          "Восстановить",
        .actionDeepUninstall:        "Удалить весь olcrtc с сервера",
        .deepUninstallResultSuccess:          "Все данные olcrtc удалены",
        .reconfigureResultSuccess_fmt: "Параметры изменены (%@/%@)",
        .rebootResultSuccess:        "Команда reboot отправлена",
        .logsBytesReceived_fmt:      "Логи получены (%d байт)",
        .provisionPasswordMissing:   "Пароль не найден в Keychain",
        .provisionSSHPrefix_fmt:     "SSH: %@",
        .provisionCommandPrefix_fmt: "Команда: %@",
        .provisionParsePrefix_fmt:   "Не удалось разобрать вывод: %@",
        .sshAttemptFailed_fmt:       "✗ SSH attempt %d/2 failed: %@",
        .sshRetryIn4s:               "  повтор через 4 с…",
        .sshPortNotResponding_fmt:   "Порт %d на %@ не ответил — проверь что SSH открыт и VPS доступен",
        .serverUnreachable_fmt:      "Сервер %@ не отвечает — проверь что VPS включён и SSH-порт открыт",

        // NetPing
        .pingTCPOK_fmt:              "TCP/%d отвечает за %@ ms",
        .pingTCPFail_fmt:            "TCP/%d недоступен",

        // ConnectionsView per-connection ping (#234)
        .pingNoFreePort:             "Нет свободного локального порта для пинга",
        .pingFailed:                 "Пинг не удался",
        .healthCheckAction:          "Проверка соединения",
        .healthResult_fmt:           "🩺 Соединение %@ — готовность %@ · RTT %@",
        .healthResultRTT_fmt:        "🩺 Соединение %@ — RTT %@",

        // ServersView alerts
        .alertPasswordMissingShort:  "Пароль не найден",

        // AddServerHostView
        .nameSettingLabel:           "Название",
        .sectionDescription:         "Описание",
        .testSSHAction:              "Тест SSH",

        // ConnectionsView misc
        .diagnosticsTitle:           "Диагностика",
        .ipCheckTitle:               "IP проверка",
        .ipCheckRun:                 "Проверить IP",
        .speedTestRun:               "Запустить тест",

        // #311 — speed-tile metric labels/units + upload-fallback log line (ru = en, see L10n.swift)
        .speedLabelPing:             "Ping",
        .speedLabelDL:               "DL",
        .speedLabelUL:               "UL",
        // #342 was: "%.0f ms" / "%.1f Mbps" — unit moved to OlcMetric(unit:)
        .speedPingValue_fmt:         "%.0f",
        .speedRateValue_fmt:         "%.1f",
        .speedUnitMs:                "ms",
        .speedUnitMbps:              "Mbps",
        .speedUploadFallback_fmt:    "  upload: %@ has no upload endpoint — using %@",

        // #236/#237 — UI strings localized after the i18n pass
        .ipChecking:                 "Проверка…",
        .ipNotChecked:               "Ещё не проверялось",
        .ipDnsLeak:                  "IP различаются — возможна утечка DNS",
        .ipSourcesAgree_fmt:         "✓ %@ (источников: %d)",
        .socksProxyAddr_fmt:         "SOCKS5-прокси: 127.0.0.1:%@",
        .portInUseByOlcrtc:          "занят туннелем olcrtc",
        .roomPrefix_fmt:             "комната: %@",
        .qrCodeURIA11y:              "QR-код URI подключения",
        .qrCodeHintA11y:             "Отсканируйте этот код, чтобы импортировать подключение на другом устройстве",
        .cameraUnavailableTitle:     "Камера недоступна",
        .cameraUnavailableBody:      "Для сканирования QR нужно физическое устройство с камерой.",
        .sectionCarrier:             "Оператор",
        .labelTransport:             "Транспорт",
        .carrierTelemost:            "Телемост",
        .carrierWbstream:            "WB Stream",
        .carrierJitsi:               "Jitsi",
        .transportDatachannel:       "DataChannel",
        .transportVp8channel:        "VP8",
        .transportSeichannel:        "SEI",
        .transportVideochannel:      "Видео",
        .fieldRoomID:                "ID комнаты",
        .fieldJitsiURL:              "https://meet.example.org",

        // DNS carrier labels
        .dnsLabelMts:                "МТС",
        .dnsLabelBeeline:            "Билайн",
        .dnsLabelMegafon:            "МегаФон",
        .dnsLabelTele2:              "Tele2",
        .dnsLabelYota:               "Yota",

        // SubscriptionFetcher
        .subDohFailed_fmt:           "DoH не смог разрешить %@",
        .subInvalidResponse_fmt:     "HTTP %d",
        .subNoAddress:               "DoH вернул пустой список адресов",

        // #111: subscription import (olcrtc-sub:// links)
        .subImportTitle:             "Импорт подписки",
        .subImportConfirm_fmt:       "Добавить соединений: %d (из «%@»)?",
        .subImportAddAction:         "Добавить",
        .subInvalidLink:             "Ссылка подписки должна иметь вид olcrtc-sub://host/path",
        .subEmptyList:               "Подписка не содержит действительных соединений",
        .subImportPastedSource:      "вставленный список",

        // #363: отображение метаданных подписки
        .subMetaSource:              "Источник",
        .subMetaServers:             "Серверы",
        .subMetaRefresh:             "Обновление",
        .subMetaRefreshNever:        "Никогда",
        .subMetaRefreshInterval_fmt: "каждые %@",
        .subMetaUsed:                "Использовано",
        .subMetaAvailable:           "Доступно",
        .subMetaMultipleSources_fmt: "%d источников",   // #396

        // #364: групповой пинг
        .pingGroupAction:            "Пинговать все",
        .pingGroupResult_fmt:        "📡 Пинг %@: %d ок, %d неудач",

        // #346: подписи мини-статистики карточки VPS (аббревиатуры; ru = en по решению оператора)
        .vpsStatPing:                "Ping",
        .vpsStatDisk:                "Disk",
        .vpsStatRAM:                 "RAM",
        .vpsStatUp:                  "Up",
        .scanRestored_fmt:           "Восстановлено: %@",

        // #337: безопасный для скриншотов режим — скрытие IP
        .maskIPsLabel:               "Скрывать IP-адреса",
        .maskIPsFooter:              "Скрывает IP-адреса в диагностике на вкладке «Соединения» и на карточках VPS для безопасных скриншотов. Только отображение — копирование и сохранённые значения остаются настоящими. Логи не скрываются.",

        // #328: конечные точки активного оператора с копированием в один тап
        .carrierEndpointsTitle:      "Точки оператора",
        .carrierEndpointsHint:       "Добавь их как DIRECT-правила в прокси-приложении, чтобы его собственный трафик не зациклился через olcrtc.",
        .carrierEndpointHost:        "Хост",
        .carrierEndpointResolvedIPs: "Найденные IP",
        .carrierEndpointResolving:   "Разрешение…",
        .carrierEndpointUnresolved:  "Не удалось разрешить",
        .carrierEndpointNoHost:      "ID комнаты этого оператора не является хостом — исключать нечего.",
        .carrierEndpointCopied_fmt:  "📋 Скопировано: %@",
        .carrierEndpointRefresh:     "Разрешить заново",
        .carrierEndpointsCheckAction: "Проверить",
        .carrierEndpointsConnectHint: "Подключись к серверу, чтобы посмотреть точки оператора.",
        .carrierEndpointsReadyHint:  "Точки для DIRECT-правил в прокси-приложении.",
        .carrierEndpointCopyAll:     "Скопировать хост и IP",

        // #359: доступность переключателя подключения и кнопок-иконок в тулбаре
        .a11yConnectToggle:          "Подключиться",
        .a11yConnectHintSelectFirst: "Сначала выбери соединение",
        .a11yStateConnected:         "Подключено",
        .a11yStateConnecting:        "Подключение",
        .a11yStateDisconnected:      "Отключено",

        // #360: проверка обновлений (GitHub Releases)
        .updateCheckLabel:           "Проверять обновления",
        .updateCheckFooter:          "Раз в сутки проверяет в GitHub Releases новую сборку и подсказывает, как её установить через сайдлоад. Анонимно — без аккаунта, без идентификатора установки, ничего не отправляется. Отключи, чтобы вообще не обращаться к GitHub.",
        .updateAvailableTitle_fmt:   "Доступно обновление — %@",
        .updateAvailableBody:        "В GitHub есть более новая сборка. Открой страницу релиза или, если ставишь через сайдлоад, нажми кнопку своего установщика ниже, чтобы скачать неподписанную сборку.",
        .updateOpenReleasePage:      "Открыть страницу релиза",
        .updateInstallSideStore:     "Установить через SideStore",
        .updateInstallLiveContainer: "Установить через LiveContainer",
        .updateLater:                "Позже",
    ]
}
