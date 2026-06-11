import SwiftUI

// #294: the Logs tab is back to per-source tabs (Connection / Diagnostics /
// VPS / Container) — the merged single-stream view (#276/#289/#290) mixed
// unrelated sources into one pile that wasn't useful. Per-line wins from the
// merge are kept: severity colour-coding (#276), dated newest-first
// timestamps (#277), and in-tab container download/refresh (#278).
//
// #289 was: a `selectedTab == 3`-driven `isActive` flag gated an expensive
// merged-stream rebuild (sort + AttributedString over ALL categories) so it
// only ran while the Logs tab was on-screen. With per-source tabs each tab
// only ever rebuilds its own (much smaller) category buffer, and SwiftUI's
// `TabView` already avoids rendering off-screen tab content — so the
// dedicated visibility-gate plumbing is no longer worth the complexity. We
// keep `isActive` as a courtesy (still passed from App.swift) but it is no
// longer used here; there's no separate "cache" left to suppress rebuilding.

struct LogsView: View {
    @ObservedObject private var serverStore: ServerHostStore

    /// #289 was: drove the merged-stream rebuild gate; see file header for why
    /// per-source tabs no longer need it. Kept as an unused parameter so
    /// App.swift's call site doesn't need a special case.
    let isActive: Bool

    @State private var selection: LogCategory = .connection

    init(serverStore: ServerHostStore, isActive: Bool) {
        _serverStore = ObservedObject(wrappedValue: serverStore)
        self.isActive = isActive
    }

    var body: some View {
        TabView(selection: $selection) {
            LogCategoryTabView(category: .connection)
                .tabItem { Label(LogCategory.connection.title, systemImage: LogCategory.connection.systemImage) }
                .tag(LogCategory.connection)

            LogCategoryTabView(category: .diagnostics)
                .tabItem { Label(LogCategory.diagnostics.title, systemImage: LogCategory.diagnostics.systemImage) }
                .tag(LogCategory.diagnostics)

            LogCategoryTabView(category: .provisioning)
                .tabItem { Label(LogCategory.provisioning.title, systemImage: LogCategory.provisioning.systemImage) }
                .tag(LogCategory.provisioning)

            ContainerLogsTabView(serverStore: serverStore)
                .tabItem { Label(LogCategory.containerLogs.title, systemImage: LogCategory.containerLogs.systemImage) }
                .tag(LogCategory.containerLogs)
        }
    }
}

// MARK: - Shared rendering helpers

/// Newest-first (#277), colour-coded (#276) rendering of a list of `LogEntry`
/// plus the matching plain-text export, filtered by `searchText`.
@MainActor
enum LogRendering {
    static func filtered(_ entries: [LogEntry], search: String) -> [LogEntry] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let ordered = entries.reversed()
        guard !q.isEmpty else { return Array(ordered) }
        return ordered.filter { e in
            e.text.localizedStandardContains(q)
                || LogStore.format(date: e.date).localizedStandardContains(q)
        }
    }

    static func attributed(_ entries: [LogEntry]) -> AttributedString {
        var attr = AttributedString()
        for e in entries {
            let ts = LogStore.format(date: e.date)
            var stamp = AttributedString("\(ts)  ")
            stamp.foregroundColor = Theme.Palette.textTertiary
            var msg = AttributedString("\(e.text)\n")
            msg.foregroundColor = tint(e.level)
            attr.append(stamp)
            attr.append(msg)
        }
        return attr
    }

    static func plain(_ entries: [LogEntry]) -> String {
        entries.map { "\(LogStore.format(date: $0.date)) \($0.text)" }.joined(separator: "\n")
    }

    static func tint(_ level: LogLineLevel) -> Color {
        switch level {
        case .error: return Theme.Palette.red
        case .warn:  return Theme.Palette.orange
        case .info:  return Theme.Palette.textSecondary
        case .debug: return Theme.Palette.textTertiary
        }
    }
}

