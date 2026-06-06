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

    @State private var portCheck: PortCheckResult?
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

    private enum PortCheckResult: Equatable {
        case free
        case busy
        case inUseByUs  // port busy because our tunnel is using it
    }

    var body: some View {
        NavigationStack {
            Form {
                socksSection
                dnsSection
                transportSection
                connectionSection
                ipSourcesSection
                speedProviderSection
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
        }
    }

    // MARK: SOCKS

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
                let free = PortAvailability.isFree(UInt16(settings.socksPort))
                if !free && TunnelManager.socksPort == settings.socksPort {
                    portCheck = .inUseByUs
                } else {
                    portCheck = free ? .free : .busy
                }
                // #287: one L10n key per concept instead of assembling the line
                // from fragments (which drifted between code paths / languages).
                LogStore.shared.log(.connection,
                    free ? L10n.logPortFree_fmt.formatted(settings.socksPort)
                         : L10n.logPortBusy_fmt.formatted(settings.socksPort))
            } label: {
                HStack {
                    Image(systemName: "checkmark.circle")
                    Text(L10n.checkPortAction.localized())
                    Spacer()
                    if let r = portCheck {
                        switch r {
                        case .free:     Text(L10n.portFree.localized()).foregroundStyle(.green)
                        case .inUseByUs: Text(L10n.portInUseByTunnel.localized()).foregroundStyle(.green)
                        case .busy:     Text(L10n.portBusy.localized()).foregroundStyle(.red)
                        }
                    }
                }
            }
        } header: {
            Text(L10n.sectionSOCKS5.localized())
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.socksFooter.localized())
                Text(L10n.socksPortChangeNote.localized())
                    .foregroundStyle(.secondary)
            }
            .font(.caption2)
        }

        Section {
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
        } footer: {
            Text(L10n.localSocksAuthFooter.localized())
                .font(.caption2)
        }
    }

    private var dnsSection: some View {
        Section {
            // #258: one OlcChipPicker over all DNS presets (global + RU-carrier),
            // replacing two rows of differently-styled .mini buttons.
            OlcChipPicker(
                selection: $settings.dnsServer,
                options: AppConstants.dnsPresets.map { ($0.value, $0.label) }
                       + AppConstants.ruCarrierDnsPresets.map { ($0.value, $0.label.localized()) }
            )
            // Free-form field
            TextField(L10n.dnsFreeFormPlaceholder.localized(), text: $settings.dnsServer)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.system(.body, design: .monospaced))
        } header: {
            Text(L10n.sectionDNS.localized())
        } footer: {
            Text(L10n.dnsFooter.localized())
                .font(.caption2)
        }
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

    @ViewBuilder
    private var connectionSection: some View {
        Section {
            numericField(L10n.startTimeoutLabel.localized(), value: $settings.startTimeoutSeconds,
                         presets: [Preset(value: 30,  label: "30"),
                                   Preset(value: 60,  label: "60"),
                                   Preset(value: 120, label: "120")],
                         unit: "s")
        } header: {
            Text(L10n.sectionConnection.localized())
        } footer: {
            Text(L10n.footerStartTimeout.localized()).font(.caption2)
        }

        Section {
            Toggle(L10n.autoConnectOnLaunchLabel.localized(), isOn: $settings.autoConnectOnLaunch)
        } footer: {
            Text(L10n.footerAutoConnect.localized()).font(.caption2)
        }

        Section {
            Toggle(L10n.autoRemoveConnectionOnUninstallLabel.localized(), isOn: $settings.autoRemoveConnectionOnUninstall)
        } footer: {
            Text(L10n.footerAutoRemove.localized()).font(.caption2)
        }

        Section {
            numericField(L10n.tunnelCheckLabel.localized(), value: $settings.keepAliveSeconds,
                         presets: [Preset(value: 0,  label: L10n.keepAliveOff.localized()),
                                   Preset(value: 30, label: "30"),
                                   Preset(value: 60, label: "60")],
                         unit: "s")
        } header: {
            Text(L10n.sectionKeepAlive.localized())
        } footer: {
            Text(L10n.footerKeepAlive.localized()).font(.caption2)
        }

        Section {
            Toggle(L10n.backgroundAudioLabel.localized(), isOn: $settings.backgroundAudio)
        } footer: {
            Text(L10n.footerBackgroundAudio.localized()).font(.caption2)
        }

        Section {
            Picker(L10n.logLevelLabel.localized(), selection: $settings.logLevel) {
                ForEach(LogLevel.allCases, id: \.self) { level in
                    Text(level.label).tag(level)
                }
            }
        } footer: {
            Text(L10n.footerDebugLogging.localized()).font(.caption2)
        }
    }

    // MARK: Logs

    @ViewBuilder
    private var logsSection: some View {
        Section {
            numericField(L10n.logBufferLabel.localized(), value: $settings.logBufferSize,
                         presets: [Preset(value: 500,  label: "500"),
                                   Preset(value: 1000, label: "1k"),
                                   Preset(value: 5000, label: "5k")])
        } header: {
            Text(L10n.sectionLogs.localized())
        } footer: {
            Text(L10n.footerLogBuffer.localized()).font(.caption2)
        }

        Section {
            numericField(L10n.containerLogsTailLabel.localized(), value: $settings.containerLogsTailLines,
                         presets: [Preset(value: 100,  label: "100"),
                                   Preset(value: 200,  label: "200"),
                                   Preset(value: 1000, label: "1k")])
        } footer: {
            Text(L10n.footerContainerTail.localized()).font(.caption2)
        }

        Section {
            // #258: danger design-system button (was a plain destructive row).
            OlcButton(L10n.clearAllLogsAction.localized(), systemImage: "trash",
                      role: .danger, fillWidth: true) {
                LogStore.shared.clearAll()
            }
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

            // #267: design-direction picker (Refined / Console).
            Picker(L10n.themeLabel.localized(), selection: $settings.designConsole) {
                Text(L10n.themeRefined.localized()).tag(false)
                Text(L10n.themeConsole.localized()).tag(true)
            }

            HStack {
                Text(L10n.fontSizeLabel.localized())
                Spacer()
                Text(SettingsStore.fontSizeLabels[fontLiveIndex])
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
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
            Text(L10n.sectionFont.localized())
        } footer: {
            Text(L10n.fontFooter.localized())
                .font(.caption2)
        }
    }

    // MARK: IP-check sources (#286)

    @ViewBuilder
    private var ipSourcesSection: some View {
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
        } header: {
            Text(L10n.sectionIPSources.localized())
        } footer: {
            Text(L10n.ipSourcesFooter.localized())
                .font(.caption2)
        }
    }

    // MARK: Speed-test provider (#285)

    @ViewBuilder
    private var speedProviderSection: some View {
        Section {
            Picker(L10n.sectionSpeedProvider.localized(), selection: $settings.speedTestProviderID) {
                ForEach(AppConstants.SpeedTest.providers) { p in
                    Text(p.label).tag(p.id)
                }
            }
        } header: {
            Text(L10n.sectionSpeedProvider.localized())
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
