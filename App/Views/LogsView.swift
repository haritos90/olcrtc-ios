import SwiftUI

// #276/#277/#278: the Logs tab is one merged, chronological stream instead of
// per-category tabs. Each line is tagged with its source ([Connection], [VPS],
// [Container]…) and colour-coded by severity (#276); timestamps are dated and
// newest-first (#277); and container logs can be pulled / refreshed straight
// from here once a host has been targeted (#278). A single attributed `Text`
// keeps rendering cheap (one layout region, system-handled wrapping/selection)
// while still allowing per-line colour.

struct LogsView: View {
    @ObservedObject private var store = LogStore.shared
    @ObservedObject private var serverStore: ServerHostStore
    @StateObject  private var provisioner = Provisioner()

    /// Whether the Logs tab is the visible `TabView` selection. The merged-stream
    /// rebuild is expensive and `LogStore.revision` bumps on *every* log line, so
    /// we only rebuild while on-screen — `TabView` keeps off-screen tabs alive, so
    /// without this the stream pointlessly re-sorts + re-renders in the background
    /// during a log storm on another tab. (#290 will further debounce bursts while
    /// the tab is open.)
    let isActive: Bool

    /// `nil` = all sources (the merged default); otherwise a single category.
    @State private var filter: LogCategory? = nil
    @State private var searchText = ""
    @State private var cachedAttributed = AttributedString()
    @State private var cachedPlain = ""
    @State private var fetching = false

    init(serverStore: ServerHostStore, isActive: Bool) {
        _serverStore = ObservedObject(wrappedValue: serverStore)
        self.isActive = isActive
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerRow
                logContent
            }
            .navigationTitle(L10n.logsTitle.localized())
            .searchable(text: $searchText,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: L10n.logsSearchPlaceholder.localized())
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    OlcOverflowMenu(items: [
                        .share(L10n.shareAction.localized(), systemImage: "square.and.arrow.up", item: cachedPlain),
                        .action(L10n.copyAllAction.localized(), systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = cachedPlain
                        },
                        .divider,
                        clearItem,
                    ])
                    .disabled(cachedPlain.isEmpty)
                }
            }
            .onAppear { refreshCache() }
            // Only rebuild on new log lines while the tab is on-screen (the gate).
            .onChange(of: store.revision) { if isActive { refreshCache() } }
            // Catch up once when the tab becomes visible after off-screen activity.
            .onChange(of: isActive) { if isActive { refreshCache() } }
            // filter / search only change via on-tab interaction, so they're never
            // off-screen — no gate needed.
            .onChange(of: filter) { refreshCache() }
            .onChange(of: searchText) { refreshCache() }
        }
    }

    // MARK: Header (source filter + container refresh)

    private var headerRow: some View {
        HStack(spacing: 12) {
            Menu {
                Button { filter = nil } label: { filterRow(L10n.logsAllSources.localized(), active: filter == nil) }
                Divider()
                ForEach(LogCategory.allCases) { cat in
                    Button { filter = cat } label: { filterRow(cat.title, active: filter == cat) }
                }
            } label: {
                Label(filter?.title ?? L10n.logsAllSources.localized(),
                      systemImage: "line.3.horizontal.decrease.circle")
                    .font(.subheadline)
            }
            .accessibilityLabel(L10n.logsSourceLabel.localized())

            Spacer()

            // #278: once a container has been targeted (via the server card or a
            // previous pull) the same fetch is one tap away here.
            if containerTarget != nil, filter == nil || filter == .containerLogs {
                Button(action: refreshContainerLogs) {
                    if fetching {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(L10n.logsRefreshFromServer.localized(), systemImage: "arrow.clockwise")
                            .font(.subheadline)
                    }
                }
                .disabled(fetching)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func filterRow(_ title: String, active: Bool) -> some View {
        if active { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    // MARK: Log content

    @ViewBuilder
    private var logContent: some View {
        if cachedPlain.isEmpty {
            let isSearching = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            OlcEmptyState(
                systemImage: isSearching ? "magnifyingglass" : (filter?.systemImage ?? "doc.text"),
                title: isSearching ? L10n.noSearchResults.localized() : L10n.emptyLogsGeneric.localized(),
                hint: isSearching
                      ? L10n.noSearchResultsHint_fmt.formatted(searchText)
                      : L10n.emptyLogsGenericHint.localized()
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Newest-first (#277): the freshest line sits at the top, so the view
            // opens on what just happened and never snaps away from where the
            // user scrolled — no forced scroll-to-bottom.
            ScrollView {
                Text(cachedAttributed)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }

    // MARK: Cache build

    /// Rebuilds the rendered stream + the plain-text export from the current
    /// filter/search. The merged entries are already sorted; we walk them
    /// newest-first and colour each line by its inferred severity.
    private func refreshCache() {
        let items = mergedFiltered
        var attr = AttributedString()
        var plain = ""
        for e in items {
            let ts = LogStore.format(date: e.date)
            let badge = e.category.title

            var stamp = AttributedString("\(ts)  ")
            stamp.foregroundColor = Theme.Palette.textTertiary
            var tag = AttributedString("[\(badge)] ")
            tag.foregroundColor = Theme.Palette.textTertiary
            var msg = AttributedString("\(e.text)\n")
            msg.foregroundColor = tint(e.level)

            attr.append(stamp)
            attr.append(tag)
            attr.append(msg)

            plain += "\(ts) [\(badge)] \(e.text)\n"
        }
        cachedAttributed = attr
        cachedPlain = plain
    }

    private var mergedFiltered: [LogEntry] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.merged.reversed().filter { e in
            if let f = filter, e.category != f { return false }
            if q.isEmpty { return true }
            return e.text.localizedStandardContains(q)
                || e.category.title.localizedStandardContains(q)
                || LogStore.format(date: e.date).localizedStandardContains(q)
        }
    }

    private func tint(_ level: LogLineLevel) -> Color {
        switch level {
        case .error: return Theme.Palette.red
        case .warn:  return Theme.Palette.orange
        case .info:  return Theme.Palette.textSecondary
        case .debug: return Theme.Palette.textTertiary
        }
    }

    private var clearItem: OlcMenuItem {
        if let f = filter {
            return .action(L10n.clearCategoryAction.localized(), systemImage: "trash", role: .destructive) {
                LogStore.shared.clear(category: f)
            }
        }
        return .action(L10n.clearAllLogsAction.localized(), systemImage: "trash", role: .destructive) {
            LogStore.shared.clearAll()
        }
    }

    // MARK: Container-log refresh (#278)

    private var containerTarget: (host: ServerHost, name: String)? {
        guard let t = store.lastContainerTarget,
              let h = serverStore.hosts.first(where: { $0.id == t.hostID }) else { return nil }
        return (h, t.containerName)
    }

    private func refreshContainerLogs() {
        guard let t = containerTarget, let pw = serverStore.password(for: t.host) else { return }
        fetching = true
        Task {
            defer { fetching = false }
            _ = try? await provisioner.containerLogs(
                on: t.host, password: pw,
                containerName: t.name,
                tail: SettingsStore.shared.containerLogsTailLines)
        }
    }
}