/// The scrollable log body shared by every tab: empty state, search results
/// empty state, or the colour-coded newest-first text.
struct LogBodyView: View {
    let entries: [LogEntry]
    let searchText: String
    let emptySystemImage: String
    let emptyTitle: String
    let emptyHint: String

    var body: some View {
        let items = LogRendering.filtered(entries, search: searchText)
        if items.isEmpty {
            let isSearching = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            OlcEmptyState(
                systemImage: isSearching ? "magnifyingglass" : emptySystemImage,
                title: isSearching ? L10n.noSearchResults.localized() : emptyTitle,
                hint: isSearching
                      ? L10n.noSearchResultsHint_fmt.formatted(searchText)
                      : emptyHint
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                Text(LogRendering.attributed(items))
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }
}

/// Short description + backing-file-name header shown at the top of every tab
/// (#294).
struct LogTabHeader: View {
    let description: String
    let fileName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(description)
                .font(.subheadline)
                .foregroundStyle(Theme.Palette.textSecondary)
            Text(L10n.logsFileNameLabel_fmt.formatted(fileName))
                .font(.caption2)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.top, 8)
    }
}

// MARK: - Connection / Diagnostics / VPS tabs

/// A simple per-category tab: description + file name header, search, and the
/// colour-coded newest-first content. Connection/Diagnostics/VPS only —
/// Container has its own view (`ContainerLogsTabView`) since #295 made it
/// per-server.
struct LogCategoryTabView: View {
    let category: LogCategory
    @ObservedObject private var store = LogStore.shared
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                LogTabHeader(description: category.tabDescription,
                             fileName: category.logFileName)
                LogBodyView(
                    entries: store.entries[category] ?? [],
                    searchText: searchText,
                    emptySystemImage: category.systemImage,
                    emptyTitle: L10n.emptyLogsGeneric.localized(),
                    emptyHint: L10n.emptyLogsGenericHint.localized()
                )
            }
            .navigationTitle(category.title)
            .searchable(text: $searchText,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: L10n.logsSearchPlaceholder.localized())
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    let plain = LogRendering.plain((store.entries[category] ?? []).reversed())
                    OlcOverflowMenu(items: [
                        .share(L10n.shareAction.localized(), systemImage: "square.and.arrow.up", item: plain),
                        .action(L10n.copyAllAction.localized(), systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = plain
                        },
                        .divider,
                        .action(L10n.clearCategoryAction.localized(), systemImage: "trash", role: .destructive) {
                            LogStore.shared.clear(category: category)
                        },
                    ])
                    .disabled((store.entries[category] ?? []).isEmpty)
                }
            }
        }
    }
}

// MARK: - Container tab (#294/#295/#296)

/// The Container tab shows one server's `<serverPrefix>_container.log` at a
/// time. #295: server selection drives which per-server buffer/file is
/// displayed. #296: a "Download logs from server" / "Check server" button is
/// always present, even when the buffer is empty.
struct ContainerLogsTabView: View {
    @ObservedObject private var serverStore: ServerHostStore
    @ObservedObject private var store = LogStore.shared
    @StateObject private var provisioner = Provisioner()

    @State private var searchText = ""
    @State private var selectedHostID: UUID?
    @State private var fetching = false

    init(serverStore: ServerHostStore) {
        _serverStore = ObservedObject(wrappedValue: serverStore)
    }

    /// The host whose container log is shown: the explicit selection, falling
    /// back to the last-fetched target (#278), falling back to the first
    /// configured host.
    private var selectedHost: ServerHost? {
        if let id = selectedHostID, let h = serverStore.hosts.first(where: { $0.id == id }) {
            return h
        }
        if let target = store.lastContainerTarget,
           let h = serverStore.hosts.first(where: { $0.id == target.hostID }) {
            return h
        }
        return serverStore.hosts.first
    }

