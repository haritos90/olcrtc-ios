import SwiftUI

// MARK: - ServersView
//
// Third tab. Manages SSH credentials for VPS hosts where we can install /
// uninstall olcrtc, plus triggers those operations from the device.
//
// #258: SINGLE-SOURCE display model (replaces the old dual-source
// `statusIconInfo`, which read `provisioner.status` + per-host `readiness`
// together and wrote optimistic base states mid-flight — the cause of the
// "status jumps"). A host now shows exactly ONE of:
//   • .base(HostBase)            — what the server IS; set ONLY by a confirmed probe
//   • .running(op, phase, note)  — what we're DOING; steady amber, phases advance
//                                  forward only, never touches base state
//   • .failed(op, phase, msg)    — an op threw; shown over the last base, with Retry
// The dot stays amber for the whole operation and changes colour exactly once,
// at the terminal probe result (`.animation(.easeInOut, value: display)`).
//
// Status / phase strings here are hardcoded English to match this file's existing
// convention (the old statusIconInfo did the same); menu/action labels reuse the
// existing L10n cases. Promoting these to L10n is a separate cleanup.

struct ServersView: View {
    @ObservedObject var serverStore: ServerHostStore
    @ObservedObject var connections: ConnectionStore
    /// Per-tab lifecycle, NOT a shared singleton — intentional split from
    /// `TunnelManager.shared` / `SettingsStore.shared` / `LogStore.shared`.
    @StateObject  private var provisioner = Provisioner()

