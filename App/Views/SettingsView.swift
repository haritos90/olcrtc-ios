import SwiftUI

// MARK: - SettingsView
//
// Fourth tab. Surfaces values that used to be hardcoded:
//   - SOCKS5 listener port (with a "check port" button that probes binding)
//   - DNS server passed to the Go runtime
//   - vp8channel codec tuning (FPS + batch size)
//   - Connection start timeout
//   - Debug logging toggle
//   - Logs view font size
//
// Reads/writes go through SettingsStore.shared, which mirrors UserDefaults.
// SwiftUI rebinds on @Published changes automatically.

struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    // #300: live tunnel state, needed to tell "port busy because our tunnel
    // reserved it" apart from "port busy because something else holds it" —
    // the old check compared configured ports only, so it reported "in use
    // by tunnel" even while disconnected. #313: the gate now reads
    // `tunnel.boundPort` — the port the session actually bound — so a live
    // port edit in Settings can't mislabel the check either.
    @ObservedObject var tunnel: TunnelManager
    /// #420: bot registry (shared with Manage VPS). Managed in `BotsSettingsView`.
    @ObservedObject var botStore: BotStore

    @State private var portCheck: PortAvailability.PortState?
    @State private var socksPassInput: String = ""
    @State private var socksPassLoaded = false
    @FocusState private var anyFieldFocused: Bool

    /// #280: live slider position while dragging the font size. Non-nil only
    /// during a drag; the committed value lands in `settings.fontSizeIndex` on
    /// release, so the whole app re-lays out once instead of on every tick.
    @State private var fontDragIndex: Double?

    private var fontLiveIndex: Int {
        let raw = Int((fontDragIndex ?? Double(settings.fontSizeIndex)).rounded())
        return max(0, min(SettingsStore.fontSizes.count - 1, raw))
    }

    /// #298: scroll anchor for the Font control. Committing the font size relayouts
    /// the whole app (dynamic type), moving the viewport — we scroll back here to
    /// keep the control in place.
    private static let fontAnchorID = "settingsFontAnchor"

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                // #343: regrouped per design_handoff_logs_theme §7 — SOCKS5 →
                // DNS (submenu) → vp8channel → Connection → Diagnostics →
                // Logs → Appearance LAST → version footer; max one short
                // footer per section.
                Form {
                    socksSection
                    dnsRowSection
                    transportSection
                    connectionSection
                    botsSection
                    diagnosticsSection
                    logsSection
                    appearanceSection
                    infoSection
                }
                .onDisappear { socksPassLoaded = false }
                .navigationTitle(L10n.settingsTitle.localized())
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button(L10n.done.localized()) { anyFieldFocused = false }
                    }
                }
                // #298: committing the font size triggers the app-wide dynamic-type
                // relayout, which shifted the Settings viewport (it jumped). Pull the
                // Font control back into view so the scroll position stays stable.
                .onChange(of: settings.fontSizeIndex) { _, _ in
                    DispatchQueue.main.async {
                        withAnimation { proxy.scrollTo(Self.fontAnchorID, anchor: .center) }
                    }
                }
            }
        }
    }

    // MARK: SOCKS

    // #343 was: two sections (port+check / auth) with three stacked footers —
    // one section now, one short footer (the long socksFooter/auth copy cut
    // per the handoff's one-footer rule).
    @ViewBuilder
    private var socksSection: some View {
        Section {
            HStack {
                Text(L10n.settingsPortLabel.localized())
                Spacer()
                TextField("8808", value: $settings.socksPort, format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numberPad)
                    .focused($anyFieldFocused)
                    .frame(width: 90)
                Button(L10n.randomPortAction.localized()) {
                    settings.socksPort = Int.random(in: 1024...65535)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button {
                let port = UInt16(settings.socksPort)
                // #313: compare against the port the tunnel actually bound
                // (`tunnel.boundPort`, snapshotted at connect; nil unless a
                // session is live). The #300 gate compared two reads of the
                // *configured* port — always equal — so while connected, any
                // value typed into the field was labeled "in use by olcrtc
                // tunnel" even though the tunnel still holds the old port.
                // #313 was: let tunnelHoldsPort = tunnel.state.isConnected
                //     && TunnelManager.socksPort == settings.socksPort
                let tunnelHoldsPort = tunnel.boundPort == settings.socksPort
                let result = PortAvailability.state(port, tunnelHoldsPort: tunnelHoldsPort)
                portCheck = result
                // #287: one L10n key per concept instead of assembling the line
                // from fragments (which drifted between code paths / languages).
                // #300: three states → three log lines.
                let logLine: String
                switch result {
                case .free:      logLine = L10n.logPortFree_fmt.formatted(settings.socksPort)
                case .busyOther: logLine = L10n.logPortBusyOther_fmt.formatted(settings.socksPort)
                case .busyOurs:  logLine = L10n.logPortBusyOlcrtc_fmt.formatted(settings.socksPort)
                }
                LogStore.shared.log(.connection, logLine)
            } label: {
                HStack {
                    Image(systemName: "checkmark.circle")
                    Text(L10n.checkPortAction.localized())
                    Spacer()
                    if let r = portCheck {
                        switch r {
                        // #317: ad-hoc .green/.red → Theme.Palette status tokens (#258 invariant)
                        // #317 was: .foregroundStyle(.green) / .foregroundStyle(.red)
                        case .free:      Text(L10n.portFree.localized()).foregroundStyle(Theme.Palette.green)
                        case .busyOurs:  Text(L10n.portInUseByOlcrtc.localized()).foregroundStyle(Theme.Palette.green)
                        case .busyOther: Text(L10n.portBusy.localized()).foregroundStyle(Theme.Palette.red)
                        }
                    }
                }
            }

            Toggle(L10n.localSocksAuthLabel.localized(), isOn: $settings.localSocksAuthEnabled)
            if settings.localSocksAuthEnabled {
                TextField(L10n.socksUserLabel.localized(), text: $settings.localSocksUser)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField(L10n.socksPassLabel.localized(), text: $socksPassInput)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onAppear {
                        if !socksPassLoaded {
                            socksPassInput = settings.localSocksPass
                            socksPassLoaded = true
                        }
                    }
                    .onChange(of: socksPassInput) { _, v in
                        settings.localSocksPass = v
                    }
            }
        } header: {
            Text(L10n.sectionSOCKS5.localized())
        } footer: {
            Text(L10n.socksPortChangeNote.localized())
                .font(.caption2)
        }
    }

    // MARK: DNS (#343 — submenu)

    // #343 was: dnsSection — a top-level OlcChipPicker "chip wall" over all
    // presets + the free-form field (the MegaFon/Yota shared value also made
    // duplicate ForEach IDs there). Now a summary NavigationLink row; the
    // presets/footer live in DNSSettingsView, same pattern as the IP sources.
    private var dnsRowSection: some View {
        Section {
            NavigationLink {
                DNSSettingsView()
            } label: {
                HStack {
                    Text(L10n.sectionDNS.localized())
                    Spacer()
                    Text(dnsSummary)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    /// "Yandex · 77.88.8.8:53" when the value matches a preset, else the raw value.
    private var dnsSummary: String {
        let v = settings.dnsServer
        let presets: [(String, String)] = AppConstants.dnsPresets.map { ($0.label, $0.value) }
            + AppConstants.ruCarrierDnsPresets.map { ($0.label.localized(), $0.value) }
        if let hit = presets.first(where: { $0.1 == v }) { return "\(hit.0) · \(v)" }
        return v
    }

    // MARK: Numeric field helper
    //
    // Replaces Stepper. TextField for direct entry + quick-pick row for typical
    // values. Out-of-range entries are auto-clamped by SettingsStore.didSet.

    /// A labelled quick-pick value for the log buffer size stepper row.
    private struct Preset { let value: Int; let label: String }

    @ViewBuilder
    private func numericField(_ title: String,
                               value: Binding<Int>,
                               presets: [Preset],
                               unit: String? = nil) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", value: value, format: .number.grouping(.never))
                .multilineTextAlignment(.trailing)
                .keyboardType(.numberPad)
                .monospacedDigit()
                .focused($anyFieldFocused)
                .frame(width: 80)
            if let unit { Text(unit).foregroundStyle(.secondary) }
        }
        // #258: design-system chip picker (was a row of .mini bordered buttons).
        OlcChipPicker(selection: value, options: presets.map { ($0.value, $0.label) })
    }

    // MARK: Transport tuning

    private var transportSection: some View {
        Section {
            numericField(L10n.vp8FpsLabel.localized(), value: $settings.vp8FPS,
                         presets: [Preset(value: 15, label: "15"),
                                   Preset(value: 30, label: "30"),
                                   Preset(value: 60, label: "60")])
            numericField(L10n.vp8BatchLabel.localized(), value: $settings.vp8BatchSize,
                         presets: [Preset(value: 1,  label: "1"),
                                   Preset(value: 8,  label: "8"),
                                   Preset(value: 64, label: "64")])
        } header: {
            Text(L10n.sectionVP8.localized())
        } footer: {
            Text(L10n.vp8Footer.localized())
                .font(.caption2)
        }
    }

    // MARK: Connection

    // #343 was: six separate sections (start timeout / auto-connect /
    // auto-remove / keep-alive / background audio / log level), each with its
    // own footer — one "Connection" section now, one short footer (keep-alive
    // is the least self-explanatory row, its footer survives).
    private var connectionSection: some View {
        Section {
            numericField(L10n.startTimeoutLabel.localized(), value: $settings.startTimeoutSeconds,
                         presets: [Preset(value: 30,  label: "30"),
                                   Preset(value: 60,  label: "60"),
                                   Preset(value: 120, label: "120")],
                         unit: "s")
            Toggle(L10n.autoConnectOnLaunchLabel.localized(), isOn: $settings.autoConnectOnLaunch)
            Toggle(L10n.autoRemoveConnectionOnUninstallLabel.localized(), isOn: $settings.autoRemoveConnectionOnUninstall)
            numericField(L10n.tunnelCheckLabel.localized(), value: $settings.keepAliveSeconds,
                         presets: [Preset(value: 0,  label: L10n.keepAliveOff.localized()),
                                   Preset(value: 30, label: "30"),
                                   Preset(value: 60, label: "60")],
                         unit: "s")
            Toggle(L10n.backgroundAudioLabel.localized(), isOn: $settings.backgroundAudio)
            // #360: opt-out of the daily, anonymous GitHub-Releases update
            // check. Self-explanatory label keeps the §7 one-footer rule (the
            // keep-alive footer survives); the full privacy note lives in the
            // L10n table (updateCheckFooter) for any future detail screen.
            Toggle(L10n.updateCheckLabel.localized(), isOn: $settings.updateCheckEnabled)
            Picker(L10n.logLevelLabel.localized(), selection: $settings.logLevel) {
                ForEach(LogLevel.allCases, id: \.self) { level in
                    Text(level.label).tag(level)
                }
            }
        } header: {
            Text(L10n.sectionConnection.localized())
        } footer: {
            Text(L10n.footerKeepAlive.localized()).font(.caption2)
        }
    }

    // MARK: Bots (#420)

    private var botsSection: some View {
        Section {
            NavigationLink {
                BotsSettingsView(botStore: botStore)
            } label: {
                HStack {
                    Text(L10n.sectionBots.localized())
                    Spacer()
                    Text("\(botStore.bots.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    // MARK: Logs

    // #343 was: three sections (buffer / container tail / clear-all) with two
    // footers — one "Logs" section, one short footer.
    private var logsSection: some View {
        Section {
            numericField(L10n.logBufferLabel.localized(), value: $settings.logBufferSize,
                         presets: [Preset(value: 500,  label: "500"),
                                   Preset(value: 1000, label: "1k"),
                                   Preset(value: 5000, label: "5k")])
            numericField(L10n.containerLogsTailLabel.localized(), value: $settings.containerLogsTailLines,
                         presets: [Preset(value: 100,  label: "100"),
                                   Preset(value: 200,  label: "200"),
                                   Preset(value: 1000, label: "1k")])
            // #258: danger design-system button (was a plain destructive row).
            OlcButton(L10n.clearAllLogsAction.localized(), systemImage: "trash",
                      role: .danger, fillWidth: true) {
                LogStore.shared.clearAll()
            }
        } header: {
            Text(L10n.sectionLogs.localized())
        } footer: {
            Text(L10n.footerLogBuffer.localized()).font(.caption2)
        }
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        Section {
            Picker(L10n.languageLabel.localized(),
                   selection: Binding(
                    get: { AppLocale(rawValue: settings.language) ?? .english },
                    set: { settings.language = $0.rawValue }
                   )) {
                ForEach(AppLocale.allCases) { locale in
                    Text(locale.displayName).tag(locale)
                }
            }

            // #340: appearance scheme — System / Light / Dark (applied via
            // preferredColorScheme in App.swift). #343: relabeled "Theme" —
            // the section header carries "Appearance" now. #299: + Gray, a real
            // fourth colour scheme (the picker iterates allCases, so it appears
            // automatically); the Refined/Console "Direction" picker was removed.
            Picker(L10n.themeLabel.localized(), selection: $settings.appearanceMode) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            HStack {
                Text(L10n.fontSizeLabel.localized())
                Spacer()
                Text(SettingsStore.fontSizeLabels[fontLiveIndex])
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .id(Self.fontAnchorID)   // #298: re-anchor here after the relayout
            // #280: drag updates local @State (cheap — only this row + the
            // preview re-render); the app-wide `fontSizeIndex` (and its
            // UserDefaults write + full-tree relayout) commits once, on release.
            Slider(
                value: Binding(
                    get: { fontDragIndex ?? Double(settings.fontSizeIndex) },
                    set: { fontDragIndex = $0 }
                ),
                in: 0...Double(SettingsStore.fontSizes.count - 1),
                step: 1,
                label: { Text(L10n.fontSizeLabel.localized()) },
                minimumValueLabel: { Text("A").font(.caption2) },
                maximumValueLabel: { Text("A").font(.title3) },
                onEditingChanged: { editing in
                    if !editing {
                        if let v = fontDragIndex { settings.fontSizeIndex = Int(v.rounded()) }
                        fontDragIndex = nil
                    }
                }
            )
            // Live preview without committing: scope the dragged size to this text.
            Text(L10n.fontPreviewText.localized())
                .foregroundStyle(.secondary)
                .environment(\.dynamicTypeSize, SettingsStore.fontSizes[fontLiveIndex])
        } header: {
            // #343 was: sectionFont ("Font") — the section holds language +
            // theme + direction + font now.
            Text(L10n.appearanceLabel.localized())
        } footer: {
            Text(L10n.fontFooter.localized())
                .font(.caption2)
        }
    }

    // MARK: Diagnostics (#343 — merges the #293 IP-sources row + #285 provider)

    // #343 was: two sections (ipSourcesSection / speedProviderSection) — one
    // "Diagnostics" section now. The IP-sources footer already lives in its
    // subscreen (IPSourcesSettingsView), so only the provider footer stays.
    // The provider picker itself is unchanged (submenu, per operator decision).
    private var diagnosticsSection: some View {
        Section {
            NavigationLink {
                IPSourcesSettingsView()
            } label: {
                HStack {
                    Text(L10n.sectionIPSources.localized())
                    Spacer()
                    Text("\(settings.enabledIPSources.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Picker(L10n.sectionSpeedProvider.localized(), selection: $settings.speedTestProviderID) {
                ForEach(AppConstants.SpeedTest.providers) { p in
                    Text(p.label).tag(p.id)
                }
            }
            // #337: screenshot-safe mode — masks IPs in the Diagnostics rows
            // and on VPS cards (display-only; copy + Logs stay real). The label
            // is self-explanatory, so the section footer keeps the less obvious
            // speed-provider note (§7 one-footer rule); the full mask
            // explanation lives in the L10n table for any future detail screen.
            Toggle(L10n.maskIPsLabel.localized(), isOn: $settings.maskIPs)
        } header: {
            Text(L10n.diagnosticsTitle.localized())
        } footer: {
            Text(L10n.speedProviderFooter.localized())
                .font(.caption2)
        }
    }

    // MARK: Info

    private var infoSection: some View {
        Section {
            HStack {
                Text("olcrtc-ios")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(appVersion)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v).\(b)"
    }
}

// MARK: - IPSourcesSettingsView (#293)
//
// Dedicated sub-screen for the IP-check source checkboxes (moved out of the main
// Settings list, which #286 had crowded). Pushed from the "IP check sources" row;
// the model + default subset + empty-set fallback live in SettingsStore.

struct IPSourcesSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section {
                ForEach(AppConstants.ipCheckServices, id: \.label) { svc in
                    Toggle(isOn: Binding(
                        get: { settings.enabledIPSources.contains(svc.label) },
                        set: { on in
                            if on { settings.enabledIPSources.insert(svc.label) }
                            else  { settings.enabledIPSources.remove(svc.label) }
                        }
                    )) {
                        Text(svc.label)
                    }
                }
            } footer: {
                Text(L10n.ipSourcesFooter.localized())
                    .font(.caption2)
            }
        }
        .navigationTitle(L10n.sectionIPSources.localized())
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - DNSSettingsView (#343)
//
// DNS presets as rows (name + monospaced address + checkmark) + the free-form
// field, moved off the main Settings list into a subscreen — same pattern as
// IPSourcesSettingsView (#293). The top-level row shows the current summary.

struct DNSSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @FocusState private var fieldFocused: Bool

    /// Global presets + RU-carrier presets (labels localized). Keyed by label
    /// — values are NOT unique (Yota shares MegaFon's resolver).
    private var presets: [(label: String, value: String)] {
        AppConstants.dnsPresets.map { ($0.label, $0.value) }
            + AppConstants.ruCarrierDnsPresets.map { ($0.label.localized(), $0.value) }
    }

    var body: some View {
        Form {
            Section {
                ForEach(presets, id: \.label) { preset in
                    Button {
                        settings.dnsServer = preset.value
                    } label: {
                        HStack {
                            Text(preset.label)
                                .foregroundStyle(Theme.Palette.textPrimary)
                            Spacer()
                            Text(preset.value)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Theme.Palette.textSecondary)
                            if settings.dnsServer == preset.value {
                                Image(systemName: "checkmark")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Theme.Palette.accent)
                            }
                        }
                    }
                }
            } footer: {
                // The long explanation lives here now, off the main list (#343).
                Text(L10n.dnsFooter.localized())
                    .font(.caption2)
            }

            Section {
                TextField(L10n.dnsFreeFormPlaceholder.localized(), text: $settings.dnsServer)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(.body, design: .monospaced))
                    .focused($fieldFocused)
            }
        }
        .navigationTitle(L10n.sectionDNS.localized())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(L10n.done.localized()) { fieldFocused = false }
            }
        }
    }
}

// MARK: - BotsSettingsView (#420)
//
// Manages the bot registry: list bots (name + platform), add / edit / delete.

struct BotsSettingsView: View {
    @ObservedObject var botStore: BotStore
    @State private var editorBot: BotIdentity?
    @State private var addingNew = false

    var body: some View {
        Form {
            Section {
                if botStore.bots.isEmpty {
                    Text(L10n.botsEmptyHint.localized()).foregroundStyle(.secondary)
                } else {
                    ForEach(botStore.bots) { bot in
                        Button { editorBot = bot } label: {
                            HStack {
                                Text(bot.name).foregroundStyle(Theme.Palette.textPrimary)
                                Spacer()
                                Text(bot.platform.title).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { botStore.remove(at: $0) }
                }
            } footer: {
                Text(L10n.botsFooter.localized()).font(.caption2)
            }
        }
        .navigationTitle(L10n.sectionBots.localized())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { addingNew = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel(L10n.botAddTitle.localized())
            }
        }
        .sheet(item: $editorBot) { bot in
            BotEditorView(botStore: botStore, existing: bot)
        }
        .sheet(isPresented: $addingNew) {
            BotEditorView(botStore: botStore, existing: nil)
        }
    }
}

// MARK: - BotEditorView (#420)
//
// Add / edit one registry bot: name, platform (Telegram first, Max second), and
// token. The token field is masked and paste-only with a Copy button (no reveal).

struct BotEditorView: View {
    @ObservedObject var botStore: BotStore
    var existing: BotIdentity?

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var platform: BotPlatform = .telegram
    @State private var token = ""
    @State private var copied = false

    private var isDuplicateName: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return botStore.bots.contains {
            $0.id != existing?.id && $0.name.lowercased() == trimmed.lowercased()
        }
    }
    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isDuplicateName
    }
    private var hasAnyToken: Bool {
        !token.isEmpty || (existing.map { botStore.hasToken($0) } ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    FormField(label: L10n.botNameLabel.localized(),
                              placeholder: L10n.botNamePlaceholder.localized(), text: $name)
                    if isDuplicateName {
                        Text(L10n.botNameTakenError.localized())
                            .font(.caption).foregroundStyle(Theme.Palette.red)
                    }
                    Picker(L10n.botPlatformLabel.localized(), selection: $platform) {
                        ForEach(BotPlatform.allCases) { p in Text(p.title).tag(p) }
                    }
                }
                Section {
                    // Masked, paste-only token field — no reveal (a screenshot
                    // shows only dots). Copy retrieves it without displaying it.
                    SecureField(L10n.botTokenPlaceholder.localized(), text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if token.isEmpty {
                        Text((existing.map { botStore.hasToken($0) } ?? false)
                             ? L10n.botTokenSavedHint.localized()
                             : L10n.botTokenNoneHint.localized())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button { copyToken() } label: {
                        Label(copied ? L10n.botTokenCopied.localized()
                                     : L10n.botCopyTokenAction.localized(),
                              systemImage: "doc.on.doc")
                    }
                    .disabled(!hasAnyToken)
                } header: {
                    Text(L10n.botTokenLabel.localized())
                }
            }
            .navigationTitle(existing == nil ? L10n.botAddTitle.localized()
                                             : L10n.botEditTitle.localized())
            .navigationBarTitleDisplayMode(.inline)
            .olcSheet(confirm: L10n.save.localized(), disabled: !isValid) { save() }
            .onAppear { prefill() }
        }
    }

    private func copyToken() {
        let value = token.isEmpty ? (existing.map { botStore.token(for: $0) } ?? "") : token
        guard !value.isEmpty else { return }
        UIPasteboard.general.string = value
        copied = true
    }

    private func save() {
        var bot = existing ?? BotIdentity(name: "", platform: .telegram)
        bot.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        bot.platform = platform
        if existing == nil {
            botStore.add(bot, token: token)
        } else {
            botStore.update(bot, token: token.isEmpty ? nil : token)
        }
        dismiss()
    }

    private func prefill() {
        guard let e = existing else { return }
        name = e.name
        platform = e.platform
        // Token left blank: paste to replace, blank keeps the stored one.
    }
}

// #340: both appearance variants.
#if DEBUG
#Preview("Settings — Dark") {
    SettingsView(tunnel: TunnelManager(), botStore: BotStore()).preferredColorScheme(.dark)
}
#Preview("Settings — Light") {
    SettingsView(tunnel: TunnelManager(), botStore: BotStore()).preferredColorScheme(.light)
}
#endif