    private var entries: [LogEntry] {
        guard let host = selectedHost else { return [] }
        return store.containerEntries[host.logFilePrefix] ?? []
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                LogTabHeader(description: LogCategory.containerLogs.tabDescription,
                             fileName: fileNameLabel)
                if serverStore.hosts.count > 1 {
                    serverPicker
                }
                downloadBar
                LogBodyView(
                    entries: entries,
                    searchText: searchText,
                    emptySystemImage: LogCategory.containerLogs.systemImage,
                    emptyTitle: L10n.emptyLogsGeneric.localized(),
                    emptyHint: L10n.logsContainerEmptyHint.localized()
                )
            }
            .navigationTitle(LogCategory.containerLogs.title)
            .searchable(text: $searchText,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: L10n.logsSearchPlaceholder.localized())
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    let plain = LogRendering.plain(entries.reversed())
                    OlcOverflowMenu(items: [
                        .share(L10n.shareAction.localized(), systemImage: "square.and.arrow.up", item: plain),
                        .action(L10n.copyAllAction.localized(), systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = plain
                        },
                        .divider,
                        .action(L10n.clearCategoryAction.localized(), systemImage: "trash", role: .destructive) {
                            if let host = selectedHost {
                                LogStore.shared.clearContainer(serverPrefix: host.logFilePrefix)
                            }
                        },
                    ])
                    .disabled(entries.isEmpty)
                }
            }
        }
    }

    private var fileNameLabel: String {
        guard let host = selectedHost else { return "—_container.log" }
        return "\(host.logFilePrefix)_container.log"
    }

    @ViewBuilder
    private var serverPicker: some View {
        Picker(L10n.logsContainerSelectServer.localized(), selection: Binding(
            get: { selectedHost?.id },
            set: { selectedHostID = $0 }
        )) {
            ForEach(serverStore.hosts) { host in
                Text(host.label).tag(Optional(host.id))
            }
        }
        .pickerStyle(.menu)
        .padding(.horizontal)
        .padding(.top, 4)
    }

    /// #296: always-present action — "Download logs from server" once the
    /// host's connection is established (it has a known container), otherwise
    /// "Check server" (mirrors the Manage VPS card's readiness check, run
    /// first). Hidden only when there's no server configured at all.
    @ViewBuilder
    private var downloadBar: some View {
        if let host = selectedHost {
            HStack {
                Spacer()
                Button(action: { Task { await primaryAction(host) } }) {
                    if fetching {
                        ProgressView().controlSize(.small)
                    } else if host.lastContainerName == nil {
                        Label(L10n.logsCheckServer.localized(), systemImage: "antenna.radiowaves.left.and.right")
                            .font(.subheadline)
                    } else {
                        Label(L10n.logsDownloadFromServer.localized(), systemImage: "arrow.down.doc")
                            .font(.subheadline)
                    }
                }
                .disabled(fetching)
            }
            .padding(.horizontal)
            .padding(.top, 8)
        } else {
            HStack {
                Spacer()
                Text(L10n.logsContainerNoServers.localized())
                    .font(.subheadline)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
    }

    /// #296: the button never blocks the UI — it kicks off a `Task` and
    /// returns immediately; `fetching` drives the spinner. The SSH calls
    /// inside `Provisioner` are themselves `async`/non-blocking (full
    /// freeze-on-unchecked-host fix is #297's territory).
    private func primaryAction(_ host: ServerHost) async {
        guard let pw = serverStore.password(for: host) else { return }
        fetching = true
        defer { fetching = false }

        var target = host
        if target.lastContainerName == nil {
            // "Check server": run the readiness probe first (mirrors the
            // Manage VPS card's "Check server"), then adopt any container it
            // finds so a subsequent tap can download logs directly.
            if let (state, _) = try? await provisioner.probeReadiness(
                on: target, password: pw, containerName: nil) {
                switch state {
                case .containerRunning(let name), .containerStopped(let name):
                    target.lastContainerName = name
                    serverStore.update(target, password: nil)
                default:
                    break
                }
            }
        }

        guard let cname = target.lastContainerName else { return }
        _ = try? await provisioner.containerLogs(
            on: target, password: pw, containerName: cname,
            tail: SettingsStore.shared.containerLogsTailLines)
    }
}