    @State private var showAdd        = false
    @State private var editHost       : ServerHost?
    @State private var installFor     : ServerHost?
    @State private var reconfigureFor : ServerHost?
    @State private var logsPayload    : ContainerLogsPayload?
    // #258 was: readiness[id] + activeHostID (two competing display sources).
    // Now a single per-host display state; base is only ever set from a probe.
    @State private var display        : [UUID: HostDisplay] = [:]
    @State private var vpsStats       : [UUID: SSHRunner.VPSStats] = [:]
    @State private var pingLatencies  : [UUID: Double?] = [:]   // ms, nil=unreachable, absent=not pinged
    @State private var scanFor        : ServerHost?
    @State private var foundContainers: [SSHRunner.FoundContainer] = []
    @State private var alertText           : String?
    @State private var removeHost          : ServerHost?
    @State private var uninstallConfirmHost    : ServerHost?
    @State private var deepUninstallConfirmHost: ServerHost?
    @State private var rebootConfirmHost       : ServerHost?
    @State private var pingTimer       : Timer?

    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        NavigationStack {
            List {
                matrixSection

                if serverStore.hosts.isEmpty {
                    emptyState
                } else {
                    ForEach(serverStore.hosts) { host in
                        hostCard(host)
                    }
                    .onDelete { serverStore.remove(at: $0) }
                }
            }
            .navigationTitle(L10n.serversTitle.localized())
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .onAppear { startAutoPingIfNeeded() }
            .onDisappear { pingTimer?.invalidate(); pingTimer = nil }
            // #258: route the provisioner's progress stream into the running host's
            // phase/subtitle ONLY — never the base state or the dot colour.
            .onChange(of: provisioner.status) { _, status in
                guard case .running(let msg) = status else { return }
                advancePhase(note: msg)
            }
            .sheet(isPresented: $showAdd) {
                AddServerHostView { host, pw in
                    serverStore.add(host, password: pw)
                }
            }
            .sheet(item: $editHost) { host in
                AddServerHostView(existing: host,
                                  existingPassword: serverStore.password(for: host)) { updated, pw in
                    serverStore.update(updated, password: pw.isEmpty ? nil : pw)
                }
            }
            .sheet(item: $installFor) { host in
                InstallOptionsView { options in
                    Task { await install(host, options: options) }
                }
            }
            .sheet(item: $reconfigureFor) { host in
                ReconfigureOptionsView { options in
                    Task { await reconfigure(host, options: options) }
                }
            }
            .sheet(item: $logsPayload) { payload in
                ContainerLogsView(payload: payload)
            }
            .sheet(item: $scanFor) { host in
                containerScanSheet(host: host)
            }
            .alert(L10n.okPrompt.localized(), isPresented: Binding(
                get: { alertText != nil },
                set: { if !$0 { alertText = nil } }
            )) {
                Button(L10n.ok.localized()) { alertText = nil }
            } message: {
                Text(alertText ?? "")
            }
            .confirmationDialog(
                removeHost.map { L10n.removeHostConfirmTitle.formatted($0.label) } ?? "",
                isPresented: Binding(
                    get: { removeHost != nil },
                    set: { if !$0 { removeHost = nil } }
                ),
                titleVisibility: .visible,
                presenting: removeHost
            ) { host in
                Button(L10n.actionRemoveFromList.localized(), role: .destructive) {
                    removeFromList(host)
                    removeHost = nil
                }
                Button(L10n.cancel.localized(), role: .cancel) { removeHost = nil }
            } message: { _ in
                Text(L10n.removeHostConfirmMessage.localized())
            }
            .confirmationDialog(
                L10n.uninstallConfirmTitle.localized(),
                isPresented: Binding(
                    get: { uninstallConfirmHost != nil },
                    set: { if !$0 { uninstallConfirmHost = nil } }
                ),
                titleVisibility: .visible,
                presenting: uninstallConfirmHost
            ) { host in
                Button(L10n.actionUninstall.localized(), role: .destructive) {
                    uninstallConfirmHost = nil
                    Task { await uninstall(host) }
                }
                Button(L10n.cancel.localized(), role: .cancel) { uninstallConfirmHost = nil }
            } message: { _ in
                Text(L10n.uninstallConfirmBody.localized())
            }
            .confirmationDialog(
                L10n.actionDeepUninstall.localized(),
                isPresented: Binding(
                    get: { deepUninstallConfirmHost != nil },
                    set: { if !$0 { deepUninstallConfirmHost = nil } }
                ),
                titleVisibility: .visible,
                presenting: deepUninstallConfirmHost
            ) { host in
                Button(L10n.actionDeepUninstall.localized(), role: .destructive) {
                    deepUninstallConfirmHost = nil
                    Task { await deepUninstall(host, removeImage: false) }
                }
                Button(L10n.cancel.localized(), role: .cancel) { deepUninstallConfirmHost = nil }
            } message: { _ in
                Text(L10n.deepUninstallConfirmBody.localized())
            }
            .confirmationDialog(
                L10n.rebootConfirmTitle.localized(),
                isPresented: Binding(
                    get: { rebootConfirmHost != nil },
                    set: { if !$0 { rebootConfirmHost = nil } }
                ),
                titleVisibility: .visible,
                presenting: rebootConfirmHost
            ) { host in
                Button(L10n.actionReboot.localized(), role: .destructive) {
                    rebootConfirmHost = nil
                    Task { await reboot(host) }
                }
                Button(L10n.cancel.localized(), role: .cancel) { rebootConfirmHost = nil }
            } message: { _ in
                Text(L10n.rebootConfirmBody.localized())
            }
        }
    }

    private func removeFromList(_ host: ServerHost) {
        if let idx = serverStore.hosts.firstIndex(where: { $0.id == host.id }) {
            serverStore.remove(at: IndexSet([idx]))
        }
    }

    // MARK: Compatibility matrix

    private var matrixSection: some View {
        Section {
            OlcCard { MatrixView() }
                .olcCardRow()
        } header: {
            Text(L10n.carrierTransportMatrix.localized())
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        Section {
            // #258: shared OlcEmptyState with a primary CTA (was a bare VStack).
            OlcEmptyState(systemImage: "externaldrive.connected.to.line.below",
                          title: L10n.emptyNoServers.localized(),
                          hint: L10n.emptyNoServersHint.localized(),
                          ctaTitle: L10n.newServerTitle.localized()) {
                showAdd = true
            }
            .olcCardRow()
        }
    }

    // MARK: Display-state helpers (single source of truth)

    /// The host's current display state. Before any probe, seed a conservative
    /// base from persisted data: a known container → `.stopped` (so Start/Stop and
    /// the metrics surface, and we never offer a reinstall by mistake); otherwise
    /// `.unknown` ("tap Check"). Never asserts a running container without a probe.
    private func displayState(_ host: ServerHost) -> HostDisplay {
        display[host.id] ?? .base(.seed(lastContainerName: host.lastContainerName))
    }

    /// The base under whatever is currently shown (running/failed keep the base
    /// they started from). Drives the menu / button shape.
    private func currentBase(_ host: ServerHost) -> HostBase { displayState(host).base }

    private func hasContainer(_ host: ServerHost) -> Bool { currentBase(host).hasContainer }
    private func isRunning(_ host: ServerHost)   -> Bool { currentBase(host) == .running }

    /// Any host mid-operation. Operations are serialized (one provisioner), so we
    /// disable every card's actions while one runs — this also keeps `runningHostID`
    /// unambiguous for phase routing.
    private var anyBusy: Bool { display.values.contains { $0.isRunning } }
    private var actionsDisabled: Bool { anyBusy || provisioner.status.isRunning }
    private var runningHostID: UUID? { display.first { $0.value.isRunning }?.key }

    // MARK: The ONE operation driver
    //
    // Sets `.running`, lets `work` do the SSH work + the confirming probe (the
    // ONLY thing that returns a base), then makes a SINGLE terminal assignment:
    // `.base` on success, `.failed` on throw. `work` must not write `display`.

    private func run(_ op: HostOp, on host: ServerHost,
                     _ work: @escaping (_ password: String) async throws -> HostBase?) async {
        guard !anyBusy else { return }
        let prev = currentBase(host)
        display[host.id] = .start(op, from: prev)

        guard let pw = password(for: host) else {
            withAnimation(.easeInOut(duration: 0.35)) {
                display[host.id] = HostDisplay.start(op, from: prev)
                    .failed(message: L10n.alertPasswordMissingShort.localized())
            }
            return
        }

        do {
            let resolved = try await work(pw)
            // One terminal change — the probe result is authoritative (no optimism);
            // else the op's nominal target; else keep the previous base (e.g. reboot).
            let base = HostDisplay.terminalBase(op: op, probed: resolved, previous: prev)
            withAnimation(.easeInOut(duration: 0.35)) { display[host.id] = .base(base) }
        } catch {
            let current = display[host.id] ?? .start(op, from: prev)
            withAnimation(.easeInOut(duration: 0.35)) {
                display[host.id] = current.failed(message: error.localizedDescription)
            }
        }
    }

    /// Maps a provisioner progress message onto the running host: phase forward
    /// (monotonic, capped) + subtitle = the live message. Never touches base/dot.
    private func advancePhase(note: String) {
        guard let id = runningHostID else { return }
        display[id] = display[id]?.advanced(note: note)
    }

    /// Re-runs the failed op. Returns to the previous base first, then dispatches
    /// (sheet-driven ops reopen their sheet so the user reconfirms options).
    private func retry(_ op: HostOp, on host: ServerHost) async {
        if let restored = display[host.id]?.retryBase() { display[host.id] = restored }
        switch op {
        case .check:         await checkServer(host)
        case .start:         await startContainer(host)
        case .stop:          await stop(host)
        case .update:        await update(host)
        case .reboot:        await reboot(host)
        case .install:       installFor = host
        case .reconfigure:   reconfigureFor = host
        case .uninstall:     uninstallConfirmHost = host
        case .deepUninstall: deepUninstallConfirmHost = host
        }
    }

    // MARK: Auto-ping

    private func startAutoPingIfNeeded() {
        let unpinged = serverStore.hosts.filter { pingLatencies[$0.id] == nil }
        if !unpinged.isEmpty {
            Task { for h in unpinged { await doPing(h) } }
        }
        pingTimer?.invalidate()
        guard settings.vpsAutoPingEnabled, settings.vpsAutoPingInterval > 0 else { return }
        let interval = TimeInterval(settings.vpsAutoPingInterval)
        pingTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                for h in serverStore.hosts { await doPing(h) }
            }
        }
    }

    private func doPing(_ host: ServerHost) async {
        let result = await NetPing.tcp(host: host.host, port: UInt16(host.port), timeout: 5)
        pingLatencies[host.id] = result.success ? result.ms : nil
    }

    // MARK: Host card

    private func hostCard(_ host: ServerHost) -> some View {
        let state = displayState(host)
        return Section {
            OlcCard {
                VStack(alignment: .leading, spacing: 12) {
                    // Header: label + connection + the single complete action menu
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(host.label)
                                .font(.headline)
                                .foregroundStyle(Theme.Palette.textPrimary)
                            Text("\(host.username)@\(host.host):\(String(host.port))")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                        Spacer()
                        OlcOverflowMenu(items: menuItems(host))
                            .disabled(actionsDisabled)
                    }

                    statusRegion(host, state: state)

                    // Metrics only when idle on a container-bearing base.
                    if case .base(let b) = state, b.hasContainer {
                        metricsRow(host)
                    }

                    actionBar(host, state: state)
                }
                .animation(.easeInOut(duration: 0.35), value: state)
            }
            .olcCardRow()
        }
    }

    // Status region — exactly one of: operation / error / base.
    @ViewBuilder
    private func statusRegion(_ host: ServerHost, state: HostDisplay) -> some View {
        switch state {
        case .running(let op, let phase, let note, _):
            VStack(alignment: .leading, spacing: 12) {
                OlcStatusPill(tone: .progress,
                              title: "\(op.verb)…",
                              subtitle: "\(note) · \(min(phase + 1, op.stepCount))/\(op.stepCount)") {
                    ProgressView().controlSize(.small)
                }
                ProgressView(value: Double(min(phase + 1, op.stepCount)),
                             total: Double(max(op.stepCount, 1)))
                    .tint(Theme.Palette.amber)
            }
        case .failed(let op, let phase, let message, _):
            OlcStatusPill(tone: .error,
                          title: L10n.vpsOpFailed_fmt.formatted(op.verb),
                          subtitle: "\(phase.replacingOccurrences(of: "…", with: "")) · \(message)")
        case .base(let b):
            OlcStatusPill(tone: b.tone, title: b.title, subtitle: b.subtitle)
        }
    }

    private func metricsRow(_ host: ServerHost) -> some View {
        HStack(alignment: .top, spacing: 18) {
            pingMetric(host)
            if let s = vpsStats[host.id] {
                if !s.disk.isEmpty   { OlcMetric(label: "Disk",   value: s.disk) }
                if !s.ram.isEmpty    { OlcMetric(label: "RAM",    value: s.ram) }
                if !s.uptime.isEmpty { OlcMetric(label: "Uptime", value: s.uptime) }
            }
            Spacer(minLength: 0)
        }
    }

    private func pingMetric(_ host: ServerHost) -> OlcMetric {
        switch pingLatencies[host.id] {
        case .some(.some(let ms)):
            return OlcMetric(label: "Ping", value: String(format: "%.0f ms", ms),
                             tone: ms < 100 ? Theme.Palette.green
                                 : ms < 300 ? Theme.Palette.orange : Theme.Palette.red)
        case .some(.none):
            return OlcMetric(label: "Ping", value: "✕", tone: Theme.Palette.red)
        case .none:
            return OlcMetric(label: "Ping", value: "—", tone: Theme.Palette.textTertiary)
        }
    }

    // Action bar — one contextual primary + a fixed Check secondary. Both are a
    // subset of `menuItems`; nothing here is unique to the card.
    @ViewBuilder
    private func actionBar(_ host: ServerHost, state: HostDisplay) -> some View {
        HStack(spacing: 8) {
            primaryButton(host, state: state)
            OlcButton(systemImage: "antenna.radiowaves.left.and.right", role: .secondary) {
                Task { await checkServer(host) }
            }
            .disabled(actionsDisabled)
        }
    }

    @ViewBuilder
    private func primaryButton(_ host: ServerHost, state: HostDisplay) -> some View {
        switch state {
        case .running:
            OlcButton(L10n.vpsWorking.localized(), role: .secondary, isBusy: true, fillWidth: true) {}
        case .failed(let op, _, _, _):
            OlcButton(L10n.actionRetry.localized(), systemImage: "arrow.clockwise",
                      role: .primary, fillWidth: true) {
                Task { await retry(op, on: host) }
            }
            .disabled(actionsDisabled)
        case .base(let b):
            if b.hasContainer {
                if b == .running {
                    OlcButton(L10n.actionStop.localized(), systemImage: "stop.fill",
                              role: .danger, fillWidth: true) {
                        Task { await stop(host) }
                    }
                    .disabled(actionsDisabled)
                } else {
                    OlcButton(L10n.actionStart.localized(), systemImage: "play.fill",
                              role: .primary, fillWidth: true) {
                        Task { await startContainer(host) }
                    }
                    .disabled(actionsDisabled)
                }
            } else {
                OlcButton(L10n.actionInstall.localized(), systemImage: "arrow.down.app",
                          role: .primary, fillWidth: true) {
                    installFor = host
                }
                .disabled(actionsDisabled)
            }
        }
    }

    // MARK: Overflow menu — the single COMPLETE action set
    //
    // #258: this is the source of truth. The card's primary + Check buttons are a
    // derived subset of these items (no more "MUST mirror card buttons" duplication).

    private func menuItems(_ host: ServerHost) -> [OlcMenuItem] {
        var items: [OlcMenuItem] = [
            .action(L10n.vpsCheckServer.localized(), systemImage: "antenna.radiowaves.left.and.right") {
                Task { await checkServer(host) }
            }
        ]

        if hasContainer(host) {
            if isRunning(host) {
                items.append(.action(L10n.actionStop.localized(), systemImage: "stop.fill", role: .destructive) {
                    Task { await stop(host) }
                })
            } else {
                items.append(.action(L10n.actionStart.localized(), systemImage: "play.fill") {
                    Task { await startContainer(host) }
                })
            }
            items.append(.action(L10n.actionDownloadContainerLogs.localized(), systemImage: "arrow.down.doc") {
                Task { await fetchLogs(host) }
            })
            items.append(.action(L10n.actionChangeRoomTransport.localized(), systemImage: "slider.horizontal.3") {
                reconfigureFor = host
            })
            items.append(.action(L10n.actionUpdate.localized(), systemImage: "arrow.triangle.2.circlepath") {
                Task { await update(host) }
            })
            items.append(.divider)
            items.append(.action(L10n.actionUninstall.localized(), systemImage: "trash", role: .destructive) {
                uninstallConfirmHost = host
            })
        } else {
            items.append(.action(L10n.actionInstall.localized(), systemImage: "arrow.down.app") {
                installFor = host
            })
            items.append(.action(L10n.actionScanVPS.localized(), systemImage: "magnifyingglass") {
                Task { await scanContainers(host) }
            })
        }

        // Deep uninstall whenever there's something to wipe (Podman present).
        if currentBase(host) != .noPodman {
            items.append(.action(L10n.actionDeepUninstall.localized(), systemImage: "flame", role: .destructive) {
                deepUninstallConfirmHost = host
            })
        }

        items.append(.divider)
        items.append(.action(L10n.actionReboot.localized(), systemImage: "arrow.clockwise", role: .destructive) {
            rebootConfirmHost = host
        })
        items.append(.divider)
        items.append(.action(L10n.edit.localized(), systemImage: "pencil") { editHost = host })
        items.append(.action(L10n.actionRemoveFromList.localized(), systemImage: "minus.circle", role: .destructive) {
            removeHost = host
        })
        return items
    }

    // MARK: Actions (each drives the card through `run`; the probe sets base)

    private func password(for host: ServerHost) -> String? {
        serverStore.password(for: host)
    }

    /// SSH status probe + TCP ping. The probe is the authoritative base setter.
    private func checkServer(_ host: ServerHost) async {
        Task { await doPing(host) }  // parallel TCP ping; updates the Ping metric
        await run(.check, on: host) { pw in
            let (rstate, stats) = try await provisioner.checkReadiness(
                on: host, password: pw, containerName: host.lastContainerName)
            if let stats { vpsStats[host.id] = stats }
            return HostBase(rstate)
        }
    }

    private func install(_ host: ServerHost, options: InstallOptions) async {
        await run(.install, on: host) { pw in
            let result = try await provisioner.install(on: host, password: pw, options: options)
            let cfg = try OlcrtcURI.parse(result.uri)
            let params = OlcrtcConnection(
                carrier:   cfg.carrier,
                transport: cfg.transport,
                roomID:    cfg.roomID,
                key:       cfg.key,
                clientID:  cfg.clientID
            )
            let record = ConnectionRecord(name: host.label, details: .olcrtc(params))
            connections.add(record)
            var updated = host
            updated.lastContainerName = result.containerName
            updated.lastConnectionID  = record.id
            serverStore.update(updated, password: nil)
            // #258 was: readiness[id] = .containerRunning("just installed") (optimistic).
            // Confirm the real post-install state with a probe instead.
            let (rstate, stats) = try await provisioner.probeReadiness(
                on: host, password: pw, containerName: result.containerName)
            if let stats { vpsStats[host.id] = stats }
            return HostBase(rstate)
        }
    }

    private func uninstall(_ host: ServerHost) async {
        await run(.uninstall, on: host) { pw in
            try await provisioner.uninstall(on: host, password: pw,
                                            containerName: host.lastContainerName)
            var updated = host
            updated.lastContainerName = nil
            var removedConnName: String?
            if let connID = updated.lastConnectionID {
                if SettingsStore.shared.autoRemoveConnectionOnUninstall,
                   let conn = connections.connections.first(where: { $0.id == connID }) {
                    removedConnName = conn.displayName
                    connections.remove(id: connID)
                }
                updated.lastConnectionID = nil
            }
            serverStore.update(updated, password: nil)
            if let name = removedConnName {
                LogStore.shared.log(.provisioning, "Connection «\(name)» also removed from list.")
            }
            return .imageReady   // container gone, image still cached (deterministic)
        }
    }

    private func update(_ host: ServerHost) async {
        await run(.update, on: host) { pw in
            try await provisioner.update(on: host, password: pw,
                                         containerName: host.lastContainerName)
            guard let cname = host.lastContainerName else { return nil }
            let (rstate, stats) = try await provisioner.probeReadiness(
                on: host, password: pw, containerName: cname)
            if let stats { vpsStats[host.id] = stats }
            return HostBase(rstate)
        }
    }

    private func startContainer(_ host: ServerHost) async {
        await run(.start, on: host) { pw in
            guard let cname = host.lastContainerName else {
                throw ProvisionError.parseFailed(L10n.containerNotInstalled.localized())
            }
            // #258 was: readiness[id] = .containerRunning("starting…") before the probe.
            try await provisioner.start(on: host, password: pw, containerName: cname)
            let (rstate, stats) = try await provisioner.probeReadiness(
                on: host, password: pw, containerName: cname)
            if let stats { vpsStats[host.id] = stats }
            return HostBase(rstate)
        }
    }

    private func stop(_ host: ServerHost) async {
        await run(.stop, on: host) { pw in
            guard let cname = host.lastContainerName else {
                throw ProvisionError.parseFailed(L10n.containerNotInstalled.localized())
            }
            // #258 was: readiness[id] = .containerStopped("stopping…") before the probe.
            try await provisioner.stop(on: host, password: pw, containerName: cname)
            let (rstate, stats) = try await provisioner.probeReadiness(
                on: host, password: pw, containerName: cname)
            if let stats { vpsStats[host.id] = stats }
            return HostBase(rstate)
        }
    }

    private func deepUninstall(_ host: ServerHost, removeImage: Bool) async {
        await run(.deepUninstall, on: host) { pw in
            try await provisioner.deepUninstall(on: host, password: pw,
                                                containerName: host.lastContainerName,
                                                removeImage: removeImage)
            var updated = host
            updated.lastContainerName = nil
            var removedConnName: String?
            if let connID = updated.lastConnectionID {
                if SettingsStore.shared.autoRemoveConnectionOnUninstall,
                   let conn = connections.connections.first(where: { $0.id == connID }) {
                    removedConnName = conn.displayName
                    connections.remove(id: connID)
                }
                updated.lastConnectionID = nil
            }
            serverStore.update(updated, password: nil)
            let (rstate, _) = try await provisioner.probeReadiness(
                on: host, password: pw, containerName: nil)
            if let name = removedConnName {
                LogStore.shared.log(.provisioning, "Connection «\(name)» also removed from list.")
            }
            return HostBase(rstate)
        }
    }

    private func reboot(_ host: ServerHost) async {
        await run(.reboot, on: host) { pw in
            try await provisioner.reboot(on: host, password: pw)
            return nil   // host going down; keep the previous base, user re-checks
        }
    }

    private func reconfigure(_ host: ServerHost, options: InstallOptions) async {
        await run(.reconfigure, on: host) { pw in
            guard let cname = host.lastContainerName else {
                throw ProvisionError.parseFailed(L10n.containerNotInstalled.localized())
            }
            let newURI = try await provisioner.reconfigure(on: host, password: pw,
                                                           containerName: cname, options: options)
            // Update the linked ConnectionRecord with the new room/transport.
            if let uri = newURI,
               let connID = host.lastConnectionID,
               let existing = connections.connections.first(where: { $0.id == connID }),
               case .olcrtc(let oldParams) = existing.details,
               let cfg = try? OlcrtcURI.parse(uri) {
                let updated = OlcrtcConnection(
                    carrier:      cfg.carrier,
                    transport:    cfg.transport,
                    roomID:       cfg.roomID,
                    key:          cfg.key.isEmpty ? oldParams.key : cfg.key,
                    clientID:     cfg.clientID,
                    vp8FPS:       oldParams.vp8FPS,
                    vp8BatchSize: oldParams.vp8BatchSize,
                    socksUser:    oldParams.socksUser,
                    socksPass:    oldParams.socksPass
                )
                var updatedRecord = existing
                updatedRecord.details = .olcrtc(updated)
                connections.update(updatedRecord)
            }
            let (rstate, stats) = try await provisioner.probeReadiness(
                on: host, password: pw, containerName: cname)
            if let stats { vpsStats[host.id] = stats }
            return HostBase(rstate)
        }
    }

    // MARK: Container logs / scan (no base change → outside `run`)

    private func fetchLogs(_ host: ServerHost) async {
        guard let pw = password(for: host) else {
            alertText = L10n.alertPasswordMissingShort.localized(); return
        }
        guard let cname = host.lastContainerName else {
            alertText = L10n.containerNotInstalled.localized(); return
        }
        do {
            let output = try await provisioner.containerLogs(
                on: host, password: pw, containerName: cname,
                tail: SettingsStore.shared.containerLogsTailLines)
            logsPayload = ContainerLogsPayload(containerName: cname, output: output)
        } catch {
            alertText = L10n.stateErrorPrefix_fmt.formatted(error.localizedDescription)
        }
    }

    private func scanContainers(_ host: ServerHost) async {
        guard let pw = password(for: host) else {
            alertText = L10n.alertPasswordMissingShort.localized(); return
        }
        do {
            let found = try await provisioner.scanContainers(on: host, password: pw)
            foundContainers = found
            scanFor = host
        } catch {
            alertText = L10n.stateErrorPrefix_fmt.formatted(error.localizedDescription)
        }
    }

    @ViewBuilder
    private func containerScanSheet(host: ServerHost) -> some View {
        NavigationStack {
            Group {
                if foundContainers.isEmpty {
                    Text(L10n.scanNoContainers.localized())
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    List(foundContainers) { container in
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(container.name)
                                    .font(.system(.body, design: .monospaced))
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(container.status == .notFound ? Color.secondary :
                                              container.status.shortLabel.hasPrefix("Up") ? Color.green : Color.orange)
                                        .frame(width: 8, height: 8)
                                    Text(container.status.shortLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if !container.carrier.isEmpty {
                                        Text("· \(container.carrier)/\(container.transport)")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                if !container.roomID.isEmpty {
                                    Text(L10n.roomPrefix_fmt.formatted(container.roomID))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            Button(L10n.scanRestoreAction.localized()) {
                                restoreContainer(container, on: host)
                            }
                            .buttonStyle(.bordered)
                            .tint(.accentColor)
                            .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle(L10n.actionScanVPS.localized())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.actionDone.localized()) { scanFor = nil }
                }
            }
        }
        .onDisappear { foundContainers = [] }
        .presentationDetents([.medium, .large])
    }

    private func restoreContainer(_ container: SSHRunner.FoundContainer, on host: ServerHost) {
        scanFor = nil
        var updated = host
        updated.lastContainerName = container.name
        serverStore.update(updated, password: nil)
        display[host.id] = .base(.stopped)   // container present; Check confirms run-state
        alertText = "Restored: \(container.name)"
    }
}
