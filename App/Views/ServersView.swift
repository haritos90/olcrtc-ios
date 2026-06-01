import SwiftUI

// MARK: - ServersView
//
// Third tab. Manages SSH credentials for VPS hosts where we can install /
// uninstall olcrtc, plus triggers those operations from the device.
//
// State machine (VPSReadinessState):
//   unknown          → gray ?  — never probed (readiness[id] == nil)
//   noPodman         → gray ●  — full install ~5-7 min
//   noImage          → yellow ● — image pull ~3-5 min
//   imageReady       → green ● — fast reinstall ~1-2 min
//   containerStopped → green ■ — running but stopped
//   containerRunning → green ▶ — active
//
// Transitions:
//   Status check         → any state (probed via SSH)
//   Install              → containerRunning
//   Uninstall            → imageReady (image stays cached)
//   Start                → containerRunning (re-probed after)
//   Stop                 → containerStopped (re-probed after)
//   Reconfigure          → re-probed (container restarted, may be stopped or running)
//   deepUninstall        → noPodman or noImage
//
// Operations NEVER transition to unknown. The last known state is preserved
// while an operation is in-flight (yellow ● in-progress overlay via activeHostID).
// Unknown (gray ?) only shows if we literally have no data at all.
//
// IMPORTANT: The context menu MUST mirror the card buttons.
// Every action on the card must also appear in the menu, and vice versa.
// When adding a new action, add it to BOTH hostCard and hostMenu.

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
    @State private var readiness      : [UUID: VPSReadinessState] = [:]
    @State private var vpsStats       : [UUID: SSHRunner.VPSStats] = [:]
    @State private var pingLatencies  : [UUID: Double?] = [:]   // ms or nil=not yet pinged
    @State private var activeHostID   : UUID?                   // which host is being operated on
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
        Section(L10n.carrierTransportMatrix.localized()) {
            MatrixView()
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        Section {
            VStack(spacing: 8) {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text(L10n.emptyNoServers.localized()).font(.headline)
                Text(L10n.emptyNoServersHint.localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }

    // MARK: Server state helpers (single source of truth)

    /// Resolved state: probed readiness if available, else inferred from persisted data.
    private func serverState(_ host: ServerHost) -> VPSReadinessState {
        if let r = readiness[host.id] { return r }
        // Fallback: conservative — show stopped if container name known, image-ready otherwise.
        // Never assume running without a live SSH probe.
        return host.lastContainerName != nil ? .containerStopped("tap to check") : .imageReady
    }

    private func hasContainer(_ host: ServerHost) -> Bool {
        switch serverState(host) {
        case .containerRunning, .containerStopped: return true
        default: return false
        }
    }

    private func isRunning(_ host: ServerHost) -> Bool {
        if case .containerRunning = serverState(host) { return true }
        return false
    }

    // MARK: Status icon (shape + color)

    private struct StatusIcon {
        let systemName: String
        let color: Color
        let title: String
        let subtitle: String
        var subtitleIcon: String? = nil  // optional SF symbol shown before subtitle text
    }

    private func statusIconInfo(for host: ServerHost) -> StatusIcon {
        let hostIsActive = activeHostID == host.id
        // Not yet probed and no active operation → show neutral "unknown" state
        if readiness[host.id] == nil && !hostIsActive && !provisioner.status.isRunning {
            return StatusIcon(systemName: "questionmark.circle", color: .secondary,
                              title: "Status unknown", subtitle: "Tap to check",
                              subtitleIcon: "antenna.radiowaves.left.and.right")
        }
        if hostIsActive {
            switch provisioner.status {
            case .running(let msg):
                return StatusIcon(systemName: "circle.fill", color: .yellow, title: "In progress", subtitle: msg)
            case .failure(let msg):
                return StatusIcon(systemName: "circle.fill", color: .red, title: "Error", subtitle: msg)
            case .success(let msg):
                return StatusIcon(systemName: "circle.fill", color: .green, title: "Done", subtitle: msg)
            case .idle: break
            }
        }
        switch serverState(host) {
        case .containerRunning(let s):
            return StatusIcon(systemName: "play.fill",   color: .green,     title: "Running",          subtitle: s)
        case .containerStopped(let s):
            return StatusIcon(systemName: "stop.fill",   color: .orange,    title: "Stopped",          subtitle: s)
        case .imageReady:
            return StatusIcon(systemName: "circle.fill", color: .green,     title: "Ready to install", subtitle: "Image cached — fast reinstall")
        case .noImage:
            return StatusIcon(systemName: "circle.fill", color: .yellow,    title: "Podman ready",     subtitle: "First install pulls image (~300 MB)")
        case .noPodman:
            return StatusIcon(systemName: "circle.fill", color: .secondary, title: "Ready to install", subtitle: "Full setup ~5–7 min")
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
        let icon = statusIconInfo(for: host)
        let pingMs = pingLatencies[host.id]

        return Section {
            VStack(alignment: .leading, spacing: 10) {
                // ── Header row ──
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(host.label).font(.headline)
                        Text("\(host.username)@\(host.host):\(String(host.port))")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    hostMenu(host)
                }

                // ── Status row: icon + title + subtitle ──
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: icon.systemName)
                        .foregroundStyle(icon.color)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(icon.title).font(.subheadline).fontWeight(.medium)
                        if !icon.subtitle.isEmpty {
                            HStack(spacing: 3) {
                                if let sIcon = icon.subtitleIcon {
                                    Image(systemName: sIcon)
                                }
                                Text(icon.subtitle)
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if activeHostID == host.id && provisioner.status.isRunning {
                        ProgressView().controlSize(.small)
                    }
                }

                // ── Ping row ──
                HStack(spacing: 16) {
                    HStack(spacing: 4) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.caption2).foregroundStyle(.secondary)
                        Group {
                            if let ms = pingMs {
                                if let latency = ms {
                                    Text(String(format: "%.0f ms", latency))
                                        .foregroundStyle(latency < 100 ? .green : latency < 300 ? .orange : .red)
                                } else {
                                    Text(L10n.statusUnreachable.localized()).foregroundStyle(.red)
                                }
                            } else {
                                Text("—").foregroundStyle(.tertiary)
                            }
                        }
                        .font(.caption).monospacedDigit()
                    }

                    if let s = vpsStats[host.id] {
                        if !s.disk.isEmpty {
                            Label(s.disk, systemImage: "internaldrive")
                        }
                        if !s.ram.isEmpty {
                            Label(s.ram, systemImage: "memorychip")
                        }
                        if !s.uptime.isEmpty {
                            Label(s.uptime, systemImage: "clock")
                        }
                    }
                }
                .font(.caption2).foregroundStyle(.tertiary).labelStyle(.titleAndIcon)

                // ── Connection link ──
                if let connID = host.lastConnectionID,
                   let conn = connections.connections.first(where: { $0.id == connID }) {
                    Text(L10n.connectionLine_fmt.formatted(conn.displayName))
                        .font(.caption2).foregroundStyle(.tertiary)
                }

                // ── Action buttons (icon-only) ──
                // IMPORTANT: mirror all actions in hostMenu too.
                HStack(spacing: 8) {
                    // Check server: SSH status probe + TCP ping combined
                    iconButton("antenna.radiowaves.left.and.right", tint: .blue) {
                        Task { await checkServer(host) }
                    }
                    if !hasContainer(host) {
                        iconButton("arrow.down.app", tint: .accentColor) { installFor = host }
                        iconButton("magnifyingglass", tint: .secondary) { Task { await scanContainers(host) } }
                    } else {
                        // Play/Stop
                        iconButton(isRunning(host) ? "stop.fill" : "play.fill",
                                   tint: isRunning(host) ? .red : .green) {
                            if isRunning(host) { Task { await stop(host) } }
                            else               { Task { await startContainer(host) } }
                        }
                        // Reconfigure room/transport
                        iconButton("slider.horizontal.3", tint: .secondary) { reconfigureFor = host }
                    }
                    Spacer()
                    // Reboot (always available when SSH credentials exist)
                    iconButton("arrow.clockwise", tint: .secondary) {
                        rebootConfirmHost = host
                    }
                }
                .padding(.top, 2)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func iconButton(_ systemName: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 40, height: 34)
        }
        .buttonStyle(.bordered)
        .tint(tint)
        .controlSize(.regular)
        .disabled(provisioner.status.isRunning)
    }

    // MARK: Context menu
    //
    // IMPORTANT: MUST mirror card buttons — every action on the card must
    // also appear here, and vice versa. When adding a new action add to BOTH.

    @ViewBuilder
    private func hostMenu(_ host: ServerHost) -> some View {
        Menu {
            // Check server = SSH probe + TCP ping (mirrors card ✓ button)
            Button { Task { await checkServer(host) } } label: {
                Label("Check server", systemImage: "antenna.radiowaves.left.and.right")
            }

            if !hasContainer(host) {
                Button { installFor = host } label: {
                    Label(L10n.actionInstall.localized(), systemImage: "arrow.down.app")
                }
                Button { Task { await scanContainers(host) } } label: {
                    Label(L10n.actionScanVPS.localized(), systemImage: "magnifyingglass")
                }
            } else {
                // Start / Stop (mirrors card play/stop button)
                if isRunning(host) {
                    Button(role: .destructive) { Task { await stop(host) } } label: {
                        Label(L10n.actionStop.localized(), systemImage: "stop.fill")
                    }
                } else {
                    Button { Task { await startContainer(host) } } label: {
                        Label(L10n.actionStart.localized(), systemImage: "play.fill")
                    }
                }

                Divider()

                // Container logs via SSH (NOT the app logs tab — these come from `podman logs`)
                Button { Task { await fetchLogs(host) } } label: {
                    Label(L10n.actionLogs.localized(), systemImage: "doc.text.magnifyingglass")
                }

                Divider()

                Button { Task { await update(host) } } label: {
                    Label(L10n.actionUpdate.localized(), systemImage: "arrow.triangle.2.circlepath")
                }
                // Reconfigure room/transport (mirrors card slider button)
                Button { reconfigureFor = host } label: {
                    Label(L10n.actionChangeRoomTransport.localized(), systemImage: "slider.horizontal.3")
                }
                Button(role: .destructive) {
                    uninstallConfirmHost = host
                } label: {
                    Label(L10n.actionUninstall.localized(), systemImage: "trash")
                }
            }

            // Deep uninstall when Podman is present (has something to wipe)
            switch serverState(host) {
            case .noPodman: EmptyView()
            default:
                Button(role: .destructive) {
                    deepUninstallConfirmHost = host
                } label: {
                    Label(L10n.actionDeepUninstall.localized(), systemImage: "flame")
                }
            }

            Divider()

            // Reboot (mirrors card arrow.clockwise button)
            Button(role: .destructive) { rebootConfirmHost = host } label: {
                Label(L10n.actionReboot.localized(), systemImage: "arrow.clockwise")
            }

            Divider()

            Button { editHost = host } label: {
                Label(L10n.edit.localized(), systemImage: "pencil")
            }
            Button(role: .destructive) {
                removeHost = host
            } label: {
                Label(L10n.actionRemoveFromList.localized(), systemImage: "minus.circle")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .disabled(provisioner.status.isRunning)
    }

    private func statusColor(_ s: ContainerStatus) -> Color {
        switch s {
        case .running:  return .green
        case .stopped:  return .red
        case .notFound: return .gray
        }
    }

    // MARK: Actions

    private func password(for host: ServerHost) -> String? {
        serverStore.password(for: host)
    }

    /// Runs `op(password)` if the password exists, otherwise sets alertText.
    /// Catches thrown errors and surfaces them as alertText.
    private func withPassword(for host: ServerHost,
                               _ op: (String) async throws -> Void) async {
        guard let pw = password(for: host) else {
            alertText = L10n.alertPasswordMissingShort.localized(); return
        }
        do { try await op(pw) }
        catch { alertText = L10n.stateErrorPrefix_fmt.formatted(error.localizedDescription) }
    }

    /// Runs `op(password, containerName)` if both exist, otherwise sets alertText.
    private func withPasswordAndContainer(for host: ServerHost,
                                          _ op: (String, String) async throws -> Void) async {
        guard let pw = password(for: host) else {
            alertText = L10n.alertPasswordMissingShort.localized(); return
        }
        guard let cname = host.lastContainerName else {
            alertText = L10n.containerNotInstalled.localized(); return
        }
        do { try await op(pw, cname) }
        catch { alertText = L10n.stateErrorPrefix_fmt.formatted(error.localizedDescription) }
    }

    /// SSH status probe + TCP ping combined. Sets activeHostID so the card shows
    /// yellow in-progress; clears on completion. Does NOT nil out readiness first —
    /// the last known state stays visible during the probe.
    private func checkServer(_ host: ServerHost) async {
        activeHostID = host.id
        Task { await doPing(host) }  // ping runs in parallel, doesn't need activeHostID
        await withPassword(for: host) { pw in
            // checkReadiness sets provisioner.status = .running so the card shows
            // the yellow indicator and buttons are disabled during the probe.
            let (rstate, stats) = try await provisioner.checkReadiness(
                on: host, password: pw, containerName: host.lastContainerName)
            readiness[host.id] = rstate
            if let stats { vpsStats[host.id] = stats }
        }
        activeHostID = nil
    }

    private func install(_ host: ServerHost, options: InstallOptions) async {
        guard let pw = password(for: host) else {
            alertText = L10n.alertPasswordMissingDetail.localized(); return
        }
        activeHostID = host.id
        do {
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
            readiness[host.id] = .containerRunning("just installed")
        } catch {
            alertText = L10n.stateErrorPrefix_fmt.formatted(error.localizedDescription)
        }
        activeHostID = nil
    }

    private func uninstall(_ host: ServerHost) async {
        activeHostID = host.id
        await withPassword(for: host) { pw in
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
            readiness[host.id] = .imageReady  // container gone, image still cached
            if let name = removedConnName {
                LogStore.shared.log(.provisioning, "Connection «\(name)» also removed from list.")
            }
        }
        activeHostID = nil
    }

    private func fetchLogs(_ host: ServerHost) async {
        activeHostID = host.id
        await withPasswordAndContainer(for: host) { pw, cname in
            let output = try await provisioner.containerLogs(
                on: host, password: pw, containerName: cname,
                tail: SettingsStore.shared.containerLogsTailLines)
            logsPayload = ContainerLogsPayload(containerName: cname, output: output)
        }
        activeHostID = nil
    }

    private func update(_ host: ServerHost) async {
        activeHostID = host.id
        await withPassword(for: host) { pw in
            try await provisioner.update(on: host, password: pw,
                                         containerName: host.lastContainerName)
        }
        activeHostID = nil
    }

    private func startContainer(_ host: ServerHost) async {
        activeHostID = host.id
        // Keep existing readiness; activeHostID shows yellow in-progress overlay.
        // After success, set optimistic state then confirm with probe.
        await withPasswordAndContainer(for: host) { pw, cname in
            try await provisioner.start(on: host, password: pw, containerName: cname)
            readiness[host.id] = .containerRunning("starting…")
            let (rstate, stats) = try await provisioner.probeReadiness(
                on: host, password: pw, containerName: cname)
            readiness[host.id] = rstate
            if let stats { vpsStats[host.id] = stats }
        }
        activeHostID = nil
    }

    private func stop(_ host: ServerHost) async {
        activeHostID = host.id
        await withPasswordAndContainer(for: host) { pw, cname in
            try await provisioner.stop(on: host, password: pw, containerName: cname)
            readiness[host.id] = .containerStopped("stopping…")
            let (rstate, stats) = try await provisioner.probeReadiness(
                on: host, password: pw, containerName: cname)
            readiness[host.id] = rstate
            if let stats { vpsStats[host.id] = stats }
        }
        activeHostID = nil
    }

    private func deepUninstall(_ host: ServerHost, removeImage: Bool) async {
        activeHostID = host.id
        await withPassword(for: host) { pw in
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
            // After deep uninstall, probe to see if podman/image remain
            let (rstate, _) = try await provisioner.probeReadiness(on: host, password: pw, containerName: nil)
            readiness[host.id] = rstate
            if let name = removedConnName {
                LogStore.shared.log(.provisioning, "Connection «\(name)» also removed from list.")
            }
        }
        activeHostID = nil
    }

    private func reboot(_ host: ServerHost) async {
        activeHostID = host.id
        await withPassword(for: host) { pw in
            try await provisioner.reboot(on: host, password: pw)
        }
        activeHostID = nil
    }

    private func reconfigure(_ host: ServerHost, options: InstallOptions) async {
        activeHostID = host.id
        // Keep existing readiness during op; probe after to get confirmed state.
        await withPasswordAndContainer(for: host) { pw, cname in
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
            // Probe actual state — reconfigure stops+recreates container, it may
            // be running (if room is valid) or stopped (if it exited immediately).
            let (rstate, stats) = try await provisioner.probeReadiness(
                on: host, password: pw, containerName: cname)
            readiness[host.id] = rstate
            if let stats { vpsStats[host.id] = stats }
        }
        activeHostID = nil
    }

    // MARK: Scan for existing containers

    private func scanContainers(_ host: ServerHost) async {
        activeHostID = host.id
        await withPassword(for: host) { pw in
            let found = try await provisioner.scanContainers(on: host, password: pw)
            foundContainers = found
            scanFor = host
        }
        activeHostID = nil
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
        alertText = "Restored: \(container.name)"
    }
}

// MARK: - VPSReadinessState helpers

private extension VPSReadinessState {
    /// The container label string for .containerRunning / .containerStopped, empty otherwise.
    var containerLabel: String {
        switch self {
        case .containerRunning(let s), .containerStopped(let s): return s
        default: return ""
        }
    }
}
